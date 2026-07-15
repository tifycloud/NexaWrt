#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../manifests/nss.lock
source "$ROOT_DIR/manifests/nss.lock"

NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
if [[ "$NEXAWRT_FLAVOR" != nss ]]; then
  echo "Refusing NSS artifact staging for flavor: $NEXAWRT_FLAVOR" >&2
  exit 1
fi

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work/openwrt-nss}"
BIN_DIR="$WORK_DIR/bin/targets/qualcommax/ipq807x"
DIST_DIR="${DIST_NSS_DIR_OVERRIDE:-$ROOT_DIR/dist-nss}"
EXPECTED_IMAGE="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb"
FIRMWARE_LICENSE="$ROOT_DIR/files-nss/usr/share/licenses/nss-firmware/LICENSE.md"
THIRD_PARTY_NOTICE="$ROOT_DIR/THIRD_PARTY_NOTICES.md"

fail() {
  echo "NSS artifact staging refused: $*" >&2
  exit 1
}

[[ -d "$BIN_DIR" ]] || fail "build output not found: $BIN_DIR"
[[ -f "$FIRMWARE_LICENSE" ]] || fail "NSS firmware license notice is missing"
[[ -f "$THIRD_PARTY_NOTICE" ]] || fail "THIRD_PARTY_NOTICES.md is missing"

case "$DIST_DIR" in
  ""|/|.|..|"$ROOT_DIR"|"$WORK_DIR"|"$BIN_DIR")
    fail "unsafe staging directory: $DIST_DIR"
    ;;
esac
[[ "$(basename "$DIST_DIR")" == dist-nss ]] ||
  fail "staging directory must end in dist-nss: $DIST_DIR"

expected_images=()
while IFS= read -r -d '' candidate; do
  expected_images+=("$candidate")
done < <(find "$BIN_DIR" -maxdepth 1 -type f -name "$EXPECTED_IMAGE" -print0)

((${#expected_images[@]} == 1)) ||
  fail "expected exactly one $EXPECTED_IMAGE, found ${#expected_images[@]}"

# Fail closed on every image-like file. The only permitted image is the exact,
# flavor-specific AX9000 single_ubi initramfs ITB named above.
while IFS= read -r -d '' candidate; do
  base="$(basename "$candidate")"
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *sysupgrade*|*factory*)
      fail "persistent/installer artifact present: $base"
      ;;
  esac
  case "$lower" in
    *.bin|*.img|*.itb|*.ubi|*.ubifs|*.squashfs|*.jffs2|*.ext4|*.trx|*.chk|*.iso|*.vmdk|*.vdi|*.qcow2|*.fit|*.uimage|*.elf|*.dtb|*.fdt|*.fw|*.firmware|*rootfs*.tar|*rootfs*.tar.gz|*rootfs*.tgz|*rootfs*.gz|*rootfs*.xz|*rootfs*.zst)
      [[ "$candidate" == "$BIN_DIR/$EXPECTED_IMAGE" ]] || fail "non-allowlisted image artifact present: $candidate"
      ;;
  esac
done < <(find "$BIN_DIR" -type f -print0)

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/LICENSES/nss-firmware"
cp "${expected_images[0]}" "$DIST_DIR/$EXPECTED_IMAGE"

for metadata in config.buildinfo feeds.buildinfo profiles.json version.buildinfo; do
  [[ -f "$BIN_DIR/$metadata" ]] && cp "$BIN_DIR/$metadata" "$DIST_DIR/$metadata"
done

cp "$THIRD_PARTY_NOTICE" "$DIST_DIR/THIRD_PARTY_NOTICES.md"
cp "$FIRMWARE_LICENSE" "$DIST_DIR/LICENSES/nss-firmware/LICENSE.md"

cat > "$DIST_DIR/BUILD-MANIFEST.txt" <<MANIFEST
project=NexaWrt
flavor=nss
source_repository=$NSS_OPENWRT_REPO
source_branch=$NSS_OPENWRT_BRANCH
source_commit=$NSS_OPENWRT_COMMIT
nss_packages_feed_repository=$NSS_PACKAGES_REPO
nss_packages_feed_commit=$NSS_PACKAGES_COMMIT
nss_sqm_feed_repository=$NSS_SQM_REPO
nss_sqm_feed_commit=$NSS_SQM_COMMIT
stage=initramfs-ram-boot-only
real_device_boot_approved=no
image=$EXPECTED_IMAGE
build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST

cat > "$DIST_DIR/DO-NOT-FLASH.txt" <<'NOTICE'
NexaWrt experimental NSS artifact: initramfs RAM-boot candidate only.
Do not flash, write to MTD/UBI, run sysupgrade, or save bootloader changes.
Real-device RAM boot is not approved. UART, backups, bootloader visibility,
and a reviewed recovery path are required before any separately authorized test.
NOTICE

(
  cd "$DIST_DIR"
  hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -- "$1"
    else
      shasum -a 256 -- "$1"
    fi
  }
  while IFS= read -r staged_file; do
    hash_file "$staged_file"
  done < <(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort) > SHA256SUMS
)

# Audit the resulting directory itself. Future additions must be explicitly
# allowlisted here before they can leave the build job.
while IFS= read -r -d '' staged_file; do
  relative="${staged_file#"$DIST_DIR"/}"
  case "$relative" in
    "$EXPECTED_IMAGE"|config.buildinfo|feeds.buildinfo|profiles.json|version.buildinfo|\
    BUILD-MANIFEST.txt|DO-NOT-FLASH.txt|THIRD_PARTY_NOTICES.md|SHA256SUMS|\
    LICENSES/nss-firmware/LICENSE.md)
      ;;
    *)
      fail "unexpected file entered staging directory: $relative"
      ;;
  esac
done < <(find "$DIST_DIR" -type f -print0)

printf 'NexaWrt experimental NSS RAM-boot-only artifact staged at %s\n' "$DIST_DIR"
