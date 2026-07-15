#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
SOURCE_DIR=""
CHECK_ARTIFACTS=0

usage() {
  echo "Usage: $0 [--source PATH] [--artifacts]" >&2
}

while (($#)); do
  case "$1" in
    --source) SOURCE_DIR="${2:?missing source path}"; shift ;;
    --artifacts) CHECK_ARTIFACTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

fail() { echo "validation: $*" >&2; exit 1; }

patch_added_lines() {
  sed -n -e '/^+++ /d' -e 's/^+//p' "$1"
}

assert_patch_has_context() {
  local patch="$1"
  awk '''
    /^@@ / {
      if (seen_hunk && !has_context) bad = 1
      seen_hunk = 1
      has_context = 0
      next
    }
    seen_hunk && /^ / { has_context = 1 }
    END {
      if (!seen_hunk || !has_context) bad = 1
      exit bad
    }
  ''' "$patch" || fail "patch has a zero-context or malformed hunk: $(basename "$patch")"
}

extract_shell_function() {
  local function_name="$1"
  local file="$2"
  awk -v signature="${function_name}() {" '
    $0 == signature { in_function = 1 }
    in_function { print }
    in_function && $0 == "}" { exit }
  ' "$file"
}

extract_board_branch() {
  local board="$1"
  awk -v board="$board" '
    $0 ~ "^[[:space:]]*" board "\\)" { in_branch = 1 }
    in_branch { print }
    in_branch && /^[[:space:]]*;;[[:space:]]*$/ { exit }
  '
}

assert_ax9000_upgrade_blocked() {
  local platform="$1"
  local function_name function_body branch

  for function_name in platform_check_image platform_pre_upgrade platform_do_upgrade; do
    function_body="$(extract_shell_function "$function_name" "$platform")"
    [[ -n "$function_body" ]] || fail "$function_name is missing"
    branch="$(printf '%s\n' "$function_body" | extract_board_branch 'xiaomi,ax9000')"
    [[ -n "$branch" ]] || fail "$function_name has no dedicated xiaomi,ax9000 branch"
    grep -Fq 'ax9000_persistent_upgrade_blocked' <<<"$branch" ||
      fail "$function_name does not fail closed for xiaomi,ax9000"
  done

  function_body="$(extract_shell_function platform_do_upgrade "$platform")"
  branch="$(printf '%s\n' "$function_body" | extract_board_branch 'xiaomi,ax9000')"
  grep -Fq 'return 1' <<<"$branch" ||
    fail "platform_do_upgrade does not explicitly return failure for xiaomi,ax9000"
  if grep -Eq '(^|[^[:alnum:]_])(nand_do_upgrade|fw_setenv|ubiformat)([^[:alnum:]_]|$)' <<<"$branch"; then
    fail "platform_do_upgrade uses a dangerous persistent-upgrade tool for xiaomi,ax9000"
  fi
}

[[ "$OPENWRT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid OpenWrt commit lock"
[[ "$ROOTFS_MTD_OFFSET_HEX" == 0x01180000 ]] || fail "unexpected rootfs offset lock"
[[ "$ROOTFS_MTD_SIZE_HEX" == 0x0e800000 ]] || fail "unexpected rootfs size lock"

seed_config="$ROOT_DIR/configs/ax9000-single-ubi.config"
patch_001="$ROOT_DIR/patches/001-ax9000-single-large-ubi-layout.patch"
patch_002="$ROOT_DIR/patches/002-ax9000-block-persistent-upgrade.patch"

assert_patch_has_context "$patch_001"
assert_patch_has_context "$patch_002"

selected_targets=()
while IFS= read -r target; do
  selected_targets+=("$target")
done < <(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' "$seed_config")
((${#selected_targets[@]} == 1)) || fail "seed config must select exactly one device"
[[ "${selected_targets[0]}" == \
  'CONFIG_TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax9000_single_ubi=y' ]] ||
  fail "seed config selects the wrong device"

if grep -Eq '^CONFIG_PACKAGE_(mtd|uboot-envtools|ubi-utils)=' "$seed_config"; then
  fail "seed config must not select persistent flash/environment tools"
fi

for forbidden in NSS ECM OPENCLASH PASSWALL DOCKER PODMAN SQM SAMBA ADGUARD; do
  if grep -Eiq "^CONFIG_.*${forbidden}.*=y$" "$seed_config"; then
    fail "forbidden first-stage package/config detected: $forbidden"
  fi
done

patch_001_added="$(patch_added_lines "$patch_001")"
grep -Fq 'bootargs-override = "root=/dev/ram0";' <<<"$patch_001_added" ||
  fail "001 patch does not force the AX9000 initramfs root"
if grep -Eq 'ubi\.mtd=|root=/dev/ubiblock' <<<"$patch_001_added"; then
  fail "001 patch adds a persistent UBI root command line"
fi
grep -Fq $'DEVICE_PACKAGES += -uboot-envtools -ubi-utils -mtd' <<<"$patch_001_added" ||
  fail "custom AX9000 profile does not remove dangerous packages"
grep -Fq $'read-only;' <<<"$patch_001_added" ||
  fail "custom rootfs MTD partition is not marked read-only"
grep -Fq 'diff --git a/package/base-files/Makefile b/package/base-files/Makefile' "$patch_001" ||
  fail "001 patch does not remove the base-files ubi-utils dependency"
grep -Fq 'diff --git a/package/system/fstools/Makefile b/package/system/fstools/Makefile' "$patch_001" ||
  fail "001 patch does not remove the fstools ubi-utils dependency"
grep -Fq $'IMAGES :=' <<<"$patch_001_added" || fail "custom AX9000 profile must clear IMAGES"
grep -Fq $'ARTIFACTS :=' <<<"$patch_001_added" || fail "custom AX9000 profile must clear ARTIFACTS"

patch_002_added="$(patch_added_lines "$patch_002")"
grep -Fq 'return 1' <<<"$patch_002_added" || fail "002 patch lacks a fail-closed helper"
blocked_call_count="$(grep -Fxc $'\t\tax9000_persistent_upgrade_blocked' <<<"$patch_002_added" || true)"
((blocked_call_count == 3)) ||
  fail "002 patch must block AX9000 check, pre-upgrade, and do-upgrade paths"
if grep -Eq '(^|[^[:alnum:]_])(nand_do_upgrade|fw_setenv|ubiformat)([^[:alnum:]_]|$)' <<<"$patch_002_added"; then
  fail "002 patch adds a dangerous persistent-upgrade command"
fi

if grep -RIEq --exclude='validate.sh' \
  '(password[[:space:]]*=|passwd[[:space:]]*=|token[[:space:]]*=|secret[[:space:]]*=|https?://[^/[:space:]]+:[^/@[:space:]]+@|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[[:alnum:]]{20,}|github_pat_[[:alnum:]_]{20,}|(AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}|aws_(access_key_id|secret_access_key|session_token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=]{16,})' \
  "$ROOT_DIR/.github" "$ROOT_DIR/configs" "$ROOT_DIR/docs" "$ROOT_DIR/files" \
  "$ROOT_DIR/manifests" "$ROOT_DIR/patches" "$ROOT_DIR/scripts" "$ROOT_DIR/tests" \
  "$ROOT_DIR"/*.md "$ROOT_DIR/LICENSE" "$ROOT_DIR/Makefile" "$ROOT_DIR/.gitignore"; then
  fail "possible embedded credential detected"
fi

for script in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/tests/*.sh; do
  [[ -e "$script" ]] || continue
  bash -n "$script"
done

if [[ -n "$SOURCE_DIR" ]]; then
  [[ -d "$SOURCE_DIR/.git" ]] || fail "source is not a Git checkout: $SOURCE_DIR"
  [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$OPENWRT_COMMIT" ]] ||
    fail "source checkout is not at locked commit"

  platform="$SOURCE_DIR/target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh"
  dts="$SOURCE_DIR/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq8072-ax9000.dts"
  image_mk="$SOURCE_DIR/target/linux/qualcommax/image/ipq807x.mk"
  base_files_mk="$SOURCE_DIR/package/base-files/Makefile"
  fstools_mk="$SOURCE_DIR/package/system/fstools/Makefile"
  [[ -f "$platform" && -f "$dts" && -f "$image_mk" && -f "$base_files_mk" && -f "$fstools_mk" ]] ||
    fail "patched source files missing"

  sh -n "$platform"
  grep -Fq 'reg = <0x1180000 0xe800000>;' "$dts" || fail "single rootfs DTS layout missing"
  ! grep -A3 -F 'partition@1180000' "$dts" | grep -Fq 'label = "ubi_kernel"' ||
    fail "stock ubi_kernel partition still present"
  grep -Fq 'bootargs-override = "root=/dev/ram0";' "$dts" ||
    fail "AX9000 DTS does not force root=/dev/ram0"
  grep -A4 -F 'partition@1180000' "$dts" | grep -Fq 'read-only;' ||
    fail "AX9000 persistent rootfs MTD partition is not read-only"
  if grep -Eq 'ubi\.mtd=|root=/dev/ubiblock' "$dts"; then
    fail "AX9000 DTS still contains a persistent UBI root command line"
  fi

  image_profile="$(awk '
    /^define Device\/xiaomi_ax9000_single_ubi$/ { in_profile = 1 }
    in_profile { print }
    in_profile && /^endef$/ { exit }
  ' "$image_mk")"
  [[ -n "$image_profile" ]] || fail "custom image profile missing"
  grep -Fq 'DEVICE_PACKAGES += -uboot-envtools -ubi-utils -mtd' <<<"$image_profile" ||
    fail "custom image profile does not remove dangerous packages"
  grep -Eq '^[[:space:]]*IMAGES :=[[:space:]]*$' <<<"$image_profile" ||
    fail "custom image profile does not clear IMAGES"
  grep -Eq '^[[:space:]]*ARTIFACTS :=[[:space:]]*$' <<<"$image_profile" ||
    fail "custom image profile does not clear ARTIFACTS"
  grep -Fq 'TARGET_DEVICES += xiaomi_ax9000_single_ubi' "$image_mk" ||
    fail "custom image profile is not selected"
  ! grep -Eq '^TARGET_DEVICES \+= xiaomi_ax9000$' "$image_mk" ||
    fail "stock-looking AX9000 profile is still exposed"

  assert_ax9000_upgrade_blocked "$platform"
  if grep -Fq 'NAND_SUPPORT:ubi-utils' "$base_files_mk" "$fstools_mk"; then
    fail "RAM-only source still forces the ubi-utils package"
  fi

  while read -r feed revision; do
    [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
    grep -Eq "^src-git(-full)? ${feed} .+\^${revision}$" "$SOURCE_DIR/feeds.conf.default" ||
      fail "feed $feed is not pinned to $revision"
  done < "$ROOT_DIR/manifests/feeds.lock"

  if [[ -f "$SOURCE_DIR/.config" ]]; then
    grep -Fq 'CONFIG_TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax9000_single_ubi=y' \
      "$SOURCE_DIR/.config" || fail "resolved config lost the custom device"
    grep -Fq 'CONFIG_LUCI_LANG_zh_Hans=y' "$SOURCE_DIR/.config" ||
      fail "resolved config lost Simplified Chinese LuCI language"
    for package in luci luci-ssl ca-bundle curl ethtool htop iperf3 nano tcpdump-mini; do
      grep -Fq "CONFIG_PACKAGE_${package}=y" "$SOURCE_DIR/.config" ||
        fail "resolved config lost required package: $package"
    done
    if grep -Eq '^CONFIG_PACKAGE_(mtd|uboot-envtools|ubi-utils)=y$' "$SOURCE_DIR/.config"; then
      fail "resolved config enabled a persistent flash/environment tool"
    fi
    if grep -Eq '^CONFIG_PACKAGE_.*(qca-nss-drv|qca-nss-ecm|nss-ecm|qca-nss-fw|openclash|dockerd|docker|lucky).*=y$' \
      "$SOURCE_DIR/.config"; then
      fail "resolved config enabled a forbidden package"
    fi
  fi
fi

if ((CHECK_ARTIFACTS)); then
  [[ -n "$SOURCE_DIR" ]] || fail "--artifacts requires --source"
  out="$SOURCE_DIR/bin/targets/qualcommax/ipq807x"
  [[ -d "$out" ]] || fail "target output directory missing"
  for forbidden_pattern in '*sysupgrade*' '*factory*' '*.ubi'; do
    if find "$out" -maxdepth 1 -type f -name "$forbidden_pattern" -print -quit | grep -q .; then
      fail "RAM-only output contains forbidden artifact matching $forbidden_pattern"
    fi
  done
  find "$out" -maxdepth 1 -type f -name '*xiaomi_ax9000_single_ubi*initramfs*uImage.itb' | grep -q . ||
    fail "initramfs RAM-boot image missing"
fi

echo "validation: OK"
