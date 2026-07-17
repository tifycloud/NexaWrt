#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: test-vm-smoke.sh <x86-64|armsr-armv8> <image.img.gz> <ssh-private-key>

Boot a VM-only image in QEMU and validate networking, SSH, HTTP, ubus, UCI,
core services, and the dangerous-command guards. This is not hardware or NSS
validation.
USAGE
}

fail() {
  printf 'test-vm-smoke: %s\n' "$*" >&2
  return 1
}

[[ $# -eq 3 ]] || { usage; exit 2; }
TARGET="$1"
IMAGE_GZ="$(cd "$(dirname "$2")" 2>/dev/null && pwd)/$(basename "$2")"
SSH_KEY="$(cd "$(dirname "$3")" 2>/dev/null && pwd)/$(basename "$3")"
OUTPUT_DIR="${VM_SMOKE_OUTPUT_DIR:-$(pwd)/vm-smoke-results/$TARGET}"
BOOT_TIMEOUT="${VM_SMOKE_BOOT_TIMEOUT:-300}"
mkdir -p "$OUTPUT_DIR"
SERIAL_LOG="$OUTPUT_DIR/serial.log"
SSH_LOG="$OUTPUT_DIR/ssh-checks.log"
HTTP_HEADERS="$OUTPUT_DIR/http-headers.txt"
HTTP_BODY="$OUTPUT_DIR/http-body.html"
REPORT="$OUTPUT_DIR/smoke-report.txt"
DISK_IMAGE="$OUTPUT_DIR/disk.img"
QEMU_PID=""
SMOKE_STATUS="FAIL"

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
    printf 'status=%s\ntarget=%s\n' "$SMOKE_STATUS" "$TARGET" > "$REPORT"
  fi
  if [[ "$SMOKE_STATUS" != PASS ]]; then
    {
      printf 'status=FAIL\n'
      printf 'target=%s\n' "$TARGET"
      printf 'vm_only=true\n'
      printf 'not_ax9000_firmware=true\n'
      printf 'hardware_validation=false\n'
      printf 'nss_validation=false\n'
      printf 'serial_log=%s\n' "$SERIAL_LOG"
      printf 'ssh_log=%s\n' "$SSH_LOG"
    } > "$REPORT"
    if [[ -s "$SERIAL_LOG" ]]; then
      printf '%s\n' '--- QEMU serial tail ---' >&2
      tail -n 80 "$SERIAL_LOG" >&2 || true
    fi
  fi
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

case "$TARGET" in
  x86-64) QEMU_BIN="qemu-system-x86_64" ;;
  armsr-armv8) QEMU_BIN="qemu-system-aarch64" ;;
  *) usage; fail "unsupported target: $TARGET"; exit 2 ;;
esac

[[ -f "$IMAGE_GZ" && ! -L "$IMAGE_GZ" ]] || { fail "image must be a regular file: $IMAGE_GZ"; exit 1; }
[[ -f "$SSH_KEY" && ! -L "$SSH_KEY" ]] || { fail "SSH key must be a regular file: $SSH_KEY"; exit 1; }
case "$(basename "$IMAGE_GZ" | tr '[:upper:]' '[:lower:]')" in
  *ax9000*) fail "VM image filename must not identify itself as AX9000 firmware"; exit 1 ;;
esac
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { fail "VM_SMOKE_BOOT_TIMEOUT must be a positive integer"; exit 1; }
for command_name in "$QEMU_BIN" curl gzip python3 ssh timeout; do
  command -v "$command_name" >/dev/null 2>&1 || { fail "required command is missing: $command_name"; exit 1; }
done

gzip -dc "$IMAGE_GZ" > "$DISK_IMAGE"

allocate_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}
SSH_PORT="$(allocate_port)"
HTTP_PORT="$(allocate_port)"
[[ "$SSH_PORT" != "$HTTP_PORT" ]] || HTTP_PORT="$(allocate_port)"

QEMU_ARGS=(
  -m 512
  -smp 2
  -display none
  -monitor none
  -serial stdio
  -no-reboot
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80"
)
if [[ "$TARGET" == x86-64 ]]; then
  QEMU_ARGS+=(
    -machine "q35,accel=tcg"
    -drive "file=$DISK_IMAGE,format=raw,if=ide"
    -device "e1000,netdev=net0"
  )
else
  AARCH64_EFI="${VM_AARCH64_EFI:-}"
  if [[ -z "$AARCH64_EFI" ]]; then
    for candidate in \
      /usr/share/AAVMF/AAVMF_CODE.fd \
      /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
      /usr/share/edk2/aarch64/QEMU_EFI.fd; do
      if [[ -f "$candidate" ]]; then
        AARCH64_EFI="$candidate"
        break
      fi
    done
  fi
  [[ -n "$AARCH64_EFI" && -f "$AARCH64_EFI" ]] || { fail "AArch64 QEMU EFI firmware was not found"; exit 1; }
  QEMU_ARGS+=(
    -machine "virt,accel=tcg"
    -cpu cortex-a57
    -bios "$AARCH64_EFI"
    -drive "file=$DISK_IMAGE,format=raw,if=virtio"
    -device "virtio-net-pci,netdev=net0"
  )
fi

printf 'Starting %s for VM-only smoke validation (not hardware/NSS validation).\n' "$TARGET"
"$QEMU_BIN" "${QEMU_ARGS[@]}" > "$SERIAL_LOG" 2>&1 &
QEMU_PID=$!

SSH_OPTIONS=(
  -i "$SSH_KEY"
  -p "$SSH_PORT"
  -o BatchMode=yes
  -o ConnectTimeout=4
  -o ConnectionAttempts=1
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

deadline=$((SECONDS + BOOT_TIMEOUT))
ssh_ready=false
while (( SECONDS < deadline )); do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    wait "$QEMU_PID" || true
    fail "QEMU exited before SSH became ready"
    exit 1
  fi
  if timeout 10 ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 true >/dev/null 2>&1; then
    ssh_ready=true
    break
  fi
  sleep 3
done
[[ "$ssh_ready" == true ]] || { fail "SSH did not become ready within ${BOOT_TIMEOUT}s"; exit 1; }

if ! timeout 120 ssh "${SSH_OPTIONS[@]}" root@127.0.0.1 'sh -s' > "$SSH_LOG" 2>&1 <<'REMOTE_CHECKS'
set -eu

pass() {
  printf 'PASS %s\n' "$1"
}

label=/etc/nexawrt-vm-smoke
grep -qx 'ARTIFACT_CLASS=VM_SMOKE_IMAGE' "$label"
grep -qx 'VM_ONLY=1' "$label"
grep -qx 'NOT_AX9000_FIRMWARE=1' "$label"
grep -qx 'HARDWARE_VALIDATION=0' "$label"
grep -qx 'NSS_VALIDATION=0' "$label"
grep -q 'VM ONLY.*NOT-AX9000' /etc/banner
pass labels

ubus call system board
ubus call network.interface.lan status | grep -q '"up": true'
pass ubus

test "$(uci -q get system.@system[0].hostname)" = 'nexawrt-vm-smoke'
test "$(uci -q get network.lan.proto)" = 'dhcp'
test "$(uci -q get uhttpd.main.redirect_https)" = '0'
pass uci

ip -4 address show dev eth0 | grep -q 'inet '
ip -4 route show | grep -q '^default '
gateway="$(ip -4 route show default | awk 'NR == 1 { print $3 }')"
test -n "$gateway"
ping -c 1 -W 5 "$gateway" >/dev/null
pass network

for service_name in ubus dropbear rpcd uhttpd; do
  "/etc/init.d/$service_name" running
  printf 'service %s running\n' "$service_name"
done
pass services

wget -qO /tmp/vm-smoke-luci.html http://127.0.0.1/cgi-bin/luci/
grep -Eqi 'luci|<html' /tmp/vm-smoke-luci.html
rm -f /tmp/vm-smoke-luci.html
pass http-local

check_guard() {
  guard_path="$1"
  set +e
  guard_output="$("$guard_path" 2>&1)"
  guard_status=$?
  set -e
  test "$guard_status" -eq 74
  printf '%s\n' "$guard_output" | grep -q 'VM-only safety guard'
  printf '%s\n' "$guard_output" | grep -q 'not hardware/NSS validation'
}
for guard_path in \
  /sbin/factoryreset \
  /sbin/firstboot \
  /sbin/jffs2mark \
  /sbin/jffs2reset \
  /sbin/mtd \
  /sbin/sysupgrade \
  /sbin/ubiattach \
  /sbin/ubidetach \
  /sbin/ubiformat; do
  check_guard "$guard_path"
done
pass dangerous-command-guards
REMOTE_CHECKS
then
  fail "SSH/ubus/UCI/service/guard checks failed"
  exit 1
fi

http_status="$(curl --silent --show-error --max-time 20 \
  --dump-header "$HTTP_HEADERS" --output "$HTTP_BODY" --write-out '%{http_code}' \
  "http://127.0.0.1:${HTTP_PORT}/cgi-bin/luci/")"
[[ "$http_status" =~ ^(200|30[1278])$ ]] || { fail "unexpected LuCI HTTP status: $http_status"; exit 1; }
grep -Eqi 'luci|<html|location:' "$HTTP_BODY" "$HTTP_HEADERS" || { fail "LuCI HTTP response was not recognizable"; exit 1; }

SMOKE_STATUS=PASS
{
  printf 'status=PASS\n'
  printf 'target=%s\n' "$TARGET"
  printf 'image=%s\n' "$IMAGE_GZ"
  printf 'vm_only=true\n'
  printf 'not_ax9000_firmware=true\n'
  printf 'hardware_validation=false\n'
  printf 'nss_validation=false\n'
  printf 'qemu_boot=PASS\n'
  printf 'network=PASS\n'
  printf 'ssh=PASS\n'
  printf 'http=PASS\n'
  printf 'ubus=PASS\n'
  printf 'uci=PASS\n'
  printf 'services=PASS\n'
  printf 'dangerous_command_guards=PASS\n'
  printf 'http_status=%s\n' "$http_status"
} > "$REPORT"
printf 'VM smoke test PASS for %s. This is not hardware or NSS validation.\n' "$TARGET"
