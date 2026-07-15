#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
[[ "$NEXAWRT_FLAVOR" == official ]] || { echo "Refusing release staging for flavor: $NEXAWRT_FLAVOR" >&2; exit 1; }

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.work/openwrt}"
BUILD_LOG="${BUILD_LOG:-$ROOT_DIR/build.log}"
DIST_DIR_RAW="${DIST_DIR_OVERRIDE:-$ROOT_DIR/dist}"
EXPECTED_IMAGE="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb"
EXPECTED_PACKAGE_MANIFEST="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest"
EXPECTED_SBOM="openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json"

fail() { echo "official artifact staging refused: $*" >&2; exit 1; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi; }

canonicalize_staging_output() {
  python3 - "$ROOT_DIR" "$1" dist <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
raw = pathlib.Path(sys.argv[2])
expected_name = sys.argv[3]
absolute = pathlib.Path(os.path.abspath(raw))
legacy_output = root / expected_name
work_staging_root = root / "release-staging"
if absolute == legacy_output:
    allowed_root = root
    relative = pathlib.Path(expected_name)
else:
    try:
        relative = absolute.relative_to(work_staging_root)
    except ValueError:
        raise SystemExit("output is outside the project safe staging roots")
    if not relative.parts:
        raise SystemExit("output may not be the release-staging root")
    allowed_root = work_staging_root
if relative.name != expected_name:
    raise SystemExit(f"output must end in {expected_name}")
if os.path.lexists(allowed_root) and allowed_root.is_symlink():
    raise SystemExit(f"staging root is a symlink: {allowed_root}")
current = allowed_root
for part in relative.parts:
    current = current / part
    if os.path.lexists(current) and current.is_symlink():
        raise SystemExit(f"output path contains a symlink: {current}")
canonical = absolute.resolve(strict=False)
try:
    canonical.relative_to(allowed_root)
except ValueError:
    raise SystemExit("canonical output is outside the project safe staging root")
print(canonical)
PY
}

DIST_DIR="$(canonicalize_staging_output "$DIST_DIR_RAW")" || fail "unsafe staging directory: $DIST_DIR_RAW"
WORK_DIR="$(cd "$WORK_DIR" 2>/dev/null && pwd -P)" || fail "build checkout not found: $WORK_DIR"
BIN_DIR="$WORK_DIR/bin/targets/qualcommax/ipq807x"
actual_source_commit="$(git -C "$WORK_DIR" rev-parse --verify HEAD 2>/dev/null)" || fail "official source checkout has no valid HEAD"
actual_source_origin="$(git -C "$WORK_DIR" remote get-url origin 2>/dev/null)" || fail "official source checkout has no origin"
[[ "$actual_source_commit" == "$OPENWRT_COMMIT" ]] || fail "official source checkout is not at locked commit"
[[ "$actual_source_origin" == "$OPENWRT_REPO" ]] || fail "official source checkout uses an unexpected origin"

NEXAWRT_FLAVOR=official "$ROOT_DIR/scripts/validate.sh" --source "$WORK_DIR" --artifacts ||
  fail "official source/artifact validation failed"

[[ "$(git -C "$WORK_DIR" rev-parse --verify HEAD 2>/dev/null)" == "$actual_source_commit" ]] ||
  fail "official source HEAD changed during validation"
[[ "$(git -C "$WORK_DIR" remote get-url origin 2>/dev/null)" == "$actual_source_origin" ]] ||
  fail "official source origin changed during validation"

[[ -d "$BIN_DIR" ]] || fail "build output not found: $BIN_DIR"
expected_images=()
while IFS= read -r -d '' candidate; do expected_images+=("$candidate"); done < <(find "$BIN_DIR" -maxdepth 1 -type f -name "$EXPECTED_IMAGE" -print0)
((${#expected_images[@]} == 1)) || fail "expected exactly one $EXPECTED_IMAGE, found ${#expected_images[@]}"

while IFS= read -r -d '' candidate; do
  base="$(basename "$candidate")"; lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in *sysupgrade*|*factory*) fail "persistent/installer artifact present: $base" ;; esac
  case "$lower" in
    *.bin|*.img|*.itb|*.ubi|*.ubifs|*.squashfs|*.jffs2|*.ext4|*.trx|*.chk|*.iso|*.vmdk|*.vdi|*.qcow2|*.fit|*.uimage|*.elf|*.dtb|*.fdt|*.fw|*.firmware|*rootfs*.tar|*rootfs*.tar.gz|*rootfs*.tgz|*rootfs*.gz|*rootfs*.xz|*rootfs*.zst)
      [[ "$candidate" == "$BIN_DIR/$EXPECTED_IMAGE" ]] || fail "non-allowlisted image artifact present: $candidate"
      ;;
  esac
done < <(find "$BIN_DIR" -type f -print0)

for required in config.buildinfo feeds.buildinfo profiles.json version.buildinfo "$EXPECTED_PACKAGE_MANIFEST" "$EXPECTED_SBOM"; do
  [[ -f "$BIN_DIR/$required" ]] || fail "required build evidence is missing: $required"
done
python3 - "$BIN_DIR/$EXPECTED_SBOM" <<'PY' || fail "CycloneDX SBOM is invalid"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
if document.get("bomFormat") != "CycloneDX":
    raise SystemExit("unexpected bomFormat")
components = document.get("components")
if not isinstance(components, list) or not components:
    raise SystemExit("components must be a non-empty list")
PY

rm -rf -- "$DIST_DIR"
mkdir -p "$DIST_DIR"
for file in "$EXPECTED_IMAGE" "$EXPECTED_PACKAGE_MANIFEST" "$EXPECTED_SBOM" config.buildinfo feeds.buildinfo profiles.json version.buildinfo; do
  cp "$BIN_DIR/$file" "$DIST_DIR/$file"
done

source_date_epoch="$(git -C "$WORK_DIR" show -s --format=%ct HEAD)"
project_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)"
cat > "$DIST_DIR/BUILD-MANIFEST.txt" <<MANIFEST
project=NexaWrt
flavor=official
project_commit=$project_commit
layout=$LAYOUT_ID
source_repository=$actual_source_origin
source_tag=$OPENWRT_TAG
source_commit=$actual_source_commit
source_date_epoch=$source_date_epoch
stage=initramfs-ram-boot-only
real_device_boot_approved=no
image=$EXPECTED_IMAGE
package_manifest=$EXPECTED_PACKAGE_MANIFEST
sbom=$EXPECTED_SBOM
rootfs_mtd_offset=$ROOTFS_MTD_OFFSET_HEX
rootfs_mtd_size=$ROOTFS_MTD_SIZE_HEX
MANIFEST

cat > "$DIST_DIR/DO-NOT-FLASH.txt" <<'NOTICE'
NexaWrt official artifact: initramfs RAM-boot candidate only.
Do not flash, write to MTD/UBI, run sysupgrade, or save bootloader changes.
Real-device RAM boot is not approved until UART, backups, bootloader visibility,
a reviewed recovery path, and the hardware test gate have all passed.
NOTICE

"$ROOT_DIR/scripts/collect-build-evidence.sh" official "$WORK_DIR" "$DIST_DIR" "$BUILD_LOG"

allowed_top="$(cat <<EOF2
BUILD-MANIFEST.txt
DO-NOT-FLASH.txt
EVIDENCE
$EXPECTED_IMAGE
$EXPECTED_PACKAGE_MANIFEST
$EXPECTED_SBOM
config.buildinfo
feeds.buildinfo
profiles.json
version.buildinfo
EOF2
)"
actual_top="$(find "$DIST_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual_top" == "$(printf '%s\n' "$allowed_top" | LC_ALL=C sort)" ]] || fail "staging directory contains a non-allowlisted entry"

(
  cd "$DIST_DIR"
  while IFS= read -r file; do hash_file "$file"; done < <(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
) > "$DIST_DIR/SHA256SUMS"
(
  cd "$DIST_DIR"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS >/dev/null; else shasum -a 256 -c SHA256SUMS >/dev/null; fi
) || fail "generated SHA256SUMS did not verify"

printf 'NexaWrt official RAM-boot-only release files written to %s\n' "$DIST_DIR"
