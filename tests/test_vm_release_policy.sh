#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-vm-image.sh"
MANIFEST_SELECTION_TEST="$ROOT_DIR/tests/test_vm_manifest_selection.sh"
RELEASE_SCRIPT="$ROOT_DIR/scripts/test-vm-release.sh"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/vm-release.yml"
RELEASE_OVERLAY="$ROOT_DIR/vm-files-release"
DOC="$ROOT_DIR/docs/VM-X86_64.md"

fail() {
  printf 'VM release policy test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq -- "$needle" "$file" || fail "$file is missing required policy text: $needle"
}

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "$file contains forbidden policy text: $needle"
  fi
}

for required in \
  "$BUILD_SCRIPT" \
  "$RELEASE_SCRIPT" \
  "$RELEASE_WORKFLOW" \
  "$DOC" \
  "$RELEASE_OVERLAY/etc/banner" \
  "$RELEASE_OVERLAY/etc/nexawrt-vm-release" \
  "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release" \
  "$RELEASE_OVERLAY/usr/libexec/nexawrt-vm-dangerous-command-guard"; do
  [[ -f "$required" && ! -L "$required" ]] || fail "required regular file is missing: $required"
done

for script in "$BUILD_SCRIPT" "$RELEASE_SCRIPT" "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release" \
  "$RELEASE_OVERLAY/usr/libexec/nexawrt-vm-dangerous-command-guard" "$RELEASE_OVERLAY"/sbin/*; do
  [[ -x "$script" ]] || fail "script is not executable: $script"
  bash -n "$script" || fail "shell syntax check failed: $script"
done

grep -qx 'NEXAWRT_VM_RELEASE_METADATA_V1_BEGIN' "$RELEASE_OVERLAY/etc/nexawrt-vm-release" || \
  fail "release VM metadata begin marker is missing"
grep -qx 'NEXAWRT_VM_RELEASE_METADATA_V1_END' "$RELEASE_OVERLAY/etc/nexawrt-vm-release" || \
  fail "release VM metadata end marker is missing"

for label in \
  'ARTIFACT_CLASS=VM_DISTRIBUTION_IMAGE' \
  'VM_ONLY=1' \
  'NOT_AX9000_FIRMWARE=1' \
  'HARDWARE_VALIDATION=0' \
  'NSS_VALIDATION=0' \
  'VALIDATION_SCOPE=QEMU_BOOT_AND_USERSPACE_ONLY' \
  'SSH_DEFAULT=disabled' \
  'SSH_AUTHORIZED_KEYS=absent'; do
  grep -qx "$label" "$RELEASE_OVERLAY/etc/nexawrt-vm-release" || fail "release VM label is missing: $label"
  assert_contains "$label" "$RELEASE_OVERLAY/etc/banner"
done
assert_contains 'Remote SSH is disabled by default' "$RELEASE_OVERLAY/etc/banner"
assert_contains '不是 Xiaomi AX9000 固件' "$RELEASE_OVERLAY/etc/banner"
assert_contains '不得上传到 AX9000 LuCI' "$RELEASE_OVERLAY/etc/banner"
assert_contains "set network.lan.proto='dhcp'" "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains "set uhttpd.main.redirect_https='0'" "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains "set dropbear.@dropbear[0].PasswordAuth='off'" "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains "set dropbear.@dropbear[0].RootPasswordAuth='off'" "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains '/etc/init.d/dropbear stop >/dev/null 2>&1' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains '/etc/init.d/dropbear disable >/dev/null 2>&1' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_not_contains '|| true' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'if /etc/init.d/dropbear enabled >/dev/null 2>&1; then' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'if pidof dropbear >/dev/null 2>&1; then' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'if [ -s "$AUTHORIZED_KEYS" ]; then' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'NEXAWRT_VM_SSH_RUNTIME_EVIDENCE_V1_BEGIN' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'ssh=DISABLED_BY_DEFAULT' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'authorized_keys=ABSENT' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'dropbear_enabled=NO' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'dropbear_running=NO' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'cat "$RELEASE_METADATA" >/dev/console' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"
assert_contains 'cat "$EVIDENCE_FILE" >/dev/console' "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release"

if find "$RELEASE_OVERLAY" -type f -path '*/authorized_keys' -print -quit | grep -q .; then
  fail "release overlay must not contain SSH authorized_keys"
fi

GUARD="$RELEASE_OVERLAY/usr/libexec/nexawrt-vm-dangerous-command-guard"
for guard_name in factoryreset firstboot jffs2mark jffs2reset mtd sysupgrade ubiattach ubidetach ubiformat; do
  wrapper="$RELEASE_OVERLAY/sbin/$guard_name"
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
  'RELEASE_TAG_PATTERN=' \
  'VM_SMOKE_AUTHORIZED_KEY_FILE must not be set in release mode' \
  'RELEASE_VERSION="${RELEASE_TAG#vm-x86_64-}"' \
  'ARTIFACT_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined.img.gz"' \
  'ARTIFACT_CLASS="VM_DISTRIBUTION_IMAGE"' \
  'SSH_DEFAULT="disabled"' \
  'SSH_AUTHORIZED_KEYS="absent"' \
  'find "$OVERLAY_WORK" -type f -path '\''*/authorized_keys'\''' \
  'This artifact is not AX9000 firmware'; do
  assert_contains "$required_text" "$BUILD_SCRIPT"
done

assert_not_contains 'VM_SMOKE_AUTHORIZED_KEY_FILE is required in release mode' "$BUILD_SCRIPT"

for required_text in \
  'Usage: test-vm-release.sh x86-64' \
  'qemu-system-x86_64' \
  'hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22' \
  'serial_has_release_labels' \
  'serial_has_ssh_runtime_evidence' \
  'probe_no_ssh_service' \
  'NEXAWRT_VM_SSH_RUNTIME_EVIDENCE_V1_BEGIN' \
  'ARTIFACT_CLASS=VM_DISTRIBUTION_IMAGE' \
  'VM_ONLY=1' \
  'NOT_AX9000_FIRMWARE=1' \
  'HARDWARE_VALIDATION=0' \
  'NSS_VALIDATION=0' \
  'NEXAWRT_VM_RELEASE_METADATA_V1_BEGIN' \
  'SSH_DEFAULT=disabled' \
  'NEXAWRT_VM_RELEASE_METADATA_V1_END' \
  'exact_release_image=true' \
  'qemu_boot_result="UNVERIFIED"' \
  'qemu_boot_result="FAIL"' \
  'qemu_boot_result="PASS"' \
  "printf 'qemu_boot=%s\\n' \"\$qemu_boot_result\"" \
  'QEMU exited after completing release checks but before PASS report generation' \
  'ssh_result="UNVERIFIED"' \
  'authorized_keys_result="UNVERIFIED"' \
  'dropbear_enabled_result="UNVERIFIED"' \
  'dropbear_running_result="UNVERIFIED"' \
  'ssh_runtime_evidence=PASS' \
  'ssh_port_probe=PASS' \
  'ssh_result="DISABLED_BY_DEFAULT"' \
  'authorized_keys_result="ABSENT"' \
  'dropbear_enabled_result="NO"' \
  'dropbear_running_result="NO"' \
  "printf 'ssh=%s\\n' \"\$ssh_result\"" \
  "printf 'authorized_keys=%s\\n' \"\$authorized_keys_result\"" \
  "printf 'dropbear_enabled=%s\\n' \"\$dropbear_enabled_result\"" \
  "printf 'dropbear_running=%s\\n' \"\$dropbear_running_result\"" \
  'http_result=PASS' \
  'serial_labels=PASS'; do
  assert_contains "$required_text" "$RELEASE_SCRIPT"
done
assert_not_contains 'ssh_result="DISABLED_BY_DEFAULT"' <(sed -n '/write_report()/,/^}/p' "$RELEASE_SCRIPT")

python3 - "$RELEASE_OVERLAY/etc/uci-defaults/10-vm-release" "$RELEASE_SCRIPT" <<'PY_RUNTIME_CONTRACT'
import pathlib
import sys

init_path = pathlib.Path(sys.argv[1])
release_path = pathlib.Path(sys.argv[2])
init_text = init_path.read_text(encoding="utf-8")
release_text = release_path.read_text(encoding="utf-8")


def init_contract(text: str) -> bool:
    stop = "/etc/init.d/dropbear stop >/dev/null 2>&1"
    disable = "/etc/init.d/dropbear disable >/dev/null 2>&1"
    required = (
        stop,
        disable,
        "if /etc/init.d/dropbear enabled >/dev/null 2>&1; then",
        "if pidof dropbear >/dev/null 2>&1; then",
        'if [ -s "$AUTHORIZED_KEYS" ]; then',
        "NEXAWRT_VM_SSH_RUNTIME_EVIDENCE_V1_BEGIN",
        "ssh=DISABLED_BY_DEFAULT",
        "authorized_keys=ABSENT",
        "dropbear_enabled=NO",
        "dropbear_running=NO",
        "NEXAWRT_VM_SSH_RUNTIME_EVIDENCE_V1_END",
        'cat "$RELEASE_METADATA" >/dev/console',
        'cat "$EVIDENCE_FILE" >/dev/console',
    )
    return (
        all(item in text for item in required)
        and "|| true" not in text
        and text.index(stop) < text.index(disable)
        and text.index(disable) < text.index("if /etc/init.d/dropbear enabled")
        and text.index('if [ -s "$AUTHORIZED_KEYS" ]; then')
        < text.index('if [ ! -f "$RELEASE_METADATA" ] || [ -L "$RELEASE_METADATA" ]; then')
        < text.index('cat "$RELEASE_METADATA" >/dev/console')
        < text.index('cat >"$EVIDENCE_TMP"')
        < text.index('cat "$EVIDENCE_FILE" >/dev/console')
    )


def release_contract(text: str) -> bool:
    required = (
        "serial_has_ssh_runtime_evidence()",
        "probe_no_ssh_service()",
        "hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22",
        'qemu_boot_result="UNVERIFIED"',
        'qemu_boot_result="FAIL"',
        'qemu_boot_result="PASS"',
        "printf 'qemu_boot=%s\\n' \"$qemu_boot_result\"",
        'fail "QEMU exited after completing release checks but before PASS report generation"',
        'ssh_result="UNVERIFIED"',
        'authorized_keys_result="UNVERIFIED"',
        'dropbear_enabled_result="UNVERIFIED"',
        'dropbear_running_result="UNVERIFIED"',
        'ssh_runtime_evidence=PASS',
        'ssh_port_probe=PASS',
        'ssh_result="DISABLED_BY_DEFAULT"',
        'authorized_keys_result="ABSENT"',
        'dropbear_enabled_result="NO"',
        'dropbear_running_result="NO"',
        "printf 'ssh=%s\\n' \"$ssh_result\"",
        "printf 'authorized_keys=%s\\n' \"$authorized_keys_result\"",
        "printf 'dropbear_enabled=%s\\n' \"$dropbear_enabled_result\"",
        "printf 'dropbear_running=%s\\n' \"$dropbear_running_result\"",
    )
    if not all(item in text for item in required):
        return False
    report_body = text[text.index("write_report()") : text.index("cleanup()")]
    qemu_started = text.index("QEMU_PID=$!")
    qemu_failed_closed = text.index('qemu_boot_result="FAIL"', qemu_started)
    final_ssh_gate = text.index('[[ "$ssh_port_probe" == PASS ]] ||')
    final_alive_gate = text.index(
        'fail "QEMU exited after completing release checks but before PASS report generation"'
    )
    qemu_pass = text.index('qemu_boot_result="PASS"', final_alive_gate)
    pass_report = text.index("write_report PASS", qemu_pass)
    return (
        'ssh_result="DISABLED_BY_DEFAULT"' not in report_body
        and 'qemu_boot_result="PASS"' not in report_body
        and qemu_started < qemu_failed_closed
        and qemu_failed_closed < final_ssh_gate < final_alive_gate < qemu_pass < pass_report
    )


if not init_contract(init_text):
    raise SystemExit("positive init runtime contract failed")
if not release_contract(release_text):
    raise SystemExit("positive host runtime contract failed")

negative_init_mutations = {
    "stop errors swallowed": init_text.replace(
        "/etc/init.d/dropbear stop >/dev/null 2>&1",
        "/etc/init.d/dropbear stop >/dev/null 2>&1 || true",
        1,
    ),
    "authorized_keys check removed": init_text.replace(
        'if [ -s "$AUTHORIZED_KEYS" ]; then',
        'if [ ! -e "$AUTHORIZED_KEYS" ]; then',
        1,
    ),
    "runtime evidence field removed": init_text.replace("authorized_keys=ABSENT\n", "", 1),
}
for name, mutated in negative_init_mutations.items():
    if init_contract(mutated):
        raise SystemExit(f"negative init runtime contract unexpectedly passed: {name}")

negative_release_mutations = {
    "guest 22 forwarding removed": release_text.replace(
        ",hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22", "", 1
    ),
    "SSH probe removed": release_text.replace("probe_no_ssh_service()", "probe_removed()", 1),
    "SSH success preinitialized": release_text.replace(
        'ssh_result="UNVERIFIED"', 'ssh_result="DISABLED_BY_DEFAULT"', 1
    ),
    "QEMU success preinitialized": release_text.replace(
        'qemu_boot_result="UNVERIFIED"', 'qemu_boot_result="PASS"', 1
    ),
    "QEMU final liveness gate removed": release_text.replace(
        'fail "QEMU exited after completing release checks but before PASS report generation"',
        'fail "QEMU liveness gate removed"',
        1,
    ),
    "qemu_boot report field removed": release_text.replace(
        "printf 'qemu_boot=%s\\n' \"$qemu_boot_result\"", "", 1
    ),
    "authorized_keys report field removed": release_text.replace(
        "printf 'authorized_keys=%s\\n' \"$authorized_keys_result\"", "", 1
    ),
}
for name, mutated in negative_release_mutations.items():
    if release_contract(mutated):
        raise SystemExit(f"negative host runtime contract unexpectedly passed: {name}")
PY_RUNTIME_CONTRACT

while read -r action_use; do
  [[ "$action_use" =~ @[0-9a-f]{40}$ ]] || fail "workflow action is not pinned to a full commit: $action_use"
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^ #]+).*/\1/p' "$RELEASE_WORKFLOW")

for required_text in \
  "name: NexaWrt x86_64 VM release" \
  "- 'vm-x86_64-v*'" \
  'workflow_dispatch:' \
  'version:' \
  'test "$GITHUB_REF" = refs/heads/main' \
  'test "$GITHUB_SHA" = "$(git rev-parse refs/remotes/origin/main)"' \
  'gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs"' \
  '-f ref="refs/tags/$release_tag"' \
  'permissions: {}' \
  'contents: write' \
  'id-token: write' \
  'attestations: write' \
  'IMMUTABLE_RELEASES_READ_TOKEN' \
  'repos/$GITHUB_REPOSITORY/immutable-releases' \
  'tag_pattern=' \
  'git merge-base --is-ancestor' \
  './scripts/build-vm-image.sh x86-64 release "$RELEASE_TAG"' \
  './scripts/test-vm-release.sh x86-64' \
  'grep -Fxq '\''status=PASS'\''' \
  'grep -Fxq '\''exact_release_image=true'\''' \
  'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' \
  'image.provenance.bundle.json' \
  'checksums.provenance.bundle.json' \
  'gh release create "$RELEASE_TAG" --verify-tag --draft --prerelease --latest=false' \
  'gh release upload "$RELEASE_TAG" "$asset"' \
  'asset whitelist mismatch' \
  'release.get("immutable") is not True'; do
  assert_contains "$required_text" "$RELEASE_WORKFLOW"
done

python3 - "$RELEASE_WORKFLOW" <<'PY_STAGE_SMOKE_GATES'
import pathlib
import sys

workflow_path = pathlib.Path(sys.argv[1])
lines = workflow_path.read_text(encoding="utf-8").splitlines()
step_name = "- name: Stage exact white-listed release assets"
try:
    start = next(index for index, line in enumerate(lines) if line.strip() == step_name)
except StopIteration:
    raise SystemExit(f"VM release policy test failed: workflow is missing stage step: {step_name}")

step_indent = len(lines[start]) - len(lines[start].lstrip())
end = len(lines)
for index in range(start + 1, len(lines)):
    stripped = lines[index].strip()
    indent = len(lines[index]) - len(lines[index].lstrip())
    if indent == step_indent and stripped.startswith("- name:"):
        end = index
        break

stage_commands = {line.strip() for line in lines[start:end]}
report = '"$RELEASE_RESULTS_DIR/smoke-report.txt"'
required_greps = {
    f"grep -Fxq 'qemu_boot=PASS' {report}",
    f"grep -Fxq 'ssh_runtime_evidence=PASS' {report}",
    f"grep -Fxq 'ssh_port_probe=PASS' {report}",
    f"grep -Fxq 'ssh=DISABLED_BY_DEFAULT' {report}",
    f"grep -Fxq 'authorized_keys=ABSENT' {report}",
    f"grep -Fxq 'dropbear_enabled=NO' {report}",
    f"grep -Fxq 'dropbear_running=NO' {report}",
}
missing = sorted(required_greps - stage_commands)
if missing:
    formatted = "\n".join(f"  - {command}" for command in missing)
    raise SystemExit(
        "VM release policy test failed: Stage exact white-listed release assets "
        f"is missing exact smoke-report gates:\n{formatted}"
    )
PY_STAGE_SMOKE_GATES

[[ "$(grep -Fc 'actions/attest-build-provenance@96278af6caaf10aea03fd8d33a09a777ca52d62f' "$RELEASE_WORKFLOW")" == 2 ]] || \
  fail "VM release workflow must create exactly two attestations"
assert_not_contains "- 'ram-test-v*'" "$RELEASE_WORKFLOW"
assert_not_contains "- 'ram-test-nss-v*'" "$RELEASE_WORKFLOW"

python3 - "$RELEASE_WORKFLOW" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected_assets = {
    "$IMAGE_BASENAME",
    "${IMAGE_BASENAME}.sha256",
    "$MANIFEST_BASENAME",
    "artifact-labels.env",
    "README-VM.txt",
    "smoke-report.txt",
    "SHA256SUMS",
    "image.provenance.bundle.json",
    "checksums.provenance.bundle.json",
}
for asset in expected_assets:
    if asset not in text:
        raise SystemExit(f"VM release policy test failed: whitelist asset missing from workflow: {asset}")
if "ram-test" in re.sub(r"ram-test-\*\|ram-test-nss-\*", "", text):
    # The workflow may reject ram-test-* in a case pattern but must not publish that channel.
    allowed = "ram-test-*|ram-test-nss-*|*AX9000*|*ax9000*)"
    if allowed not in text:
        raise SystemExit("VM release policy test failed: unexpected ram-test usage")
PY

for required_text in \
  'vm-x86_64-vX.Y.Z-rc.N' \
  'NexaWrt-x86_64-v0.1.0-rc.1-generic-ext4-combined.img.gz' \
  'sha256sum -c' \
  'qemu-system-x86_64' \
  'http://127.0.0.1:8080/cgi-bin/luci/' \
  'Remote SSH' \
  'VM_ONLY=1' \
  'NOT_AX9000_FIRMWARE=1' \
  'HARDWARE_VALIDATION=0' \
  'NSS_VALIDATION=0' \
  '不能直接等同于“可以安全刷机”'; do
  assert_contains "$required_text" "$DOC"
done

policy_tmp="$(mktemp -d)"
trap 'rm -rf "$policy_tmp"' EXIT
printf 'not-an-image\n' > "$policy_tmp/image.img.gz"
if /bin/bash "$BUILD_SCRIPT" armsr-armv8 release vm-x86_64-v0.1.0-rc.1 >"$policy_tmp/build-armsr-release.out" 2>&1; then
  fail "build script accepted armsr release mode"
fi
if /bin/bash "$BUILD_SCRIPT" x86-64 release ram-test-v0.1.0-rc.1 >"$policy_tmp/build-ram-tag.out" 2>&1; then
  fail "build script accepted AX9000 ram-test tag as a VM release tag"
fi
if VM_RELEASE_OUTPUT_DIR="$policy_tmp/release-results" /bin/bash "$RELEASE_SCRIPT" armsr-armv8 "$policy_tmp/image.img.gz" >"$policy_tmp/test-armsr-release.out" 2>&1; then
  fail "release test script accepted non-x86 target"
fi
FAIL_REPORT="$policy_tmp/release-results/smoke-report.txt"
assert_contains 'status=FAIL' "$FAIL_REPORT"
assert_contains 'qemu_boot=UNVERIFIED' "$FAIL_REPORT"
assert_not_contains 'qemu_boot=PASS' "$FAIL_REPORT"

"$MANIFEST_SELECTION_TEST"

printf 'VM release policy tests passed.\n'
