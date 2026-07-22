#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$ROOT_DIR/.work"
TMP="$(mktemp -d "$ROOT_DIR/.work/package-repository-policy.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "package repository policy test failed: $*" >&2; exit 1; }
expect_rejected() {
  local label="$1" expected="$2"
  shift 2
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    fail "$label unexpectedly passed"
  fi
  grep -Fqi "$expected" "$TMP/stderr" || {
    cat "$TMP/stderr" >&2
    fail "$label failed for an unexpected reason"
  }
}
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1"
  else
    shasum -a 256 -- "$1"
  fi
}

source "$ROOT_DIR/scripts/lock-file-policy.sh"
nexawrt_validate_lock_file "$ROOT_DIR/manifests/package-repository.lock" package-repository
# shellcheck source=../manifests/package-repository.lock
source "$ROOT_DIR/manifests/package-repository.lock"

"$ROOT_DIR/scripts/package-repository-key.sh" public
actual_set_sha="$(hash_file "$ROOT_DIR/manifests/package-repository-packages.txt" | awk '{print $1}')"
[[ "$actual_set_sha" == "$NEXAWRT_REPOSITORY_PACKAGE_SET_SHA256" ]] ||
  fail 'package set digest does not match its lock'
grep -Fxq 'nexawrt-repository' "$ROOT_DIR/manifests/package-repository-packages.txt" ||
  fail 'bootstrap package is not selected'

cp "$ROOT_DIR/manifests/package-repository.lock" "$TMP/tampered-url.lock"
sed -i.bak 's#/packages.adb#/Packages.gz#' "$TMP/tampered-url.lock"
rm -f "$TMP/tampered-url.lock.bak"
expect_rejected 'OPKG index URL' 'invalid NEXAWRT_REPOSITORY_INDEX_URL' \
  nexawrt_validate_lock_file "$TMP/tampered-url.lock" package-repository

cp "$ROOT_DIR/manifests/package-repository.lock" "$TMP/inconsistent-url.lock"
sed -i.bak 's#/testing/aarch64_cortex-a53/packages.adb#/stable/aarch64_cortex-a53/packages.adb#' "$TMP/inconsistent-url.lock"
rm -f "$TMP/inconsistent-url.lock.bak"
expect_rejected 'inconsistent APK index URL' 'inconsistent' \
  nexawrt_validate_lock_file "$TMP/inconsistent-url.lock" package-repository

openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/wrong-private.pem" 2>/dev/null
chmod 600 "$TMP/wrong-private.pem"
expect_rejected 'mismatched private key' 'does not match' \
  "$ROOT_DIR/scripts/package-repository-key.sh" private "$TMP/wrong-private.pem"
chmod 644 "$TMP/wrong-private.pem"
expect_rejected 'world-readable private key' 'permissions' \
  "$ROOT_DIR/scripts/package-repository-key.sh" private "$TMP/wrong-private.pem"

if grep -RIEq --include='*.conf' --include='*.list' --include='*.lock' \
    '(^|/)(Packages\.gz|[^[:space:]]+\.ipk)([/?#[:space:]]|$)|/etc/opkg|customfeeds\.conf' \
    "$ROOT_DIR/manifests/package-repository.lock" "$ROOT_DIR/packages/nexawrt-repository"; then
  fail 'repository policy contains an OPKG/IPK endpoint'
fi

workflow="$ROOT_DIR/.github/workflows/package-repository.yml"
pages_workflow="$ROOT_DIR/.github/workflows/pages.yml"
[[ -f "$workflow" && ! -L "$workflow" ]] || fail 'package repository workflow is missing or unsafe'
grep -Fq 'environment: package-repository' "$workflow" || fail 'signing job is not environment-gated'
grep -Fq "github.event_name != 'pull_request'" "$workflow" || fail 'untrusted pull requests can reach repository publishing'
grep -Fq "github.ref == 'refs/heads/main'" "$workflow" || fail 'repository publishing is not restricted to main'
grep -Fq 'secrets.NEXAWRT_REPOSITORY_SIGNING_PRIVATE_KEY' "$workflow" || fail 'repository signing secret is not wired explicitly'
grep -Fq 'NEXAWRT_APK_PUBLIC_ONLY=1' "$workflow" || fail 'package build is not public-key-only'
# The dollar expression is intentionally matched literally in workflow YAML.
# shellcheck disable=SC2016
grep -Fq -- '--public-key "$GITHUB_WORKSPACE/manifests/package-repository-public.pem"' "$workflow" || fail 'workflow does not pass the committed repository public key to the signed index builder'
grep -Fq '"--allow-untrusted",' "$ROOT_DIR/scripts/stage-package-repository.py" || fail 'mkndx does not explicitly allow reading public-only input APKs'
grep -Fq '"verify",' "$ROOT_DIR/scripts/stage-package-repository.py" || fail 'signed packages.adb is not verified with apk'
grep -Fq '"signature_verified": True' "$ROOT_DIR/scripts/stage-package-repository.py" || fail 'repository metadata does not record successful signature verification'
grep -Fq 'index.get("signature_verified") is not True' "$ROOT_DIR/scripts/stage-package-repository.py" || fail 'Pages staging does not fail closed on the signature verification receipt'
grep -Fq 'Repository release tag already exists' "$workflow" || fail 'immutable release guard is missing'
grep -Fq 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$workflow" || fail 'repository archive attestation is missing or unpinned'
grep -Fq 'NexaWrt signed APK package repository' "$pages_workflow" || fail 'Pages is not triggered after repository publication'
grep -Fq 'asset.get('"'"'digest'"'"')' "$pages_workflow" || fail 'Pages does not require the GitHub asset digest'
grep -Fq 'scripts/stage-package-repository.py stage-pages' "$pages_workflow" || fail 'Pages does not safely stage the signed repository archive'
grep -Fq 'refusing to deploy Pages without the locked repository' "$pages_workflow" || fail 'Pages does not fail closed when the locked repository release is missing'
for config in "$ROOT_DIR/configs/ax9000-single-ubi.config" "$ROOT_DIR/configs/ax9000-single-ubi-nss.config"; do
  grep -Fxq 'CONFIG_PACKAGE_nexawrt-repository=m' "$config" ||
    fail "repository bootstrap package is not built as a module in $(basename "$config")"
done
grep -Fq 'files/etc/apk/repositories.d/nexawrt.list' "$ROOT_DIR/scripts/prepare.sh" ||
  fail 'prepare does not embed the APK repository URL'
grep -Fq 'files/etc/apk/keys/nexawrt-repository.pem' "$ROOT_DIR/scripts/prepare.sh" ||
  fail 'prepare does not embed the APK repository public key'

python3 "$ROOT_DIR/tests/test_package_repository.py"
echo 'package repository lock, key, workflow, archive, Pages, and APK-only policy: OK'
