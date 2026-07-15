#!/usr/bin/env bash
# Read-only Xiaomi AX9000 backup collector.
# The remote side is only queried/read; no remote files or flash writes are made.

set -euo pipefail

HOST="192.168.2.1"
USER_NAME="root"
PORT="22"
OUTPUT_DIR=""

usage() {
  cat <<'USAGE'
Usage: backup-router.sh [options]

Read-only backup of a Xiaomi AX9000 over SSH.

Options:
  -H, --host HOST       Router address (default: 192.168.2.1)
  -u, --user USER       SSH user (default: root)
  -p, --port PORT       SSH port (default: 22)
  -d, --output DIR      Local output directory
  -h, --help            Show this help

Authentication uses the normal ssh client (SSH key or interactive prompt).
There is deliberately no password option. Do not use sshpass and do not put a
password in command arguments, environment variables, or files.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    -H|--host)
      (($# >= 2)) || fail "$1 requires a value"
      HOST=$2
      shift 2
      ;;
    -u|--user)
      (($# >= 2)) || fail "$1 requires a value"
      USER_NAME=$2
      shift 2
      ;;
    -p|--port)
      (($# >= 2)) || fail "$1 requires a value"
      PORT=$2
      shift 2
      ;;
    -d|--output)
      (($# >= 2)) || fail "$1 requires a value"
      OUTPUT_DIR=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || fail "unexpected arguments after --"
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ $PORT =~ ^[0-9]+$ ]] || fail "SSH port must be numeric"
((PORT >= 1 && PORT <= 65535)) || fail "SSH port is out of range"
[[ -n $HOST ]] || fail "host must not be empty"
[[ -n $USER_NAME ]] || fail "user must not be empty"

for tool in ssh awk grep date wc tr mkdir chmod mv rm mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail "required local command not found: $tool"
done

if [[ -z $OUTPUT_DIR ]]; then
  OUTPUT_DIR="ax9000-backup-$(date '+%Y%m%d-%H%M%S')"
fi
[[ ! -e $OUTPUT_DIR ]] || fail "output path already exists: $OUTPUT_DIR"

PARENT_DIR=$(dirname "$OUTPUT_DIR")
BASE_NAME=$(basename "$OUTPUT_DIR")
mkdir -p "$PARENT_DIR"
TMP_DIR=$(mktemp -d "$PARENT_DIR/.${BASE_NAME}.tmp.XXXXXX")
chmod 700 "$TMP_DIR"
FINALIZED=0

cleanup() {
  if ((FINALIZED == 0)); then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM HUP

CONTROL_PATH="$TMP_DIR/ssh-control-%C"
SSH_BASE=(
  ssh
  -p "$PORT"
  -o "ControlMaster=auto"
  -o "ControlPersist=60"
  -o "ControlPath=$CONTROL_PATH"
  -o "ServerAliveInterval=15"
  -o "ServerAliveCountMax=3"
)
SSH=("${SSH_BASE[@]}" -- "$USER_NAME@$HOST")

remote_capture() {
  local output=$1
  local command=$2
  if ! "${SSH[@]}" "$command" >"$TMP_DIR/$output" 2>&1; then
    printf 'WARNING: remote command failed; see %s\n' "$output" >&2
    return 1
  fi
}

printf 'Connecting to %s@%s:%s using the normal SSH client...\n' "$USER_NAME" "$HOST" "$PORT"
printf 'No password is accepted or stored by this script.\n'
printf 'Remote operations are read-only. No files are created on the router.\n\n'

# Establish and validate the first connection. The ssh client may prompt for an
# SSH key passphrase, host-key confirmation, or interactive authentication.
"${SSH[@]}" 'printf "connected\n"' >/dev/null || fail "unable to connect"

printf '[1/5] Collecting /proc/mtd...\n'
"${SSH[@]}" 'cat /proc/mtd' >"$TMP_DIR/proc-mtd.txt" \
  || fail "could not read /proc/mtd"

if ! grep -Eq '^mtd[0-9]+: [0-9a-fA-F]+ [0-9a-fA-F]+ ".+"$' "$TMP_DIR/proc-mtd.txt"; then
  fail "unexpected /proc/mtd format; refusing to guess device names"
fi

printf '[2/5] Collecting UBI, kernel log, and boot environment information...\n'
remote_capture "ubinfo-a.txt" \
  'if command -v ubinfo >/dev/null 2>&1; then ubinfo -a; else echo "ubinfo: command not found"; exit 127; fi' || true
remote_capture "dmesg.txt" 'dmesg' || true
remote_capture "fw_printenv.txt" \
  'if command -v fw_printenv >/dev/null 2>&1; then fw_printenv; else echo "fw_printenv: command not found"; exit 127; fi' || true
remote_capture "uname-a.txt" 'uname -a' || true
remote_capture "board-info.txt" \
  'printf "board_name=%s\n" "$(cat /tmp/sysinfo/board_name 2>/dev/null)"; printf "model=%s\n" "$(cat /tmp/sysinfo/model 2>/dev/null)"; cat /etc/openwrt_release 2>/dev/null || true' \
  || fail "could not read board identity"
remote_capture "proc-cmdline.txt" 'cat /proc/cmdline' || true
remote_capture "mtd-sysfs.txt" \
  'for path in /sys/class/mtd/mtd[0-9]*; do dev=${path##*/}; printf "%s\t%s\t%s\t%s\t%s\n" "$dev" "$(cat "$path/name")" "$(cat "$path/offset")" "$(cat "$path/size")" "$(cat "$path/erasesize")"; done' \
  || fail "could not read MTD offset/size information from sysfs"
remote_capture "ubi-sysfs.txt" \
  'for path in /sys/class/ubi/ubi[0-9]*; do dev=${path##*/}; [ -r "$path/mtd_num" ] || continue; printf "device\t%s\t%s\n" "$dev" "$(cat "$path/mtd_num")"; for volume in /sys/class/ubi/${dev}_*; do [ -r "$volume/name" ] || continue; volume_id=${volume##*_}; printf "volume\t%s\t%s\t%s\n" "$dev" "$volume_id" "$(cat "$volume/name")"; done; done' \
  || fail "could not read UBI device/volume information from sysfs"

printf '[3/5] Verifying the expected single-large-UBI v1 layout...\n'
BOARD_NAME=$(awk -F= '$1 == "board_name" {print $2}' "$TMP_DIR/board-info.txt")
[[ $BOARD_NAME == "xiaomi,ax9000" ]] || fail "unexpected board identity: ${BOARD_NAME:-missing}"
ROOTFS_LINE=$(awk '$4 == "\"rootfs\"" || $4 == "\"0:rootfs\"" {print $1, $2}' "$TMP_DIR/proc-mtd.txt")
[[ -n $ROOTFS_LINE ]] || fail "rootfs MTD was not found"
read -r ROOTFS_MTD_COL ROOTFS_HEX <<<"$ROOTFS_LINE"
ROOTFS_MTD_NAME=${ROOTFS_MTD_COL%:}
ROOTFS_MTD_NUM=${ROOTFS_MTD_NAME#mtd}
ROOTFS_HEX_LOWER=$(printf '%s' "$ROOTFS_HEX" | tr '[:upper:]' '[:lower:]')
[[ $ROOTFS_HEX_LOWER == "0e800000" ]] \
  || fail "rootfs size is $ROOTFS_HEX, expected 0e800000; this is not the supported layout"

rootfs_geometry=$(awk '$2 == "rootfs" || $2 == "0:rootfs" {print $3, $4, $5}' "$TMP_DIR/mtd-sysfs.txt")
[[ -n $rootfs_geometry ]] || fail "rootfs sysfs geometry was not found"
read -r rootfs_offset rootfs_size rootfs_erasesize <<<"$rootfs_geometry"
[[ $rootfs_offset == "18350080" ]] \
  || fail "rootfs offset is $rootfs_offset, expected 18350080 (0x01180000)"
[[ $rootfs_size == "243269632" ]] \
  || fail "rootfs size is $rootfs_size, expected 243269632 (0x0e800000)"
[[ $rootfs_erasesize == "131072" ]] \
  || fail "rootfs erase size is $rootfs_erasesize, expected 131072"

cmdline_tokens=$(tr ' ' '\n' <"$TMP_DIR/proc-cmdline.txt")
[[ $(grep -Ec '^ubi\.mtd=' <<<"$cmdline_tokens") == 1 ]] ||
  fail "kernel command line must contain exactly one ubi.mtd= argument"
grep -Fxq 'ubi.mtd=rootfs' <<<"$cmdline_tokens" ||
  fail "kernel command line does not select ubi.mtd=rootfs"
[[ $(grep -Ec '^root=' <<<"$cmdline_tokens") == 1 ]] ||
  fail "kernel command line must contain exactly one root= argument"
grep -Fxq 'root=/dev/ubiblock0_1' <<<"$cmdline_tokens" ||
  fail "kernel command line does not select root=/dev/ubiblock0_1"

UBI_DEVICE=$(awk -v mtd="$ROOTFS_MTD_NUM" '$1 == "device" && $3 == mtd {print $2}' \
  "$TMP_DIR/ubi-sysfs.txt")
[[ $UBI_DEVICE == "ubi0" ]] \
  || fail "rootfs MTD must be attached as ubi0, found: ${UBI_DEVICE:-none}"
[[ $(awk -v dev="$UBI_DEVICE" '$1 == "volume" && $2 == dev {count++} END {print count+0}' \
  "$TMP_DIR/ubi-sysfs.txt") == 3 ]] \
  || fail "expected exactly three UBI volumes on $UBI_DEVICE"
for expected in '0 kernel' '1 rootfs' '2 rootfs_data'; do
  read -r volume_id volume_name <<<"$expected"
  awk -v dev="$UBI_DEVICE" -v id="$volume_id" -v name="$volume_name" \
    '$1 == "volume" && $2 == dev && $3 == id && $4 == name {found=1} END {exit !found}' \
    "$TMP_DIR/ubi-sysfs.txt" \
    || fail "UBI volume $volume_id on $UBI_DEVICE is not named $volume_name"
done

if command -v shasum >/dev/null 2>&1; then
  HASH_KIND="shasum"
elif command -v sha256sum >/dev/null 2>&1; then
  HASH_KIND="sha256sum"
else
  fail "need local shasum or sha256sum"
fi

PARTITIONS=(
  appsblenv
  appsbl
  appsbl_1
  art
  bdata
  bootconfig
  bootconfig1
  rootfs
)

printf '[4/5] Reading critical MTD partitions (this may take several minutes)...\n'
printf 'WARNING: the raw rootfs MTD can include sensitive rootfs_data content.\n'
: >"$TMP_DIR/mtd-sizes.txt"
for part in "${PARTITIONS[@]}"; do
  line=$(awk -v wanted="$part" \
    '$4 == "\"" wanted "\"" || $4 == "\"0:" wanted "\"" {print $1, $2}' \
    "$TMP_DIR/proc-mtd.txt")
  [[ -n $line ]] || fail "required MTD partition not found: $part"

  read -r mtd_col size_hex <<<"$line"
  mtd_name=${mtd_col%:}
  [[ $mtd_name =~ ^mtd[0-9]+$ ]] || fail "invalid MTD device parsed for $part: $mtd_name"
  [[ $size_hex =~ ^[0-9a-fA-F]+$ ]] || fail "invalid MTD size parsed for $part: $size_hex"

  expected_bytes=$((16#$size_hex))
  output="$TMP_DIR/${part}-${mtd_name}.bin"
  log="$TMP_DIR/${part}-${mtd_name}.read.log"

  printf '  - %-12s /dev/%s (%s bytes)\n' "$part" "$mtd_name" "$expected_bytes"
  if ! "${SSH[@]}" "dd if=/dev/$mtd_name bs=65536" >"$output" 2>"$log"; then
    rm -f "$output"
    fail "failed reading $part from /dev/$mtd_name; see $(basename "$log")"
  fi

  actual_bytes=$(wc -c <"$output" | tr -d '[:space:]')
  if [[ $actual_bytes != "$expected_bytes" ]]; then
    fail "$part size mismatch: read $actual_bytes bytes, expected $expected_bytes"
  fi
  printf '%s\t%s\t%s\t%s\n' "$part" "$mtd_name" "$size_hex" "$actual_bytes" \
    >>"$TMP_DIR/mtd-sizes.txt"
done

printf '[5/5] Generating local SHA256SUMS...\n'
generate_checksums() {
  (
    cd "$TMP_DIR"
    local files=() file base
    for file in ./*; do
      [[ -f $file ]] || continue
      base=${file#./}
      [[ $base == "SHA256SUMS" ]] || files+=("$base")
    done
    ((${#files[@]} > 0)) || fail "no files available for checksumming"

    if [[ $HASH_KIND == "shasum" ]]; then
      shasum -a 256 "${files[@]}" >SHA256SUMS
    else
      sha256sum "${files[@]}" >SHA256SUMS
    fi
  )
}

cat >"$TMP_DIR/README-SENSITIVE.txt" <<'NOTICE'
This directory contains raw router flash backups and must be treated as
sensitive. The collector does not explicitly export /etc/config, password
files, SSH private keys, or wireless credentials. However, the required raw
rootfs MTD image spans the UBI area and can include rootfs_data, so it may still
contain credentials, keys, MAC addresses, serial data, and personal settings.
Do not commit or upload this directory. Keep it encrypted or offline.
NOTICE

# Include every final regular file except the checksum file itself.
generate_checksums

# Ask the multiplexing master to exit; failure is harmless because the socket
# is local and ControlPersist is short.
"${SSH_BASE[@]}" -O exit -- "$USER_NAME@$HOST" >/dev/null 2>&1 || true

mv "$TMP_DIR" "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
FINALIZED=1
trap - EXIT INT TERM HUP

printf '\nBackup complete: %s\n' "$OUTPUT_DIR"
if [[ $HASH_KIND == "shasum" ]]; then
  printf 'Verify with: (cd %q && shasum -a 256 -c SHA256SUMS)\n' "$OUTPUT_DIR"
else
  printf 'Verify with: (cd %q && sha256sum -c SHA256SUMS)\n' "$OUTPUT_DIR"
fi
printf 'Copy it to another trusted medium and treat the entire directory as sensitive.\n'
printf 'No flash write, erase, format, or remote file creation was performed.\n'
