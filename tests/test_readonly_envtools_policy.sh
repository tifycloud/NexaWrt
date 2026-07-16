#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-readonly-envtools.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test_readonly_envtools_policy: $*" >&2; exit 1; }

for config in \
  "$ROOT_DIR/configs/ax9000-single-ubi.config" \
  "$ROOT_DIR/configs/ax9000-single-ubi-nss.config"; do
  [[ "$(grep -Fxc 'CONFIG_PACKAGE_uboot-envtools=y' "$config")" == 1 ]] ||
    fail "$(basename "$config") must enable exactly one patched uboot-envtools package"
  ! grep -Eq '^CONFIG_PACKAGE_(mtd|ubi-utils)=[ym]$' "$config" ||
    fail "$(basename "$config") enables a persistent flash/UBI utility"
done

PATCH001="$ROOT_DIR/patches/001-ax9000-single-large-ubi-layout.patch"
patch001_added="$(sed -n -e '/^+++ /d' -e 's/^+//p' "$PATCH001")"
[[ "$(grep -Ec '^[[:space:]]*DEVICE_PACKAGES \+= -ubi-utils -mtd[[:space:]]*$' <<<"$patch001_added")" == 1 ]] ||
  fail 'AX9000 profile must exclude exactly -ubi-utils -mtd'
[[ "$(grep -Ec '^[[:space:]]*DEVICE_PACKAGES[[:space:]]*\+=' <<<"$patch001_added")" == 1 ]] ||
  fail 'AX9000 profile contains an additional DEVICE_PACKAGES override'
! grep -Eq '(^|[[:space:]])-uboot-envtools([[:space:]]|$)' <<<"$patch001_added" ||
  fail 'AX9000 profile must not exclude uboot-envtools through merge_packages'

PATCH="$ROOT_DIR/patches/003-uboot-envtools-read-only.patch"
for removed in fw_setenv fw_setsys fw_loadenv 05_fw_defaults; do
  grep -Eq "^-[^-].*${removed}" "$PATCH" || fail "003 patch does not remove $removed"
done
! grep -Eq '^-[^-].*30_uboot-envtools' "$PATCH" ||
  fail '003 patch must preserve target-specific 30_uboot-envtools'
for reader in fw_printenv fw_printsys; do
  grep -Fq "$reader" "$PATCH" || fail "003 patch lost $reader install context"
done

mkdir -p "$TMP/source/package/boot/uboot-tools"
makefile_fixture="$TMP/source/package/boot/uboot-tools/Makefile"
: > "$makefile_fixture"
for ((line = 1; line < 100; line++)); do printf '\n' >> "$makefile_fixture"; done
cat >> "$makefile_fixture" <<'MAKEFILE'
define Package/fit-check-sign/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tools/fit_check_sign $(1)/usr/bin
endef

define Package/uboot-envtools/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tools/env/fw_printenv $(1)/usr/sbin
	$(LN) fw_printenv $(1)/usr/sbin/fw_setenv
	$(INSTALL_BIN) ./uboot-envtools/files/fw_printsys $(1)/usr/sbin
	$(INSTALL_BIN) ./uboot-envtools/files/fw_setsys $(1)/usr/sbin
	$(INSTALL_BIN) ./uboot-envtools/files/fw_loadenv $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/board.d
	$(INSTALL_DATA) ./uboot-envtools/files/fw_defaults $(1)/etc/board.d/05_fw_defaults
	$(INSTALL_DIR) $(1)/lib
	$(INSTALL_DATA) ./uboot-envtools/files/uboot-envtools.sh $(1)/lib
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(if $(wildcard ./uboot-envtools/files/$(BOARD)_$(SUBTARGET)), \
		$(INSTALL_DATA) ./uboot-envtools/files/$(BOARD)_$(SUBTARGET) \
		$(1)/etc/uci-defaults/30_uboot-envtools, \
		$(if $(wildcard ./uboot-envtools/files/$(BOARD)), \
			$(INSTALL_DATA) ./uboot-envtools/files/$(BOARD) \
			$(1)/etc/uci-defaults/30_uboot-envtools \
		) \
	)
endef
MAKEFILE
patch -s -p1 -d "$TMP/source" < "$PATCH" || fail '003 patch does not apply to the locked install block fixture'
install_block="$(awk '
  /^define Package\/uboot-envtools\/install$/ { in_block=1 }
  in_block { print }
  in_block && /^endef$/ { exit }
' "$makefile_fixture")"
for required in fw_printenv fw_printsys 30_uboot-envtools; do
  grep -Fq "$required" <<<"$install_block" || fail "patched install block lost $required"
done
if grep -Eq 'fw_(setenv|setsys|loadenv)|fw_defaults|05_fw_defaults' <<<"$install_block"; then
  fail 'patched install block retains an environment write entry'
fi

VALIDATE="$ROOT_DIR/scripts/validate.sh"
grep -Fq "grep -Fq 'CONFIG_PACKAGE_uboot-envtools=y'" "$VALIDATE" ||
  fail 'validate no longer requires patched uboot-envtools'
grep -Fq "^CONFIG_PACKAGE_(mtd|ubi-utils)=[ym]" "$VALIDATE" ||
  fail 'validate does not keep mtd/ubi-utils disabled'
! grep -Fq '^CONFIG_PACKAGE_(mtd|uboot-envtools|ubi-utils)=[ym]' "$VALIDATE" ||
  fail 'validate still blanket-forbids uboot-envtools'
grep -Fq 'custom AX9000 profile must not exclude uboot-envtools via merge_packages' "$VALIDATE" ||
  fail 'validate does not reject profile-level -uboot-envtools exclusion'
grep -Fq 'custom image profile excludes uboot-envtools, so merge_packages would remove fw_printenv' "$VALIDATE" ||
  fail 'SOURCE_DIR validation does not reject profile-level -uboot-envtools exclusion'
grep -Fq 'target-specific 30_uboot-envtools source' "$VALIDATE" ||
  fail 'validate does not inspect the prepared source read configuration'
grep -Fq 'final rootfs 30_uboot-envtools' "$VALIDATE" ||
  fail 'validate does not require the final rootfs read configuration'
grep -Fq "fw_printenv\\nfw_printsys" "$VALIDATE" ||
  fail 'validate does not constrain the final fw_* tool set to readers'

PROBE="$ROOT_DIR/scripts/ax9000-runtime-probe.sh"
grep -Fq 'for write_tool in fw_setenv fw_setsys fw_loadenv' "$PROBE" ||
  fail 'runtime probe does not reject all U-Boot environment write tools'
grep -Fq "echo 'fw_printenv_available=yes'" "$PROBE" ||
  fail 'runtime probe lost the fw_printenv availability marker'
grep -Fq "echo 'uboot_env_write_tools=absent'" "$PROBE" ||
  fail 'runtime probe lost the write-tool absence marker'
for marker in fw_printenv_available uboot_env_write_tools; do
  grep -Fq "\"$marker\"" "$ROOT_DIR/scripts/verify-hardware-evidence.sh" ||
    fail "hardware verifier schema lost $marker"
done

echo 'profile merge_packages and read-only uboot-envtools package/config/patch/runtime policy: OK'
