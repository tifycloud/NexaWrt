#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-vm-image.sh"
RUNTIME_SCRIPT="$ROOT_DIR/scripts/test-vm-release.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/vm-release.yml"

fail() {
  printf 'VM release policy test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1" path="$2"
  grep -Fq -- "$needle" "$path" || fail "missing policy text in ${path#$ROOT_DIR/}: $needle"
}

assert_not_contains() {
  local needle="$1" path="$2"
  if grep -Fq -- "$needle" "$path"; then
    fail "forbidden policy text in ${path#$ROOT_DIR/}: $needle"
  fi
}

for path in "$BUILD_SCRIPT" "$RUNTIME_SCRIPT" "$WORKFLOW"; do
  [[ -f "$path" && ! -L "$path" ]] || fail "required policy input is missing or unsafe: $path"
done

bash -n "$BUILD_SCRIPT"
bash -n "$RUNTIME_SCRIPT"

# Build contract: six exact upstream inputs produce five published files. The
# native VMDKs are gzip-compressed monolithicSparse capability evidence only;
# release VMDKs must be streamOptimized conversions from matching raw disks.
for text in \
  "RELEASE_CONTRACT='vm-x86_64/v2'" \
  "PUBLISHED_VARIANTS='raw_bios,iso_bios,iso_efi,vmdk_bios,vmdk_efi'" \
  'openwrt-${openwrt_version}-x86-64-generic' \
  '${generic_prefix}-ext4-combined.img.gz' \
  '${generic_prefix}-ext4-combined-efi.img.gz' \
  '${generic_prefix}-image.iso' \
  '${generic_prefix}-image-efi.iso' \
  '${generic_prefix}-ext4-combined.vmdk.gz' \
  '${generic_prefix}-ext4-combined-efi.vmdk.gz' \
  'CONFIG_TARGET_ROOTFS_EXT4FS=y' \
  'CONFIG_TARGET_ROOTFS_SQUASHFS=n' \
  'CONFIG_ISO_IMAGES=y' \
  'CONFIG_VMDK_IMAGES=y' \
  'qemu-img convert -f raw -O vmdk -o subformat=streamOptimized' \
  'data.get("create-type") == "monolithicSparse"' \
  'data.get("create-type") == "streamOptimized"' \
  'qemu-img check -f vmdk "$native_vmdk"' \
  'qemu-img check -f vmdk "$vmdk_path"' \
  'ARTIFACT_CLASS="VM_DISTRIBUTION_SET"' \
  'VALIDATION_SCOPE_VALUE="QEMU_RUNTIME_ALL_VARIANTS"' \
  'RELEASE_CONTRACT="%s"' \
  'PUBLISHED_VARIANTS="%s"' \
  'ESXI_VALIDATION="not-tested"' \
  'VM_ONLY="true"' \
  'NOT_AX9000_FIRMWARE="true"' \
  'HARDWARE_VALIDATION="false"' \
  'NSS_VALIDATION="false"' \
  'SSH_DEFAULT="disabled"' \
  'SSH_AUTHORIZED_KEYS="absent"'; do
  assert_contains "$text" "$BUILD_SCRIPT"
done
assert_contains 'NexaWrt-x86_64-${RELEASE_VERSION}-generic-image.iso' "$BUILD_SCRIPT"
assert_contains 'NexaWrt-x86_64-${RELEASE_VERSION}-generic-image-efi.iso' "$BUILD_SCRIPT"
assert_contains 'After upload, import/convert each streamOptimized VMDK into an ESXi datastore-backed writable disk' "$BUILD_SCRIPT"
assert_not_contains 'release build unexpectedly produced squashfs' "$BUILD_SCRIPT"
assert_not_contains 'squashfs generation is disabled' "$BUILD_SCRIPT"

# Functional selector fixture mirrors the confirmed OpenWrt 25.12.5 output.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
version=25.12.5
prefix="openwrt-${version}-x86-64-generic"
expected_inputs=(
  "${prefix}-ext4-combined.img.gz"
  "${prefix}-ext4-combined-efi.img.gz"
  "${prefix}-image.iso"
  "${prefix}-image-efi.iso"
  "${prefix}-ext4-combined.vmdk.gz"
  "${prefix}-ext4-combined-efi.vmdk.gz"
)
for name in "${expected_inputs[@]}"; do
  printf 'fixture\n' > "$fixture/$name"
done
# Squashfs output may still exist even with CONFIG_TARGET_ROOTFS_SQUASHFS=n.
printf 'allowed-extra\n' > "$fixture/${prefix}-squashfs-combined.img.gz"
printf 'allowed-extra\n' > "$fixture/${prefix}-squashfs-combined.vmdk"
printf 'manifest\n' > "$fixture/${prefix}.manifest"
selector_output="$(bash -c 'source "$1"; select_x86_64_release_inputs "$2" "$3"' policy "$BUILD_SCRIPT" "$fixture" "$version")"
selected_inputs=()
while IFS= read -r selected_input; do
  [[ -n "$selected_input" ]] && selected_inputs+=("$selected_input")
done <<< "$selector_output"
[[ "${#selected_inputs[@]}" -eq 6 ]] || fail "selector did not return six exact inputs"
for index in "${!expected_inputs[@]}"; do
  [[ "${selected_inputs[$index]}" == "$fixture/${expected_inputs[$index]}" ]] ||
    fail "selector order mismatch at index $index"
done
manifest="$(bash -c 'source "$1"; select_x86_64_release_manifest "$2" "$3" "$4"' policy \
  "$BUILD_SCRIPT" "$fixture" "$version" "${prefix}-ext4-combined.img.gz")"
[[ "$manifest" == "$fixture/${prefix}.manifest" ]] || fail "target-level manifest selection changed"

# Missing or symlinked mandatory input must fail closed.
missing_fixture="$fixture/missing"
mkdir -p "$missing_fixture"
for name in "${expected_inputs[@]}"; do
  printf 'fixture\n' > "$missing_fixture/$name"
done
rm "$missing_fixture/${expected_inputs[5]}"
if bash -c 'source "$1"; select_x86_64_release_inputs "$2" "$3"' policy \
  "$BUILD_SCRIPT" "$missing_fixture" "$version" >/dev/null 2>&1; then
  fail "selector accepted a missing native EFI VMDK source"
fi
printf 'fixture\n' > "$missing_fixture/${expected_inputs[5]}"
rm "$missing_fixture/${expected_inputs[5]}"
ln -s "$fixture/${expected_inputs[5]}" "$missing_fixture/${expected_inputs[5]}"
if bash -c 'source "$1"; select_x86_64_release_inputs "$2" "$3"' policy \
  "$BUILD_SCRIPT" "$missing_fixture" "$version" >/dev/null 2>&1; then
  fail "selector accepted a symlinked upstream input"
fi

# Runtime contract: every format gets full QEMU validation, VMDKs are checked as
# streamOptimized, and -snapshot prevents writes to import transport images.
for text in \
  '-snapshot' \
  'run_variant raw_bios "$RAW_BIOS_PATH" bios raw_gz' \
  'run_variant iso_bios "$ISO_BIOS_PATH" bios iso' \
  'run_variant iso_efi "$ISO_EFI_PATH" uefi iso' \
  'run_variant vmdk_bios "$VMDK_BIOS_PATH" bios vmdk' \
  'run_variant vmdk_efi "$VMDK_EFI_PATH" uefi vmdk' \
  'data.get("create-type") == "streamOptimized"' \
  'qemu-img check -f vmdk "$image_path"' \
  'RELEASE_CONTRACT=vm-x86_64/v2' \
  'ARTIFACT_CLASS=VM_DISTRIBUTION_SET' \
  'PUBLISHED_VARIANTS=raw_bios,iso_bios,iso_efi,vmdk_bios,vmdk_efi' \
  'ESXI_VALIDATION=not-tested' \
  'VALIDATION_SCOPE=QEMU_RUNTIME_ALL_VARIANTS' \
  '( "$status" == 200 && "$auth_challenge" == false )' \
  'ssh=DISABLED_BY_DEFAULT' \
  'authorized_keys=ABSENT' \
  'dropbear_enabled=NO' \
  'dropbear_running=NO' \
  "printf 'release_contract=vm-x86_64/v2\\n'" \
  "printf 'raw_bios_qemu=%s\\n'" \
  "printf 'iso_bios_qemu=%s\\n'" \
  "printf 'iso_efi_qemu=%s\\n'" \
  "printf 'vmdk_bios_qemu=%s\\n'" \
  "printf 'vmdk_efi_qemu=%s\\n'" \
  "printf 'esxi_validation=not-tested\\n'"; do
  assert_contains "$text" "$RUNTIME_SCRIPT"
done
assert_not_contains "printf 'image=%s\\n'" "$RUNTIME_SCRIPT"
assert_not_contains "printf 'qemu_boot=%s\\n'" "$RUNTIME_SCRIPT"
assert_contains 'NexaWrt-x86_64-${RELEASE_VERSION}-generic-image.iso' "$RUNTIME_SCRIPT"
assert_contains 'NexaWrt-x86_64-${RELEASE_VERSION}-generic-image-efi.iso' "$RUNTIME_SCRIPT"

python3 - "$RUNTIME_SCRIPT" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"^write_report\(\) \{\n(?P<body>.*?)^\}", text, re.MULTILINE | re.DOTALL)
if match is None:
    raise SystemExit("write_report() not found")
keys = re.findall(r"printf '([a-z0-9_]+)=", match.group("body"))
expected = {
    "status", "target", "release_contract", "vm_only", "not_ax9000_firmware",
    "hardware_validation", "nss_validation", "exact_release_image", "serial_labels", "http",
    "ssh_runtime_evidence", "ssh_port_probe", "ssh", "authorized_keys", "dropbear_enabled",
    "dropbear_running", "http_status", "auth_challenge", "http_host_port", "ssh_host_port",
    "serial_log", "ssh_probe_log", "raw_bios_file", "raw_bios_qemu", "iso_bios_file",
    "iso_bios_qemu", "iso_efi_file", "iso_efi_qemu", "vmdk_bios_file", "vmdk_bios_qemu",
    "vmdk_efi_file", "vmdk_efi_qemu", "esxi_validation",
}
if len(keys) != len(set(keys)) or set(keys) != expected:
    raise SystemExit(f"write_report exact keys mismatch: keys={keys!r}")
if "image" in keys or "qemu_boot" in keys:
    raise SystemExit("v1-only report keys remain")
PY

# Workflow contract and supply-chain/release gates.
for text in \
  'runs-on: ubuntu-24.04' \
  'timeout-minutes: 180' \
  'genisoimage' \
  'qemu-utils' \
  'ovmf' \
  './scripts/test-vm-release.sh x86-64 "$ARTIFACT_DIR"' \
  'RELEASE_CONTRACT="vm-x86_64/v2"' \
  'ARTIFACT_CLASS="VM_DISTRIBUTION_SET"' \
  'PUBLISHED_VARIANTS="raw_bios,iso_bios,iso_efi,vmdk_bios,vmdk_efi"' \
  'ESXI_VALIDATION="not-tested"' \
  'VALIDATION_SCOPE="QEMU_RUNTIME_ALL_VARIANTS"' \
  'data.get("create-type") == "streamOptimized"' \
  'qemu-img check -f vmdk "$ARTIFACT_DIR/$vmdk"' \
  'release_contract": "vm-x86_64/v2"' \
  'raw_bios_qemu": "runtime-pass"' \
  'iso_bios_qemu": "runtime-pass"' \
  'iso_efi_qemu": "runtime-pass"' \
  'vmdk_bios_qemu": "runtime-pass"' \
  'vmdk_efi_qemu": "runtime-pass"' \
  'esxi_validation": "not-tested"' \
  '(values["http_status"], values["auth_challenge"]) not in {("200", "false"), ("403", "true")}' \
  '1024 <= int(values[key]) <= 65535' \
  'expected_result_dir = report_path.parent / "raw_bios"' \
  'test "$(find "$PUBLISH_DIR" -maxdepth 1 -type f | wc -l)" -eq 15' \
  'Verify exact 21-asset whitelist' \
  'raw-bios.provenance.bundle.json' \
  'iso-bios.provenance.bundle.json' \
  'iso-efi.provenance.bundle.json' \
  'vmdk-bios.provenance.bundle.json' \
  'vmdk-efi.provenance.bundle.json' \
  'checksums.provenance.bundle.json' \
  'immutable-releases' \
  'persist-credentials: false' \
  'test "$remote_sha" = "$EXPECTED_SOURCE_SHA"' \
  'release.get("immutable") is not True'; do
  assert_contains "$text" "$WORKFLOW"
done
assert_not_contains 'IMAGE_BASENAME' "$WORKFLOW"
assert_not_contains 'VM_DISTRIBUTION_IMAGE' "$WORKFLOW"
assert_not_contains '"image",' "$WORKFLOW"
assert_not_contains '"qemu_boot",' "$WORKFLOW"

python3 - "$WORKFLOW" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
attest = re.findall(r"uses: actions/attest-build-provenance@([0-9a-f]{40})", text)
if len(attest) != 6 or len(set(attest)) != 1:
    raise SystemExit(f"workflow must contain six identically pinned provenance actions: {attest!r}")
match = re.search(r'expected_assets="(?P<body>.*?)"\n\s+EXPECTED_ASSETS=', text, re.DOTALL)
if match is None:
    raise SystemExit("exact asset whitelist block not found")
assets = [line.strip() for line in match.group("body").splitlines() if line.strip()]
if len(assets) != 21 or len(set(assets)) != 21:
    raise SystemExit(f"workflow whitelist is not exactly 21 unique assets: {assets!r}")
if text.count('subject-path:') != 6:
    raise SystemExit("workflow must attest five images plus SHA256SUMS")
if 'ESXI_VALIDATION="tested"' in text or 'ESXI_VALIDATION=tested' in text:
    raise SystemExit("workflow falsely claims ESXi validation")
PY

printf 'VM release policy tests passed.\n'
