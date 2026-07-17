#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/manifests/vm.lock"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-vm-image.sh"
SMOKE_SCRIPT="$ROOT_DIR/scripts/test-vm-smoke.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/vm-smoke.yml"
OVERLAY="$ROOT_DIR/vm-files"

fail() {
  printf 'VM policy test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq -- "$needle" "$file" || fail "$file is missing required policy text: $needle"
}

for required in "$LOCK_FILE" "$BUILD_SCRIPT" "$SMOKE_SCRIPT" "$WORKFLOW" \
  "$OVERLAY/etc/nexawrt-vm-smoke" "$OVERLAY/etc/banner" \
  "$OVERLAY/etc/uci-defaults/10-vm-smoke" \
  "$OVERLAY/usr/libexec/nexawrt-vm-dangerous-command-guard"; do
  [[ -f "$required" && ! -L "$required" ]] || fail "required regular file is missing: $required"
done

python3 - "$LOCK_FILE" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
expected = {
    "VM_OPENWRT_VERSION": "25.12.5",
    "VM_X86_64_IMAGEBUILDER_URL": "https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/openwrt-imagebuilder-25.12.5-x86-64.Linux-x86_64.tar.zst",
    "VM_X86_64_IMAGEBUILDER_SHA256": "313221253d9bac534e4a4ee6492a4941b4ba0f43200eceb8d16a4785470ae9df",
    "VM_ARMSR_ARMV8_IMAGEBUILDER_URL": "https://downloads.openwrt.org/releases/25.12.5/targets/armsr/armv8/openwrt-imagebuilder-25.12.5-armsr-armv8.Linux-x86_64.tar.zst",
    "VM_ARMSR_ARMV8_IMAGEBUILDER_SHA256": "225243a1963f05c98f6d0f3a0c4b62c5a267ef505fc6df0c262a588603f53c4c",
}
assignment = re.compile(r'([A-Z][A-Z0-9_]*)="([^"\\]*)"')
actual = {}
for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = assignment.fullmatch(line)
    if not match:
        raise SystemExit(f"non-declarative vm.lock line {number}")
    key, value = match.groups()
    if key in actual:
        raise SystemExit(f"duplicate vm.lock key: {key}")
    actual[key] = value
if actual != expected:
    raise SystemExit(f"vm.lock mismatch: {actual!r}")
PY

for script in "$BUILD_SCRIPT" "$SMOKE_SCRIPT" "$OVERLAY/etc/uci-defaults/10-vm-smoke" \
  "$OVERLAY/usr/libexec/nexawrt-vm-dangerous-command-guard" "$OVERLAY"/sbin/*; do
  [[ -x "$script" ]] || fail "script is not executable: $script"
  bash -n "$script" || fail "shell syntax check failed: $script"
done

for package in luci luci-ssl dropbear ca-bundle curl ethtool htop iperf3 nano tcpdump-mini; do
  grep -Eq "^[[:space:]]+${package}$" "$BUILD_SCRIPT" || fail "shared VM package is not pinned in build script: $package"
done
assert_contains 'source "$LOCK_FILE"' "$BUILD_SCRIPT"
assert_contains 'sha256sum --check --status' "$BUILD_SCRIPT"
assert_contains 'PROFILE="$PROFILE"' "$BUILD_SCRIPT"
assert_contains 'FILES="$OVERLAY_WORK"' "$BUILD_SCRIPT"
assert_contains 'ARTIFACT_BASENAME="nexawrt-vm-smoke-openwrt-${VM_OPENWRT_VERSION}-${TARGET}.img.gz"' "$BUILD_SCRIPT"
artifact_expression="$(sed -nE 's/^ARTIFACT_BASENAME="(.*)"/\1/p' "$BUILD_SCRIPT")"
[[ -n "$artifact_expression" ]] || fail "VM artifact basename is not explicit"
artifact_expression_lower="$(printf '%s' "$artifact_expression" | tr '[:upper:]' '[:lower:]')"
[[ "$artifact_expression_lower" != *ax9000* ]] || fail "VM image artifact name mentions AX9000"
! grep -Fq 'files/etc' "$BUILD_SCRIPT" || fail "VM build script references the hardware overlay"

for label in \
  'ARTIFACT_CLASS=VM_SMOKE_IMAGE' \
  'VM_ONLY=1' \
  'NOT_AX9000_FIRMWARE=1' \
  'HARDWARE_VALIDATION=0' \
  'NSS_VALIDATION=0' \
  'VALIDATION_SCOPE=QEMU_BOOT_AND_USERSPACE_ONLY'; do
  grep -qx "$label" "$OVERLAY/etc/nexawrt-vm-smoke" || fail "VM label is missing: $label"
done
assert_contains 'VM ONLY — NOT-AX9000 FIRMWARE' "$OVERLAY/etc/banner"
assert_contains 'NOT HARDWARE VALIDATION AND NOT NSS VALIDATION' "$OVERLAY/etc/banner"
assert_contains "set network.lan.proto='dhcp'" "$OVERLAY/etc/uci-defaults/10-vm-smoke"
assert_contains "set uhttpd.main.redirect_https='0'" "$OVERLAY/etc/uci-defaults/10-vm-smoke"
assert_contains "set dropbear.@dropbear[0].PasswordAuth='off'" "$OVERLAY/etc/uci-defaults/10-vm-smoke"

GUARD="$OVERLAY/usr/libexec/nexawrt-vm-dangerous-command-guard"
for guard_name in factoryreset firstboot jffs2mark jffs2reset mtd sysupgrade ubiattach ubidetach ubiformat; do
  wrapper="$OVERLAY/sbin/$guard_name"
  [[ -f "$wrapper" && -x "$wrapper" && ! -L "$wrapper" ]] || fail "dangerous-command wrapper is missing: $guard_name"
  set +e
  guard_output="$(NEXAWRT_VM_GUARD_PATH="$GUARD" "$wrapper" --policy-test 2>&1)"
  guard_status=$?
  set -e
  [[ "$guard_status" -eq 74 ]] || fail "$guard_name guard returned $guard_status instead of 74"
  grep -Fq 'VM-only safety guard' <<<"$guard_output" || fail "$guard_name guard lacks VM-only warning"
  grep -Fq 'not hardware/NSS validation' <<<"$guard_output" || fail "$guard_name guard overstates validation"
done

for required_text in \
  'qemu-system-x86_64' \
  'qemu-system-aarch64' \
  'hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22' \
  'hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80' \
  'ubus call system board' \
  'ubus call network.interface.lan status' \
  'uci -q get system.@system[0].hostname' \
  '/etc/init.d/$service_name' \
  'dangerous_command_guards=PASS' \
  'hardware_validation=false' \
  'nss_validation=false'; do
  assert_contains "$required_text" "$SMOKE_SCRIPT"
done
assert_contains 'for service_name in ubus dropbear rpcd uhttpd' "$SMOKE_SCRIPT"
assert_contains 'http=PASS' "$SMOKE_SCRIPT"
assert_contains 'ssh=PASS' "$SMOKE_SCRIPT"
assert_contains 'network=PASS' "$SMOKE_SCRIPT"

while read -r action_use; do
  [[ "$action_use" =~ @[0-9a-f]{40}$ ]] || fail "workflow action is not pinned to a full commit: $action_use"
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^ #]+).*/\1/p' "$WORKFLOW")
assert_contains 'persist-credentials: false' "$WORKFLOW"
assert_contains 'shellcheck -S warning' "$WORKFLOW"
assert_contains '- x86-64' "$WORKFLOW"
assert_contains '- armsr-armv8' "$WORKFLOW"
assert_contains 'qemu-system-x86' "$WORKFLOW"
assert_contains 'qemu-system-arm' "$WORKFLOW"
assert_contains 'qemu-efi-aarch64' "$WORKFLOW"
assert_contains 'Upload VM image, logs, and report' "$WORKFLOW"
assert_contains 'vm-smoke-results/${{ matrix.target }}/' "$WORKFLOW"
workflow_artifact_name="$(sed -nE 's/^[[:space:]]+name: (vm-smoke-.*)$/\1/p' "$WORKFLOW")"
[[ -n "$workflow_artifact_name" ]] || fail "workflow artifact name is missing"
workflow_artifact_name_lower="$(printf '%s' "$workflow_artifact_name" | tr '[:upper:]' '[:lower:]')"
[[ "$workflow_artifact_name_lower" != *ax9000* ]] || fail "workflow artifact calls the VM image AX9000 firmware"

policy_tmp="$(mktemp -d)"
trap 'rm -rf "$policy_tmp"' EXIT
printf 'not-an-image\n' > "$policy_tmp/image.img.gz"
printf 'not-a-key\n' > "$policy_tmp/key"
if /bin/bash "$BUILD_SCRIPT" unsupported-target >"$policy_tmp/build.out" 2>&1; then
  fail "build script accepted an unsupported target"
fi
if VM_SMOKE_OUTPUT_DIR="$policy_tmp/smoke-results" /bin/bash "$SMOKE_SCRIPT" unsupported-target "$policy_tmp/image.img.gz" "$policy_tmp/key" >"$policy_tmp/smoke.out" 2>&1; then
  fail "smoke script accepted an unsupported target"
fi

printf 'VM policy tests passed.\n'
