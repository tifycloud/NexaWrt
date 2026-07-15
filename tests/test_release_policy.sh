#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

make_bin_dir() {
  local case_name="$1"
  local bin_dir="$TMP_DIR/$case_name/work/bin/targets/qualcommax/ipq807x"
  mkdir -p "$bin_dir"
  touch "$bin_dir/openwrt-xiaomi_ax9000_single_ubi-initramfs-uImage.itb"
  printf '{}\n' > "$bin_dir/profiles.json"
  printf '%s\n' "$bin_dir"
}

make_bin_dir success >/dev/null
WORK_DIR="$TMP_DIR/success/work" DIST_DIR_OVERRIDE="$TMP_DIR/success/dist" \
  "$ROOT_DIR/scripts/release.sh" >/dev/null
[[ -f "$TMP_DIR/success/dist/openwrt-xiaomi_ax9000_single_ubi-initramfs-uImage.itb" ]]
[[ -f "$TMP_DIR/success/dist/DO-NOT-FLASH.txt" ]]
grep -Fq 'project=NexaWrt' "$TMP_DIR/success/dist/BUILD-MANIFEST.txt"
grep -Fq 'stage=initramfs-ram-boot-only' "$TMP_DIR/success/dist/BUILD-MANIFEST.txt"

expect_rejected() {
  local case_name="$1"
  local forbidden_name="$2"
  local bin_dir
  bin_dir="$(make_bin_dir "$case_name")"
  touch "$bin_dir/$forbidden_name"

  if WORK_DIR="$TMP_DIR/$case_name/work" \
    DIST_DIR_OVERRIDE="$TMP_DIR/$case_name/dist" \
    "$ROOT_DIR/scripts/release.sh" >"$TMP_DIR/$case_name.stdout" \
    2>"$TMP_DIR/$case_name.stderr"; then
    echo "release unexpectedly accepted $forbidden_name" >&2
    exit 1
  fi
  grep -Fq 'Refusing non-RAM build artifact:' "$TMP_DIR/$case_name.stderr"
  [[ ! -e "$TMP_DIR/$case_name/dist" ]]
}

expect_rejected sysupgrade 'openwrt-test-sysupgrade.bin'
expect_rejected factory 'openwrt-test-factory.bin'
expect_rejected ubi 'openwrt-test-rootfs.ubi'

echo 'release policy mock: success and sysupgrade/factory/ubi rejection paths OK'
