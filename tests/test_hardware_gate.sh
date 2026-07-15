#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
mkdir -p "$TMP/dist" "$TMP/evidence"
printf firmware > "$TMP/dist/$IMAGE"
(cd "$TMP/dist" && sha256sum "$IMAGE" > SHA256SUMS)
sha="$(sha256sum "$TMP/dist/$IMAGE" | awk '{print $1}')"
printf 'model=xiaomi,ax9000\nimage_sha256=%s\n' "$sha" > "$TMP/evidence/device.txt"
for f in uart-cold-boot.log uboot-help.txt uboot-printenv-before.txt uboot-printenv-after.txt ram-boot.log stress-24h.log network-regression.log thermal.log; do printf evidence > "$TMP/evidence/$f"; done
printf '%s\n' 'root=/dev/ram0' 'persistent_ubi_attached=no' 'persistent_mounts=no' 'all_mtd_partitions_readonly=yes' 'raw_mtd_write_probe=blocked' 'sysupgrade_guard_exit=74' 'factoryreset_guard_exit=74' 'firstboot_guard_exit=74' 'jffs2reset_guard_exit=74' 'jffs2mark_guard_exit=74' 'mount_root_guard_exit=74' > "$TMP/evidence/runtime-gate.txt"
printf '%s\n' 'reboot_to_production=pass' 'mtd_layout_unchanged=pass' 'uboot_env_unchanged=pass' > "$TMP/evidence/post-reboot-gate.txt"
printf '%s\n' 'stress_24h=pass' 'network_regression=pass' 'panic_oops=none' 'thermal_throttle=none' > "$TMP/evidence/stress-gate.txt"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/reviewer-key"
printf 'tester %s\n' "$(cat "$TMP/reviewer-key.pub")" > "$TMP/allowed_signers"
payload_files=(device.txt uart-cold-boot.log uboot-help.txt uboot-printenv-before.txt uboot-printenv-after.txt ram-boot.log runtime-gate.txt post-reboot-gate.txt stress-gate.txt stress-24h.log network-regression.log thermal.log)
payload_manifest="$(for file in "${payload_files[@]}"; do sha256sum "$TMP/evidence/$file" | sed "s#  $TMP/evidence/#  #"; done)"
evidence_sha="$(printf '%s\n' "$payload_manifest" | sha256sum | awk '{print $1}')"
printf '%s\n' \
  'decision=approved-for-ram-boot-only' \
  'reviewer=tester' \
  "reviewed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "firmware_sha256=$sha" \
  "evidence_sha256=$evidence_sha" > "$TMP/evidence/APPROVAL.txt"
ssh-keygen -q -Y sign -f "$TMP/reviewer-key" -n nexawrt-hardware-approval "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | xargs sha256sum) > "$TMP/evidence/SHA256SUMS"
"$ROOT_DIR/scripts/verify-hardware-evidence.sh" "$TMP/evidence" "$TMP/dist" "$TMP/allowed_signers" >/dev/null

sed -i.bak 's/stress_24h=pass/stress_24h=fail/' "$TMP/evidence/stress-gate.txt"; rm "$TMP/evidence/stress-gate.txt.bak"
(cd "$TMP/evidence" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | xargs sha256sum) > "$TMP/evidence/SHA256SUMS"
if "$ROOT_DIR/scripts/verify-hardware-evidence.sh" "$TMP/evidence" "$TMP/dist" "$TMP/allowed_signers" >/dev/null 2>&1; then echo 'failed stress gate accepted' >&2; exit 1; fi

printf '%s\n' 'stress_24h=pass' 'network_regression=pass' 'panic_oops=none' 'thermal_throttle=none' > "$TMP/evidence/stress-gate.txt"
payload_manifest="$(for file in "${payload_files[@]}"; do sha256sum "$TMP/evidence/$file" | sed "s#  $TMP/evidence/#  #"; done)"
evidence_sha="$(printf '%s\n' "$payload_manifest" | sha256sum | awk '{print $1}')"
# A submitter can rewrite the approval and checksums, but cannot forge the trusted reviewer's signature.
printf '%s\n' 'decision=approved-for-ram-boot-only' 'reviewer=tester' "reviewed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "firmware_sha256=$sha" "evidence_sha256=$evidence_sha" 'submitter_rewrote=yes' > "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | xargs sha256sum) > "$TMP/evidence/SHA256SUMS"
if "$ROOT_DIR/scripts/verify-hardware-evidence.sh" "$TMP/evidence" "$TMP/dist" "$TMP/allowed_signers" >/dev/null 2>&1; then echo 'forged approval accepted' >&2; exit 1; fi

printf '%s\n' "$(grep -v 'thermal.log$' "$TMP/evidence/SHA256SUMS")" > "$TMP/evidence/SHA256SUMS"
if "$ROOT_DIR/scripts/verify-hardware-evidence.sh" "$TMP/evidence" "$TMP/dist" "$TMP/allowed_signers" >/dev/null 2>&1; then echo 'incomplete checksum coverage accepted' >&2; exit 1; fi
echo 'hardware evidence gate with trusted signed approval: OK'
