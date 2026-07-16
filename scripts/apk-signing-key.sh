#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lock-file-policy.sh
source "$ROOT_DIR/scripts/lock-file-policy.sh"

fail() { echo "APK signing policy refused: $*" >&2; exit 1; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi; }

load_lock() {
  nexawrt_validate_lock_file "$ROOT_DIR/manifests/apk-signing.lock" apk-signing || fail "invalid signing trust lock"
  # shellcheck source=../manifests/apk-signing.lock
  source "$ROOT_DIR/manifests/apk-signing.lock"
}

validate_profile_hash_policy() {
  local profile="$1" public_sha256="$2"
  [[ "$public_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "public key SHA-256 must be 64 lowercase hexadecimal characters"
  case "$profile" in
    repro-test)
      [[ "${NEXAWRT_APK_SIGNING_PUBLIC_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] ||
        fail "repro-test requires NEXAWRT_APK_SIGNING_PUBLIC_SHA256"
      [[ "$NEXAWRT_APK_SIGNING_PUBLIC_SHA256" == "$public_sha256" ]] ||
        fail "repro-test public key SHA-256 does not match NEXAWRT_APK_SIGNING_PUBLIC_SHA256"
      ;;
    production)
      [[ "$NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256" != UNPROVISIONED ]] ||
        fail "production signing trust anchor is UNPROVISIONED"
      [[ "$NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256" == "$public_sha256" ]] ||
        fail "production public key SHA-256 does not match the repository trust anchor"
      if [[ -n "${NEXAWRT_APK_SIGNING_PUBLIC_SHA256:-}" &&
            "${NEXAWRT_APK_SIGNING_PUBLIC_SHA256}" != "$public_sha256" ]]; then
        fail "production public key SHA-256 does not match NEXAWRT_APK_SIGNING_PUBLIC_SHA256"
      fi
      ;;
    *) fail "NEXAWRT_APK_SIGNING_PROFILE must be repro-test or production" ;;
  esac
}

canonical_external_public_key() {
  python3 -I - "$ROOT_DIR" "$1" "$2" "$3" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
topdir = pathlib.Path(sys.argv[2]).resolve(strict=True)
profile = sys.argv[3]
raw_text = sys.argv[4]
if any(ord(ch) < 32 or ord(ch) == 127 for ch in raw_text):
    raise SystemExit("public key path contains control characters")
raw = pathlib.Path(raw_text)
if not raw.is_absolute():
    raise SystemExit("public key path must be absolute")
absolute = pathlib.Path(os.path.abspath(raw))
if raw != absolute:
    raise SystemExit("public key path must not contain parent-directory traversal")

current = pathlib.Path(absolute.anchor)
for part in absolute.parts[1:]:
    current = current / part
    try:
        mode = current.lstat().st_mode
    except FileNotFoundError:
        raise SystemExit("public key file does not exist")
    if stat.S_ISLNK(mode):
        raise SystemExit("public key path must not contain symlinks")
    if current != absolute and not stat.S_ISDIR(mode):
        raise SystemExit("public key parent path is not a directory")

st = absolute.stat()
if not stat.S_ISREG(st.st_mode):
    raise SystemExit("public key must be a non-symlink regular file")
if st.st_uid != os.geteuid():
    raise SystemExit("public key must be owned by the current user")
if st.st_mode & 0o022:
    raise SystemExit("public key must not be group- or world-writable")
if st.st_nlink != 1:
    raise SystemExit("public key must not have hard links")
if profile == "production":
    expected = root / "manifests" / "apk-signing-public.pem"
    if absolute != expected:
        raise SystemExit("production public key must be manifests/apk-signing-public.pem")
else:
    for forbidden, label in ((topdir, "OpenWrt TOPDIR"), (root, "project workspace")):
        try:
            absolute.relative_to(forbidden)
        except ValueError:
            pass
        else:
            raise SystemExit(f"repro-test public key must be outside the {label}")
print(absolute)
PY
}

canonical_public_output() {
  python3 -I - "$ROOT_DIR" "$1" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
absolute = pathlib.Path(os.path.abspath(sys.argv[2]))
try:
    relative = absolute.relative_to(root / ".work" / "apk-signing")
except ValueError:
    raise SystemExit("canonical public key output must be below .work/apk-signing")
if not relative.parts or absolute.name in {"", ".", ".."}:
    raise SystemExit("invalid canonical public key output")
current = root / ".work"
if os.path.lexists(current) and current.is_symlink():
    raise SystemExit(".work must not be a symlink")
for part in ("apk-signing", *relative.parts[:-1]):
    current = current / part
    if os.path.lexists(current):
        mode = current.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            raise SystemExit("canonical public key parent is unsafe")
if os.path.lexists(absolute):
    mode = absolute.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise SystemExit("canonical public key output is unsafe")
print(absolute)
PY
}

normalize_public_key() {
  local input_file="$1" der_output="$2" pem_output="$3"
  openssl pkey -pubin -in "$input_file" -outform DER -out "$der_output" 2>/dev/null ||
    fail "public key is not a valid SubjectPublicKeyInfo PEM"
  if ! openssl pkey -pubin -inform DER -in "$der_output" -noout -text 2>/dev/null |
      grep -Eq 'ASN1 OID: prime256v1|NIST CURVE: P-256'; then
    fail "public key must use EC prime256v1 (P-256)"
  fi
  openssl pkey -pubin -inform DER -in "$der_output" -outform PEM -out "$pem_output" 2>/dev/null ||
    fail "could not encode canonical APK signing public key"
}

prepare_key() {
  local topdir_raw="${1:-}" topdir profile input_file canonical_input tmp_dir tmp_der tmp_pem
  local public_sha256 public_output output_parent
  [[ -n "$topdir_raw" ]] || fail "usage: $0 prepare OPENWRT_TOPDIR"
  [[ -d "$topdir_raw" ]] || fail "OpenWrt TOPDIR does not exist"
  topdir="$(cd "$topdir_raw" && pwd -P)"
  load_lock
  profile="${NEXAWRT_APK_SIGNING_PROFILE:-}"
  input_file="${NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE:-}"
  [[ -n "$profile" ]] || fail "NEXAWRT_APK_SIGNING_PROFILE is required"
  [[ -n "$input_file" ]] || fail "NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE is required"
  canonical_input="$(canonical_external_public_key "$topdir" "$profile" "$input_file")" || fail "unsafe public key file"
  command -v openssl >/dev/null 2>&1 || fail "openssl is required"

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-apk-public.XXXXXX")" ||
    fail "could not create public key temporary directory"
  trap 'rm -rf -- "$tmp_dir"' RETURN
  tmp_der="$tmp_dir/public.der"
  tmp_pem="$tmp_dir/public.pem"
  normalize_public_key "$canonical_input" "$tmp_der" "$tmp_pem"
  public_sha256="$(hash_file "$tmp_der" | awk '{print $1}')"
  validate_profile_hash_policy "$profile" "$public_sha256"

  public_output="$ROOT_DIR/.work/apk-signing/public-$public_sha256.pem"
  public_output="$(canonical_public_output "$public_output")" || fail "unsafe canonical public key output"
  output_parent="$(dirname "$public_output")"
  mkdir -p -- "$output_parent"
  chmod 0700 "$output_parent"
  install -m 0644 "$tmp_pem" "$public_output.tmp.$$"
  mv -f -- "$public_output.tmp.$$" "$public_output"
  printf '%s\t%s\t%s\n' "$profile" "$public_sha256" "$public_output"
  trap - RETURN
  rm -rf -- "$tmp_dir"
}

verify_public_identity() {
  local profile declared_sha public_file canonical_file tmp_dir tmp_der tmp_pem actual_sha
  load_lock
  profile="${NEXAWRT_APK_SIGNING_PROFILE:-}"
  declared_sha="${NEXAWRT_APK_SIGNING_PUBLIC_SHA256:-}"
  public_file="${NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE:-}"
  [[ -n "$profile" && -n "$declared_sha" && -n "$public_file" ]] ||
    fail "signing profile, public SHA-256, and canonical public key file are required"
  canonical_file="$(canonical_public_output "$public_file")" || fail "unsafe canonical public key file"
  [[ -f "$canonical_file" && ! -L "$canonical_file" ]] ||
    fail "canonical public key must be a non-symlink regular file"
  command -v openssl >/dev/null 2>&1 || fail "openssl is required"
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-apk-public.XXXXXX")" ||
    fail "could not create public key validation directory"
  trap 'rm -rf -- "$tmp_dir"' RETURN
  tmp_der="$tmp_dir/public.der"
  tmp_pem="$tmp_dir/public.pem"
  normalize_public_key "$canonical_file" "$tmp_der" "$tmp_pem"
  actual_sha="$(hash_file "$tmp_der" | awk '{print $1}')"
  [[ "$actual_sha" == "$declared_sha" ]] ||
    fail "canonical public key SHA-256 does not match declared identity"
  validate_profile_hash_policy "$profile" "$actual_sha"
  cmp -s -- "$canonical_file" "$tmp_pem" || fail "canonical public key PEM has been modified"
  trap - RETURN
  rm -rf -- "$tmp_dir"
}

case "${1:-}" in
  prepare) shift; [[ $# -eq 1 ]] || fail "prepare requires exactly one OpenWrt TOPDIR"; prepare_key "$@" ;;
  verify-public) shift; [[ $# -eq 0 ]] || fail "verify-public takes no arguments"; verify_public_identity ;;
  *) fail "usage: $0 prepare OPENWRT_TOPDIR | verify-public" ;;
esac
