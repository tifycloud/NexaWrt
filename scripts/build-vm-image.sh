#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/manifests/vm.lock"
SMOKE_OVERLAY_DIR="$ROOT_DIR/vm-files"
RELEASE_OVERLAY_DIR="$ROOT_DIR/vm-files-release"
WORK_DIR="${VM_WORK_DIR:-$ROOT_DIR/.work/vm}"
OUTPUT_ROOT="${VM_OUTPUT_DIR:-$ROOT_DIR/dist/vm}"
ROOTFS_PARTSIZE="${VM_ROOTFS_PARTSIZE:-256}"
RELEASE_TAG_PATTERN='^vm-x86_64-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*)$'

usage() {
  cat >&2 <<'USAGE'
Usage:
  build-vm-image.sh <x86-64|armsr-armv8>
  build-vm-image.sh x86-64 release <vm-x86_64-vX.Y.Z-rc.N>
  build-vm-image.sh x86-64 <vm-x86_64-vX.Y.Z-rc.N>

Build a VM-only OpenWrt image from a SHA256-pinned ImageBuilder.

The one-argument form is the existing smoke mode. It remains compatible with
.github/workflows/vm-smoke.yml and requires VM_SMOKE_AUTHORIZED_KEY_FILE.

Release mode is only for x86-64 user-distribution images. It never injects CI
SSH authorized_keys and uses the independent vm-files-release overlay.
USAGE
}

fail() {
  printf 'build-vm-image: %s\n' "$*" >&2
  exit 1
}

select_x86_64_release_manifest() {
  local target_dir="$1"
  local openwrt_version="$2"
  local built_image_basename="$3"
  local expected_basename="openwrt-${openwrt_version}-x86-64-generic.manifest"
  local image_derived_basename="${built_image_basename%.img.gz}.manifest"
  local candidate
  local candidate_basename
  local manifests=()

  [[ -d "$target_dir" ]] || fail "release manifest target directory is missing: $target_dir"
  [[ "$built_image_basename" == *.img.gz ]] ||
    fail "release manifest selection requires an .img.gz image basename: $built_image_basename"
  [[ "$expected_basename" != "$image_derived_basename" ]] ||
    fail "target manifest must not be named after the concrete release image: $expected_basename"

  while IFS= read -r -d '' candidate; do
    manifests+=("$candidate")
  done < <(find "$target_dir" -mindepth 1 -maxdepth 1 -name '*.manifest' -print0)

  [[ "${#manifests[@]}" -eq 1 ]] ||
    fail "release build requires exactly one manifest directory entry in $target_dir; found ${#manifests[@]}"

  candidate="${manifests[0]}"
  [[ -f "$candidate" && ! -L "$candidate" ]] ||
    fail "release target manifest must be a regular non-symlink file: $candidate"
  candidate_basename="${candidate##*/}"
  [[ "$candidate_basename" == "$expected_basename" ]] ||
    fail "unexpected release target manifest name: $candidate_basename (expected $expected_basename)"
  [[ "$candidate_basename" != "$image_derived_basename" ]] ||
    fail "release manifest must be target-level, not image-specific: $candidate_basename"

  printf '%s\n' "$candidate"
}

# Keep the selector sourceable for offline policy tests without executing a build.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

MODE="smoke"
RELEASE_TAG=""
case "$#" in
  1)
    TARGET="$1"
    ;;
  2)
    TARGET="$1"
    if [[ "$2" == release ]]; then
      MODE="release"
      RELEASE_TAG="${VM_RELEASE_TAG:-}"
    elif [[ "$2" =~ $RELEASE_TAG_PATTERN ]]; then
      MODE="release"
      RELEASE_TAG="$2"
    else
      usage
      fail "unsupported mode or release tag: $2"
    fi
    ;;
  3)
    TARGET="$1"
    [[ "$2" == release ]] || { usage; fail "unsupported mode: $2"; }
    MODE="release"
    RELEASE_TAG="$3"
    ;;
  *)
    usage
    exit 2
    ;;
esac

[[ -f "$LOCK_FILE" ]] || fail "missing lock file: $LOCK_FILE"
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
    [[ "$MODE" == smoke ]] || fail "release mode supports x86-64 only, not $TARGET"
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

case "$MODE" in
  smoke)
    OVERLAY_DIR="$SMOKE_OVERLAY_DIR"
    ARTIFACT_CLASS="VM_SMOKE_IMAGE"
    ARTIFACT_BASENAME="nexawrt-vm-smoke-openwrt-${VM_OPENWRT_VERSION}-${TARGET}.img.gz"
    RELEASE_VERSION=""
    ;;
  release)
    [[ "$TARGET" == x86-64 ]] || fail "release mode supports x86-64 only"
    [[ -n "$RELEASE_TAG" ]] || fail "release mode requires a tag: vm-x86_64-vX.Y.Z-rc.N"
    [[ "$RELEASE_TAG" =~ $RELEASE_TAG_PATTERN ]] || fail "release tag must match vm-x86_64-vX.Y.Z-rc.N: $RELEASE_TAG"
    OVERLAY_DIR="$RELEASE_OVERLAY_DIR"
    ARTIFACT_CLASS="VM_DISTRIBUTION_IMAGE"
    RELEASE_VERSION="${RELEASE_TAG#vm-x86_64-}"
    ARTIFACT_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined.img.gz"
    ;;
  *)
    fail "internal error: unsupported mode $MODE"
    ;;
esac

[[ -d "$OVERLAY_DIR" ]] || fail "missing VM overlay: $OVERLAY_DIR"
for command_name in curl sha256sum tar make find install cp tee wc grep sort; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done
[[ "$ROOTFS_PARTSIZE" =~ ^[1-9][0-9]*$ ]] || fail "VM_ROOTFS_PARTSIZE must be a positive integer"

AUTHORIZED_KEY_FILE="${VM_SMOKE_AUTHORIZED_KEY_FILE:-}"
if [[ "$MODE" == smoke ]]; then
  [[ -n "$AUTHORIZED_KEY_FILE" ]] || fail "VM_SMOKE_AUTHORIZED_KEY_FILE is required in smoke mode"
  [[ -f "$AUTHORIZED_KEY_FILE" && ! -L "$AUTHORIZED_KEY_FILE" ]] || fail "authorized key must be a regular file"
  [[ "$(wc -l < "$AUTHORIZED_KEY_FILE" | tr -d ' ')" == 1 ]] || fail "authorized key must contain exactly one line"
  grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+' "$AUTHORIZED_KEY_FILE" ||
    fail "authorized key is not a supported OpenSSH public key"
elif [[ -n "$AUTHORIZED_KEY_FILE" ]]; then
  fail "VM_SMOKE_AUTHORIZED_KEY_FILE must not be set in release mode"
fi

case "$(printf '%s' "$ARTIFACT_BASENAME" | tr '[:upper:]' '[:lower:]')" in
  *ax9000*) fail "VM image artifact name must not mention AX9000: $ARTIFACT_BASENAME" ;;
esac

ARCHIVE_NAME="${IMAGEBUILDER_URL##*/}"
DOWNLOAD_DIR="$WORK_DIR/downloads"
BUILDER_ROOT="$WORK_DIR/imagebuilders/$TARGET-$MODE"
OVERLAY_WORK="$WORK_DIR/overlay-$TARGET-$MODE"
OUTPUT_DIR="$OUTPUT_ROOT/$TARGET"
ARCHIVE_PATH="$DOWNLOAD_DIR/$ARCHIVE_NAME"
rm -rf "$OUTPUT_DIR"
mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"
BUILD_LOG="$OUTPUT_DIR/build.log"

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
if [[ "$MODE" == smoke ]]; then
  mkdir -p "$OVERLAY_WORK/etc/dropbear"
  install -m 0600 "$AUTHORIZED_KEY_FILE" "$OVERLAY_WORK/etc/dropbear/authorized_keys"
else
  if find "$OVERLAY_WORK" -type f -path '*/authorized_keys' -print -quit | grep -q .; then
    fail "release overlay must not contain SSH authorized_keys"
  fi
fi

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
  printf 'VM-only OpenWrt %s %s build for %s\n' "$VM_OPENWRT_VERSION" "$MODE" "$TARGET"
  printf 'ImageBuilder: %s\n' "$IMAGEBUILDER_URL"
  printf 'ImageBuilder SHA256: %s\n' "$IMAGEBUILDER_SHA256"
  if [[ "$MODE" == release ]]; then
    printf 'Release tag: %s\n' "$RELEASE_TAG"
    printf 'Release version: %s\n' "$RELEASE_VERSION"
  fi
  printf 'Validation scope: QEMU boot/userspace only; not hardware or NSS validation.\n'
  make -C "$BUILDER_DIR" image \
    PROFILE="$PROFILE" \
    PACKAGES="$PACKAGE_LIST" \
    FILES="$OVERLAY_WORK" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"
} 2>&1 | tee "$BUILD_LOG"

BUILT_IMAGE="$BUILDER_DIR/bin/targets/$TARGET_PATH/$UPSTREAM_IMAGE"
[[ -f "$BUILT_IMAGE" ]] || fail "expected image was not produced: $BUILT_IMAGE"
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME"
cp "$BUILT_IMAGE" "$ARTIFACT_PATH"

MANIFEST_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME%.img.gz}.manifest"
if [[ "$MODE" == release ]]; then
  MANIFEST_SOURCE="$(
    select_x86_64_release_manifest \
      "$BUILDER_DIR/bin/targets/$TARGET_PATH" \
      "$VM_OPENWRT_VERSION" \
      "${BUILT_IMAGE##*/}"
  )"
  cp "$MANIFEST_SOURCE" "$MANIFEST_PATH"
else
  # Preserve the historical smoke-mode behavior: copy an image-specific
  # manifest only when that optional file exists.
  MANIFEST_SOURCE="${BUILT_IMAGE%.img.gz}.manifest"
  if [[ -f "$MANIFEST_SOURCE" ]]; then
    cp "$MANIFEST_SOURCE" "$MANIFEST_PATH"
  fi
fi

LABELS_PATH="$OUTPUT_DIR/artifact-labels.env"
cat > "$LABELS_PATH" <<EOF_LABELS
ARTIFACT_CLASS="$ARTIFACT_CLASS"
OPENWRT_VERSION="$VM_OPENWRT_VERSION"
TARGET="$TARGET"
MODE="$MODE"
VM_ONLY="true"
NOT_AX9000_FIRMWARE="true"
HARDWARE_VALIDATION="false"
NSS_VALIDATION="false"
VALIDATION_SCOPE="QEMU_BOOT_AND_USERSPACE_ONLY"
IMAGEBUILDER_URL="$IMAGEBUILDER_URL"
IMAGEBUILDER_SHA256="$IMAGEBUILDER_SHA256"
EOF_LABELS
if [[ "$MODE" == release ]]; then
  {
    printf 'RELEASE_TAG="%s"\n' "$RELEASE_TAG"
    printf 'RELEASE_VERSION="%s"\n' "$RELEASE_VERSION"
    printf 'SSH_DEFAULT="disabled"\n'
    printf 'SSH_AUTHORIZED_KEYS="absent"\n'
  } >> "$LABELS_PATH"
fi

README_PATH="$OUTPUT_DIR/README-VM.txt"
if [[ "$MODE" == release ]]; then
  cat > "$README_PATH" <<EOF_README
NexaWrt x86_64 VM ${RELEASE_VERSION}

WARNING / 警告
- This is an x86_64 virtual-machine image only.
- It is NOT Xiaomi AX9000 firmware.
- Do not upload it to AX9000 LuCI.
- Do not use it with sysupgrade, mtd, UBI, NAND, or router flash tools.
- QEMU PASS means OpenWrt userspace/LuCI/basic networking works in a VM only.
- It does not validate AX9000 bootloader, DTS, Wi-Fi, switch, NSS, NAND layout, or recovery.

First boot
1. Decompress the image:
   gzip -dk ${ARTIFACT_BASENAME}
2. Verify checksum:
   sha256sum -c ${ARTIFACT_BASENAME}.sha256
3. Boot with QEMU:
   qemu-system-x86_64 \\
     -m 512 \\
     -smp 2 \\
     -display none \\
     -monitor none \\
     -serial stdio \\
     -machine q35,accel=tcg \\
     -drive file=${ARTIFACT_BASENAME%.gz},format=raw,if=ide \\
     -netdev user,id=net0,hostfwd=tcp:127.0.0.1:8080-:80 \\
     -device e1000,netdev=net0
4. Open LuCI: http://127.0.0.1:8080/cgi-bin/luci/
5. Remote SSH is disabled by default. Use the VM serial console, run passwd,
   then enable SSH only if you need it:
   /etc/init.d/dropbear enable
   /etc/init.d/dropbear start

Dangerous router-write commands are intentionally guarded inside this VM image.
EOF_README
fi

(
  cd "$OUTPUT_DIR"
  sha256sum "$ARTIFACT_BASENAME" > "${ARTIFACT_BASENAME}.sha256"
  if [[ "$MODE" == release ]]; then
    sha256sum \
      "$ARTIFACT_BASENAME" \
      "${ARTIFACT_BASENAME}.sha256" \
      "$(basename "$MANIFEST_PATH")" \
      "$(basename "$LABELS_PATH")" \
      "$(basename "$README_PATH")" > SHA256SUMS
  else
    sha256sum "$ARTIFACT_BASENAME" > SHA256SUMS
  fi
)

printf 'Built VM-only %s image: %s\n' "$MODE" "$ARTIFACT_PATH"
printf 'This artifact is not AX9000 firmware, not hardware validation, and not NSS validation.\n'
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'image=%s\n' "$ARTIFACT_PATH"
    printf 'artifact_dir=%s\n' "$OUTPUT_DIR"
    printf 'artifact_basename=%s\n' "$ARTIFACT_BASENAME"
    printf 'manifest=%s\n' "$MANIFEST_PATH"
    printf 'labels=%s\n' "$LABELS_PATH"
    printf 'readme=%s\n' "$README_PATH"
    printf 'sha256=%s\n' "$OUTPUT_DIR/${ARTIFACT_BASENAME}.sha256"
  } >> "$GITHUB_OUTPUT"
fi
