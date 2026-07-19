#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: test-vm-release.sh x86-64 <NexaWrt-x86_64-vX.Y.Z-rc.N-generic-ext4-combined.img.gz>

Boot the exact public x86_64 VM release image in QEMU without relying on an
in-image SSH key. Validate serial VM-only labels, LuCI HTTP reachability, the
runtime Dropbear/authorized_keys evidence, and that forwarded guest port 22
never completes an SSH protocol handshake.
This is not AX9000 hardware, flash, Wi-Fi, switch, or NSS validation.
USAGE
}

fail() {
  printf 'test-vm-release: %s\n' "$*" >&2
  return 1
}

dump_http_diagnostics() {
  printf '%s\n' '--- LuCI HTTP diagnostics ---' >&2
  for diagnostic_file in "$HTTP_STATUS" "$HTTP_ERROR" "$HTTP_HEADERS"; do
    if [[ -s "$diagnostic_file" ]]; then
      printf '%s\n' "--- $(basename "$diagnostic_file") ---" >&2
      cat "$diagnostic_file" >&2 || true
    fi
  done
  if [[ -s "$HTTP_BODY" ]]; then
    printf '%s\n' '--- http-body.html (last 4096 bytes) ---' >&2
    tail -c 4096 "$HTTP_BODY" >&2 || true
    printf '\n' >&2
  fi
}

fail_http() {
  dump_http_diagnostics
  fail "$@"
}

http_status_is_healthy() {
  local status="$1"
  local auth_challenge="$2"

  [[ "$status" == 200 || ( "$status" == 403 && "$auth_challenge" == true ) ]]
}

luci_auth_challenge_from_headers() {
  python3 - "$1" <<'PY'
import pathlib
import re
import sys

header_path = pathlib.Path(sys.argv[1])
try:
    header_bytes = header_path.read_bytes()
except OSError:
    print("false")
    raise SystemExit(0)

final_headers = None
for block in re.split(br"\r?\n\r?\n", header_bytes):
    lines = block.splitlines()
    if lines and re.match(br"^HTTP/\S+\s+\d{3}(?:\s|$)", lines[0], re.IGNORECASE):
        final_headers = lines[1:]

auth_challenge = False
if final_headers is not None:
    for line in final_headers:
        name, separator, value = line.partition(b":")
        if (
            separator
            and name.strip().lower() == b"x-luci-login-required"
            and value.strip().lower() == b"yes"
        ):
            auth_challenge = True
            break

print("true" if auth_challenge else "false")
PY
}

allocate_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

serial_has_release_labels() {
  grep -Fq 'NexaWrt x86_64 VM release image' "$SERIAL_LOG" &&
    grep -Fxq 'ARTIFACT_CLASS=VM_DISTRIBUTION_IMAGE' "$SERIAL_LOG" &&
    grep -Fxq 'VM_ONLY=1' "$SERIAL_LOG" &&
    grep -Fxq 'NOT_AX9000_FIRMWARE=1' "$SERIAL_LOG" &&
    grep -Fxq 'HARDWARE_VALIDATION=0' "$SERIAL_LOG" &&
    grep -Fxq 'NSS_VALIDATION=0' "$SERIAL_LOG" &&
    grep -Fq 'Remote SSH is disabled by default' "$SERIAL_LOG"
}

serial_has_ssh_runtime_evidence() {
  python3 - "$SERIAL_LOG" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace").replace("\r", "")
expected = "\n".join(
    (
        "NEXAWRT_VM_SSH_RUNTIME_EVIDENCE_V1_BEGIN",
        "ssh=DISABLED_BY_DEFAULT",
        "authorized_keys=ABSENT",
        "dropbear_enabled=NO",
        "dropbear_running=NO",
        "NEXAWRT_VM_SSH_RUNTIME_EVIDENCE_V1_END",
    )
)
raise SystemExit(0 if expected in text else 1)
PY
}

probe_luci_http() {
  set +e
  http_status="$(curl --silent --show-error \
    --connect-timeout 5 --max-time 30 \
    --retry 1 --retry-delay 1 --retry-all-errors \
    --location --max-redirs 5 \
    --dump-header "$HTTP_HEADERS" --output "$HTTP_BODY" --write-out '%{http_code}' \
    "http://127.0.0.1:${HTTP_PORT}/cgi-bin/luci/" 2> "$HTTP_ERROR")"
  curl_status=$?
  set -e
  printf '%s\n' "$http_status" > "$HTTP_STATUS"
  auth_challenge="$(luci_auth_challenge_from_headers "$HTTP_HEADERS")"
  (( curl_status == 0 )) || return 1
  http_status_is_healthy "$http_status" "$auth_challenge" || return 1
  grep -Eqi 'luci|<html' "$HTTP_BODY" || return 1
}

probe_no_ssh_service() {
  python3 - "$SSH_PORT" >"$SSH_PROBE" 2>&1 <<'PY'
import socket
import sys
import time

port = int(sys.argv[1])
for attempt in range(1, 4):
    sock = socket.socket()
    sock.settimeout(2.0)
    try:
        sock.connect(("127.0.0.1", port))
        try:
            first = sock.recv(512)
        except socket.timeout:
            sock.sendall(b"SSH-2.0-NexaWrtReleaseProbe\r\n")
            try:
                first = sock.recv(512)
            except socket.timeout:
                first = b""
        if first:
            print(f"attempt={attempt} result=UNEXPECTED_SERVICE_DATA data={first[:160]!r}")
            raise SystemExit(1)
        print(f"attempt={attempt} result=NO_SSH_PROTOCOL connection_closed_or_silent=true")
    except (ConnectionRefusedError, ConnectionResetError, BrokenPipeError, TimeoutError, OSError) as exc:
        print(f"attempt={attempt} result=NO_SSH_PROTOCOL error={type(exc).__name__}")
    finally:
        sock.close()
    time.sleep(0.5)

print("ssh_host_port=NO_SSH_PROTOCOL")
PY
}

[[ $# -eq 2 ]] || { usage; exit 2; }
TARGET="$1"
IMAGE_GZ="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"
OUTPUT_DIR="${VM_RELEASE_OUTPUT_DIR:-$(pwd)/vm-release-results/$TARGET}"
BOOT_TIMEOUT="${VM_RELEASE_BOOT_TIMEOUT:-300}"
mkdir -p "$OUTPUT_DIR"
SERIAL_LOG="$OUTPUT_DIR/serial.log"
HTTP_HEADERS="$OUTPUT_DIR/http-headers.txt"
HTTP_BODY="$OUTPUT_DIR/http-body.html"
HTTP_STATUS="$OUTPUT_DIR/http-status.txt"
HTTP_ERROR="$OUTPUT_DIR/http-error.txt"
SSH_PROBE="$OUTPUT_DIR/ssh-port-probe.txt"
REPORT="$OUTPUT_DIR/smoke-report.txt"
DISK_IMAGE="$OUTPUT_DIR/disk.img"
QEMU_PID=""
HTTP_PORT="unallocated"
SSH_PORT="unallocated"
SMOKE_STATUS="FAIL"
qemu_boot_result="UNVERIFIED"
http_status="unknown"
auth_challenge="false"
serial_labels="FAIL"
http_result="FAIL"
ssh_runtime_evidence="FAIL"
ssh_port_probe="FAIL"
ssh_result="UNVERIFIED"
authorized_keys_result="UNVERIFIED"
dropbear_enabled_result="UNVERIFIED"
dropbear_running_result="UNVERIFIED"

write_report() {
  local status="$1"
  {
    printf 'status=%s\n' "$status"
    printf 'target=%s\n' "$TARGET"
    printf 'image=%s\n' "${IMAGE_GZ:-}"
    printf 'vm_only=true\n'
    printf 'not_ax9000_firmware=true\n'
    printf 'hardware_validation=false\n'
    printf 'nss_validation=false\n'
    printf 'exact_release_image=true\n'
    printf 'qemu_boot=%s\n' "$qemu_boot_result"
    printf 'serial_labels=%s\n' "$serial_labels"
    printf 'http=%s\n' "$http_result"
    printf 'ssh_runtime_evidence=%s\n' "$ssh_runtime_evidence"
    printf 'ssh_port_probe=%s\n' "$ssh_port_probe"
    printf 'ssh=%s\n' "$ssh_result"
    printf 'authorized_keys=%s\n' "$authorized_keys_result"
    printf 'dropbear_enabled=%s\n' "$dropbear_enabled_result"
    printf 'dropbear_running=%s\n' "$dropbear_running_result"
    printf 'http_status=%s\n' "${http_status:-unknown}"
    printf 'auth_challenge=%s\n' "$auth_challenge"
    printf 'http_host_port=%s\n' "$HTTP_PORT"
    printf 'ssh_host_port=%s\n' "$SSH_PORT"
    printf 'serial_log=%s\n' "$SERIAL_LOG"
    printf 'ssh_probe_log=%s\n' "$SSH_PROBE"
  } > "$REPORT"
}

cleanup() {
  rc=$?
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ ! -f "$REPORT" ]]; then
    write_report "$SMOKE_STATUS"
  fi
  if [[ "$SMOKE_STATUS" != PASS ]]; then
    if [[ -s "$SSH_PROBE" ]]; then
      printf '%s\n' '--- SSH host-port diagnostics ---' >&2
      cat "$SSH_PROBE" >&2 || true
    fi
    if [[ -s "$SERIAL_LOG" ]]; then
      printf '%s\n' '--- QEMU serial tail ---' >&2
      tail -n 120 "$SERIAL_LOG" >&2 || true
    fi
  fi
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

[[ "$TARGET" == x86-64 ]] || { usage; fail "release validation supports x86-64 only"; exit 2; }
[[ -f "$IMAGE_GZ" && ! -L "$IMAGE_GZ" ]] || { fail "image must be a regular file: $IMAGE_GZ"; exit 1; }
case "$(basename "$IMAGE_GZ" | tr '[:upper:]' '[:lower:]')" in
  *ax9000*) fail "VM release image filename must not identify itself as AX9000 firmware"; exit 1 ;;
  nexawrt-x86_64-v*-generic-ext4-combined.img.gz) ;;
  *) fail "unexpected x86_64 VM release image filename: $(basename "$IMAGE_GZ")"; exit 1 ;;
esac
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { fail "VM_RELEASE_BOOT_TIMEOUT must be a positive integer"; exit 1; }
for command_name in qemu-system-x86_64 curl gzip python3 tail grep; do
  command -v "$command_name" >/dev/null 2>&1 || { fail "required command is missing: $command_name"; exit 1; }
done

gzip -t "$IMAGE_GZ"
gzip -dc "$IMAGE_GZ" > "$DISK_IMAGE"
HTTP_PORT="$(allocate_port)"
SSH_PORT="$(allocate_port)"
[[ "$HTTP_PORT" != "$SSH_PORT" ]] || { fail "random HTTP and SSH host ports collided"; exit 1; }

QEMU_ARGS=(
  -m 512
  -smp 2
  -display none
  -monitor none
  -serial "file:$SERIAL_LOG"
  -no-reboot
  -machine "q35,accel=tcg"
  -drive "file=$DISK_IMAGE,format=raw,if=ide"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
  -device "e1000,netdev=net0"
)

printf 'Starting exact x86_64 VM release image for QEMU validation (not AX9000 hardware/NSS validation).\n'
qemu-system-x86_64 "${QEMU_ARGS[@]}" >/dev/null 2>&1 &
QEMU_PID=$!
qemu_boot_result="FAIL"

deadline=$((SECONDS + BOOT_TIMEOUT))
while (( SECONDS < deadline )); do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" || true
    fail "QEMU exited before release validation completed"
    exit 1
  fi
  if [[ "$serial_labels" != PASS ]] && serial_has_release_labels; then
    serial_labels=PASS
  fi
  if [[ "$ssh_runtime_evidence" != PASS ]] && serial_has_ssh_runtime_evidence; then
    ssh_runtime_evidence=PASS
    ssh_result="DISABLED_BY_DEFAULT"
    authorized_keys_result="ABSENT"
    dropbear_enabled_result="NO"
    dropbear_running_result="NO"
  fi
  if [[ "$http_result" != PASS ]] && probe_luci_http >/dev/null 2>&1; then
    http_result=PASS
  fi
  if [[ "$ssh_runtime_evidence" == PASS && "$http_result" == PASS && "$ssh_port_probe" != PASS ]] && probe_no_ssh_service; then
    ssh_port_probe=PASS
  fi
  [[ "$serial_labels" == PASS && "$http_result" == PASS && "$ssh_runtime_evidence" == PASS && "$ssh_port_probe" == PASS ]] && break
  sleep 3
done

[[ "$serial_labels" == PASS ]] || { fail "serial VM-only release labels did not appear within ${BOOT_TIMEOUT}s"; exit 1; }
[[ "$ssh_runtime_evidence" == PASS ]] || { fail "runtime Dropbear/authorized_keys evidence did not appear within ${BOOT_TIMEOUT}s"; exit 1; }
if [[ "$http_result" != PASS ]]; then
  fail_http "LuCI HTTP did not become healthy within ${BOOT_TIMEOUT}s"
  exit 1
fi
[[ "$ssh_port_probe" == PASS ]] || { fail "forwarded guest port 22 accepted SSH or could not be verified closed"; exit 1; }
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  wait "$QEMU_PID" || true
  fail "QEMU exited after completing release checks but before PASS report generation"
  exit 1
fi

qemu_boot_result="PASS"
SMOKE_STATUS=PASS
write_report PASS
printf 'VM release test PASS for %s. SSH is runtime-verified disabled; this is not AX9000 hardware or NSS validation.\n' "$TARGET"
