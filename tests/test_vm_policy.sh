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

assert_not_contains() {
  local needle="$1" file="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "$file contains forbidden policy text: $needle"
  fi
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
assert_contains '"PROFILE=$PROFILE"' "$BUILD_SCRIPT"
assert_contains '"FILES=$OVERLAY_WORK"' "$BUILD_SCRIPT"
assert_contains 'ARTIFACT_BASENAME="nexawrt-vm-smoke-openwrt-${VM_OPENWRT_VERSION}-${TARGET}.img.gz"' "$BUILD_SCRIPT"
assert_contains 'ARTIFACT_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined.img.gz"' "$BUILD_SCRIPT"
artifact_expressions="$(sed -nE 's/^[[:space:]]*ARTIFACT_BASENAME="(.*)"/\1/p' "$BUILD_SCRIPT")"
[[ -n "$artifact_expressions" ]] || fail "VM artifact basenames are not explicit"
while IFS= read -r artifact_expression; do
  artifact_expression_lower="$(printf '%s' "$artifact_expression" | tr '[:upper:]' '[:lower:]')"
  [[ "$artifact_expression_lower" != *ax9000* ]] || fail "VM image artifact name mentions AX9000"
done <<<"$artifact_expressions"
! grep -Fq 'files/etc' "$BUILD_SCRIPT" || fail "VM build script references the hardware overlay"
assert_contains 'MODE="smoke"' "$BUILD_SCRIPT"
assert_contains 'release mode supports x86-64 only' "$BUILD_SCRIPT"
assert_contains 'VM_SMOKE_AUTHORIZED_KEY_FILE is required in smoke mode' "$BUILD_SCRIPT"
assert_contains 'VM_SMOKE_AUTHORIZED_KEY_FILE must not be set in release mode' "$BUILD_SCRIPT"
assert_contains 'RELEASE_TAG_PATTERN=' "$BUILD_SCRIPT"

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
assert_contains 'for service_name in dropbear rpcd uhttpd' "$SMOKE_SCRIPT"
assert_contains 'test -x "/etc/init.d/$service_name"' "$SMOKE_SCRIPT"
assert_not_contains 'for service_name in ubus' "$SMOKE_SCRIPT"
assert_not_contains '/etc/init.d/ubus' "$SMOKE_SCRIPT"
assert_not_contains 'wget ' "$SMOKE_SCRIPT"
assert_not_contains 'pass http-local' "$SMOKE_SCRIPT"
for http_policy_text in \
  'HTTP_STATUS="$OUTPUT_DIR/http-status.txt"' \
  'HTTP_ERROR="$OUTPUT_DIR/http-error.txt"' \
  '--location' \
  '--max-redirs 5' \
  '--dump-header "$HTTP_HEADERS"' \
  '--output "$HTTP_BODY"' \
  '--write-out '"'"'%{http_code}'"'"'' \
  'curl_status=$?' \
  'printf '"'"'%s\n'"'"' "$http_status" > "$HTTP_STATUS"' \
  'x-luci-login-required' \
  'http_status_is_healthy' \
  'printf '"'"'auth_challenge=%s\n'"'"' "$auth_challenge"' \
  'dump_http_diagnostics'; do
  assert_contains "$http_policy_text" "$SMOKE_SCRIPT"
done

python3 - "$SMOKE_SCRIPT" <<'PY'
import pathlib
import re
import subprocess
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
text = path.read_text()

def fail(message):
    print(f"VM policy test failed: {message}", file=sys.stderr)
    raise SystemExit(1)

function_match = re.search(
    r"^fail_http\(\) \{\n(?P<body>.*?)^\}$",
    text,
    flags=re.MULTILINE | re.DOTALL,
)
if function_match is None:
    fail("smoke script is missing fail_http()")
function_body = function_match.group("body")
dump_match = re.search(r"^\s*dump_http_diagnostics\s*$", function_body, re.MULTILINE)
fail_match = re.search(r'^\s*fail \"\$@\"\s*$', function_body, re.MULTILINE)
if dump_match is None or fail_match is None:
    fail("fail_http() must call dump_http_diagnostics and fail \"$@\"")
if dump_match.start() > fail_match.start():
    fail("fail_http() must dump HTTP diagnostics before calling fail")

health_function_match = re.search(
    r"^http_status_is_healthy\(\) \{\n.*?^\}$",
    text,
    flags=re.MULTILINE | re.DOTALL,
)
if health_function_match is None:
    fail("smoke script is missing http_status_is_healthy()")
health_function = health_function_match.group(0)
health_cases = (
    ("200", "false", True),
    ("200", "true", True),
    ("403", "true", True),
    ("403", "false", False),
    ("403", "", False),
    ("401", "true", False),
    ("500", "true", False),
)
for status, auth_challenge, expected_healthy in health_cases:
    result = subprocess.run(
        [
            "/bin/bash",
            "-c",
            f'{health_function}\nhttp_status_is_healthy "$1" "$2"',
            "http-health-policy",
            status,
            auth_challenge,
        ],
        check=False,
    )
    actual_healthy = result.returncode == 0
    if actual_healthy != expected_healthy:
        fail(
            "http_status_is_healthy returned "
            f"{actual_healthy} for status={status!r}, auth_challenge={auth_challenge!r}; "
            f"expected {expected_healthy}"
        )

header_function_match = re.search(
    r"^luci_auth_challenge_from_headers\(\) \{\n.*?^\}$",
    text,
    flags=re.MULTILINE | re.DOTALL,
)
if header_function_match is None:
    fail("smoke script is missing luci_auth_challenge_from_headers()")
header_function = header_function_match.group(0)
header_cases = (
    (
        "early redirect yes, final no header (CRLF)",
        b"HTTP/1.1 302 Found\r\nX-LuCI-Login-Required: yes\r\nLocation: /login\r\n\r\n"
        b"HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\n\r\n",
        "false",
    ),
    (
        "early no, final yes (CRLF)",
        b"HTTP/1.1 302 Found\r\nX-LuCI-Login-Required: no\r\nLocation: /login\r\n\r\n"
        b"HTTP/1.1 403 Forbidden\r\nx-luci-login-required: yes\r\n\r\n",
        "true",
    ),
    (
        "final response without auth header (LF)",
        b"HTTP/1.1 403 Forbidden\nContent-Type: text/html\n\n",
        "false",
    ),
    (
        "final auth header value no (CRLF)",
        b"HTTP/1.1 403 Forbidden\r\nx-luci-login-required: no\r\n\r\n",
        "false",
    ),
    (
        "case-insensitive header with whitespace yes (LF)",
        b"HTTP/1.1 403 Forbidden\nX-LuCI-LoGiN-ReQuIrEd:   YeS \t\n\n",
        "true",
    ),
    ("empty header file", b"", "false"),
    ("missing header file", None, "false"),
)
with tempfile.TemporaryDirectory(prefix="nexawrt-vm-header-policy-") as temp_dir:
    for index, (case_name, header_bytes, expected_output) in enumerate(header_cases):
        header_path = pathlib.Path(temp_dir) / f"headers-{index}.txt"
        if header_bytes is not None:
            header_path.write_bytes(header_bytes)
        result = subprocess.run(
            [
                "/bin/bash",
                "-c",
                f'{header_function}\nluci_auth_challenge_from_headers "$1"',
                "luci-header-policy",
                str(header_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        actual_output = result.stdout.strip()
        if result.returncode != 0:
            fail(
                f"luci_auth_challenge_from_headers failed for {case_name}: "
                f"exit={result.returncode}, stderr={result.stderr.strip()!r}"
            )
        if actual_output != expected_output:
            fail(
                f"luci_auth_challenge_from_headers returned {actual_output!r} for {case_name}; "
                f"expected {expected_output!r}"
            )

http_start = text.find('http_status="$(curl')
http_end = text.find('\nSMOKE_STATUS=PASS', http_start)
if http_start < 0 or http_end < 0:
    fail("could not isolate runner-side HTTP validation block")
http_block = text[http_start:http_end]
fail_http_calls = re.findall(r"^\s*fail_http(?:\s|$)", http_block, re.MULTILINE)
if len(fail_http_calls) != 3:
    fail(f"runner-side HTTP validation must contain exactly three fail_http calls, found {len(fail_http_calls)}")
if re.search(r"^\s*fail(?:\s|$)", http_block, re.MULTILINE):
    fail("runner-side HTTP validation must not bypass fail_http")
if re.search(r"^\s*dump_http_diagnostics\s*$", http_block, re.MULTILINE):
    fail("HTTP failure branches must centralize diagnostic ordering in fail_http")
PY
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
