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
RELEASE_CONTRACT='vm-x86_64/v2'
PUBLISHED_VARIANTS='raw_bios,iso_bios,iso_efi,vmdk_bios,vmdk_efi'

usage() {
  cat >&2 <<'USAGE'
Usage:
  build-vm-image.sh <x86-64|armsr-armv8>
  build-vm-image.sh x86-64 release <vm-x86_64-vX.Y.Z-rc.N>
  build-vm-image.sh x86-64 <vm-x86_64-vX.Y.Z-rc.N>
  build-vm-image.sh x86-64 custom

Build VM-only OpenWrt artifacts from a SHA256-pinned ImageBuilder.

The one-argument form is the existing smoke mode. It remains compatible with
.github/workflows/vm-smoke.yml and requires VM_SMOKE_AUTHORIZED_KEY_FILE.

Release mode is x86-64 only. The v2 contract builds exactly five publishable
ext4 variants: raw BIOS, BIOS/EFI Live ISO, and BIOS/EFI VMDK. It never injects
CI SSH authorized_keys and never claims ESXi validation.

Custom mode is x86-64 only and accepts component IDs only through the validated
NEXAWRT_COMPONENTS environment set by scripts/custom-build.sh.
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

select_x86_64_release_inputs() {
  local target_dir="$1"
  local openwrt_version="$2"
  local generic_prefix="openwrt-${openwrt_version}-x86-64-generic"
  local expected_names=(
    "${generic_prefix}-ext4-combined.img.gz"
    "${generic_prefix}-ext4-combined-efi.img.gz"
    "${generic_prefix}-image.iso"
    "${generic_prefix}-image-efi.iso"
    "${generic_prefix}-ext4-combined.vmdk.gz"
    "${generic_prefix}-ext4-combined-efi.vmdk.gz"
  )
  local selected=()
  local candidate
  local expected

  [[ -d "$target_dir" ]] || fail "release image target directory is missing: $target_dir"

  # OpenWrt 25.12.5 still emits squashfs files even when
  # CONFIG_TARGET_ROOTFS_SQUASHFS=n is passed to ImageBuilder. Do not use that
  # make argument as evidence that squashfs was suppressed; bind only these six
  # exact inputs. The native monolithicSparse VMDKs are source/capability checks,
  # while the published VMDKs are converted from the matching ext4 raw disks.
  for expected in "${expected_names[@]}"; do
    candidate="$target_dir/$expected"
    [[ -f "$candidate" && ! -L "$candidate" ]] ||
      fail "required upstream release input is missing or not a regular non-symlink file: $candidate"
    [[ -s "$candidate" ]] || fail "required upstream release input is empty: $candidate"
    selected+=("$candidate")
  done

  [[ "${#selected[@]}" -eq 6 ]] || fail "internal error: release selector did not bind six upstream inputs"
  printf '%s\n' "${selected[@]}"
}

# Backward-compatible function name for focused policy tests. The v2 release
# selector now returns six build inputs used to produce five published images.
select_x86_64_release_images() {
  select_x86_64_release_inputs "$@"
}
# Keep selectors sourceable for offline policy tests without executing a build.
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
    elif [[ "$2" == custom ]]; then
      MODE="custom"
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
    [[ "$MODE" == smoke ]] || fail "$MODE mode supports x86-64 only, not $TARGET"
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

CUSTOM_REQUEST_HASH=""
CUSTOM_CATALOG_VERSION=""
CUSTOM_FLAVOR=""
CUSTOM_COMPONENTS=""
CUSTOM_RESOLVED_COMPONENTS=""
CUSTOM_PACKAGES=()
if [[ "$MODE" == custom ]]; then
  [[ "$TARGET" == x86-64 ]] || fail "custom mode supports x86-64 only"
  CUSTOM_COMPONENTS="${NEXAWRT_COMPONENTS:-}"
  CUSTOM_FLAVOR="${NEXAWRT_COMPONENT_FLAVOR:-}"
  CUSTOM_CATALOG_VERSION="${NEXAWRT_COMPONENT_CATALOG_VERSION:-}"
  CUSTOM_REQUEST_HASH="${NEXAWRT_COMPONENT_REQUEST_HASH:-}"
  [[ ${#CUSTOM_COMPONENTS} -le 1024 ]] ||
    fail "custom mode component input exceeds the bounded length"
  if [[ -n "$CUSTOM_COMPONENTS" ]]; then
    [[ "$CUSTOM_COMPONENTS" =~ ^[a-z0-9][a-z0-9_-]{0,63}(,[a-z0-9][a-z0-9_-]{0,63})*$ ]] ||
      fail "non-empty custom components must be comma-separated catalog component IDs"
  fi
  [[ "$CUSTOM_FLAVOR" == official ]] ||
    fail "custom x86 mode requires NEXAWRT_COMPONENT_FLAVOR=official"
  [[ "$CUSTOM_CATALOG_VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] ||
    fail "custom mode requires a valid NEXAWRT_COMPONENT_CATALOG_VERSION"
  [[ "$CUSTOM_REQUEST_HASH" =~ ^[0-9a-f]{64}$ ]] ||
    fail "custom mode requires a full lowercase NEXAWRT_COMPONENT_REQUEST_HASH"
  custom_resolver_args=(--target x86_64 --flavor "$CUSTOM_FLAVOR")
  if [[ -n "$CUSTOM_COMPONENTS" ]]; then
    IFS=',' read -r -a custom_component_ids <<< "$CUSTOM_COMPONENTS"
    for component_id in "${custom_component_ids[@]}"; do
      custom_resolver_args+=(--component "$component_id")
    done
  fi
  custom_resolution="$(python3 "$ROOT_DIR/scripts/resolve-components.py" "${custom_resolver_args[@]}")" ||
    fail "custom component selection was rejected"
  custom_fields_output="$(python3 -c '
import json, re, sys
request = json.load(sys.stdin)
if request.get("target", {}).get("id") != "x86_64":
    raise SystemExit("unexpected resolver target")
request_hash = request.get("request_hash", "")
catalog_version = request.get("catalog_version", "")
flavor = request.get("flavor", "")
packages = request.get("packages")
components = request.get("resolved_components")
if not re.fullmatch(r"[0-9a-f]{64}", request_hash):
    raise SystemExit("invalid resolver request hash")
if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]+)?", catalog_version):
    raise SystemExit("invalid resolver catalog version")
if flavor != "official":
    raise SystemExit("invalid resolver flavor")
if not isinstance(components, list) or not components:
    raise SystemExit("resolver returned no components")
if any(not isinstance(component, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", component) for component in components):
    raise SystemExit("invalid resolver component")
if not isinstance(packages, list) or not packages:
    raise SystemExit("resolver returned no packages")
print(request_hash)
print(catalog_version)
print(flavor)
print(",".join(components))
for package in packages:
    if not isinstance(package, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]{0,127}", package):
        raise SystemExit("invalid resolver package")
    print(package)
' <<< "$custom_resolution")" || fail "custom resolver output failed validation"
  custom_resolution_fields=()
  while IFS= read -r custom_field; do
    custom_resolution_fields+=("$custom_field")
  done <<< "$custom_fields_output"
  ((${#custom_resolution_fields[@]} >= 5)) || fail "custom resolver output is incomplete"
  [[ "${custom_resolution_fields[0]}" == "$CUSTOM_REQUEST_HASH" ]] ||
    fail "custom request hash does not match the resolved catalog request"
  [[ "${custom_resolution_fields[1]}" == "$CUSTOM_CATALOG_VERSION" ]] ||
    fail "custom catalog version does not match the resolved catalog request"
  [[ "${custom_resolution_fields[2]}" == "$CUSTOM_FLAVOR" ]] ||
    fail "custom flavor does not match the resolved catalog request"
  CUSTOM_RESOLVED_COMPONENTS="${custom_resolution_fields[3]}"
  CUSTOM_PACKAGES=("${custom_resolution_fields[@]:4}")
fi

case "$MODE" in
  smoke)
    OVERLAY_DIR="$SMOKE_OVERLAY_DIR"
    ARTIFACT_CLASS="VM_SMOKE_IMAGE"
    VALIDATION_SCOPE_VALUE="QEMU_BOOT_AND_USERSPACE_ONLY"
    ARTIFACT_BASENAME="nexawrt-vm-smoke-openwrt-${VM_OPENWRT_VERSION}-${TARGET}.img.gz"
    RELEASE_VERSION=""
    ;;
  release)
    [[ "$TARGET" == x86-64 ]] || fail "release mode supports x86-64 only"
    [[ -n "$RELEASE_TAG" ]] || fail "release mode requires a tag: vm-x86_64-vX.Y.Z-rc.N"
    [[ "$RELEASE_TAG" =~ $RELEASE_TAG_PATTERN ]] || fail "release tag must match vm-x86_64-vX.Y.Z-rc.N: $RELEASE_TAG"
    OVERLAY_DIR="$RELEASE_OVERLAY_DIR"
    ARTIFACT_CLASS="VM_DISTRIBUTION_SET"
    VALIDATION_SCOPE_VALUE="QEMU_RUNTIME_ALL_VARIANTS"
    RELEASE_VERSION="${RELEASE_TAG#vm-x86_64-}"
    RELEASE_CHANNEL="rc"
    PROJECT_COMMIT="${NEXAWRT_PROJECT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}')}"
    [[ "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "project commit must be a full lowercase Git object ID"
    ARTIFACT_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined.img.gz"
    RAW_BIOS_BASENAME="$ARTIFACT_BASENAME"
    ISO_BIOS_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-image.iso"
    ISO_EFI_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-image-efi.iso"
    VMDK_BIOS_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined.vmdk"
    VMDK_EFI_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined-efi.vmdk"
    RELEASE_MANIFEST_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic.manifest"
    ;;
  custom)
    [[ "$TARGET" == x86-64 ]] || fail "custom mode supports x86-64 only"
    OVERLAY_DIR="$RELEASE_OVERLAY_DIR"
    ARTIFACT_CLASS="VM_CUSTOM_COMPONENT_IMAGE"
    VALIDATION_SCOPE_VALUE="UNVALIDATED_CUSTOM_BUILD"
    RELEASE_VERSION=""
    PROJECT_COMMIT="${NEXAWRT_PROJECT_COMMIT:-$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}')}"
    [[ "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "project commit must be a full lowercase Git object ID"
    ARTIFACT_BASENAME="NexaWrt-custom-x86_64-${CUSTOM_REQUEST_HASH:0:12}-generic-ext4-combined.img.gz"
    ;;
  *)
    fail "internal error: unsupported mode $MODE"
    ;;
esac

[[ -d "$OVERLAY_DIR" ]] || fail "missing VM overlay: $OVERLAY_DIR"
for command_name in curl sha256sum tar make find install cp tee wc grep sort sed gzip python3 git; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done
if [[ "$MODE" == release ]]; then
  for command_name in mkisofs qemu-img; do
    command -v "$command_name" >/dev/null 2>&1 || fail "release image format tool is missing: $command_name"
  done
fi
[[ "$ROOTFS_PARTSIZE" =~ ^[1-9][0-9]*$ ]] || fail "VM_ROOTFS_PARTSIZE must be a positive integer"

AUTHORIZED_KEY_FILE="${VM_SMOKE_AUTHORIZED_KEY_FILE:-}"
if [[ "$MODE" == smoke ]]; then
  [[ -n "$AUTHORIZED_KEY_FILE" ]] || fail "VM_SMOKE_AUTHORIZED_KEY_FILE is required in smoke mode"
  [[ -f "$AUTHORIZED_KEY_FILE" && ! -L "$AUTHORIZED_KEY_FILE" ]] || fail "authorized key must be a regular file"
  [[ "$(wc -l < "$AUTHORIZED_KEY_FILE" | tr -d ' ')" == 1 ]] || fail "authorized key must contain exactly one line"
  grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/=]+' "$AUTHORIZED_KEY_FILE" ||
    fail "authorized key is not a supported OpenSSH public key"
elif [[ "$MODE" == release && -n "$AUTHORIZED_KEY_FILE" ]]; then
  fail "VM_SMOKE_AUTHORIZED_KEY_FILE must not be set in release mode"
elif [[ "$MODE" == custom && -n "$AUTHORIZED_KEY_FILE" ]]; then
  fail "VM_SMOKE_AUTHORIZED_KEY_FILE must not be set in custom mode"
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
elif [[ "$MODE" == release ]]; then
  if find "$OVERLAY_WORK" -type f -path '*/authorized_keys' -print -quit | grep -q .; then
    fail "release overlay must not contain SSH authorized_keys"
  fi
  cat > "$OVERLAY_WORK/etc/nexawrt-vm-release" <<EOF_METADATA
NEXAWRT_VM_RELEASE_METADATA_V2_BEGIN
RELEASE_CONTRACT=$RELEASE_CONTRACT
RELEASE_TAG=$RELEASE_TAG
RELEASE_VERSION=$RELEASE_VERSION
RELEASE_CHANNEL=$RELEASE_CHANNEL
PROJECT_COMMIT=$PROJECT_COMMIT
ARTIFACT_CLASS=$ARTIFACT_CLASS
PUBLISHED_VARIANTS=$PUBLISHED_VARIANTS
ESXI_VALIDATION=not-tested
VM_ONLY=1
NOT_AX9000_FIRMWARE=1
HARDWARE_VALIDATION=0
NSS_VALIDATION=0
VALIDATION_SCOPE=$VALIDATION_SCOPE_VALUE
SSH_DEFAULT=disabled
SSH_AUTHORIZED_KEYS=absent
NEXAWRT_VM_RELEASE_METADATA_V2_END
EOF_METADATA
  cat > "$OVERLAY_WORK/etc/banner" <<EOF_BANNER
NexaWrt x86_64 VM distribution set ${RELEASE_VERSION}
RELEASE_CONTRACT=$RELEASE_CONTRACT
RELEASE_TAG=$RELEASE_TAG
RELEASE_VERSION=$RELEASE_VERSION
RELEASE_CHANNEL=$RELEASE_CHANNEL
PROJECT_COMMIT=$PROJECT_COMMIT
ARTIFACT_CLASS=$ARTIFACT_CLASS
PUBLISHED_VARIANTS=$PUBLISHED_VARIANTS
ESXI_VALIDATION=not-tested
VM_ONLY=1
NOT_AX9000_FIRMWARE=1
HARDWARE_VALIDATION=0
NSS_VALIDATION=0
VALIDATION_SCOPE=$VALIDATION_SCOPE_VALUE
SSH_DEFAULT=disabled
SSH_AUTHORIZED_KEYS=absent

VM-only images. NOT Xiaomi AX9000 firmware. Do not use router flash tools.
QEMU runtime validation is not VMware ESXi validation.
NIC 1 is the static management LAN at 192.168.8.1; NIC 2 is optional DHCP WAN.
HTTPS is mandatory. A unique temporary password is printed on first boot console.
Remote SSH is disabled by default.
EOF_BANNER
else
  if find "$OVERLAY_WORK" -type f -path '*/authorized_keys' -print -quit | grep -q .; then
    fail "custom overlay must not contain SSH authorized_keys"
  fi
  cat > "$OVERLAY_WORK/etc/nexawrt-vm-release" <<EOF_METADATA
NEXAWRT_VM_CUSTOM_METADATA_V1_BEGIN
PROJECT_COMMIT=$PROJECT_COMMIT
REQUEST_HASH=$CUSTOM_REQUEST_HASH
CATALOG_VERSION=$CUSTOM_CATALOG_VERSION
FLAVOR=$CUSTOM_FLAVOR
RESOLVED_COMPONENTS=$CUSTOM_RESOLVED_COMPONENTS
ARTIFACT_CLASS=$ARTIFACT_CLASS
VM_ONLY=1
NOT_AX9000_FIRMWARE=1
HARDWARE_VALIDATION=0
NSS_VALIDATION=0
VALIDATION_SCOPE=$VALIDATION_SCOPE_VALUE
SSH_DEFAULT=disabled
SSH_AUTHORIZED_KEYS=absent
NEXAWRT_VM_CUSTOM_METADATA_V1_END
EOF_METADATA
  cat > "$OVERLAY_WORK/etc/banner" <<EOF_BANNER
NexaWrt x86_64 custom component image
PROJECT_COMMIT=$PROJECT_COMMIT
REQUEST_HASH=$CUSTOM_REQUEST_HASH
CATALOG_VERSION=$CUSTOM_CATALOG_VERSION
FLAVOR=$CUSTOM_FLAVOR
RESOLVED_COMPONENTS=$CUSTOM_RESOLVED_COMPONENTS
ARTIFACT_CLASS=$ARTIFACT_CLASS
VM_ONLY=1
NOT_AX9000_FIRMWARE=1
HARDWARE_VALIDATION=0
NSS_VALIDATION=0
VALIDATION_SCOPE=$VALIDATION_SCOPE_VALUE
SSH_DEFAULT=disabled
SSH_AUTHORIZED_KEYS=absent

VM-only custom image. NOT Xiaomi AX9000 firmware. Do not use router flash tools.
This build contains the repository VM runtime baseline plus catalog-resolved packages.
Remote SSH is disabled by default.
EOF_BANNER
fi

# Preserve the release runtime baseline for custom images because the production
# overlay configures LuCI, uhttpd, firewall, DHCP, and Dropbear on first boot.
# Dropbear is installed so its init/UCI entries exist, but the overlay stops and
# disables it before completing first boot.
VM_BASELINE_PACKAGES=(
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
VM_PACKAGES=("${VM_BASELINE_PACKAGES[@]}")
if [[ "$MODE" == custom ]]; then
  for custom_package in "${CUSTOM_PACKAGES[@]}"; do
    package_present=0
    for existing_package in "${VM_PACKAGES[@]}"; do
      if [[ "$existing_package" == "$custom_package" ]]; then
        package_present=1
        break
      fi
    done
    ((package_present == 1)) || VM_PACKAGES+=("$custom_package")
  done
  printf -v PACKAGE_LIST ' %s' "${VM_PACKAGES[@]}"
else
  printf -v PACKAGE_LIST ' %q' "${VM_PACKAGES[@]}"
fi
PACKAGE_LIST="${PACKAGE_LIST# }"

rm -rf "$BUILDER_DIR/bin/targets/$TARGET_PATH"
MAKE_ARGS=(
  "PROFILE=$PROFILE"
  "PACKAGES=$PACKAGE_LIST"
  "FILES=$OVERLAY_WORK"
  "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
)
if [[ "$MODE" == release ]]; then
  MAKE_ARGS+=(
    'CONFIG_TARGET_ROOTFS_EXT4FS=y'
    'CONFIG_TARGET_ROOTFS_SQUASHFS=n'
    'CONFIG_ISO_IMAGES=y'
    'CONFIG_VMDK_IMAGES=y'
  )
fi
{
  printf 'VM-only OpenWrt %s %s build for %s\n' "$VM_OPENWRT_VERSION" "$MODE" "$TARGET"
  printf 'ImageBuilder: %s\n' "$IMAGEBUILDER_URL"
  printf 'ImageBuilder SHA256: %s\n' "$IMAGEBUILDER_SHA256"
  if [[ "$MODE" == release ]]; then
    printf 'Release contract: %s\n' "$RELEASE_CONTRACT"
    printf 'Release tag: %s\n' "$RELEASE_TAG"
    printf 'Release version: %s\n' "$RELEASE_VERSION"
    printf 'Published variants: %s\n' "$PUBLISHED_VARIANTS"
    printf 'ESXi validation: not-tested\n'
  fi
  printf 'Validation scope: %s; not hardware, NSS, or ESXi validation.\n' "$VALIDATION_SCOPE_VALUE"
  make -C "$BUILDER_DIR" image "${MAKE_ARGS[@]}"
} 2>&1 | tee "$BUILD_LOG"

if [[ "$MODE" == release ]]; then
  TARGET_DIR="$BUILDER_DIR/bin/targets/$TARGET_PATH"
  BUILT_INPUTS_OUTPUT="$(select_x86_64_release_inputs "$TARGET_DIR" "$VM_OPENWRT_VERSION")" ||
    fail "failed to select the exact six upstream release inputs"
  BUILT_INPUTS=()
  while IFS= read -r selected_input; do
    [[ -n "$selected_input" ]] && BUILT_INPUTS+=("$selected_input")
  done <<< "$BUILT_INPUTS_OUTPUT"
  [[ "${#BUILT_INPUTS[@]}" -eq 6 ]] || fail "internal error: release selector did not return six inputs"

  RELEASE_BASENAMES=(
    "$RAW_BIOS_BASENAME"
    "$ISO_BIOS_BASENAME"
    "$ISO_EFI_BASENAME"
    "$VMDK_BIOS_BASENAME"
    "$VMDK_EFI_BASENAME"
  )
  cp "${BUILT_INPUTS[0]}" "$OUTPUT_DIR/$RAW_BIOS_BASENAME"
  cp "${BUILT_INPUTS[2]}" "$OUTPUT_DIR/$ISO_BIOS_BASENAME"
  cp "${BUILT_INPUTS[3]}" "$OUTPUT_DIR/$ISO_EFI_BASENAME"

  VMDK_WORK="$WORK_DIR/vmdk-conversion-$RELEASE_VERSION"
  rm -rf "$VMDK_WORK"
  mkdir -p "$VMDK_WORK"
  gzip -t "${BUILT_INPUTS[0]}"
  gzip -dc "${BUILT_INPUTS[0]}" > "$VMDK_WORK/bios.raw"
  gzip -t "${BUILT_INPUTS[1]}"
  gzip -dc "${BUILT_INPUTS[1]}" > "$VMDK_WORK/efi.raw"

  # The ImageBuilder-native VMDKs prove that the pinned upstream exposes VMDK
  # generation, but OpenWrt 25.12.5 emits monolithicSparse. Validate and retain
  # them only as build inputs; ESXi-facing release VMDKs are streamOptimized
  # conversions from the matching BIOS/EFI ext4 raw disks.
  for index in 4 5; do
    native_vmdk="$VMDK_WORK/native-$index.vmdk"
    gzip -t "${BUILT_INPUTS[$index]}"
    gzip -dc "${BUILT_INPUTS[$index]}" > "$native_vmdk"
    qemu-img info --output=json "$native_vmdk" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); data=d.get("format-specific", {}).get("data", {}); raise SystemExit(0 if d.get("format") == "vmdk" and data.get("create-type") == "monolithicSparse" else 1)' ||
      fail "native ImageBuilder VMDK is not the expected monolithicSparse source: ${BUILT_INPUTS[$index]}"
    qemu-img check -f vmdk "$native_vmdk" >/dev/null ||
      fail "native ImageBuilder VMDK failed qemu-img check: ${BUILT_INPUTS[$index]}"
  done

  qemu-img convert -f raw -O vmdk -o subformat=streamOptimized \
    "$VMDK_WORK/bios.raw" "$OUTPUT_DIR/$VMDK_BIOS_BASENAME"
  qemu-img convert -f raw -O vmdk -o subformat=streamOptimized \
    "$VMDK_WORK/efi.raw" "$OUTPUT_DIR/$VMDK_EFI_BASENAME"
  for vmdk_path in "$OUTPUT_DIR/$VMDK_BIOS_BASENAME" "$OUTPUT_DIR/$VMDK_EFI_BASENAME"; do
    [[ -s "$vmdk_path" ]] || fail "converted release VMDK is empty: $vmdk_path"
    qemu-img info --output=json "$vmdk_path" | python3 -c \
      'import json,sys; d=json.load(sys.stdin); data=d.get("format-specific", {}).get("data", {}); raise SystemExit(0 if d.get("format") == "vmdk" and data.get("create-type") == "streamOptimized" else 1)' ||
      fail "converted release image is not a streamOptimized VMDK: $vmdk_path"
    qemu-img check -f vmdk "$vmdk_path" >/dev/null ||
      fail "converted release VMDK failed qemu-img check: $vmdk_path"
  done

  MANIFEST_SOURCE="$(select_x86_64_release_manifest "$TARGET_DIR" "$VM_OPENWRT_VERSION" "${BUILT_INPUTS[0]##*/}")"
  MANIFEST_PATH="$OUTPUT_DIR/$RELEASE_MANIFEST_BASENAME"
  cp "$MANIFEST_SOURCE" "$MANIFEST_PATH"
  ARTIFACT_PATH="$OUTPUT_DIR/$RAW_BIOS_BASENAME"
else
  BUILT_IMAGE="$BUILDER_DIR/bin/targets/$TARGET_PATH/$UPSTREAM_IMAGE"
  [[ -f "$BUILT_IMAGE" ]] || fail "expected image was not produced: $BUILT_IMAGE"
  ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_BASENAME"
  cp "$BUILT_IMAGE" "$ARTIFACT_PATH"
  MANIFEST_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME%.img.gz}.manifest"
  MANIFEST_SOURCE="${BUILT_IMAGE%.img.gz}.manifest"
  if [[ -f "$MANIFEST_SOURCE" ]]; then
    cp "$MANIFEST_SOURCE" "$MANIFEST_PATH"
  fi
fi

if [[ "$MODE" == custom ]]; then
  CUSTOM_PACKAGES_PATH="$OUTPUT_DIR/custom-imagebuilder-packages.json"
  python3 - "$CUSTOM_PACKAGES_PATH" "${VM_PACKAGES[@]}" <<'PY_PACKAGES'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
packages = sys.argv[2:]
if not packages or len(packages) != len(set(packages)):
    raise SystemExit("custom ImageBuilder package set must be non-empty and unique")
temporary = path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(packages, indent=2, sort_keys=False) + "\n", encoding="utf-8")
os.replace(temporary, path)
PY_PACKAGES
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
VALIDATION_SCOPE="$VALIDATION_SCOPE_VALUE"
IMAGEBUILDER_URL="$IMAGEBUILDER_URL"
IMAGEBUILDER_SHA256="$IMAGEBUILDER_SHA256"
EOF_LABELS
if [[ "$MODE" == release ]]; then
  {
    printf 'RELEASE_CONTRACT="%s"\n' "$RELEASE_CONTRACT"
    printf 'RELEASE_TAG="%s"\n' "$RELEASE_TAG"
    printf 'RELEASE_VERSION="%s"\n' "$RELEASE_VERSION"
    printf 'RELEASE_CHANNEL="%s"\n' "$RELEASE_CHANNEL"
    printf 'PROJECT_COMMIT="%s"\n' "$PROJECT_COMMIT"
    printf 'PUBLISHED_VARIANTS="%s"\n' "$PUBLISHED_VARIANTS"
    printf 'ESXI_VALIDATION="not-tested"\n'
    printf 'SSH_DEFAULT="disabled"\n'
    printf 'SSH_AUTHORIZED_KEYS="absent"\n'
  } >> "$LABELS_PATH"
elif [[ "$MODE" == custom ]]; then
  {
    printf 'PROJECT_COMMIT="%s"\n' "$PROJECT_COMMIT"
    printf 'REQUEST_HASH="%s"\n' "$CUSTOM_REQUEST_HASH"
    printf 'RESOLVED_COMPONENTS="%s"\n' "$CUSTOM_RESOLVED_COMPONENTS"
    printf 'SSH_DEFAULT="disabled"\n'
    printf 'SSH_AUTHORIZED_KEYS="absent"\n'
  } >> "$LABELS_PATH"
fi

README_PATH="$OUTPUT_DIR/README-VM.txt"
if [[ "$MODE" == release ]]; then
  cat > "$README_PATH" <<EOF_README
NexaWrt x86_64 VM ${RELEASE_VERSION}
Release contract: ${RELEASE_CONTRACT}

WARNING / 警告
- These are x86_64 virtual-machine images only, not Xiaomi AX9000 firmware.
- QEMU SeaBIOS/OVMF runtime PASS is not VMware ESXi validation.
- ESXI_VALIDATION=not-tested. Do not describe these VMDKs as ESXi-tested.
- SSH is disabled by default and no authorized_keys are embedded.
- NIC 1 is LAN (192.168.8.1/24, DHCP server); NIC 2 is WAN (DHCP).
- HTTP redirects to HTTPS. The first-boot console prints a unique temporary root password.

Published variants
- ${RAW_BIOS_BASENAME}: raw BIOS disk for QEMU/PVE and conversion workflows.
- ${ISO_BIOS_BASENAME}: BIOS Live ISO; configuration is not guaranteed persistent.
- ${ISO_EFI_BASENAME}: EFI Live ISO; configuration is not guaranteed persistent.
- ${VMDK_BIOS_BASENAME}: BIOS streamOptimized VMDK for VMware import; QEMU runtime-tested only.
- ${VMDK_EFI_BASENAME}: EFI streamOptimized VMDK for VMware import; QEMU+OVMF runtime-tested only.

After upload, import/convert each streamOptimized VMDK into an ESXi datastore-backed writable disk; do not run it as a directly writable base.
Verify every downloaded image with its adjacent .sha256 file or SHA256SUMS.
Change the console-printed temporary root password immediately after first login.
Do not connect NIC 1 to an existing DHCP-enabled LAN; use an isolated LAN port group.
Dangerous router-write commands are intentionally guarded inside these VM images.
EOF_README
fi

(
  cd "$OUTPUT_DIR"
  if [[ "$MODE" == release ]]; then
    for image_basename in "${RELEASE_BASENAMES[@]}"; do
      sha256sum "$image_basename" > "${image_basename}.sha256"
    done
    sha256sum \
      "$RAW_BIOS_BASENAME" "${RAW_BIOS_BASENAME}.sha256" \
      "$ISO_BIOS_BASENAME" "${ISO_BIOS_BASENAME}.sha256" \
      "$ISO_EFI_BASENAME" "${ISO_EFI_BASENAME}.sha256" \
      "$VMDK_BIOS_BASENAME" "${VMDK_BIOS_BASENAME}.sha256" \
      "$VMDK_EFI_BASENAME" "${VMDK_EFI_BASENAME}.sha256" \
      "$RELEASE_MANIFEST_BASENAME" \
      "$(basename "$LABELS_PATH")" \
      "$(basename "$README_PATH")" > SHA256SUMS
  else
    sha256sum "$ARTIFACT_BASENAME" > "${ARTIFACT_BASENAME}.sha256"
    sha256sum "$ARTIFACT_BASENAME" > SHA256SUMS
  fi
)

printf 'Built VM-only %s artifact set in: %s\n' "$MODE" "$OUTPUT_DIR"
printf 'These artifacts are not AX9000 firmware and do not claim hardware, NSS, or ESXi validation.\n'
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'image=%s\n' "$ARTIFACT_PATH"
    printf 'artifact_dir=%s\n' "$OUTPUT_DIR"
    printf 'artifact_basename=%s\n' "$ARTIFACT_BASENAME"
    printf 'manifest=%s\n' "$MANIFEST_PATH"
    printf 'labels=%s\n' "$LABELS_PATH"
    printf 'readme=%s\n' "$README_PATH"
    printf 'sha256=%s\n' "$OUTPUT_DIR/${ARTIFACT_BASENAME}.sha256"
    if [[ "$MODE" == release ]]; then
      printf 'raw_bios=%s\n' "$OUTPUT_DIR/$RAW_BIOS_BASENAME"
      printf 'iso_bios=%s\n' "$OUTPUT_DIR/$ISO_BIOS_BASENAME"
      printf 'iso_efi=%s\n' "$OUTPUT_DIR/$ISO_EFI_BASENAME"
      printf 'vmdk_bios=%s\n' "$OUTPUT_DIR/$VMDK_BIOS_BASENAME"
      printf 'vmdk_efi=%s\n' "$OUTPUT_DIR/$VMDK_EFI_BASENAME"
    fi
  } >> "$GITHUB_OUTPUT"
fi
