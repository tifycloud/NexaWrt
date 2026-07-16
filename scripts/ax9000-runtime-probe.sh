#!/bin/sh
set -eu

IMAGE_SHA="${1:-}"
FLAVOR="${2:-}"
OUTPUT_DIR="${3:-/tmp/nexawrt-runtime-evidence}"
PROBE_SHA="${4:-}"
SESSION_ID="${5:-}"
TEST_MODE="${NEXAWRT_PROBE_TEST_MODE:-0}"

fail() {
  echo "AX9000 runtime gate failed: $*" >&2
  exit 1
}

case "$IMAGE_SHA" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) ;;
  *) fail "firmware SHA-256 is missing or malformed" ;;
esac
[ "${#IMAGE_SHA}" -eq 64 ] || fail "firmware SHA-256 must contain exactly 64 hexadecimal characters"
case "$IMAGE_SHA" in *[!0-9a-fA-F]*) fail "firmware SHA-256 is malformed" ;; esac
case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac
[ "${#PROBE_SHA}" -eq 64 ] || fail "runtime probe SHA-256 must contain exactly 64 hexadecimal characters"
case "$PROBE_SHA" in *[!0-9a-fA-F]*) fail "runtime probe SHA-256 is malformed" ;; esac
[ "${#SESSION_ID}" -eq 64 ] || fail "hardware session ID must contain exactly 64 lowercase hexadecimal characters"
case "$SESSION_ID" in *[!0-9a-f]*) fail "hardware session ID is malformed" ;; esac

if [ "$TEST_MODE" = 1 ]; then
  PROC_ROOT="${NEXAWRT_PROC_ROOT:?test proc root is required}"
  SYS_ROOT="${NEXAWRT_SYS_ROOT:?test sys root is required}"
  DEV_ROOT="${NEXAWRT_DEV_ROOT:?test dev root is required}"
  ROOT_FS="${NEXAWRT_ROOT_FS:?test root filesystem is required}"
else
  PROC_ROOT=/proc
  SYS_ROOT=/sys
  DEV_ROOT=/dev
  ROOT_FS=
  [ "$OUTPUT_DIR" = /tmp/nexawrt-runtime-evidence ] ||
    fail "production evidence output must be /tmp/nexawrt-runtime-evidence"
fi

[ ! -L "$OUTPUT_DIR" ] || fail "evidence output must not be a symlink"
rm -rf -- "$OUTPUT_DIR"
mkdir -m 0700 -- "$OUTPUT_DIR"

COMPATIBLE_FILE="$PROC_ROOT/device-tree/compatible"
CMDLINE_FILE="$PROC_ROOT/cmdline"
MOUNTS_FILE="$PROC_ROOT/mounts"
MTD_FILE="$PROC_ROOT/mtd"
[ -r "$COMPATIBLE_FILE" ] || fail "device-tree compatible is unavailable"
[ -r "$CMDLINE_FILE" ] || fail "kernel command line is unavailable"
[ -r "$MOUNTS_FILE" ] || fail "mount table is unavailable"
[ -r "$MTD_FILE" ] || fail "MTD table is unavailable"

compatible="$(tr '\000' '\n' < "$COMPATIBLE_FILE")"
printf '%s\n' "$compatible" | grep -Fxq 'xiaomi,ax9000' || fail "device is not Xiaomi AX9000"
cmdline="$(cat "$CMDLINE_FILE")"
root_count="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -cx 'root=/dev/ram0' || true)"
root_total="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -c '^root=' || true)"
[ "$root_count" -eq 1 ] && [ "$root_total" -eq 1 ] ||
  fail "kernel command line must contain exactly one root= token and it must be root=/dev/ram0"
session_count="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -cx "nexawrt.session=$SESSION_ID" || true)"
session_total="$(printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -c '^nexawrt\.session=' || true)"
[ "$session_count" -eq 1 ] && [ "$session_total" -eq 1 ] ||
  fail "kernel command line must contain exactly one matching nexawrt.session token"
if printf '%s\n' "$cmdline" | tr ' ' '\n' | grep -Eq '^(ubi\.|root=/dev/ubiblock)'; then
  fail "kernel command line references persistent UBI"
fi

if grep -Eiq '(^|[[:space:]])(/dev/ubi|ubi[0-9]+:|ubiblock|ubifs|jffs2|overlay)([[:space:]]|$)' "$MOUNTS_FILE"; then
  fail "persistent UBI/UBIFS/JFFS2/overlay mount is active"
fi
for ubi_path in "$SYS_ROOT"/class/ubi/ubi[0-9]*; do
  [ ! -e "$ubi_path" ] && [ ! -L "$ubi_path" ] || fail "persistent UBI device is attached: $ubi_path"
done

mtd_count=0
for mtd_path in "$SYS_ROOT"/class/mtd/mtd[0-9]*; do
  [ -d "$mtd_path" ] || continue
  mtd_count=$((mtd_count + 1))
  flags_file="$mtd_path/flags"
  [ -r "$flags_file" ] || fail "MTD flags are unavailable: $flags_file"
  flags="$(cat "$flags_file")"
  printf '%s\n' "$flags" | grep -Eq '^(0x[0-9a-fA-F]+|[0-9]+)$' ||
    fail "invalid MTD flags for $mtd_path: $flags"
  flags_value=$((flags))
  [ $((flags_value & 0x400)) -eq 0 ] || fail "writable MTD partition detected: $mtd_path"

  device="$DEV_ROOT/$(basename "$mtd_path")"
  [ -e "$device" ] || fail "MTD character device is missing: $device"
  if [ "$TEST_MODE" = 1 ]; then
    probe_command="${NEXAWRT_MTD_OPEN_PROBE_COMMAND:?test MTD probe command is required}"
    if "$probe_command" "$device" >/dev/null 2>&1; then
      fail "raw MTD write-open unexpectedly succeeded: $device"
    fi
  elif (exec 9>"$device") 2>/dev/null; then
    fail "raw MTD write-open unexpectedly succeeded: $device"
  fi
done
[ "$mtd_count" -gt 0 ] || fail "no MTD partitions were discovered"
command -v fw_printenv >/dev/null 2>&1 || fail "fw_printenv is required for stable device identity"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required for stable device identity"
for write_tool in fw_setenv fw_setsys fw_loadenv; do
  ! command -v "$write_tool" >/dev/null 2>&1 || fail "U-Boot environment write tool is present: $write_tool"
done
ethaddr="$(fw_printenv -n ethaddr 2>/dev/null | tr 'A-F' 'a-f')" || fail "cannot read U-Boot ethaddr"
printf '%s\n' "$ethaddr" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || fail "U-Boot ethaddr is missing or malformed"
device_fingerprint="$(printf 'xiaomi,ax9000\nethaddr=%s\n' "$ethaddr" | sha256sum | awk '{print $1}')"
printf '%s\n' "$device_fingerprint" | grep -Eq '^[0-9a-f]{64}$' || fail "device fingerprint calculation failed"

run_guard() {
  guard_name="$1"
  set +e
  "$guard_name" >"$OUTPUT_DIR/$guard_name.out" 2>&1
  guard_status=$?
  set -e
  [ "$guard_status" -eq 74 ] || fail "$guard_name returned $guard_status instead of 74"
  printf '%s_guard_exit=74\n' "$guard_name"
}

{
  echo 'root=/dev/ram0'
  echo 'persistent_ubi_attached=no'
  echo 'persistent_mounts=no'
  echo 'all_mtd_partitions_readonly=yes'
  echo 'raw_mtd_write_probe=blocked'
  run_guard sysupgrade
  run_guard factoryreset
  run_guard firstboot
  run_guard jffs2reset
  run_guard jffs2mark
  run_guard mount_root
  printf 'flavor=%s\n' "$FLAVOR"
  printf 'probe_sha256=%s\n' "$(printf '%s' "$PROBE_SHA" | tr 'A-F' 'a-f')"
  printf 'session_id=%s\n' "$SESSION_ID"
  printf 'device_fingerprint_sha256=%s\n' "$device_fingerprint"
  echo 'fw_printenv_available=yes'
  echo 'uboot_env_write_tools=absent'
  if [ "$FLAVOR" = nss ]; then
    grep -Eq '^qca_nss_drv[[:space:]]' "$PROC_ROOT/modules" || fail "qca_nss_drv is not loaded"
    grep -Eq '^ecm[[:space:]]' "$PROC_ROOT/modules" || fail "ECM is not loaded"
    [ -s "$ROOT_FS/lib/firmware/qca-nss0-retail.bin" ] || fail "NSS core 0 firmware is missing"
    [ -s "$ROOT_FS/lib/firmware/qca-nss1-retail.bin" ] || fail "NSS core 1 firmware is missing"
    echo 'nss_driver_loaded=yes'
    echo 'nss_ecm_loaded=yes'
    echo 'nss_firmware_present=yes'
  else
    ! grep -Eq '^(qca_nss_drv|ecm)[[:space:]]' "$PROC_ROOT/modules" || fail "official flavor loaded third-party NSS/ECM modules"
    [ ! -e "$ROOT_FS/lib/firmware/qca-nss0-retail.bin" ] || fail "official flavor contains NSS core firmware"
    [ ! -e "$ROOT_FS/lib/firmware/qca-nss1-retail.bin" ] || fail "official flavor contains NSS core firmware"
    echo 'third_party_nss_components=absent'
  fi
} > "$OUTPUT_DIR/runtime-gate.txt"

if [ "$FLAVOR" = nss ]; then
  [ "$(uci -q get network.globals.packet_steering)" = 0 ] || fail "NSS packet steering baseline is not disabled"
  [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 0 ] || fail "software flow offload is not disabled"
  [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 0 ] || fail "hardware flow offload is not disabled"
fi

{
  printf 'model=xiaomi,ax9000\n'
  printf 'image_sha256=%s\n' "$(printf '%s' "$IMAGE_SHA" | tr 'A-F' 'a-f')"
  printf 'flavor=%s\n' "$FLAVOR"
  printf 'probe_sha256=%s\n' "$(printf '%s' "$PROBE_SHA" | tr 'A-F' 'a-f')"
  printf 'session_id=%s\n' "$SESSION_ID"
  printf 'device_fingerprint_sha256=%s\n' "$device_fingerprint"
} > "$OUTPUT_DIR/device.txt"

{
  echo '=== timestamp UTC ==='
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date
  echo '=== uname ==='
  uname -a
  echo '=== compatible ==='
  printf '%s\n' "$compatible"
  echo '=== cmdline ==='
  printf '%s\n' "$cmdline"
  echo '=== hardware session and identity ==='
  printf 'session_id=%s\nethaddr=%s\ndevice_fingerprint_sha256=%s\n' "$SESSION_ID" "$ethaddr" "$device_fingerprint"
  echo '=== proc mtd ==='
  cat "$MTD_FILE"
  echo '=== mtd flags ==='
  for mtd_path in "$SYS_ROOT"/class/mtd/mtd[0-9]*; do
    [ -d "$mtd_path" ] || continue
    printf '%s flags=%s\n' "$(basename "$mtd_path")" "$(cat "$mtd_path/flags")"
  done
  echo '=== mounts ==='
  cat "$MOUNTS_FILE"
  echo '=== ubi sysfs ==='
  ls -la "$SYS_ROOT/class/ubi" 2>&1 || true
  echo '=== network ==='
  ip link 2>&1 || true
  ip addr 2>&1 || true
  echo '=== nss baseline ==='
  if [ "$FLAVOR" = nss ]; then
    printf 'network.globals.packet_steering=%s\n' "$(uci -q get network.globals.packet_steering)"
    printf 'firewall.defaults.flow_offloading=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading)"
    printf 'firewall.defaults.flow_offloading_hw=%s\n' "$(uci -q get firewall.@defaults[0].flow_offloading_hw)"
  else
    echo 'not-applicable'
  fi
  echo '=== modules ==='
  lsmod 2>&1 || true
  echo '=== thermal ==='
  for thermal in "$SYS_ROOT"/class/thermal/thermal_zone*/temp; do
    [ -r "$thermal" ] || continue
    printf '%s=%s\n' "$thermal" "$(cat "$thermal")"
  done
  echo '=== dmesg ==='
  dmesg 2>&1 || true
} > "$OUTPUT_DIR/ram-boot.log"

for guard_output in "$OUTPUT_DIR"/*.out; do
  [ -f "$guard_output" ] || continue
  {
    printf '\n=== %s ===\n' "$(basename "$guard_output")"
    cat "$guard_output"
  } >> "$OUTPUT_DIR/ram-boot.log"
  rm -f -- "$guard_output"
done

for required in device.txt runtime-gate.txt ram-boot.log; do
  [ -s "$OUTPUT_DIR/$required" ] || fail "runtime evidence file is missing: $required"
done

echo "AX9000 runtime gate passed; evidence written to $OUTPUT_DIR"
