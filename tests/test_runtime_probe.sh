#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-runtime-probe.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SHA='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
SESSION='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
WRONG_SESSION='1111111111111111111111111111111111111111111111111111111111111111'
ETHADDR='00:11:22:33:44:55'
FINGERPRINT="$(printf 'xiaomi,ax9000\nethaddr=%s\n' "$ETHADDR" | sha256sum | awk '{print $1}')"

fail() { echo "test_runtime_probe: $*" >&2; exit 1; }
expect_failure() {
  local label="$1" expected="$2"; shift 2
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then fail "$label unexpectedly passed"; fi
  grep -Fq "$expected" "$TMP/stderr" || { cat "$TMP/stderr" >&2; fail "$label failed for an unexpected reason"; }
}

PROC="$TMP/proc"
SYS="$TMP/sys"
DEV="$TMP/dev"
ROOTFS="$TMP/rootfs"
MOCKBIN="$TMP/bin"
OUT="$TMP/output"
mkdir -p "$PROC/device-tree" "$SYS/class/ubi" "$SYS/class/mtd/mtd0" "$SYS/class/mtd/mtd1" \
  "$SYS/class/thermal" "$DEV" "$ROOTFS/lib/firmware" "$MOCKBIN"
printf 'xiaomi,ax9000\0qcom,ipq8074\0' > "$PROC/device-tree/compatible"
printf 'console=ttyMSM0 root=/dev/ram0 nexawrt.session=%s init=/sbin/init\n' "$SESSION" > "$PROC/cmdline"
printf 'tmpfs / tmpfs rw,relatime 0 0\nproc /proc proc rw,relatime 0 0\n' > "$PROC/mounts"
printf 'dev:    size   erasesize  name\nmtd0: 00100000 00020000 "sbl1"\nmtd1: 0e800000 00020000 "rootfs"\n' > "$PROC/mtd"
printf 'qca_nss_drv 100 0 - Live 0x0\necm 100 0 - Live 0x0\n' > "$PROC/modules"
printf '0x0\n' > "$SYS/class/mtd/mtd0/flags"
printf '0x0\n' > "$SYS/class/mtd/mtd1/flags"
: > "$DEV/mtd0"; : > "$DEV/mtd1"
printf firmware > "$ROOTFS/lib/firmware/qca-nss0-retail.bin"
printf firmware > "$ROOTFS/lib/firmware/qca-nss1-retail.bin"

cat > "$MOCKBIN/guard" <<'MOCK'
#!/bin/sh
echo "$0 is disabled"
exit 74
MOCK
chmod +x "$MOCKBIN/guard"
for command in sysupgrade factoryreset firstboot jffs2reset jffs2mark mount_root; do ln -s guard "$MOCKBIN/$command"; done
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
[ "$1" = -q ] && [ "$2" = get ] || exit 2
case "$3" in
  network.globals.packet_steering|firewall.@defaults\[0\].flow_offloading|firewall.@defaults\[0\].flow_offloading_hw) echo 0 ;;
  *) exit 1 ;;
esac
MOCK
cat > "$MOCKBIN/fw_printenv" <<MOCK
#!/bin/sh
[ "\$1" = -n ] && [ "\$2" = ethaddr ] || exit 2
printf '%s\\n' '$ETHADDR'
MOCK
cat > "$MOCKBIN/mtd-probe" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci" "$MOCKBIN/fw_printenv" "$MOCKBIN/mtd-probe"

# Arguments are forwarded dynamically by expect_failure.
# shellcheck disable=SC2120
run_probe() {
  local session_arg="${1:-$SESSION}"
  env PATH="$MOCKBIN:$PATH" NEXAWRT_PROBE_TEST_MODE=1 \
    NEXAWRT_PROC_ROOT="$PROC" NEXAWRT_SYS_ROOT="$SYS" NEXAWRT_DEV_ROOT="$DEV" \
    NEXAWRT_ROOT_FS="$ROOTFS" NEXAWRT_MTD_OPEN_PROBE_COMMAND="$MOCKBIN/mtd-probe" \
    "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" "$SHA" nss "$OUT" "$SHA" "$session_arg"
}

run_probe >/dev/null
for marker in \
  root=/dev/ram0 persistent_ubi_attached=no persistent_mounts=no \
  all_mtd_partitions_readonly=yes raw_mtd_write_probe=blocked flavor=nss probe_sha256=$SHA \
  session_id=$SESSION device_fingerprint_sha256=$FINGERPRINT \
  fw_printenv_available=yes uboot_env_write_tools=absent \
  nss_driver_loaded=yes nss_ecm_loaded=yes nss_firmware_present=yes \
  sysupgrade_guard_exit=74 factoryreset_guard_exit=74 firstboot_guard_exit=74 \
  jffs2reset_guard_exit=74 jffs2mark_guard_exit=74 mount_root_guard_exit=74; do
  grep -Fxq "$marker" "$OUT/runtime-gate.txt" || fail "runtime marker missing: $marker"
done
for marker in model=xiaomi,ax9000 image_sha256=$SHA probe_sha256=$SHA session_id=$SESSION device_fingerprint_sha256=$FINGERPRINT; do
  grep -Fxq "$marker" "$OUT/device.txt" || fail "device marker missing: $marker"
done
[[ -s "$OUT/ram-boot.log" ]] || fail 'RAM boot log is empty'

printf 'console=ttyMSM0 root=/dev/ram0 init=/sbin/init\n' > "$PROC/cmdline"
expect_failure 'missing runtime session token' 'exactly one matching nexawrt.session token' run_probe
printf 'console=ttyMSM0 root=/dev/ram0 nexawrt.session=%s init=/sbin/init\n' "$WRONG_SESSION" > "$PROC/cmdline"
expect_failure 'wrong runtime session token' 'exactly one matching nexawrt.session token' run_probe
printf 'console=ttyMSM0 root=/dev/ram0 nexawrt.session=%s nexawrt.session=%s init=/sbin/init\n' "$SESSION" "$SESSION" > "$PROC/cmdline"
expect_failure 'duplicate runtime session token' 'exactly one matching nexawrt.session token' run_probe
printf 'console=ttyMSM0 root=/dev/ram0 nexawrt.session=%s init=/sbin/init\n' "$SESSION" > "$PROC/cmdline"
expect_failure 'wrong session argument' 'exactly one matching nexawrt.session token' run_probe "$WRONG_SESSION"
expect_failure 'missing session argument' 'hardware session ID must contain exactly 64' \
  env PATH="$MOCKBIN:$PATH" NEXAWRT_PROBE_TEST_MODE=1 \
    NEXAWRT_PROC_ROOT="$PROC" NEXAWRT_SYS_ROOT="$SYS" NEXAWRT_DEV_ROOT="$DEV" \
    NEXAWRT_ROOT_FS="$ROOTFS" NEXAWRT_MTD_OPEN_PROBE_COMMAND="$MOCKBIN/mtd-probe" \
    "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" "$SHA" nss "$OUT" "$SHA"

for write_tool in fw_setenv fw_setsys fw_loadenv; do
  cat > "$MOCKBIN/$write_tool" <<'MOCK'
#!/bin/sh
exit 0
MOCK
  chmod +x "$MOCKBIN/$write_tool"
  expect_failure "U-Boot environment write tool present: $write_tool" \
    "U-Boot environment write tool is present: $write_tool" run_probe
  rm "$MOCKBIN/$write_tool"
done

printf '0x400\n' > "$SYS/class/mtd/mtd1/flags"
expect_failure 'writable MTD' 'writable MTD partition detected' run_probe
printf '0x0garbage\n' > "$SYS/class/mtd/mtd1/flags"
expect_failure 'malformed MTD flags' 'invalid MTD flags' run_probe
printf '0x0\n' > "$SYS/class/mtd/mtd1/flags"
printf 'console=ttyMSM0 root=/dev/ram0 root=/dev/mmcblk0 nexawrt.session=%s init=/sbin/init\n' "$SESSION" > "$PROC/cmdline"
expect_failure 'additional root token' 'exactly one root= token' run_probe
printf 'console=ttyMSM0 root=/dev/ram0 nexawrt.session=%s init=/sbin/init\n' "$SESSION" > "$PROC/cmdline"
printf 'overlayfs:/overlay / overlay rw,relatime 0 0\n' > "$PROC/mounts"
expect_failure 'persistent overlay mount' 'persistent UBI/UBIFS/JFFS2/overlay mount is active' run_probe
printf 'tmpfs / tmpfs rw,relatime 0 0\nproc /proc proc rw,relatime 0 0\n' > "$PROC/mounts"
mkdir "$SYS/class/ubi/ubi0"
expect_failure 'attached UBI' 'persistent UBI device is attached' run_probe
rmdir "$SYS/class/ubi/ubi0"
rm "$MOCKBIN/mount_root"; cat > "$MOCKBIN/mount_root" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$MOCKBIN/mount_root"
expect_failure 'guard bypass' 'mount_root returned 0 instead of 74' run_probe
rm "$MOCKBIN/mount_root"; ln -s guard "$MOCKBIN/mount_root"

# The official flavor must fail if third-party NSS/ECM state leaks into runtime.
expect_failure 'official NSS contamination' 'official flavor loaded third-party NSS/ECM modules' \
  env PATH="$MOCKBIN:$PATH" NEXAWRT_PROBE_TEST_MODE=1 \
    NEXAWRT_PROC_ROOT="$PROC" NEXAWRT_SYS_ROOT="$SYS" NEXAWRT_DEV_ROOT="$DEV" \
    NEXAWRT_ROOT_FS="$ROOTFS" NEXAWRT_MTD_OPEN_PROBE_COMMAND="$MOCKBIN/mtd-probe" \
    "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" "$SHA" official "$OUT" "$SHA" "$SESSION"
: > "$PROC/modules"
rm "$ROOTFS/lib/firmware/qca-nss0-retail.bin" "$ROOTFS/lib/firmware/qca-nss1-retail.bin"
env PATH="$MOCKBIN:$PATH" NEXAWRT_PROBE_TEST_MODE=1 \
  NEXAWRT_PROC_ROOT="$PROC" NEXAWRT_SYS_ROOT="$SYS" NEXAWRT_DEV_ROOT="$DEV" \
  NEXAWRT_ROOT_FS="$ROOTFS" NEXAWRT_MTD_OPEN_PROBE_COMMAND="$MOCKBIN/mtd-probe" \
  "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" "$SHA" official "$OUT" "$SHA" "$SESSION" >/dev/null
grep -Fxq 'third_party_nss_components=absent' "$OUT/runtime-gate.txt" || fail 'official isolation marker missing'

expect_failure 'unsafe SSH target' 'unsafe SSH target' \
  "$ROOT_DIR/scripts/collect-runtime-evidence.sh" '-oProxyCommand=evil' "$TMP/dist" nss "$ROOT_DIR/hardware-evidence/test"

echo 'AX9000 runtime session/device binding and fail-closed negatives: OK'
