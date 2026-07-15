#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
if [[ "$NEXAWRT_FLAVOR" != official ]]; then
  echo "Refusing release staging for experimental flavor: $NEXAWRT_FLAVOR" >&2
  exit 1
fi
WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work/openwrt}"
BIN_DIR="$WORK_DIR/bin/targets/qualcommax/ipq807x"
DIST_DIR="${DIST_DIR_OVERRIDE:-$ROOT_DIR/dist}"

[[ -d "$BIN_DIR" ]] || { echo "Build output not found: $BIN_DIR" >&2; exit 1; }

for forbidden_pattern in '*sysupgrade*' '*factory*' '*.ubi'; do
  forbidden_artifact="$(find "$BIN_DIR" -maxdepth 1 -type f -name "$forbidden_pattern" -print -quit)"
  if [[ -n "$forbidden_artifact" ]]; then
    echo "Refusing non-RAM build artifact: $forbidden_artifact" >&2
    exit 1
  fi
done

initramfs_images=()
while IFS= read -r image; do
  initramfs_images+=("$image")
done < <(find "$BIN_DIR" -maxdepth 1 -type f \
  -name '*xiaomi_ax9000_single_ubi*initramfs*uImage.itb' -print | LC_ALL=C sort)
((${#initramfs_images[@]} > 0)) || { echo "Custom AX9000 initramfs image not found" >&2; exit 1; }

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Current project stage publishes RAM-boot images only. Reject all common
# persistent image forms above, then copy only the custom initramfs output.
cp "${initramfs_images[@]}" "$DIST_DIR/"

for metadata in config.buildinfo feeds.buildinfo profiles.json version.buildinfo; do
  [[ -f "$BIN_DIR/$metadata" ]] && cp "$BIN_DIR/$metadata" "$DIST_DIR/"
done

cat > "$DIST_DIR/BUILD-MANIFEST.txt" <<MANIFEST
project=NexaWrt
layout=$LAYOUT_ID
stage=initramfs-ram-boot-only
openwrt_tag=$OPENWRT_TAG
openwrt_commit=$OPENWRT_COMMIT
rootfs_mtd_offset=$ROOTFS_MTD_OFFSET_HEX
rootfs_mtd_size=$ROOTFS_MTD_SIZE_HEX
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

cat > "$DIST_DIR/DO-NOT-FLASH.txt" <<'NOTICE'
This NexaWrt release directory intentionally contains only initramfs RAM-boot images.
Do not write these files to MTD/UBI and do not use sysupgrade. UART, backups,
bootloader visibility, and recovery must be proven before any persistent stage.
NOTICE

(
  cd "$DIST_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- * > SHA256SUMS
  else
    shasum -a 256 -- * > SHA256SUMS
  fi
)

printf 'NexaWrt RAM-boot-only release files written to %s\n' "$DIST_DIR"
