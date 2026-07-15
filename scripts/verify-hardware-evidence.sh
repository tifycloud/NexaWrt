#!/usr/bin/env bash
set -euo pipefail
EVIDENCE_DIR="${1:-}"
DIST_DIR="${2:-}"
TRUSTED_REVIEWERS="${3:-${NEXAWRT_TRUSTED_REVIEWERS:-}}"
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
SIGNATURE_NAMESPACE='nexawrt-hardware-approval'
MAX_APPROVAL_AGE_SECONDS="${NEXAWRT_MAX_APPROVAL_AGE_SECONDS:-2592000}"
fail() { echo "hardware gate failed: $*" >&2; exit 1; }
[[ -d "$EVIDENCE_DIR" && -d "$DIST_DIR" && -f "$TRUSTED_REVIEWERS" ]] ||
  fail "usage: $0 EVIDENCE_DIR DIST_DIR TRUSTED_REVIEWERS_ALLOWED_SIGNERS"
[[ ! -L "$EVIDENCE_DIR" && ! -L "$DIST_DIR" && ! -L "$TRUSTED_REVIEWERS" ]] ||
  fail "evidence, distribution, and trusted reviewer paths must not be symlinks"
[[ "$MAX_APPROVAL_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "approval age limit must be a positive integer"
command -v ssh-keygen >/dev/null || fail "ssh-keygen with SSH signature support is required"
[[ -f "$DIST_DIR/$IMAGE" && -f "$DIST_DIR/SHA256SUMS" ]] || fail "verified build payload is incomplete"
(cd "$DIST_DIR" && sha256sum -c SHA256SUMS >/dev/null) || fail "build payload checksum verification failed"
grep -Eq "^[0-9a-fA-F]{64}  (\\./)?${IMAGE//./\\.}$" "$DIST_DIR/SHA256SUMS" || fail "firmware is not bound by build payload checksums"

payload_files=(
  device.txt
  uart-cold-boot.log
  uboot-help.txt
  uboot-printenv-before.txt
  uboot-printenv-after.txt
  ram-boot.log
  runtime-gate.txt
  post-reboot-gate.txt
  stress-gate.txt
  stress-24h.log
  network-regression.log
  thermal.log
)
required_files=(
  "${payload_files[@]}"
  APPROVAL.txt
  APPROVAL.txt.sig
)
for file in "${required_files[@]}"; do
  [[ -s "$EVIDENCE_DIR/$file" && ! -L "$EVIDENCE_DIR/$file" ]] ||
    fail "required hardware evidence is missing, empty, or a symlink: $file"
done
[[ -s "$EVIDENCE_DIR/SHA256SUMS" && ! -L "$EVIDENCE_DIR/SHA256SUMS" ]] ||
  fail "required hardware evidence is missing, empty, or a symlink: SHA256SUMS"

# Every required evidence file, and only those files, must be checksum-bound.
if grep -Evq '^[0-9a-fA-F]{64}  (\./)?[^/]+$' "$EVIDENCE_DIR/SHA256SUMS"; then
  fail "hardware evidence SHA256SUMS contains a malformed or unsafe path"
fi
expected_files="$(printf '%s\n' "${required_files[@]}" | LC_ALL=C sort)"
actual_files="$(awk '{ name=$2; sub(/^\.\//,"",name); print name }' "$EVIDENCE_DIR/SHA256SUMS" | LC_ALL=C sort)"
[[ "$actual_files" == "$expected_files" ]] || fail "hardware evidence SHA256SUMS does not exactly cover the required evidence set"
(cd "$EVIDENCE_DIR" && sha256sum -c SHA256SUMS >/dev/null) || fail "hardware evidence checksum verification failed"

image_sha="$(sha256sum "$DIST_DIR/$IMAGE" | awk '{print $1}')"
grep -Fxq 'model=xiaomi,ax9000' "$EVIDENCE_DIR/device.txt" || fail "device model mismatch"
grep -Fxq "image_sha256=$image_sha" "$EVIDENCE_DIR/device.txt" || fail "hardware evidence references a different image"
for marker in \
  'root=/dev/ram0' \
  'persistent_ubi_attached=no' \
  'persistent_mounts=no' \
  'all_mtd_partitions_readonly=yes' \
  'raw_mtd_write_probe=blocked' \
  'sysupgrade_guard_exit=74' \
  'factoryreset_guard_exit=74' \
  'firstboot_guard_exit=74' \
  'jffs2reset_guard_exit=74' \
  'jffs2mark_guard_exit=74' \
  'mount_root_guard_exit=74'; do
  grep -Fxq "$marker" "$EVIDENCE_DIR/runtime-gate.txt" || fail "runtime gate marker missing: $marker"
done
for marker in 'reboot_to_production=pass' 'mtd_layout_unchanged=pass' 'uboot_env_unchanged=pass'; do
  grep -Fxq "$marker" "$EVIDENCE_DIR/post-reboot-gate.txt" || fail "post-reboot gate marker missing: $marker"
done
for marker in 'stress_24h=pass' 'network_regression=pass' 'panic_oops=none' 'thermal_throttle=none'; do
  grep -Fxq "$marker" "$EVIDENCE_DIR/stress-gate.txt" || fail "stress gate marker missing: $marker"
done

payload_manifest="$(for file in "${payload_files[@]}"; do sha256sum "$EVIDENCE_DIR/$file" | sed "s#  $EVIDENCE_DIR/#  #"; done)"
evidence_sha="$(printf '%s\n' "$payload_manifest" | sha256sum | awk '{print $1}')"
approval="$EVIDENCE_DIR/APPROVAL.txt"
grep -Fxq 'decision=approved-for-ram-boot-only' "$approval" || fail "approval remains closed"
reviewer="$(sed -n 's/^reviewer=//p' "$approval")"
reviewed_utc="$(sed -n 's/^reviewed_utc=//p' "$approval")"
[[ "$reviewer" =~ ^[^[:space:]]+$ ]] || fail "reviewer identity missing or duplicated"
[[ "$(grep -c '^reviewer=' "$approval")" == 1 ]] || fail "reviewer identity missing or duplicated"
[[ "$(grep -c '^reviewed_utc=' "$approval")" == 1 ]] || fail "review timestamp missing or duplicated"
grep -Fxq "firmware_sha256=$image_sha" "$approval" || fail "approval is not bound to the firmware"
grep -Fxq "evidence_sha256=$evidence_sha" "$approval" || fail "approval is not bound to the evidence payload"
python3 - "$reviewed_utc" "$MAX_APPROVAL_AGE_SECONDS" <<'PY' || fail "review timestamp is malformed, stale, or in the future"
from datetime import datetime, timezone, timedelta
import sys
try:
    reviewed = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    max_age = int(sys.argv[2])
except (ValueError, IndexError):
    raise SystemExit(1)
now = datetime.now(timezone.utc)
if reviewed > now + timedelta(minutes=5) or now - reviewed > timedelta(seconds=max_age):
    raise SystemExit(1)
PY
ssh-keygen -Y verify \
  -f "$TRUSTED_REVIEWERS" \
  -I "$reviewer" \
  -n "$SIGNATURE_NAMESPACE" \
  -s "$EVIDENCE_DIR/APPROVAL.txt.sig" \
  < "$approval" >/dev/null 2>&1 || fail "approval signature is invalid or reviewer is not trusted"
echo 'hardware gate: signed approval verified for this exact initramfs image and evidence payload, RAM boot only'
