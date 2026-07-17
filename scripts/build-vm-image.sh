#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/manifests/vm.lock"
OVERLAY_DIR="$ROOT_DIR/vm-files"
WORK_DIR="${VM_WORK_DIR:-$ROOT_DIR/.work/vm}"
OUTPUT_ROOT="${VM_OUTPUT_DIR:-$ROOT_DIR/dist/vm}"
ROOTFS_PARTSIZE="${VM_ROOTFS_PARTSIZE:-256}"

usage() {
  cat >&2 <<'USAGE'
Usage: build-vm-image.sh <x86-64|armsr-armv8>

Build a VM-only OpenWrt smoke image from a SHA256-pinned ImageBuilder.
VM_SMOKE_AUTHORIZED_KEY_FILE must name the public SSH key injected for the test.
USAGE
}

fail() {
  printf 'build-vm-image: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || { usage; exit 2; }
TARGET="$1"
[[ -f "$LOCK_FILE" ]] || fail "missing lock file: $LOCK_FILE"
[[ -d "$OVERLAY_DIR" ]] || fail "missing VM overlay: $OVERLAY_DIR"
# vm.lock is repository-controlled and policy-tested as declarative assignments only.
# shellcheck source=../manifests/vm.lock
source "$LOCK_FILE"

case "$TARGET" in
  x86-64)
    TARGET_PATH="x86/64"
    PROFILE="generic"
    IMAGEBUILDER_URL="$VM_X86_64_IMAGEBUILDER_URL"
    IMAGEBUILDER_SHA256="$VM_X86_64_IMAGEBUILDER_SHA256"
    UPSTREAM_IMAGE="openwrt-${VM_OPENWRT_VERSION}-x86-64-generic-ext4-combined.img.gz"
    ;;
  armsr-armv8)
    TARGET_PATH="armsr/armv8"
    PROFILE="generic"
    IMAGEBUILDER_URL="$VM_ARMSR_ARMV8_IMAGEBUILDER_URL"
    IMAGEBUILDER_SHA256="$VM_ARMSR_ARMV8_IMAGEBUILDER_SHA256"
    UPSTREAM_IMAGE="openwrt-${VM_OPENWRT_VERSION}-armsr-armv8-generic-ext4-combined-efi.img.gz"
    ;;
  *)
    usage
    fail "unsupported target: $TARGET"
    ;;
esac

for command_name in curl sha256sum tar make find install cp tee; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done
[[ "$ROOTFS_PARTSIZE" =~ ^[1-9][0-9]*$ ]] || fail "VM_ROOTFS_PARTSIZE must be a positive integer"

AUTHORIZED_KEY_FILE="${VM_SMOKE_AUTHORIZED_KEY_FILE:-}"
[[ -n "$AUTHORIZED_KEY_FILE" ]] || fail "VM_SMOKE_AUTHORIZED_KEY_FILE is required"
[[ -f "$AUTHORIZED_KEY_FILE" && ! -L "$AUTHORIZED_KEY_FILE" ]] || fail "authorized key must be a regular file"
[[ "$(wc -l < "$AUTHORIZED_KEY_FILE" | tr -d ' ')" == 1 ]] || fail "authorized key must contain exactly one line"
grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+' "$AUTHORIZED_KEY_FILE" ||
  fail "authorized key is not a supported OpenSSH public key"

ARCHIVE_NAME="${IMAGEBUILDER_URL##*/}"
DOWNLOAD_DIR="$WORK_DIR/downloads"
BUILDER_ROOT="$WORK_DIR/imagebuilders/$TARGET"
OVERLAY_WORK="$WORK_DIR/overlay-$TARGET"
OUTPUT_DIR="$OUTPUT_ROOT/$TARGET"
ARCHIVE_PATH="$DOWNLOAD_DIR/$ARCHIVE_NAME"
BUILD_LOG="$OUTPUT_DIR/build.log"
mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"

if [[ ! -f "$ARCHIVE_PATH" ]] || ! printf '%s  %s\n' "$IMAGEBUILDER_SHA256" "$ARCHIVE_PATH" | sha256sum --check --status; then
  rm -f "$ARCHIVE_PATH"
  download_tmp="$ARCHIVE_PATH.part"
  rm -f "$download_tmp"
  curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 \
    --output "$download_tmp" "$IMAGEBUILDER_URL"
  printf '%s  %s\n' "$IMAGEBUILDER_SHA256" "$download_tmp" | sha256sum --check --status || {
    rm -f "$download_tmp"
    fail "ImageBuilder SHA256 mismatch for $TARGET"
  }
  mv "$download_tmp" "$ARCHIVE_PATH"
fi

rm -rf "$BUILDER_ROOT"
mkdir -p "$BUILDER_ROOT"
tar --zstd -xf "$ARCHIVE_PATH" -C "$BUILDER_ROOT"
BUILDER_DIR="$(find "$BUILDER_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'openwrt-imagebuilder-*' -print -quit)"
[[ -n "$BUILDER_DIR" ]] || fail "ImageBuilder archive did not contain the expected directory"

rm -rf "$OVERLAY_WORK"
mkdir -p "$OVERLAY_WORK"
cp -a "$OVERLAY_DIR/." "$OVERLAY_WORK/"
mkdir -p "$OVERLAY_WORK/etc/dropbear"
install -m 0600 "$AUTHORIZED_KEY_FILE" "$OVERLAY_WORK/etc/dropbear/authorized_keys"

# Keep this package set identical for both VM architectures. It intentionally
# contains LuCI, Dropbear SSH, and the utility baseline shared by release flavors.
VM_PACKAGES=(
  luci
  luci-ssl
  dropbear
  ca-bundle
  curl
  ethtool
  htop
  iperf3
  nano
  tcpdump-mini
)
printf -v PACKAGE_LIST ' %q' "${VM_PACKAGES[@]}"
PACKAGE_LIST="${PACKAGE_LIST# }"

rm -rf "$BUILDER_DIR/bin/targets/$TARGET_PATH"
{
  printf 'VM-only OpenWrt %s build for %s\n' "$VM_OPENWRT_VERSION" "$TARGET"
  printf 'ImageBuilder: %s\n' "$IMAGEBUILDER_URL"
  printf 'ImageBuilder SHA256: %s\n' "$IMAGEBUILDER_SHA256"
  printf 'Validation scope: QEMU boot/userspace only; not hardware or NSS validation.\n'
  make -C "$BUILDER_DIR" image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGE_LIST" \
    FILES="$OVERLAY_WORK" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"
} 2>&1 | tee "$BUILD_LOG"

BUILT_IMAGE="$BUILDER_DIR/bin/targets/$TARGET_PATH/$UPSTREAM_IMAGE"
[[ -f "$BUILT_IMAGE" ]] || fail "expected image was not produced: $BUILT_IMAGE"
ARTIFACT_BASENAME="nexawrt-vm-smoke-openwrt-${VM_OPENWRT_VERSION}-${TARGET}.img.gz"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME"
cp "$BUILT_IMAGE" "$ARTIFACT_PATH"

MANIFEST_SOURCE="${BUILT_IMAGE%.img.gz}.manifest"
if [[ -f "$MANIFEST_SOURCE" ]]; then
  cp "$MANIFEST_SOURCE" "$OUTPUT_DIR/${ARTIFACT_BASENAME%.img.gz}.manifest"
fi

cat > "$OUTPUT_DIR/artifact-labels.env" <<EOF_LABELS
ARTIFACT_CLASS="VM_SMOKE_IMAGE"
OPENWRT_VERSION="$VM_OPENWRT_VERSION"
TARGET="$TARGET"
VM_ONLY="true"
NOT_AX9000_FIRMWARE="true"
HARDWARE_VALIDATION="false"
NSS_VALIDATION="false"
VALIDATION_SCOPE="QEMU_BOOT_AND_USERSPACE_ONLY"
IMAGEBUILDER_URL="$IMAGEBUILDER_URL"
IMAGEBUILDER_SHA256="$IMAGEBUILDER_SHA256"
EOF_LABELS
(
  cd "$OUTPUT_DIR"
  sha256sum "$ARTIFACT_BASENAME" > SHA256SUMS
)

printf 'Built VM-only smoke image: %s\n' "$ARTIFACT_PATH"
printf 'This artifact is not hardware validation and not NSS validation.\n'
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'image=%s\n' "$ARTIFACT_PATH"
    printf 'artifact_dir=%s\n' "$OUTPUT_DIR"
  } >> "$GITHUB_OUTPUT"
fi
