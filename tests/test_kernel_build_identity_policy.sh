#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECKER="$ROOT_DIR/scripts/check-kernel-build-identity.sh"
VALIDATE="$ROOT_DIR/scripts/validate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-kernel-identity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test_kernel_build_identity_policy: $*" >&2; exit 1; }
expect_failure() {
  local label="$1"
  shift
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    fail "$label unexpectedly passed"
  fi
}

# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
# shellcheck source=../manifests/nss.lock
source "$ROOT_DIR/manifests/nss.lock"
official_version="nexawrt-r0-${OPENWRT_COMMIT:0:8}"
nss_version="nexawrt-r0-${NSS_OPENWRT_COMMIT:0:8}"
[[ "$official_version" == nexawrt-r0-f0a60eee ]] ||
  fail "upstream lock no longer derives the reviewed official firmware version code"
[[ "$nss_version" == nexawrt-r0-d6848fa2 ]] ||
  fail "NSS lock no longer derives the reviewed NSS firmware version code"

"$CHECKER" "$ROOT_DIR/configs/ax9000-single-ubi.config" \
  "$OPENWRT_COMMIT" official-seed
"$CHECKER" "$ROOT_DIR/configs/ax9000-single-ubi-nss.config" \
  "$NSS_OPENWRT_COMMIT" nss-seed

write_config() {
  cat > "$TMP/config" <<EOF_CONFIG
CONFIG_KERNEL_BUILD_USER="$1"
CONFIG_KERNEL_BUILD_DOMAIN="$2"
CONFIG_IMAGEOPT=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_CODE="$3"
# CONFIG_VERSION_FILENAMES is not set
# CONFIG_VERSION_CODE_FILENAMES is not set
EOF_CONFIG
}

write_config nexawrt builder "$official_version"
"$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
expect_failure 'missing resolved config' \
  "$CHECKER" "$TMP/missing.config" "$OPENWRT_COMMIT" official-config

write_config '' builder "$official_version"
expect_failure 'empty kernel build user' "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
write_config nexawrt '' "$official_version"
expect_failure 'empty kernel build domain' "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
write_config nexawrt builder ''
expect_failure 'empty firmware version code' "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config

write_config nexawrt builder "$official_version"
sed -i.bak '/^CONFIG_IMAGEOPT=y$/d' "$TMP/config"
rm -f "$TMP/config.bak"
expect_failure 'missing image options gate' \
  "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
write_config nexawrt builder "$official_version"
sed -i.bak 's/^CONFIG_IMAGEOPT=y$/# CONFIG_IMAGEOPT is not set/' "$TMP/config"
rm -f "$TMP/config.bak"
expect_failure 'disabled image options gate' \
  "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config

write_config nexawrt builder "$official_version"
sed -i.bak '/^CONFIG_VERSIONOPT=y$/d' "$TMP/config"
rm -f "$TMP/config.bak"
expect_failure 'missing version options gate' \
  "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
write_config nexawrt builder "$official_version"
sed -i.bak 's/^CONFIG_VERSIONOPT=y$/# CONFIG_VERSIONOPT is not set/' "$TMP/config"
rm -f "$TMP/config.bak"
expect_failure 'disabled version options gate' \
  "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config

check_disabled_filename_bool_policy() {
  local symbol="$1"
  local label="$2"

  write_config nexawrt builder "$official_version"
  sed -i.bak "/^# $symbol is not set$/d" "$TMP/config"
  rm -f "$TMP/config.bak"
  expect_failure "missing $label" \
    "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config

  write_config nexawrt builder "$official_version"
  sed -i.bak "s/^# $symbol is not set$/$symbol=y/" "$TMP/config"
  rm -f "$TMP/config.bak"
  expect_failure "enabled $label" \
    "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config

  write_config nexawrt builder "$official_version"
  printf '# %s is not set\n' "$symbol" >> "$TMP/config"
  expect_failure "duplicate $label" \
    "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
}

check_disabled_filename_bool_policy CONFIG_VERSION_FILENAMES \
  'version filenames option'
check_disabled_filename_bool_policy CONFIG_VERSION_CODE_FILENAMES \
  'version-code filenames option'

write_config nexawrt builder 'nexawrt-r0-f0a60ee'
expect_failure 'official 7-character git abbreviation' \
  "$CHECKER" "$TMP/config" "$OPENWRT_COMMIT" official-config
write_config nexawrt builder 'nexawrt-r0-d6848fa'
expect_failure 'NSS 7-character git abbreviation' \
  "$CHECKER" "$TMP/config" "$NSS_OPENWRT_COMMIT" nss-config

write_config nexawrt builder "$official_version"
official_stale_commit="0${OPENWRT_COMMIT:1}"
expect_failure 'official stale upstream-lock mismatch' \
  "$CHECKER" "$TMP/config" "$official_stale_commit" official-config
write_config nexawrt builder "$nss_version"
nss_stale_commit="0${NSS_OPENWRT_COMMIT:1}"
expect_failure 'NSS stale source-lock mismatch' \
  "$CHECKER" "$TMP/config" "$nss_stale_commit" nss-config

# Duplicate or contradictory Kconfig assignments must not be accepted merely
# because one matching line is present.
printf 'CONFIG_KERNEL_BUILD_USER="nexawrt"\n' >> "$TMP/config"
expect_failure 'duplicate kernel identity assignment' \
  "$CHECKER" "$TMP/config" "$NSS_OPENWRT_COMMIT" nss-config

grep -Fq '"$config" "$EXPECTED_SOURCE_COMMIT" "$description"' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not apply each flavor source lock to its configs'
grep -Fq 'EXPECTED_SOURCE_COMMIT="$OPENWRT_COMMIT"' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not select the official upstream source lock'
grep -Fq 'EXPECTED_SOURCE_COMMIT="$NSS_OPENWRT_COMMIT"' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not select the NSS source lock'
if grep -Fq 'FIRMWARE_VERSION_SOURCE_COMMIT="$NSS_OPENWRT_COMMIT"' "$ROOT_DIR/scripts/validate.sh"; then
  fail 'validate.sh still forces both flavors to use the NSS revision'
fi
grep -Fq 'assert_flavor_config "$SEED_CONFIG" "$NEXAWRT_FLAVOR seed config"' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not validate the selected seed config'
for config in \
  "$ROOT_DIR/configs/ax9000-single-ubi.config" \
  "$ROOT_DIR/configs/ax9000-single-ubi-nss.config"; do
  grep -Fxq 'CONFIG_REPRODUCIBLE_DEBUG_INFO=y' "$config" ||
    fail "seed config does not normalize compiler debug paths: $config"
done
grep -Fq 'assert_enabled_kconfig_bool "$config" CONFIG_REPRODUCIBLE_DEBUG_INFO' \
  "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not strictly enforce reproducible compiler debug paths'

REPRO_SOURCE="$TMP/repro-source"
mkdir -p "$REPRO_SOURCE"
run_repro_config_policy() {
  NEXAWRT_FLAVOR=official "$VALIDATE" \
    --source "$REPRO_SOURCE" --revision-policy-only
}
reset_repro_config_fixture() {
  cp "$ROOT_DIR/configs/ax9000-single-ubi.config" "$REPRO_SOURCE/.config"
  printf 'r0-%s\n' "${OPENWRT_COMMIT:0:8}" > "$REPRO_SOURCE/version"
}
reset_repro_config_fixture
run_repro_config_policy >/dev/null

reset_repro_config_fixture
sed -i.bak 's/^CONFIG_REPRODUCIBLE_DEBUG_INFO=y$/# CONFIG_REPRODUCIBLE_DEBUG_INFO=y/' \
  "$REPRO_SOURCE/.config"
rm -f "$REPRO_SOURCE/.config.bak"
expect_failure 'commented-only reproducible debug config' run_repro_config_policy

reset_repro_config_fixture
sed -i.bak 's/^CONFIG_REPRODUCIBLE_DEBUG_INFO=y$/# CONFIG_REPRODUCIBLE_DEBUG_INFO is not set/' \
  "$REPRO_SOURCE/.config"
rm -f "$REPRO_SOURCE/.config.bak"
expect_failure 'disabled reproducible debug config' run_repro_config_policy

reset_repro_config_fixture
printf '# CONFIG_REPRODUCIBLE_DEBUG_INFO is not set\n' >> "$REPRO_SOURCE/.config"
expect_failure 'conflicting reproducible debug config' run_repro_config_policy

reset_repro_config_fixture
printf 'CONFIG_REPRODUCIBLE_DEBUG_INFO=y\n' >> "$REPRO_SOURCE/.config"
expect_failure 'duplicate reproducible debug config' run_repro_config_policy
KERNEL_ASM_REMAP_PATCH="$ROOT_DIR/patches/005-reproducible-kernel-assembly-debug-paths.patch"
[[ -f "$KERNEL_ASM_REMAP_PATCH" ]] ||
  fail 'kernel assembly debug path patch is missing'
grep -Fq '+	KAFLAGS="$(call iremap,$(BUILD_DIR),$(notdir $(BUILD_DIR)))" \' \
  "$KERNEL_ASM_REMAP_PATCH" ||
  fail 'kernel assembly debug path patch does not normalize assembler DWARF paths'
grep -Fq 'kernel assembly debug path patch must pass the canonical source remap to KAFLAGS' \
  "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not enforce the kernel assembler path remap patch intent'
grep -Fq 'resolved config is missing or is not a regular file' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not fail closed when the source resolved config is absent'
grep -Fq 'assert_flavor_config "$resolved_config" "$NEXAWRT_FLAVOR resolved config"' "$ROOT_DIR/scripts/validate.sh" ||
  fail 'validate.sh does not validate the source resolved config'
grep -Fq "OpenWrt's resolved CONFIG_KERNEL_BUILD_USER/DOMAIN locks are authoritative." \
  "$ROOT_DIR/scripts/build.sh" ||
  fail 'build.sh no longer documents that resolved Kconfig overrides the defensive exports'
[[ -x "$ROOT_DIR/tests/test_openwrt_defconfig_version.sh" ]] ||
  fail 'OpenWrt make defconfig retention integration test is missing or not executable'
grep -Fq 'make -s -C "$FIXTURE" defconfig' "$ROOT_DIR/tests/test_openwrt_defconfig_version.sh" ||
  fail 'defconfig retention test no longer runs the OpenWrt Kconfig make defconfig fixture'

echo 'per-flavor kernel identity and canonical artifact filename policy: OK'
