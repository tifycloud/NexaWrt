#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-collectors.XXXXXX")"
EVIDENCE="$ROOT_DIR/hardware-evidence/.collector-test-$$"
REMOTE_DIR=/tmp/nexawrt-runtime-evidence
trap 'rm -rf "$TMP" "$EVIDENCE" "$REMOTE_DIR"' EXIT
fail() { echo "test_evidence_collectors: $*" >&2; exit 1; }
expect_failure() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$label unexpectedly passed"; fi; }

mkdir -p "$TMP/bin" "$TMP/dist" "$EVIDENCE"
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
printf firmware > "$TMP/dist/$IMAGE"
printf 'flavor=nss\n' > "$TMP/dist/BUILD-MANIFEST.txt"
(cd "$TMP/dist" && sha256sum "$IMAGE" BUILD-MANIFEST.txt > SHA256SUMS)
export TEST_IMAGE_SHA TEST_PROBE_SHA TEST_SESSION TEST_FINGERPRINT TEST_CAPTURE_COUNT_FILE
TEST_IMAGE_SHA="$(sha256sum "$TMP/dist/$IMAGE" | awk '{print $1}')"
TEST_PROBE_SHA="$(sha256sum "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" | awk '{print $1}')"
TEST_SESSION='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
TEST_FINGERPRINT="$(printf 'xiaomi,ax9000\nethaddr=00:11:22:33:44:55\n' | sha256sum | awk '{print $1}')"
TEST_CAPTURE_COUNT_FILE="$TMP/production-capture-count"
: > "$TEST_CAPTURE_COUNT_FILE"

cat > "$TMP/bin/ssh" <<'MOCK'
#!/bin/sh
set -eu
for argument in "$@"; do command=$argument; done
case "$command" in
  "sh -s -- '$TEST_SESSION' 'before' "*|"sh -s -- '$TEST_SESSION' 'after' "*)
    cat >/dev/null
    phase=$(printf '%s\n' "$command" | awk -F"'" '{print $4}')
    challenge=$(printf '%s\n' "$command" | awk -F"'" '{print $6}')
    printf '%s\n' "$phase" >> "$TEST_CAPTURE_COUNT_FILE"
    capture=$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-mock-capture.XXXXXX")
    trap 'rm -rf "$capture"' EXIT
    printf 'console=ttyMSM0 ubi.mtd=rootfs root=/dev/ubiblock0_1\n' > "$capture/production-cmdline.txt"
    printf 'dev:    size   erasesize  name\nmtd0: 00100000 00020000 "sbl1"\nmtd1: 0e800000 00020000 "rootfs"\n' > "$capture/mtd-layout.txt"
    printf 'bootcmd=boot_stock\nethaddr=00:11:22:33:44:55\n' > "$capture/uboot-printenv.txt"
    printf 'board_name=xiaomi,ax9000\nkernel=6.6.1\nrelease=stock\n' > "$capture/production-identity.txt"
    if [ "$phase" = before ]; then
      epoch=100000; uptime=5000; boot_id=11111111-1111-4111-8111-111111111111
    else
      epoch=100100; uptime=60; boot_id=22222222-2222-4222-8222-222222222222
    fi
    file_sha() { sha256sum "$capture/$1" | awk '{print $1}'; }
    cat > "$capture/production-capture.txt" <<META
schema=2
session_id=$TEST_SESSION
challenge=$challenge
phase=$phase
collected_epoch=$epoch
uptime_seconds=$uptime
boot_id=$boot_id
board_name=xiaomi,ax9000
ethaddr=00:11:22:33:44:55
device_fingerprint_sha256=$TEST_FINGERPRINT
production_cmdline_sha256=$(file_sha production-cmdline.txt)
mtd_layout_sha256=$(file_sha mtd-layout.txt)
uboot_printenv_sha256=$(file_sha uboot-printenv.txt)
production_identity_sha256=$(file_sha production-identity.txt)
META
    COPYFILE_DISABLE=1 tar -C "$capture" -cf - production-capture.txt production-cmdline.txt mtd-layout.txt uboot-printenv.txt production-identity.txt
    ;;
  *"sh -s --"*)
    case "$command" in *"'$TEST_SESSION'"*) ;; *) echo 'session was not forwarded to remote probe' >&2; exit 1;; esac
    cat >/dev/null
    rm -rf /tmp/nexawrt-runtime-evidence
    mkdir -m 0700 /tmp/nexawrt-runtime-evidence
    printf 'model=xiaomi,ax9000\nimage_sha256=%s\nflavor=nss\nprobe_sha256=%s\nsession_id=%s\ndevice_fingerprint_sha256=%s\n' \
      "$TEST_IMAGE_SHA" "$TEST_PROBE_SHA" "$TEST_SESSION" "$TEST_FINGERPRINT" > /tmp/nexawrt-runtime-evidence/device.txt
    printf '%s\n' \
      'root=/dev/ram0' 'persistent_ubi_attached=no' 'persistent_mounts=no' \
      'all_mtd_partitions_readonly=yes' 'raw_mtd_write_probe=blocked' \
      'sysupgrade_guard_exit=74' 'factoryreset_guard_exit=74' 'firstboot_guard_exit=74' \
      'jffs2reset_guard_exit=74' 'jffs2mark_guard_exit=74' 'mount_root_guard_exit=74' \
      'flavor=nss' "probe_sha256=$TEST_PROBE_SHA" "session_id=$TEST_SESSION" \
      "device_fingerprint_sha256=$TEST_FINGERPRINT" \
      'fw_printenv_available=yes' 'uboot_env_write_tools=absent' \
      'nss_driver_loaded=yes' 'nss_ecm_loaded=yes' 'nss_firmware_present=yes' \
      > /tmp/nexawrt-runtime-evidence/runtime-gate.txt
    printf 'runtime log\n' > /tmp/nexawrt-runtime-evidence/ram-boot.log
    ;;
  *"tar -C '/tmp/nexawrt-runtime-evidence'"*)
    COPYFILE_DISABLE=1 tar -C /tmp/nexawrt-runtime-evidence -cf - device.txt runtime-gate.txt ram-boot.log
    ;;
  *"rm -rf -- '/tmp/nexawrt-runtime-evidence'"*) rm -rf /tmp/nexawrt-runtime-evidence ;;
  *) echo "unexpected mocked SSH command: $command" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMP/bin/ssh"

expect_failure 'production collector without SESSION' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-production-state.sh" router "$EVIDENCE" before
expect_failure 'runtime collector without SESSION' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-runtime-evidence.sh" router "$TMP/dist" nss "$EVIDENCE"
printf 'session_id=%s\n' "$TEST_SESSION" > "$EVIDENCE/SESSION.txt"

PATH="$TMP/bin:$PATH" "$ROOT_DIR/scripts/collect-production-state.sh" router "$EVIDENCE" before >/dev/null
[[ "$(wc -l < "$TEST_CAPTURE_COUNT_FILE" | tr -d ' ')" == 1 ]] || fail 'before state was not captured by exactly one SSH transaction'
printf 'preserve-me\n' > "$EVIDENCE/manual-uart-note.txt"
PATH="$TMP/bin:$PATH" "$ROOT_DIR/scripts/collect-runtime-evidence.sh" router "$TMP/dist" nss "$EVIDENCE" >/dev/null
for file in SESSION.txt production-capture-before.txt production-cmdline-before.txt mtd-layout-before.txt uboot-printenv-before.txt production-identity-before.txt device.txt runtime-gate.txt ram-boot.log manual-uart-note.txt; do
  [[ -s "$EVIDENCE/$file" ]] || fail "collector output missing or overwritten: $file"
done
for marker in "schema=2" "session_id=$TEST_SESSION" 'phase=before' "device_fingerprint_sha256=$TEST_FINGERPRINT"; do
  grep -Fxq "$marker" "$EVIDENCE/production-capture-before.txt" || fail "production capture binding missing: $marker"
done
for marker in "image_sha256=$TEST_IMAGE_SHA" "probe_sha256=$TEST_PROBE_SHA" "session_id=$TEST_SESSION" "device_fingerprint_sha256=$TEST_FINGERPRINT"; do
  grep -Fxq "$marker" "$EVIDENCE/device.txt" || fail "runtime binding was not preserved: $marker"
done
grep -Fxq preserve-me "$EVIDENCE/manual-uart-note.txt" || fail 'existing evidence was overwritten'

PATH="$TMP/bin:$PATH" "$ROOT_DIR/scripts/collect-production-state.sh" router "$EVIDENCE" after >/dev/null
[[ "$(wc -l < "$TEST_CAPTURE_COUNT_FILE" | tr -d ' ')" == 2 ]] || fail 'after state was not captured by exactly one additional SSH transaction'
before_challenge="$(sed -n 's/^challenge=//p' "$EVIDENCE/production-capture-before.txt")"
after_challenge="$(sed -n 's/^challenge=//p' "$EVIDENCE/production-capture-after.txt")"
[[ "$before_challenge" =~ ^[0-9a-f]{64}$ && "$after_challenge" =~ ^[0-9a-f]{64}$ && "$before_challenge" != "$after_challenge" ]] ||
  fail 'before/after challenges are invalid or repeated'

before_sha="$(sha256sum "$EVIDENCE/production-capture-before.txt" | awk '{print $1}')"
expect_failure 'recollect existing before phase' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-production-state.sh" router "$EVIDENCE" before
[[ "$(sha256sum "$EVIDENCE/production-capture-before.txt" | awk '{print $1}')" == "$before_sha" ]] || fail 'failed recollection overwrote before metadata'

mkdir -p "$ROOT_DIR/hardware-evidence/.collector-symlink-$$"
SYMLINK_EVIDENCE="$ROOT_DIR/hardware-evidence/.collector-symlink-$$"
printf 'session_id=%s\n' "$TEST_SESSION" > "$SYMLINK_EVIDENCE/SESSION.txt"
printf 'victim-must-survive\n' > "$TMP/victim"
ln -s "$TMP/victim" "$SYMLINK_EVIDENCE/production-cmdline-before.txt"
expect_failure 'production output leaf symlink' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-production-state.sh" router "$SYMLINK_EVIDENCE" before
grep -Fxq victim-must-survive "$TMP/victim" || fail 'production collector followed output leaf symlink'
rm -rf "$SYMLINK_EVIDENCE"

runtime_device_sha="$(sha256sum "$EVIDENCE/device.txt" | awk '{print $1}')"
expect_failure 'recollect existing runtime evidence' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-runtime-evidence.sh" router "$TMP/dist" nss "$EVIDENCE"
[[ "$(sha256sum "$EVIDENCE/device.txt" | awk '{print $1}')" == "$runtime_device_sha" ]] || fail 'failed runtime recollection overwrote committed evidence'

RUNTIME_SYMLINK_EVIDENCE="$ROOT_DIR/hardware-evidence/.runtime-collector-symlink-$$"
mkdir -p "$RUNTIME_SYMLINK_EVIDENCE"
printf 'session_id=%s\n' "$TEST_SESSION" > "$RUNTIME_SYMLINK_EVIDENCE/SESSION.txt"
ln -s "$TMP/victim" "$RUNTIME_SYMLINK_EVIDENCE/device.txt"
expect_failure 'runtime output leaf symlink' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-runtime-evidence.sh" router "$TMP/dist" nss "$RUNTIME_SYMLINK_EVIDENCE"
grep -Fxq victim-must-survive "$TMP/victim" || fail 'runtime collector followed a leaf symlink'
rm -rf "$RUNTIME_SYMLINK_EVIDENCE"

printf 'flavor=official\n' > "$TMP/dist/BUILD-MANIFEST.txt"
(cd "$TMP/dist" && sha256sum "$IMAGE" BUILD-MANIFEST.txt > SHA256SUMS)
expect_failure 'distribution flavor mismatch' env PATH="$TMP/bin:$PATH" \
  "$ROOT_DIR/scripts/collect-runtime-evidence.sh" router "$TMP/dist" nss "$EVIDENCE"

mkdir -p "$TMP/isolated/scripts" "$TMP/escape"
cp "$ROOT_DIR/scripts/collect-production-state.sh" "$ROOT_DIR/scripts/collect-runtime-evidence.sh" "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" "$TMP/isolated/scripts/"
ln -s "$TMP/escape" "$TMP/isolated/hardware-evidence"
expect_failure 'symlinked evidence root for production state' env PATH="$TMP/bin:$PATH" \
  "$TMP/isolated/scripts/collect-production-state.sh" router "$TMP/isolated/hardware-evidence/case" before
expect_failure 'symlinked evidence root for runtime state' env PATH="$TMP/bin:$PATH" \
  "$TMP/isolated/scripts/collect-runtime-evidence.sh" router "$TMP/dist" nss "$TMP/isolated/hardware-evidence/case"

echo 'production and runtime collection are single-shot, challenge/session-bound, replay-resistant, and non-overwriting: OK'
