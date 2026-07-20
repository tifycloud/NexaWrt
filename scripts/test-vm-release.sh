#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: test-vm-release.sh x86-64 <release-artifact-directory>

Validate the exact NexaWrt x86_64 v2 release set in QEMU:
- raw BIOS disk with SeaBIOS
- BIOS Live ISO with SeaBIOS
- EFI Live ISO with OVMF
- BIOS VMDK with SeaBIOS
- EFI VMDK with OVMF

Every variant must boot with two NICs (NIC 1 LAN, NIC 2 WAN), expose LuCI only
through HTTPS on the LAN, redirect HTTP to HTTPS, keep firewall4/nftables active,
emit production runtime evidence, and expose no SSH protocol. A single report
binds all five exact filenames. This is QEMU validation only; streamOptimized
VMDKs must still be imported into writable ESXi datastore disks and real ESXi
validation remains explicitly required before stable promotion.
USAGE
}

fail() {
  printf 'test-vm-release: %s\n' "$*" >&2
  return 1
}

allocate_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

https_status_is_healthy() {
  local status="$1"
  local auth_challenge="$2"
  [[ ( "$status" == 200 && "$auth_challenge" == false ) ||
     ( "$status" == 403 && "$auth_challenge" == true ) ]]
}

http_status_is_redirect() {
  case "$1" in
    301|302|307|308) return 0 ;;
    *) return 1 ;;
  esac
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
        if separator and name.strip().lower() == b"x-luci-login-required" and value.strip().lower() == b"yes":
            auth_challenge = True
            break

print("true" if auth_challenge else "false")
PY
}

serial_has_release_labels() {
  local serial_log="$1"
  [[ -s "$serial_log" ]] || return 1
  python3 - "$serial_log" <<'PY_LABELS'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace").replace("\r", "")
required = (
    "NEXAWRT_VM_RELEASE_METADATA_V2_BEGIN",
    "RELEASE_CONTRACT=vm-x86_64/v2",
    "RELEASE_CHANNEL=rc",
    "ARTIFACT_CLASS=VM_DISTRIBUTION_SET",
    "PUBLISHED_VARIANTS=raw_bios,iso_bios,iso_efi,vmdk_bios,vmdk_efi",
    "ESXI_VALIDATION=not-tested",
    "VM_ONLY=1",
    "NOT_AX9000_FIRMWARE=1",
    "HARDWARE_VALIDATION=0",
    "NSS_VALIDATION=0",
    "VALIDATION_SCOPE=QEMU_RUNTIME_ALL_VARIANTS",
    "SSH_DEFAULT=disabled",
    "SSH_AUTHORIZED_KEYS=absent",
    "NEXAWRT_VM_RELEASE_METADATA_V2_END",
)
valid_identity = re.search(r"(?m)^RELEASE_TAG=vm-x86_64-v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$", text)
valid_version = re.search(r"(?m)^RELEASE_VERSION=v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$", text)
valid_commit = re.search(r"(?m)^PROJECT_COMMIT=[0-9a-f]{40}$", text)
raise SystemExit(0 if all(value in text for value in required) and valid_identity and valid_version and valid_commit else 1)
PY_LABELS
}

serial_has_runtime_evidence() {
  local serial_log="$1"
  [[ -s "$serial_log" ]] || return 1
  python3 - "$serial_log" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace").replace("\r", "")
required = (
    "NEXAWRT_VM_RUNTIME_EVIDENCE_V2_BEGIN",
    "network_mode=router",
    "lan_device=eth0",
    "lan_address=192.168.8.1",
    "wan_device=eth1",
    "https_redirect=ENABLED",
    "firewall=ENABLED",
    "ssh=DISABLED_BY_DEFAULT",
    "authorized_keys=ABSENT",
    "dropbear_enabled=NO",
    "dropbear_running=NO",
    "NEXAWRT_VM_RUNTIME_EVIDENCE_V2_END",
)
raise SystemExit(0 if all(value in text for value in required) else 1)
PY
}

serial_has_production_runtime() {
  local serial_log="$1"
  [[ -s "$serial_log" ]] || return 1
  python3 - "$serial_log" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace").replace("\r", "")
required = (
    "NEXAWRT_VM_PRODUCTION_RUNTIME_V1_BEGIN",
    "network_mode=router",
    "lan_device=eth0",
    "lan_address=192.168.8.1",
    "wan_device=eth1",
    "https_redirect=PASS",
    "firewall_enabled=PASS",
    "nftables_fw4=PASS",
    "lan_dhcp=PASS",
    "root_password=UNIQUE_FIRST_BOOT_VALUE",
    "ssh_disabled=PASS",
    "NEXAWRT_VM_PRODUCTION_RUNTIME_V1_END",
)
raise SystemExit(0 if all(value in text for value in required) else 1)
PY
}

probe_luci_https() {
  set +e
  current_https_status="$(curl --silent --show-error --insecure \
    --connect-timeout 5 --max-time 30 \
    --retry 1 --retry-delay 1 --retry-all-errors \
    --location --max-redirs 5 \
    --dump-header "$CURRENT_HTTPS_HEADERS" --output "$CURRENT_HTTPS_BODY" --write-out '%{http_code}' \
    "https://127.0.0.1:${CURRENT_HTTPS_PORT}/cgi-bin/luci/" 2> "$CURRENT_HTTPS_ERROR")"
  local curl_status=$?
  set -e
  printf '%s\n' "$current_https_status" > "$CURRENT_HTTPS_STATUS_FILE"
  current_auth_challenge="$(luci_auth_challenge_from_headers "$CURRENT_HTTPS_HEADERS")"
  (( curl_status == 0 )) || return 1
  https_status_is_healthy "$current_https_status" "$current_auth_challenge" || return 1
  grep -Eqi 'luci|<html' "$CURRENT_HTTPS_BODY" || return 1
}

probe_http_redirect() {
  set +e
  current_http_status="$(curl --silent --show-error \
    --connect-timeout 5 --max-time 20 \
    --dump-header "$CURRENT_HTTP_HEADERS" --output "$CURRENT_HTTP_BODY" --write-out '%{http_code}' \
    "http://127.0.0.1:${CURRENT_HTTP_PORT}/cgi-bin/luci/" 2> "$CURRENT_HTTP_ERROR")"
  local curl_status=$?
  set -e
  printf '%s\n' "$current_http_status" > "$CURRENT_HTTP_STATUS_FILE"
  (( curl_status == 0 )) || return 1
  http_status_is_redirect "$current_http_status" || return 1
  grep -Eqi '^location:[[:space:]]*https://' "$CURRENT_HTTP_HEADERS"
}

probe_no_ssh_service() {
  python3 - "$CURRENT_SSH_PORT" >"$CURRENT_SSH_PROBE" 2>&1 <<'PY'
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

find_ovmf_pair() {
  local code vars
  while IFS='|' read -r code vars; do
    if [[ -f "$code" && -f "$vars" ]]; then
      code="$(readlink -f "$code")"
      vars="$(readlink -f "$vars")"
      [[ -f "$code" && -f "$vars" ]] || continue
      printf '%s|%s\n' "$code" "$vars"
      return 0
    fi
  done <<'PAIRS'
/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd
/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd
/usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd
/usr/share/edk2/x64/OVMF_CODE.fd|/usr/share/edk2/x64/OVMF_VARS.fd
PAIRS
  return 1
}

stop_current_qemu() {
  if [[ -n "${CURRENT_QEMU_PID:-}" ]] && kill -0 "$CURRENT_QEMU_PID" 2>/dev/null; then
    kill "$CURRENT_QEMU_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$CURRENT_QEMU_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$CURRENT_QEMU_PID" 2>/dev/null || true
    wait "$CURRENT_QEMU_PID" 2>/dev/null || true
  fi
  CURRENT_QEMU_PID=""
}

dump_variant_diagnostics() {
  local variant="$1"
  printf '%s\n' "--- ${variant} diagnostics ---" >&2
  for path in "$CURRENT_HTTP_STATUS_FILE" "$CURRENT_HTTP_ERROR" "$CURRENT_HTTP_HEADERS" "$CURRENT_HTTPS_STATUS_FILE" "$CURRENT_HTTPS_ERROR" "$CURRENT_HTTPS_HEADERS" "$CURRENT_SSH_PROBE"; do
    if [[ -s "$path" ]]; then
      printf '%s\n' "--- $(basename "$path") ---" >&2
      cat "$path" >&2 || true
    fi
  done
  for body_path in "$CURRENT_HTTP_BODY" "$CURRENT_HTTPS_BODY"; do
    if [[ -s "$body_path" ]]; then
      printf '%s\n' "--- $(basename "$body_path") (last 4096 bytes) ---" >&2
      tail -c 4096 "$body_path" >&2 || true
      printf '\n' >&2
    fi
  done
  if [[ -s "$CURRENT_SERIAL_LOG" ]]; then
    printf '%s\n' '--- QEMU serial tail ---' >&2
    tail -n 160 "$CURRENT_SERIAL_LOG" >&2 || true
  fi
}

set_variant_result() {
  local variant="$1" result="$2"
  case "$variant" in
    raw_bios) raw_bios_qemu="$result" ;;
    iso_bios) iso_bios_qemu="$result" ;;
    iso_efi) iso_efi_qemu="$result" ;;
    vmdk_bios) vmdk_bios_qemu="$result" ;;
    vmdk_efi) vmdk_efi_qemu="$result" ;;
    *) fail "internal error: unknown variant result key $variant" ;;
  esac
}

run_variant() {
  local variant="$1"
  local image_path="$2"
  local firmware="$3"
  local media="$4"
  local variant_dir="$OUTPUT_DIR/$variant"
  local serial_labels_result="FAIL"
  local https_result_local="FAIL"
  local http_redirect_result_local="FAIL"
  local runtime_result="FAIL"
  local production_runtime_result="FAIL"
  local ssh_port_result="FAIL"
  local ovmf_pair ovmf_code ovmf_vars_source ovmf_vars_work
  local disk_image
  local deadline
  local qemu_args=(
    -m 512
    -smp 2
    -display none
    -monitor none
    -no-reboot
    -machine "q35,accel=tcg"
  )

  mkdir -p "$variant_dir"
  CURRENT_SERIAL_LOG="$variant_dir/serial.log"
  CURRENT_HTTP_HEADERS="$variant_dir/http-redirect-headers.txt"
  CURRENT_HTTP_BODY="$variant_dir/http-redirect-body.html"
  CURRENT_HTTP_STATUS_FILE="$variant_dir/http-redirect-status.txt"
  CURRENT_HTTP_ERROR="$variant_dir/http-redirect-error.txt"
  CURRENT_HTTPS_HEADERS="$variant_dir/https-headers.txt"
  CURRENT_HTTPS_BODY="$variant_dir/https-body.html"
  CURRENT_HTTPS_STATUS_FILE="$variant_dir/https-status.txt"
  CURRENT_HTTPS_ERROR="$variant_dir/https-error.txt"
  CURRENT_SSH_PROBE="$variant_dir/ssh-port-probe.txt"
  CURRENT_HTTP_PORT="$(allocate_port)"
  CURRENT_HTTPS_PORT="$(allocate_port)"
  CURRENT_SSH_PORT="$(allocate_port)"
  while [[ "$CURRENT_HTTP_PORT" == "$CURRENT_HTTPS_PORT" || "$CURRENT_HTTP_PORT" == "$CURRENT_SSH_PORT" || "$CURRENT_HTTPS_PORT" == "$CURRENT_SSH_PORT" ]]; do
    CURRENT_HTTPS_PORT="$(allocate_port)"
    CURRENT_SSH_PORT="$(allocate_port)"
  done
  current_http_status="unknown"
  current_https_status="unknown"
  current_auth_challenge="false"

  qemu_args+=(
    -serial "file:$CURRENT_SERIAL_LOG"
    -netdev "user,id=lan0,net=192.168.8.0/24,dhcpstart=192.168.8.100,hostfwd=tcp:127.0.0.1:${CURRENT_HTTP_PORT}-192.168.8.1:80,hostfwd=tcp:127.0.0.1:${CURRENT_HTTPS_PORT}-192.168.8.1:443,hostfwd=tcp:127.0.0.1:${CURRENT_SSH_PORT}-192.168.8.1:22"
    -device "e1000,netdev=lan0"
    -netdev "user,id=wan0,net=10.0.3.0/24,dhcpstart=10.0.3.15"
    -device "e1000,netdev=wan0"
  )

  if [[ "$firmware" == uefi ]]; then
    ovmf_pair="$(find_ovmf_pair)" || { fail "OVMF CODE/VARS firmware pair is missing"; return 1; }
    ovmf_code="${ovmf_pair%%|*}"
    ovmf_vars_source="${ovmf_pair#*|}"
    ovmf_vars_work="$variant_dir/OVMF_VARS.fd"
    cp "$ovmf_vars_source" "$ovmf_vars_work"
    qemu_args+=(
      -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
      -drive "if=pflash,format=raw,file=$ovmf_vars_work"
    )
  elif [[ "$firmware" != bios ]]; then
    fail "internal error: unsupported firmware mode $firmware"
    return 1
  fi

  case "$media" in
    raw_gz)
      gzip -t "$image_path"
      disk_image="$variant_dir/disk.img"
      gzip -dc "$image_path" > "$disk_image"
      qemu_args+=( -drive "file=$disk_image,format=raw,if=ide" -boot order=c )
      ;;
    iso)
      file "$image_path" | grep -Eqi 'ISO 9660|CD-ROM filesystem' || {
        fail "$variant is not recognized as an ISO 9660 image"
        return 1
      }
      qemu_args+=( -snapshot -drive "file=$image_path,format=raw,media=cdrom,readonly=on,if=ide" -boot order=d )
      ;;
    vmdk)
      qemu-img info --output=json "$image_path" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); data=d.get("format-specific", {}).get("data", {}); raise SystemExit(0 if d.get("format") == "vmdk" and data.get("create-type") == "streamOptimized" else 1)' || {
          fail "$variant is not a streamOptimized VMDK"
          return 1
        }
      qemu-img check -f vmdk "$image_path" >"$variant_dir/qemu-img-check.txt" 2>&1 || {
        cat "$variant_dir/qemu-img-check.txt" >&2 || true
        fail "$variant failed qemu-img check"
        return 1
      }
      # streamOptimized is an import transport format, so QEMU must never write
      # the release base. The global -snapshot option provides a temporary layer.
      qemu_args+=( -snapshot -drive "file=$image_path,format=vmdk,if=ide" -boot order=c )
      ;;
    *)
      fail "internal error: unsupported media mode $media"
      return 1
      ;;
  esac

  printf 'Starting %s with QEMU %s validation (ESXi not tested).\n' "$variant" "$firmware"
  qemu-system-x86_64 "${qemu_args[@]}" >"$variant_dir/qemu-stderr.log" 2>&1 &
  CURRENT_QEMU_PID=$!

  deadline=$((SECONDS + BOOT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$CURRENT_QEMU_PID" 2>/dev/null; then
      wait "$CURRENT_QEMU_PID" || true
      dump_variant_diagnostics "$variant"
      fail "QEMU exited before $variant runtime validation completed"
      return 1
    fi
    if [[ "$serial_labels_result" != PASS ]] && serial_has_release_labels "$CURRENT_SERIAL_LOG"; then
      serial_labels_result=PASS
    fi
    if [[ "$runtime_result" != PASS ]] && serial_has_runtime_evidence "$CURRENT_SERIAL_LOG"; then
      runtime_result=PASS
    fi
    if [[ "$production_runtime_result" != PASS ]] && serial_has_production_runtime "$CURRENT_SERIAL_LOG"; then
      production_runtime_result=PASS
    fi
    if [[ "$https_result_local" != PASS ]] && probe_luci_https >/dev/null 2>&1; then
      https_result_local=PASS
    fi
    if [[ "$http_redirect_result_local" != PASS ]] && probe_http_redirect >/dev/null 2>&1; then
      http_redirect_result_local=PASS
    fi
    if [[ "$runtime_result" == PASS && "$production_runtime_result" == PASS && "$https_result_local" == PASS && "$http_redirect_result_local" == PASS && "$ssh_port_result" != PASS ]] && probe_no_ssh_service; then
      ssh_port_result=PASS
    fi
    [[ "$serial_labels_result" == PASS && "$runtime_result" == PASS && "$production_runtime_result" == PASS && "$https_result_local" == PASS && "$http_redirect_result_local" == PASS && "$ssh_port_result" == PASS ]] && break
    sleep 3
  done

  if [[ "$serial_labels_result" != PASS || "$runtime_result" != PASS || "$production_runtime_result" != PASS || "$https_result_local" != PASS || "$http_redirect_result_local" != PASS || "$ssh_port_result" != PASS ]]; then
    dump_variant_diagnostics "$variant"
    fail "$variant failed complete runtime validation within ${BOOT_TIMEOUT}s"
    return 1
  fi
  if ! kill -0 "$CURRENT_QEMU_PID" 2>/dev/null; then
    wait "$CURRENT_QEMU_PID" || true
    fail "QEMU exited after $variant checks but before result capture"
    return 1
  fi

  if [[ "$variant" == raw_bios ]]; then
    serial_labels="$serial_labels_result"
    https_result="$https_result_local"
    http_redirect_result="$http_redirect_result_local"
    runtime_evidence="$runtime_result"
    production_runtime="$production_runtime_result"
    ssh_port_probe="$ssh_port_result"
    ssh_result="DISABLED_BY_DEFAULT"
    authorized_keys_result="ABSENT"
    dropbear_enabled_result="NO"
    dropbear_running_result="NO"
    raw_http_status="$current_http_status"
    raw_https_status="$current_https_status"
    raw_auth_challenge="$current_auth_challenge"
    raw_http_port="$CURRENT_HTTP_PORT"
    raw_https_port="$CURRENT_HTTPS_PORT"
    raw_ssh_port="$CURRENT_SSH_PORT"
    raw_serial_log="$CURRENT_SERIAL_LOG"
    raw_ssh_probe_log="$CURRENT_SSH_PROBE"
  fi

  set_variant_result "$variant" runtime-pass
  stop_current_qemu
}

installation_id_from_serial() {
  python3 - "$1" <<'PY_ID'
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_bytes().decode("utf-8", errors="replace").replace("\r", "")
values = re.findall(r"(?m)^installation_id=([0-9a-f]{32})$", text)
print(values[-1] if values else "")
PY_ID
}

boot_persistent_disk_once() {
  local label="$1"
  local disk_path="$2"
  local disk_format="$3"
  local serial_path="$4"
  local deadline
  local qemu_pid
  local qemu_args=(
    -m 512
    -smp 2
    -display none
    -monitor none
    -no-reboot
    -machine "q35,accel=tcg"
    -serial "file:$serial_path"
    -netdev "user,id=lan0,net=192.168.8.0/24,dhcpstart=192.168.8.100"
    -device "e1000,netdev=lan0"
    -netdev "user,id=wan0,net=10.0.3.0/24,dhcpstart=10.0.3.15"
    -device "e1000,netdev=wan0"
    -drive "file=$disk_path,format=$disk_format,if=ide"
    -boot order=c
  )
  rm -f "$serial_path"
  qemu-system-x86_64 "${qemu_args[@]}" >"${serial_path%.log}-qemu-stderr.log" 2>&1 &
  qemu_pid=$!
  deadline=$((SECONDS + BOOT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
      wait "$qemu_pid" || true
      fail "$label exited before persistence evidence"
      return 1
    fi
    if serial_has_production_runtime "$serial_path"; then
      break
    fi
    sleep 3
  done
  if ! serial_has_production_runtime "$serial_path"; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    fail "$label did not emit production runtime evidence"
    return 1
  fi
  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" 2>/dev/null || true
}

verify_persistence_cycle() {
  local label="$1"
  local disk_path="$2"
  local disk_format="$3"
  local work_dir="$4"
  local first_log="$work_dir/persistence-first.log"
  local second_log="$work_dir/persistence-second.log"
  local first_id second_id
  mkdir -p "$work_dir"
  boot_persistent_disk_once "$label first boot" "$disk_path" "$disk_format" "$first_log"
  first_id="$(installation_id_from_serial "$first_log")"
  [[ "$first_id" =~ ^[0-9a-f]{32}$ ]] || { fail "$label first boot lacks installation ID"; return 1; }
  boot_persistent_disk_once "$label second boot" "$disk_path" "$disk_format" "$second_log"
  second_id="$(installation_id_from_serial "$second_log")"
  [[ "$second_id" == "$first_id" ]] || { fail "$label installation ID did not persist across reboot"; return 1; }
  printf '%s\n' "$first_id" >"$work_dir/installation-id.txt"
}

write_report() {
  local status="$1"
  {
    printf 'status=%s\n' "$status"
    printf 'target=%s\n' "$TARGET"
    printf 'release_contract=vm-x86_64/v2\n'
    printf 'vm_only=true\n'
    printf 'not_ax9000_firmware=true\n'
    printf 'hardware_validation=false\n'
    printf 'nss_validation=false\n'
    printf 'exact_release_image=true\n'
    printf 'serial_labels=%s\n' "$serial_labels"
    printf 'https=%s\n' "$https_result"
    printf 'http_redirect=%s\n' "$http_redirect_result"
    printf 'runtime_evidence=%s\n' "$runtime_evidence"
    printf 'production_runtime=%s\n' "$production_runtime"
    printf 'raw_bios_persistence=%s\n' "$raw_bios_persistence"
    printf 'vmdk_import_persistence=%s\n' "$vmdk_import_persistence"
    printf 'ssh_port_probe=%s\n' "$ssh_port_probe"
    printf 'ssh=%s\n' "$ssh_result"
    printf 'authorized_keys=%s\n' "$authorized_keys_result"
    printf 'dropbear_enabled=%s\n' "$dropbear_enabled_result"
    printf 'dropbear_running=%s\n' "$dropbear_running_result"
    printf 'http_redirect_status=%s\n' "$raw_http_status"
    printf 'https_status=%s\n' "$raw_https_status"
    printf 'auth_challenge=%s\n' "$raw_auth_challenge"
    printf 'http_host_port=%s\n' "$raw_http_port"
    printf 'https_host_port=%s\n' "$raw_https_port"
    printf 'ssh_host_port=%s\n' "$raw_ssh_port"
    printf 'serial_log=%s\n' "$raw_serial_log"
    printf 'ssh_probe_log=%s\n' "$raw_ssh_probe_log"
    printf 'raw_bios_file=%s\n' "$RAW_BIOS_BASENAME"
    printf 'raw_bios_qemu=%s\n' "$raw_bios_qemu"
    printf 'iso_bios_file=%s\n' "$ISO_BIOS_BASENAME"
    printf 'iso_bios_qemu=%s\n' "$iso_bios_qemu"
    printf 'iso_efi_file=%s\n' "$ISO_EFI_BASENAME"
    printf 'iso_efi_qemu=%s\n' "$iso_efi_qemu"
    printf 'vmdk_bios_file=%s\n' "$VMDK_BIOS_BASENAME"
    printf 'vmdk_bios_qemu=%s\n' "$vmdk_bios_qemu"
    printf 'vmdk_efi_file=%s\n' "$VMDK_EFI_BASENAME"
    printf 'vmdk_efi_qemu=%s\n' "$vmdk_efi_qemu"
    printf 'esxi_validation=not-tested\n'
  } > "$REPORT"
}

cleanup() {
  local rc=$?
  stop_current_qemu
  if [[ -n "${REPORT:-}" && ! -f "$REPORT" ]]; then
    write_report "$SMOKE_STATUS"
  fi
  trap - EXIT
  exit "$rc"
}
trap cleanup EXIT

[[ $# -eq 2 ]] || { usage; exit 2; }
TARGET="$1"
[[ "$TARGET" == x86-64 ]] || { usage; fail "release validation supports x86-64 only"; exit 2; }
ARTIFACT_DIR="$(cd "$2" 2>/dev/null && pwd)" || { fail "release artifact directory does not exist: $2"; exit 1; }
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || { fail "artifact path must be a non-symlink directory: $ARTIFACT_DIR"; exit 1; }
OUTPUT_DIR="${VM_RELEASE_OUTPUT_DIR:-$(pwd)/vm-release-results/$TARGET}"
BOOT_TIMEOUT="${VM_RELEASE_BOOT_TIMEOUT:-300}"
[[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { fail "VM_RELEASE_BOOT_TIMEOUT must be a positive integer"; exit 1; }
for command_name in qemu-system-x86_64 qemu-img curl gzip python3 tail grep file sha256sum cp readlink; do
  command -v "$command_name" >/dev/null 2>&1 || { fail "required command is missing: $command_name"; exit 1; }
done

shopt -s nullglob
raw_candidates=("$ARTIFACT_DIR"/NexaWrt-x86_64-v*-generic-ext4-combined.img.gz)
shopt -u nullglob
[[ "${#raw_candidates[@]}" -eq 1 ]] || { fail "artifact directory must contain exactly one raw BIOS release image"; exit 1; }
RAW_BIOS_PATH="${raw_candidates[0]}"
RAW_BIOS_BASENAME="${RAW_BIOS_PATH##*/}"
if [[ ! "$RAW_BIOS_BASENAME" =~ ^NexaWrt-x86_64-(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*))-generic-ext4-combined\.img\.gz$ ]]; then
  fail "unexpected raw BIOS release filename: $RAW_BIOS_BASENAME"
  exit 1
fi
RELEASE_VERSION="${BASH_REMATCH[1]}"
ISO_BIOS_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-image.iso"
ISO_EFI_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-image-efi.iso"
VMDK_BIOS_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined.vmdk"
VMDK_EFI_BASENAME="NexaWrt-x86_64-${RELEASE_VERSION}-generic-ext4-combined-efi.vmdk"
ISO_BIOS_PATH="$ARTIFACT_DIR/$ISO_BIOS_BASENAME"
ISO_EFI_PATH="$ARTIFACT_DIR/$ISO_EFI_BASENAME"
VMDK_BIOS_PATH="$ARTIFACT_DIR/$VMDK_BIOS_BASENAME"
VMDK_EFI_PATH="$ARTIFACT_DIR/$VMDK_EFI_BASENAME"

IMAGE_PATHS=("$RAW_BIOS_PATH" "$ISO_BIOS_PATH" "$ISO_EFI_PATH" "$VMDK_BIOS_PATH" "$VMDK_EFI_PATH")
for image_path in "${IMAGE_PATHS[@]}"; do
  [[ -f "$image_path" && ! -L "$image_path" ]] || { fail "required release image is missing or unsafe: $image_path"; exit 1; }
  case "$(basename "$image_path" | tr '[:upper:]' '[:lower:]')" in
    *ax9000*) fail "VM release image filename must not identify itself as AX9000 firmware"; exit 1 ;;
  esac
  sidecar="${image_path}.sha256"
  [[ -f "$sidecar" && ! -L "$sidecar" ]] || { fail "image checksum sidecar is missing or unsafe: $sidecar"; exit 1; }
  (cd "$ARTIFACT_DIR" && sha256sum --check --status "$(basename "$sidecar")") || {
    fail "image checksum verification failed: $(basename "$image_path")"
    exit 1
  }
done

mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/smoke-report.txt"
# Never let a stale PASS report survive a failed retry.
if [[ -e "$REPORT" || -L "$REPORT" ]]; then
  rm -f -- "$REPORT"
fi
CURRENT_QEMU_PID=""
SMOKE_STATUS="FAIL"
serial_labels="FAIL"
https_result="FAIL"
http_redirect_result="FAIL"
runtime_evidence="FAIL"
production_runtime="FAIL"
ssh_port_probe="FAIL"
ssh_result="UNVERIFIED"
authorized_keys_result="UNVERIFIED"
dropbear_enabled_result="UNVERIFIED"
dropbear_running_result="UNVERIFIED"
raw_http_status="unknown"
raw_https_status="unknown"
raw_auth_challenge="false"
raw_http_port="unallocated"
raw_https_port="unallocated"
raw_ssh_port="unallocated"
raw_serial_log="$OUTPUT_DIR/raw_bios/serial.log"
raw_ssh_probe_log="$OUTPUT_DIR/raw_bios/ssh-port-probe.txt"
raw_bios_qemu="unverified"
iso_bios_qemu="unverified"
iso_efi_qemu="unverified"
vmdk_bios_qemu="unverified"
vmdk_efi_qemu="unverified"
raw_bios_persistence="FAIL"
vmdk_import_persistence="FAIL"

run_variant raw_bios "$RAW_BIOS_PATH" bios raw_gz
run_variant iso_bios "$ISO_BIOS_PATH" bios iso
run_variant iso_efi "$ISO_EFI_PATH" uefi iso
run_variant vmdk_bios "$VMDK_BIOS_PATH" bios vmdk
run_variant vmdk_efi "$VMDK_EFI_PATH" uefi vmdk

# The raw image is tested as a writable disk copy. The VMware transport image is
# first imported into a writable qcow2 disk, matching ESXi's required import step.
verify_persistence_cycle raw-bios "$OUTPUT_DIR/raw_bios/disk.img" raw "$OUTPUT_DIR/raw_bios-persistence"
raw_bios_persistence="PASS"
IMPORTED_VMDK_DISK="$OUTPUT_DIR/vmdk-import-persistence/imported.qcow2"
mkdir -p "$(dirname "$IMPORTED_VMDK_DISK")"
qemu-img convert -f vmdk -O qcow2 "$VMDK_BIOS_PATH" "$IMPORTED_VMDK_DISK"
qemu-img check -f qcow2 "$IMPORTED_VMDK_DISK" >"$OUTPUT_DIR/vmdk-import-persistence/qemu-img-check.txt"
verify_persistence_cycle vmdk-import "$IMPORTED_VMDK_DISK" qcow2 "$OUTPUT_DIR/vmdk-import-persistence"
vmdk_import_persistence="PASS"

for image_path in "${IMAGE_PATHS[@]}"; do
  (cd "$ARTIFACT_DIR" && sha256sum --check --status "$(basename "$image_path").sha256") || {
    fail "release image changed during QEMU validation: $(basename "$image_path")"
    exit 1
  }
done

SMOKE_STATUS="PASS"
write_report PASS
printf 'VM release v2 PASS: five exact files passed QEMU SeaBIOS/OVMF runtime checks; ESXi remains not tested.\n'
