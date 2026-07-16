#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOOL="$ROOT_DIR/scripts/apk-signing-key.sh"
PATCH="$ROOT_DIR/patches/004-reproducible-package-build-inputs.patch"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-apk-signing-test.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
WORKSPACE_FIXTURE="$ROOT_DIR/.work/apk-signing-policy-test-$$"
TOPDIR="$WORKSPACE_FIXTURE/topdir"
trap 'rm -rf -- "$TMP" "$WORKSPACE_FIXTURE"' EXIT
mkdir -p "$TOPDIR"

fail() { echo "apk signing policy test failed: $*" >&2; exit 1; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi; }
expect_rejected() {
  local label="$1" expected="$2"
  shift 2
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    fail "$label unexpectedly passed"
  fi
  grep -Fq "$expected" "$TMP/stderr" || {
    cat "$TMP/stderr" >&2
    fail "$label failed for an unexpected reason"
  }
}
clean_env() {
  env -u NEXAWRT_APK_SIGNING_PROFILE \
    -u NEXAWRT_APK_SIGNING_PUBLIC_SHA256 \
    -u NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE \
    "$@"
}
public_sha256() {
  local source="$1" der
  der="$(mktemp "$TMP/public-der.XXXXXX")"
  openssl pkey -pubin -in "$source" -outform DER -out "$der" 2>/dev/null
  hash_file "$der" | awk '{print $1}'
  rm -f -- "$der"
}

command -v openssl >/dev/null 2>&1 || fail 'openssl is required'
cat > "$TMP/p256-a.pem" <<'PEM'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEz2pEOCt9AWt6ukdXH+q3k31cz+y1
fU3a5pg17N5WrAicZfKM5R/7hfKbDHdjYZkPXaEIxaVlHVarS1JgxWyQWQ==
-----END PUBLIC KEY-----
PEM
cat > "$TMP/p256-b.pem" <<'PEM'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEF/Sj9ofrRrihXTW6JjnXV/4Z0DMx
Dw5xXve2pA20XXEr3x318sCOYusGArj2tuwlcwF2o0sM2GBN+X3A2ZTm2g==
-----END PUBLIC KEY-----
PEM
cat > "$TMP/p384.pem" <<'PEM'
-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEBexxBcWHnHa9kgsM2ezDCO1j+QM3b6dF
u5iBN/HfmjjPLS0Cu4+2ThgeAgOGQtWtBZ/I1ujrxJFSsG4gohkU5i+l73UHTT2h
EbuhMk5fR5z1x3qXjsOEc12qhGwlfk7v
-----END PUBLIC KEY-----
PEM
printf 'not a public key\n' > "$TMP/bad.pem"
chmod 0644 "$TMP"/*.pem
PUBLIC_SHA="$(public_sha256 "$TMP/p256-a.pem")"
OTHER_SHA="$(public_sha256 "$TMP/p256-b.pem")"
WRONG_SHA="$(printf '0%.0s' {1..64})"
[[ "$WRONG_SHA" != "$PUBLIC_SHA" ]] || WRONG_SHA="$(printf '1%.0s' {1..64})"

expect_rejected 'missing profile' 'NEXAWRT_APK_SIGNING_PROFILE is required' \
  clean_env NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p256-a.pem" bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'missing public key' 'NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE is required' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'missing repro hash' 'repro-test requires NEXAWRT_APK_SIGNING_PUBLIC_SHA256' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p256-a.pem" bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'relative public key path' 'public key path must be absolute' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE=p256-a.pem bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'parent traversal' 'public key path must not contain parent-directory traversal' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/child/../p256-a.pem" bash "$TOOL" prepare "$TOPDIR"
ln -s "$TMP/p256-a.pem" "$TMP/public-link.pem"
expect_rejected 'symlink public key' 'public key path must not contain symlinks' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/public-link.pem" bash "$TOOL" prepare "$TOPDIR"
mkdir "$TMP/real-parent"
cp "$TMP/p256-a.pem" "$TMP/real-parent/public.pem"
ln -s "$TMP/real-parent" "$TMP/link-parent"
expect_rejected 'symlink public key parent' 'public key path must not contain symlinks' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/link-parent/public.pem" bash "$TOOL" prepare "$TOPDIR"
cp "$TMP/p256-a.pem" "$TMP/writable.pem"
chmod 0666 "$TMP/writable.pem"
expect_rejected 'writable public key' 'public key must not be group- or world-writable' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/writable.pem" bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'invalid public key' 'not a valid SubjectPublicKeyInfo PEM' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/bad.pem" bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'wrong curve' 'public key must use EC prime256v1' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p384.pem" bash "$TOOL" prepare "$TOPDIR"
expect_rejected 'repro hash mismatch' 'does not match NEXAWRT_APK_SIGNING_PUBLIC_SHA256' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$WRONG_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p256-a.pem" bash "$TOOL" prepare "$TOPDIR"

cp "$TMP/p256-a.pem" "$TOPDIR/public.pem"
expect_rejected 'TOPDIR repro public key' 'repro-test public key must be outside the OpenWrt TOPDIR' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TOPDIR/public.pem" bash "$TOOL" prepare "$TOPDIR"
cp "$TMP/p256-a.pem" "$WORKSPACE_FIXTURE/workspace-public.pem"
expect_rejected 'workspace repro public key' 'repro-test public key must be outside the project workspace' \
  clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$WORKSPACE_FIXTURE/workspace-public.pem" bash "$TOOL" prepare "$TOPDIR"

result="$(clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test \
  NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
  NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p256-a.pem" \
  bash "$TOOL" prepare "$TOPDIR")" || fail 'valid repro-test public identity was rejected'
IFS=$'\t' read -r profile derived_sha canonical_public <<<"$result"
[[ "$profile" == repro-test && "$derived_sha" == "$PUBLIC_SHA" ]] || fail 'prepared public identity metadata is incorrect'
[[ "$canonical_public" == "$ROOT_DIR/.work/apk-signing/public-$PUBLIC_SHA.pem" ]] || fail 'canonical public key path is incorrect'
[[ -f "$canonical_public" && ! -L "$canonical_public" ]] || fail 'canonical public key was not created safely'
cmp -s "$TMP/p256-a.pem" "$canonical_public" || fail 'canonical P-256 PEM differs unexpectedly'
env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
  NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$canonical_public" bash "$TOOL" verify-public
expect_rejected 'declared hash drift' 'does not match declared identity' \
  env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$OTHER_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$canonical_public" bash "$TOOL" verify-public
cp "$TMP/p256-b.pem" "$canonical_public"
expect_rejected 'canonical key replacement' 'does not match declared identity' \
  env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$canonical_public" bash "$TOOL" verify-public
result="$(clean_env NEXAWRT_APK_SIGNING_PROFILE=repro-test \
  NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
  NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p256-a.pem" bash "$TOOL" prepare "$TOPDIR")"
printf '\n# tampered encoding\n' >> "$canonical_public"
expect_rejected 'canonical PEM tamper' 'canonical public key PEM has been modified' \
  env NEXAWRT_APK_SIGNING_PROFILE=repro-test NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$canonical_public" bash "$TOOL" verify-public

PROD_PROJECT="$TMP/production-project"
PROD_TOPDIR="$TMP/production-topdir"
mkdir -p "$PROD_PROJECT/scripts" "$PROD_PROJECT/manifests" "$PROD_TOPDIR"
cp "$TOOL" "$ROOT_DIR/scripts/lock-file-policy.sh" "$PROD_PROJECT/scripts/"
cp "$TMP/p256-a.pem" "$PROD_PROJECT/manifests/apk-signing-public.pem"
printf 'NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256="%s"\n' "$PUBLIC_SHA" > "$PROD_PROJECT/manifests/apk-signing.lock"
production_result="$(env NEXAWRT_APK_SIGNING_PROFILE=production \
  NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
  NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$PROD_PROJECT/manifests/apk-signing-public.pem" \
  bash "$PROD_PROJECT/scripts/apk-signing-key.sh" prepare "$PROD_TOPDIR")" ||
  fail 'valid temporary production lock and committed public key were rejected'
IFS=$'\t' read -r production_profile production_sha production_public <<<"$production_result"
[[ "$production_profile" == production && "$production_sha" == "$PUBLIC_SHA" && -f "$production_public" ]] ||
  fail 'temporary production identity metadata is incorrect'
env NEXAWRT_APK_SIGNING_PROFILE=production NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
  NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$production_public" \
  bash "$PROD_PROJECT/scripts/apk-signing-key.sh" verify-public
expect_rejected 'production non-committed path' 'production public key must be manifests/apk-signing-public.pem' \
  env NEXAWRT_APK_SIGNING_PROFILE=production NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$TMP/p256-a.pem" \
    bash "$PROD_PROJECT/scripts/apk-signing-key.sh" prepare "$PROD_TOPDIR"
printf 'NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256=%s\n' "$PUBLIC_SHA" > "$PROD_PROJECT/manifests/apk-signing.lock"
expect_rejected 'unquoted production lock' 'invalid signing trust lock' \
  env NEXAWRT_APK_SIGNING_PROFILE=production NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$PROD_PROJECT/manifests/apk-signing-public.pem" \
    bash "$PROD_PROJECT/scripts/apk-signing-key.sh" prepare "$PROD_TOPDIR"
printf 'NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256="%s"\n' "$WRONG_SHA" > "$PROD_PROJECT/manifests/apk-signing.lock"
expect_rejected 'production anchor drift' 'does not match the repository trust anchor' \
  env NEXAWRT_APK_SIGNING_PROFILE=production NEXAWRT_APK_SIGNING_PUBLIC_SHA256="$PUBLIC_SHA" \
    NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$PROD_PROJECT/manifests/apk-signing-public.pem" \
    bash "$PROD_PROJECT/scripts/apk-signing-key.sh" prepare "$PROD_TOPDIR"

[[ "$(grep -Fc 'make "${APK_MAKE_ARGS[@]}"' "$ROOT_DIR/scripts/build.sh")" == 2 ]] ||
  fail 'download and build are not both bound to public-only APK overrides'
grep -Fq 'NEXAWRT_APK_PUBLIC_ONLY=1' "$ROOT_DIR/scripts/build.sh" || fail 'public-only make override is missing'
grep -Fq 'BUILD_KEY_APK_PUB=$APK_SIGNING_PUBLIC_KEY' "$ROOT_DIR/scripts/build.sh" || fail 'public key make override is missing'
! grep -Fq 'BUILD_KEY_APK_SEC' "$ROOT_DIR/scripts/build.sh" || fail 'build script still passes an APK secret key'
grep -Fq 'Refusing APK private key inside OpenWrt TOPDIR' "$ROOT_DIR/scripts/build.sh" || fail 'TOPDIR private-key refusal is missing'

grep -Fq '+ifeq ($(NEXAWRT_APK_PUBLIC_ONLY),1)' "$PATCH" || fail 'OpenWrt patch lacks the explicit public-only branch'
grep -Fq '+  APK_BUILD_KEY_PREREQUISITES := $(BUILD_KEY_APK_PUB)' "$PATCH" || fail 'public-only compile still depends on a secret key'
grep -Fq '+  APK_INDEX_SIGNATURE_ARGS :=' "$PATCH" || fail 'public-only index signing is not disabled'
grep -Fq '+  APK_ROOTFS_TRUST_ARGS := --allow-untrusted' "$PATCH" || fail 'public-only rootfs install is not explicitly untrusted'
grep -Fq '+  APK_BUILD_KEY_PREREQUISITES := $(BUILD_KEY_APK_SEC) $(BUILD_KEY_APK_PUB)' "$PATCH" || fail 'default upstream key prerequisites were not preserved'
grep -Fq '+  APK_INDEX_SIGNATURE_ARGS = $(if $(CONFIG_SIGNED_PACKAGES),--sign $(BUILD_KEY_APK_SEC),)' "$PATCH" || fail 'default upstream index signing was not preserved'
grep -Fq '+$(error SOURCE_DATE_EPOCH is required for reproducible qca-ssdk builds)' "$PATCH" || fail 'qca-ssdk does not fail closed without SOURCE_DATE_EPOCH'
! sed -n 's/^+//p' "$PATCH" | grep -Fq 'BUILD_DATE := $(shell date -u +%F-%T)' || fail 'qca-ssdk still falls back to wall clock time'

echo 'public-only APK identity, committed production anchor, path/tamper safety, and OpenWrt override policy: OK'
