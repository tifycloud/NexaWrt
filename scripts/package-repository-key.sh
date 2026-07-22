#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lock-file-policy.sh
source "$ROOT_DIR/scripts/lock-file-policy.sh"

fail() { echo "Package repository key policy refused: $*" >&2; exit 1; }
hash_public_der() {
  openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

nexawrt_validate_lock_file "$ROOT_DIR/manifests/package-repository.lock" package-repository
# shellcheck source=../manifests/package-repository.lock
source "$ROOT_DIR/manifests/package-repository.lock"
PUBLIC_KEY="$ROOT_DIR/manifests/package-repository-public.pem"

validate_public() {
  [[ -f "$PUBLIC_KEY" && ! -L "$PUBLIC_KEY" ]] || fail "public key is missing or unsafe"
  [[ "$(stat -c '%h' "$PUBLIC_KEY" 2>/dev/null || stat -f '%l' "$PUBLIC_KEY")" == 1 ]] ||
    fail "public key must have one hard link"
  local actual
  actual="$(hash_public_der "$PUBLIC_KEY")" || fail "public key is not valid P-256 PEM"
  [[ "$actual" == "$NEXAWRT_REPOSITORY_PUBLIC_SHA256" ]] || fail "public key hash differs from lock"
  openssl pkey -pubin -in "$PUBLIC_KEY" -text -noout 2>/dev/null | grep -Eq 'ASN1 OID: prime256v1|NIST CURVE: P-256' ||
    fail "public key must use P-256"
}

validate_private() {
  local private_key="$1" canonical mode links derived tmp
  [[ "$private_key" == /* ]] || fail "private key path must be absolute"
  canonical="$(python3 -I - "$private_key" <<'PY'
import os, pathlib, stat, sys
raw = pathlib.Path(sys.argv[1])
absolute = pathlib.Path(os.path.abspath(raw))
if raw != absolute:
    raise SystemExit("private key path must be canonical")
current = pathlib.Path(absolute.anchor)
for part in absolute.parts[1:]:
    current /= part
    mode = current.lstat().st_mode
    if stat.S_ISLNK(mode):
        raise SystemExit("private key path contains symlink")
    if current != absolute and not stat.S_ISDIR(mode):
        raise SystemExit("private key parent is not a directory")
st = absolute.stat()
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1:
    raise SystemExit("private key file metadata is unsafe")
if st.st_mode & 0o077:
    raise SystemExit("private key permissions must be 0600 or stricter")
print(absolute)
PY
)" || fail "private key path or permissions are unsafe"
  mode="$(stat -c '%a' "$canonical" 2>/dev/null || stat -f '%Lp' "$canonical")"
  links="$(stat -c '%h' "$canonical" 2>/dev/null || stat -f '%l' "$canonical")"
  [[ "$mode" == 600 || "$mode" == 400 ]] || fail "private key permissions must be 0600 or 0400"
  [[ "$links" == 1 ]] || fail "private key must have one hard link"
  openssl ec -in "$canonical" -text -noout 2>/dev/null | grep -Eq 'ASN1 OID: prime256v1|NIST CURVE: P-256' ||
    fail "private key must be a valid P-256 EC key"
  tmp="$(mktemp "${TMPDIR:-/tmp}/nexawrt-repository-public.XXXXXX")" || fail "cannot create temporary public key"
  trap 'rm -f -- "$tmp"' RETURN
  openssl ec -in "$canonical" -pubout -out "$tmp" >/dev/null 2>&1 || fail "cannot derive repository public key"
  derived="$(hash_public_der "$tmp")" || fail "cannot hash derived public key"
  [[ "$derived" == "$NEXAWRT_REPOSITORY_PUBLIC_SHA256" ]] || fail "private key does not match the locked public key"
  trap - RETURN
  rm -f -- "$tmp"
}

case "${1:-}" in
  public)
    [[ $# -eq 1 ]] || fail "public takes no path"
    validate_public
    ;;
  private)
    [[ $# -eq 2 ]] || fail "private requires one absolute key path"
    validate_public
    validate_private "$2"
    ;;
  *) fail "usage: $0 public | private ABSOLUTE_KEY_PATH" ;;
esac
