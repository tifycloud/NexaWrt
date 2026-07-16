#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-post-reboot.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
E="$TMP/evidence"; mkdir "$E"
SESSION='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
ETHADDR='00:11:22:33:44:55'
FINGERPRINT="$(printf 'xiaomi,ax9000\nethaddr=%s\n' "$ETHADDR" | sha256sum | awk '{print $1}')"
printf 'session_id=%s\n' "$SESSION" > "$E/SESSION.txt"
fail() { echo "test_post_reboot_gate: $*" >&2; exit 1; }
expect_failure() { local label="$1" expected="$2"; shift 2; if "$@" >"$TMP/out" 2>"$TMP/err"; then fail "$label unexpectedly passed"; fi; grep -Fq "$expected" "$TMP/err" || { cat "$TMP/err" >&2; fail "$label failed unexpectedly"; }; }
write_capture() {
  local phase="$1" challenge="$2" epoch="$3" uptime="$4" boot_id="$5"
  cat > "$E/production-capture-$phase.txt" <<META
schema=2
session_id=$SESSION
challenge=$challenge
phase=$phase
collected_epoch=$epoch
uptime_seconds=$uptime
boot_id=$boot_id
board_name=xiaomi,ax9000
ethaddr=$ETHADDR
device_fingerprint_sha256=$FINGERPRINT
production_cmdline_sha256=$(sha256sum "$E/production-cmdline-$phase.txt" | awk '{print $1}')
mtd_layout_sha256=$(sha256sum "$E/mtd-layout-$phase.txt" | awk '{print $1}')
uboot_printenv_sha256=$(sha256sum "$E/uboot-printenv-$phase.txt" | awk '{print $1}')
production_identity_sha256=$(sha256sum "$E/production-identity-$phase.txt" | awk '{print $1}')
META
}
reset_valid() {
  printf 'console=ttyMSM0 ubi.mtd=rootfs root=/dev/ubiblock0_1\n' > "$E/production-cmdline-before.txt"
  cp "$E/production-cmdline-before.txt" "$E/production-cmdline-after.txt"
  cat > "$E/mtd-layout-before.txt" <<'MTD'
dev:    size   erasesize  name
mtd0: 00100000 00020000 "sbl1"
mtd1: 0e800000 00020000 "rootfs"
MTD
  cp "$E/mtd-layout-before.txt" "$E/mtd-layout-after.txt"
  printf 'bootcmd=boot_stock\nethaddr=%s\n' "$ETHADDR" > "$E/uboot-printenv-before.txt"
  printf 'ethaddr=%s\nbootcmd=boot_stock\n' "$ETHADDR" > "$E/uboot-printenv-after.txt"
  printf 'board_name=xiaomi,ax9000\nkernel=6.6.1\nrelease=stock\n' > "$E/production-identity-before.txt"
  cp "$E/production-identity-before.txt" "$E/production-identity-after.txt"
  write_capture before aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100000 5000 11111111-1111-4111-8111-111111111111
  write_capture after bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100100 60 22222222-2222-4222-8222-222222222222
}
reset_valid
"$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" >/dev/null
[[ -f "$E/post-reboot-gate.txt" && ! -L "$E/post-reboot-gate.txt" ]] || fail 'post-reboot gate was not committed as a regular file'
grep -Fxq 'reboot_to_production=pass' "$E/post-reboot-gate.txt" || fail 'reboot marker missing'
grep -Fxq "session_id=$SESSION" "$E/post-reboot-gate.txt" || fail 'session marker missing'
grep -Fxq "device_fingerprint_sha256=$FINGERPRINT" "$E/post-reboot-gate.txt" || fail 'fingerprint marker missing'
gate_sha="$(sha256sum "$E/post-reboot-gate.txt" | awk '{print $1}')"
expect_failure 'post-reboot gate overwrite' 'post-reboot gate already exists' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E"
[[ "$(sha256sum "$E/post-reboot-gate.txt" | awk '{print $1}')" == "$gate_sha" ]] || fail 'failed gate rewrite modified committed gate'

reset_valid
printf 'bootcmd=boot_other\nethaddr=%s\n' "$ETHADDR" > "$E/uboot-printenv-after.txt"
write_capture after bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100100 60 22222222-2222-4222-8222-222222222222
expect_failure 'changed U-Boot env' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only
reset_valid
sed 's/0e800000/0e700000/' "$E/mtd-layout-before.txt" > "$E/mtd-layout-after.txt"
write_capture after bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100100 60 22222222-2222-4222-8222-222222222222
expect_failure 'changed MTD layout' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only
for root_device in /dev/ram0 /dev/ram1 /dev/ramdisk0 /dev/ubiblock0_2; do
  reset_valid
  printf 'console=ttyMSM0 ubi.mtd=rootfs root=%s\n' "$root_device" > "$E/production-cmdline-after.txt"
  [[ "$root_device" != /dev/ramdisk0 ]] || cp "$E/production-cmdline-after.txt" "$E/production-cmdline-before.txt"
  write_capture before aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100000 5000 11111111-1111-4111-8111-111111111111
  write_capture after bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100100 60 22222222-2222-4222-8222-222222222222
  expect_failure "invalid production root $root_device" 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only
done
reset_valid
printf 'console=ttyMSM0 ubi.mtd=rootfs\n' > "$E/production-cmdline-after.txt"
write_capture after bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100100 60 22222222-2222-4222-8222-222222222222
expect_failure 'missing production root' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only

reset_valid
sed -i.bak 's/^challenge=.*/challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$E/production-capture-after.txt"; rm "$E/production-capture-after.txt.bak"
expect_failure 'replayed challenge' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only
reset_valid
sed -i.bak 's/^boot_id=.*/boot_id=11111111-1111-4111-8111-111111111111/' "$E/production-capture-after.txt"; rm "$E/production-capture-after.txt.bak"
expect_failure 'unchanged boot ID' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only
reset_valid
sed -i.bak 's/^collected_epoch=.*/collected_epoch=99999/' "$E/production-capture-after.txt"; rm "$E/production-capture-after.txt.bak"
expect_failure 'reversed chronology' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only
reset_valid
printf 'tampered\n' >> "$E/production-identity-after.txt"
expect_failure 'payload digest mismatch' 'production state changed, was replayed, or is malformed' "$ROOT_DIR/scripts/verify-post-reboot-state.sh" "$E" --check-only

echo 'post-reboot gate strictly binds session, random challenges, capture digests, device fingerprint, chronology, and changed boot ID: OK'
