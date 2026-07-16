#!/usr/bin/env bash
set -euo pipefail
# Repository policy tests run as local fixtures unless a case injects a complete
# synthetic GitHub context explicitly. Do not inherit the enclosing CI run identity.
unset GITHUB_ACTIONS GITHUB_REF GITHUB_REPOSITORY GITHUB_RUN_ATTEMPT \
  GITHUB_RUN_ID GITHUB_SHA GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nexawrt-hardware-gate.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "test_hardware_gate: $*" >&2; exit 1; }
expect_gate_failure() {
  local label="$1"
  if "$VERIFY_HARDWARE" "$TMP/evidence" "$DIST" "$TMP/allowed_signers" >/dev/null 2>&1; then
    fail "$label unexpectedly passed"
  fi
}

IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
SESSION='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
ETHADDR='00:11:22:33:44:55'
FINGERPRINT="$(printf 'xiaomi,ax9000\nethaddr=%s\n' "$ETHADDR" | sha256sum | awk '{print $1}')"
PROJECT="$TMP/project"
mkdir -p "$PROJECT/scripts" "$PROJECT/release-staging"
cp "$ROOT_DIR/scripts/compare-reproducible-builds.sh" "$PROJECT/scripts/"
for script in verify-hardware-evidence.sh verify-post-reboot-state.sh verify-stress-evidence.sh ax9000-runtime-probe.sh lock-file-policy.sh; do
  cp "$ROOT_DIR/scripts/$script" "$PROJECT/scripts/$script"
done
VERIFY_HARDWARE="$PROJECT/scripts/verify-hardware-evidence.sh"
copy_build_inputs() {
  local flavor file
  for flavor in official nss; do
    while IFS= read -r -d '' file; do
      mkdir -p "$PROJECT/$(dirname "$file")"
      cp "$ROOT_DIR/$file" "$PROJECT/$file"
    done < <("$ROOT_DIR/scripts/list-build-inputs.sh" "$flavor")
  done
}
copy_build_inputs
APK_SIGNING_PROFILE='production'
APK_SIGNING_PUBLIC_SHA256='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
printf 'NEXAWRT_APK_SIGNING_PRODUCTION_PUBLIC_SHA256="%s"\n' "$APK_SIGNING_PUBLIC_SHA256" > "$PROJECT/manifests/apk-signing.lock"
mkdir -p "$TMP/evidence"
# shellcheck disable=SC1090
source "$PROJECT/manifests/nss.lock"
EMPTY_SHA="$(printf '' | sha256sum | awk '{print $1}')"
NSS_PATCH_SHA="$(sha256sum "$PROJECT/patches/nss/001-pin-codelinaro-source-archives.patch" | awk '{print $1}')"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name nexawrt-fixture
git -C "$PROJECT" config user.email nexawrt-fixture@example.invalid
git -C "$PROJECT" add -A
GIT_AUTHOR_DATE='1700000000 +0000' GIT_COMMITTER_DATE='1700000000 +0000' \
  git -C "$PROJECT" commit -qm 'fixture project state'
PROJECT_COMMIT="$(git -C "$PROJECT" rev-parse HEAD)"
MANIFEST='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
SBOM='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'
write_dist_checksums() {
  local directory="$1"
  (cd "$directory" && find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS)
}
make_nss_replica() {
  local directory="$1" serial="$2"
  mkdir -p "$directory/EVIDENCE" "$directory/LICENSES/nss-firmware"
  printf firmware > "$directory/$IMAGE"
  printf 'base-files - 1\n' > "$directory/$MANIFEST"
  printf '{"bomFormat":"CycloneDX","serialNumber":"%s","components":[{"type":"library","name":"base-files","version":"1"}]}\n' "$serial" > "$directory/$SBOM"
  for file in config.buildinfo feeds.buildinfo profiles.json version.buildinfo DO-NOT-FLASH.txt; do printf '%s\n' "$file" > "$directory/$file"; done
  printf 'third party\n' > "$directory/THIRD_PARTY_NOTICES.md"
  printf 'license\n' > "$directory/LICENSES/nss-firmware/LICENSE.md"
  cat > "$directory/BUILD-MANIFEST.txt" <<MANIFEST_EOF
project=NexaWrt
flavor=nss
project_commit=$PROJECT_COMMIT
source_repository=$NSS_OPENWRT_REPO
source_branch=$NSS_OPENWRT_BRANCH
source_commit=$NSS_OPENWRT_COMMIT
source_date_epoch=1
apk_signing_profile=$APK_SIGNING_PROFILE
apk_signing_public_sha256=$APK_SIGNING_PUBLIC_SHA256
nss_packages_feed_repository=$NSS_PACKAGES_REPO
nss_packages_feed_commit=$NSS_PACKAGES_COMMIT
nss_sqm_feed_repository=$NSS_SQM_REPO
nss_sqm_feed_commit=$NSS_SQM_COMMIT
stage=initramfs-ram-boot-only
real_device_boot_approved=no
image=$IMAGE
package_manifest=$MANIFEST
sbom=$SBOM
MANIFEST_EOF
  {
    printf 'flavor=nss\nproject_commit=%s\nproject_tree_state=clean\nsource_commit=%s\nsource_origin=%s\napk_signing_profile=%s\napk_signing_public_sha256=%s\n' \
      "$PROJECT_COMMIT" "$NSS_OPENWRT_COMMIT" "$NSS_OPENWRT_REPO" "$APK_SIGNING_PROFILE" "$APK_SIGNING_PUBLIC_SHA256"
    while read -r name repository commit; do
      [[ -n "$name" && "$name" != \#* ]] || continue
      printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' "$name" "$commit" "$name" "$repository" "$name" "$EMPTY_SHA"
    done < "$PROJECT/manifests/feeds.lock"
    printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_COMMIT" "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_REPO" "$NSS_PACKAGES_FEED" "$NSS_PATCH_SHA"
    printf 'feed.%s.commit=%s\nfeed.%s.origin=%s\nfeed.%s.worktree_diff_sha256=%s\n' "$NSS_SQM_FEED" "$NSS_SQM_COMMIT" "$NSS_SQM_FEED" "$NSS_SQM_REPO" "$NSS_SQM_FEED" "$EMPTY_SHA"
  } > "$directory/EVIDENCE/SOURCE-STATE.txt"
  (
    cd "$PROJECT"
    while IFS= read -r -d '' file; do sha256sum "$file"; done < <(scripts/list-build-inputs.sh nss)
  ) > "$directory/EVIDENCE/INPUTS.sha256"
  replica_id="${directory##*/}"; replica_id="${replica_id##*-}"
  printf 'schema=2\nflavor=nss\nreplica_id=%s\nrun_id=local\nrun_attempt=local\nproject_commit=%s\nsource_commit=%s\napk_signing_profile=%s\napk_signing_public_sha256=%s\n' \
    "$replica_id" "$PROJECT_COMMIT" "$NSS_OPENWRT_COMMIT" "$APK_SIGNING_PROFILE" "$APK_SIGNING_PUBLIC_SHA256" > "$directory/EVIDENCE/BUILD-IDENTITY.txt"
  printf 'environment %s\n' "$serial" > "$directory/EVIDENCE/BUILD-ENVIRONMENT.txt"
  printf 'build log\n' > "$directory/EVIDENCE/build.log"
  printf 'config\n' > "$directory/EVIDENCE/resolved.config"
  (
    cd "$directory/EVIDENCE"
    find . -type f ! -name EVIDENCE.sha256 -print | LC_ALL=C sort | while IFS= read -r file; do sha256sum "$file"; done
  ) > "$directory/EVIDENCE/EVIDENCE.sha256"
  write_dist_checksums "$directory"
}
make_nss_replica "$PROJECT/a" a
make_nss_replica "$PROJECT/b" b
DIST="$PROJECT/release-staging/case/verified-dist"
mkdir -p "$PROJECT/release-staging/test-provenance" "$TMP/bin"
write_descriptor() {
  local replica="$1" artifact_id="$2" artifact_name="browser-build-local-local-nss-$1" receipt="$PROJECT/$1/SHA256SUMS"
  python3 - "$PROJECT/release-staging/test-provenance/$replica.descriptor.json" "$receipt" \
    "$replica" "$artifact_id" "$artifact_name" "$PROJECT_COMMIT" <<'PY_DESCRIPTOR'
import hashlib, json, pathlib, sys
path, receipt, replica, artifact_id, artifact_name, project_commit = sys.argv[1:]
source_ref = "refs/heads/main"
workflow = "tifycloud/NexaWrt/.github/workflows/build.yml"
value = {
    "artifact_id": artifact_id,
    "artifact_name": artifact_name,
    "flavor": "nss",
    "receipt_filename": "SHA256SUMS",
    "receipt_sha256": hashlib.sha256(pathlib.Path(receipt).read_bytes()).hexdigest(),
    "replica_id": replica,
    "repository": "tifycloud/NexaWrt",
    "run_attempt": "local",
    "run_id": "local",
    "schema": 2,
    "signer_digest": project_commit,
    "source_digest": project_commit,
    "source_ref": source_ref,
    "workflow": workflow,
    "workflow_ref": f"{workflow}@{source_ref}",
}
pathlib.Path(path).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY_DESCRIPTOR
  printf 'descriptor_sha256=%s\n' "$(sha256sum "$PROJECT/release-staging/test-provenance/$replica.descriptor.json" | awk '{print $1}')" \
    > "$PROJECT/release-staging/test-provenance/$replica.bundle.json"
}
write_descriptor a 201
write_descriptor b 202
cat > "$TMP/bin/mock-gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == attestation && "$2" == verify ]]
subject="$3"; shift 3
bundle=""
signer_workflow=""
source_digest=""
source_ref=""
signer_digest=""
while (($#)); do
  case "$1" in
    --repo) [[ "$2" == tifycloud/NexaWrt ]]; shift 2 ;;
    --signer-workflow) signer_workflow="$2"; shift 2 ;;
    --source-digest) source_digest="$2"; shift 2 ;;
    --source-ref) source_ref="$2"; shift 2 ;;
    --signer-digest) signer_digest="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    *) exit 1 ;;
  esac
done
[[ -n "$bundle" && "$signer_workflow" == tifycloud/NexaWrt/.github/workflows/build.yml ]]
python3 - "$subject" "$bundle" "$source_digest" "$source_ref" "$signer_digest" <<'PY_VERIFY'
import hashlib, json, pathlib, sys
subject, bundle, source_digest, source_ref, signer_digest = sys.argv[1:]
descriptor = json.loads(pathlib.Path(subject).read_text())
expected = dict(line.split("=", 1) for line in pathlib.Path(bundle).read_text().splitlines())["descriptor_sha256"]
assert hashlib.sha256(pathlib.Path(subject).read_bytes()).hexdigest() == expected
assert descriptor["source_digest"] == source_digest
assert descriptor["source_ref"] == source_ref
assert descriptor["signer_digest"] == signer_digest
PY_VERIFY
GH
chmod +x "$TMP/bin/mock-gh"
NEXAWRT_ATTESTATION_VERIFIER="$TMP/bin/mock-gh"
NEXAWRT_ATTESTATION_VERIFIER_SHA256="$(sha256sum "$NEXAWRT_ATTESTATION_VERIFIER" | awk '{print $1}')"
export NEXAWRT_ATTESTATION_VERIFIER NEXAWRT_ATTESTATION_VERIFIER_SHA256
export NEXAWRT_LEFT_ARTIFACT_ID=201 NEXAWRT_RIGHT_ARTIFACT_ID=202
export NEXAWRT_LEFT_ARTIFACT_NAME=browser-build-local-local-nss-a NEXAWRT_RIGHT_ARTIFACT_NAME=browser-build-local-local-nss-b
export NEXAWRT_LEFT_PRODUCER_DESCRIPTOR="$PROJECT/release-staging/test-provenance/a.descriptor.json"
export NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR="$PROJECT/release-staging/test-provenance/b.descriptor.json"
export NEXAWRT_LEFT_PROVENANCE_BUNDLE="$PROJECT/release-staging/test-provenance/a.bundle.json"
export NEXAWRT_RIGHT_PROVENANCE_BUNDLE="$PROJECT/release-staging/test-provenance/b.bundle.json"
GITHUB_ACTIONS=true GITHUB_REPOSITORY=tifycloud/NexaWrt \
  GITHUB_REF=refs/heads/main GITHUB_SHA="$PROJECT_COMMIT" \
  GITHUB_WORKFLOW_REF=tifycloud/NexaWrt/.github/workflows/build.yml@refs/heads/main \
  GITHUB_WORKFLOW_SHA="$PROJECT_COMMIT" GITHUB_RUN_ID=local GITHUB_RUN_ATTEMPT=local \
  "$PROJECT/scripts/compare-reproducible-builds.sh" nss "$PROJECT/a" "$PROJECT/b" "$DIST" >/dev/null
sha="$(sha256sum "$DIST/$IMAGE" | awk '{print $1}')"
image_size="$(wc -c < "$DIST/$IMAGE" | tr -d ' ')"
image_size_hex="$(printf '%x' "$image_size")"
probe_sha="$(sha256sum "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" | awk '{print $1}')"

printf 'session_id=%s\n' "$SESSION" > "$TMP/evidence/SESSION.txt"
"$PROJECT/scripts/compare-reproducible-builds.sh" --verify-verified-dist "$DIST" > "$TMP/evidence/CANDIDATE.txt"
grep -Fxq "apk_signing_profile=$APK_SIGNING_PROFILE" "$TMP/evidence/CANDIDATE.txt" || fail 'hardware candidate is not production-signed'
grep -Fxq "apk_signing_public_sha256=$APK_SIGNING_PUBLIC_SHA256" "$TMP/evidence/CANDIDATE.txt" || fail 'hardware candidate signing identity mismatch'
grep -Fxq 'apk_signing_mode=public-key-only' "$TMP/evidence/CANDIDATE.txt" || fail 'hardware candidate signing mode mismatch'
grep -Fxq 'apk_index_signed=false' "$TMP/evidence/CANDIDATE.txt" || fail 'hardware candidate index signing policy mismatch'
printf 'model=xiaomi,ax9000\nimage_sha256=%s\nflavor=nss\nprobe_sha256=%s\nsession_id=%s\ndevice_fingerprint_sha256=%s\n' \
  "$sha" "$probe_sha" "$SESSION" "$FINGERPRINT" > "$TMP/evidence/device.txt"
cat > "$TMP/evidence/uart-cold-boot.log" <<EOF_UART
U-Boot cold boot transcript
IPQ807x# if hash sha256 \${loadaddr} \${filesize} nexawrt_image_sha256; then echo NEXAWRT_HASH_EXECUTION=success; else echo NEXAWRT_HASH_EXECUTION=failure; fi
sha256 for memory range completed
NEXAWRT_HASH_EXECUTION=success
nexawrt_image_sha256=$sha
nexawrt_image_size_hex=$image_size_hex
nexawrt_session_id=$SESSION
ethaddr=$ETHADDR
bootm started
EOF_UART
printf 'hash - compute hash\nprintenv - print environment\nbootm - boot application image from memory\n' > "$TMP/evidence/uboot-help.txt"
cat > "$TMP/evidence/ram-boot.log" <<EOF_RAM
=== timestamp UTC ===
2026-01-01T00:00:00Z
=== hardware session and identity ===
session_id=$SESSION
ethaddr=$ETHADDR
device_fingerprint_sha256=$FINGERPRINT
=== proc mtd ===
dev:    size   erasesize  name
EOF_RAM
printf 'console=ttyMSM0 ubi.mtd=rootfs root=/dev/ubiblock0_1\n' > "$TMP/evidence/production-cmdline-before.txt"
cp "$TMP/evidence/production-cmdline-before.txt" "$TMP/evidence/production-cmdline-after.txt"
printf 'dev:    size   erasesize  name\nmtd0: 00100000 00020000 "sbl1"\nmtd1: 0e800000 00020000 "rootfs"\n' > "$TMP/evidence/mtd-layout-before.txt"
cp "$TMP/evidence/mtd-layout-before.txt" "$TMP/evidence/mtd-layout-after.txt"
printf 'bootcmd=boot_stock\nethaddr=%s\n' "$ETHADDR" > "$TMP/evidence/uboot-printenv-before.txt"
cp "$TMP/evidence/uboot-printenv-before.txt" "$TMP/evidence/uboot-printenv-after.txt"
printf 'board_name=xiaomi,ax9000\nkernel=6.6.1\nrelease=stock\n' > "$TMP/evidence/production-identity-before.txt"
cp "$TMP/evidence/production-identity-before.txt" "$TMP/evidence/production-identity-after.txt"
write_capture() {
  local phase="$1" challenge="$2" epoch="$3" uptime="$4" boot_id="$5"
  cat > "$TMP/evidence/production-capture-$phase.txt" <<EOF_CAPTURE
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
production_cmdline_sha256=$(sha256sum "$TMP/evidence/production-cmdline-$phase.txt" | awk '{print $1}')
mtd_layout_sha256=$(sha256sum "$TMP/evidence/mtd-layout-$phase.txt" | awk '{print $1}')
uboot_printenv_sha256=$(sha256sum "$TMP/evidence/uboot-printenv-$phase.txt" | awk '{print $1}')
production_identity_sha256=$(sha256sum "$TMP/evidence/production-identity-$phase.txt" | awk '{print $1}')
EOF_CAPTURE
}
write_capture before aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100000 5000 11111111-1111-4111-8111-111111111111
write_capture after bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 100100 60 22222222-2222-4222-8222-222222222222
printf '%s\n' \
  'root=/dev/ram0' 'persistent_ubi_attached=no' 'persistent_mounts=no' \
  'all_mtd_partitions_readonly=yes' 'raw_mtd_write_probe=blocked' \
  'sysupgrade_guard_exit=74' 'factoryreset_guard_exit=74' 'firstboot_guard_exit=74' \
  'jffs2reset_guard_exit=74' 'jffs2mark_guard_exit=74' 'mount_root_guard_exit=74' \
  'flavor=nss' "probe_sha256=$probe_sha" "session_id=$SESSION" \
  "device_fingerprint_sha256=$FINGERPRINT" \
  'fw_printenv_available=yes' 'uboot_env_write_tools=absent' \
  'nss_driver_loaded=yes' 'nss_ecm_loaded=yes' 'nss_firmware_present=yes' \
  > "$TMP/evidence/runtime-gate.txt"
printf '%s\n' 'reboot_to_production=pass' "session_id=$SESSION" "device_fingerprint_sha256=$FINGERPRINT" 'mtd_layout_unchanged=pass' 'uboot_env_unchanged=pass' > "$TMP/evidence/post-reboot-gate.txt"
STRESS_BOOT_ID=33333333-3333-4333-8333-333333333333
STRESS_STARTED_UPTIME=10000
STRESS_ENDED_UPTIME=96400
cat > "$TMP/evidence/stress-gate.txt" <<EOF_GATE
stress_24h=pass
execution_mode=production
session_id=$SESSION
device_fingerprint_sha256=$FINGERPRINT
device_boot_id=$STRESS_BOOT_ID
started_device_uptime_seconds=$STRESS_STARTED_UPTIME
ended_device_uptime_seconds=$STRESS_ENDED_UPTIME
network_regression=pass
panic_oops=none
thermal_throttle=none
elapsed_seconds=86400
network_min_mbps=500
network_rounds=24
thermal_limit_millidegrees=95000
thermal_max_millidegrees=70000
round_interval_seconds=3600
iperf_seconds=10
EOF_GATE
cat > "$TMP/evidence/stress-24h.log" <<EOF_STRESS
schema=3
execution_mode=production
session_id=$SESSION
device_fingerprint_sha256=$FINGERPRINT
device_boot_id=$STRESS_BOOT_ID
started_device_uptime_seconds=$STRESS_STARTED_UPTIME
ended_device_uptime_seconds=$STRESS_ENDED_UPTIME
started_epoch=100000
ended_epoch=186400
started_monotonic_seconds=50000
ended_monotonic_seconds=136400
elapsed_seconds=86400
completed=yes
rounds=24
round_interval_seconds=3600
iperf_seconds=10
ssh_failures=0
iperf_failures=0
panic_oops_matches=0
thermal_throttle_matches=0
EOF_STRESS
: > "$TMP/evidence/network-regression.log"
: > "$TMP/evidence/thermal.log"
: > "$TMP/evidence/kernel-health.log"
for round in $(seq 1 24); do
  epoch=$((100000 + (round - 1) * 3600))
  monotonic=$((50000 + (round - 1) * 3600))
  device_uptime=$((STRESS_STARTED_UPTIME + (round - 1) * 3600))
  printf 'round=%s epoch=%s monotonic_seconds=%s boot_id=%s device_uptime_seconds=%s direction=forward mbps=900.0 status=pass\n' "$round" "$epoch" "$monotonic" "$STRESS_BOOT_ID" "$device_uptime" >> "$TMP/evidence/network-regression.log"
  printf 'round=%s epoch=%s monotonic_seconds=%s boot_id=%s device_uptime_seconds=%s direction=reverse mbps=850.0 status=pass\n' "$round" "$epoch" "$monotonic" "$STRESS_BOOT_ID" "$device_uptime" >> "$TMP/evidence/network-regression.log"
  printf 'round=%s epoch=%s monotonic_seconds=%s boot_id=%s device_uptime_seconds=%s zone=thermal_zone0 millidegrees=70000\n' "$round" "$epoch" "$monotonic" "$STRESS_BOOT_ID" "$device_uptime" >> "$TMP/evidence/thermal.log"
  printf 'round=%s epoch=%s monotonic_seconds=%s boot_id=%s device_uptime_seconds=%s panic_oops_matches=0 thermal_throttle_matches=0 status=pass\n' "$round" "$epoch" "$monotonic" "$STRESS_BOOT_ID" "$device_uptime" >> "$TMP/evidence/kernel-health.log"
done

ssh-keygen -q -t ed25519 -N '' -f "$TMP/reviewer-key"
printf 'tester %s\n' "$(cat "$TMP/reviewer-key.pub")" > "$TMP/allowed_signers"
payload_files=(SESSION.txt CANDIDATE.txt device.txt uart-cold-boot.log uboot-help.txt uboot-printenv-before.txt uboot-printenv-after.txt production-cmdline-before.txt production-cmdline-after.txt production-capture-before.txt production-capture-after.txt mtd-layout-before.txt mtd-layout-after.txt production-identity-before.txt production-identity-after.txt ram-boot.log runtime-gate.txt post-reboot-gate.txt stress-gate.txt stress-24h.log network-regression.log thermal.log kernel-health.log)
required_files=("${payload_files[@]}" APPROVAL.txt APPROVAL.txt.sig)
refresh_approval() {
  local payload_manifest evidence_sha
  payload_manifest="$(cd "$TMP/evidence" && sha256sum "${payload_files[@]}")"
  evidence_sha="$(printf '%s\n' "$payload_manifest" | sha256sum | awk '{print $1}')"
  {
    printf '%s\n' \
      'decision=approved-for-ram-boot-only' \
      'reviewer=tester' \
      "reviewed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "evidence_sha256=$evidence_sha"
    while IFS='=' read -r key value; do
      if [[ "$key" == schema ]]; then
        printf 'candidate_schema=%s\n' "$value"
      else
        printf '%s=%s\n' "$key" "$value"
      fi
    done < "$TMP/evidence/CANDIDATE.txt"
  } > "$TMP/evidence/APPROVAL.txt"
  rm -f "$TMP/evidence/APPROVAL.txt.sig"
  ssh-keygen -q -Y sign -f "$TMP/reviewer-key" -n nexawrt-hardware-approval "$TMP/evidence/APPROVAL.txt"
  (cd "$TMP/evidence" && sha256sum "${required_files[@]}") > "$TMP/evidence/SHA256SUMS"
}
refresh_approval
"$VERIFY_HARDWARE" "$TMP/evidence" "$DIST" "$TMP/allowed_signers" >/dev/null

# The final hardware gate must reject a fully checksum-rebound descriptor from any workflow outside the exact allowlist.
cp "$DIST/REPRODUCIBILITY/left.producer-descriptor.json" "$TMP/left-descriptor.valid"
cp "$DIST/REPRODUCIBILITY/left.provenance.bundle.json" "$TMP/left-bundle.valid"
cp "$DIST/REPRODUCIBILITY.json" "$TMP/reproducibility-workflow.valid"
cp "$DIST/SHA256SUMS" "$TMP/dist-workflow-SHA256SUMS.valid"
python3 - "$DIST" <<'PY_WORKFLOW'
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
descriptor_path = root / "REPRODUCIBILITY/left.producer-descriptor.json"
bundle_path = root / "REPRODUCIBILITY/left.provenance.bundle.json"
reproduction_path = root / "REPRODUCIBILITY.json"
descriptor = json.loads(descriptor_path.read_text())
descriptor["workflow"] = "tifycloud/NexaWrt/.github/workflows/evil.yml"
descriptor_path.write_text(json.dumps(descriptor, sort_keys=True, separators=(",", ":")) + "\n")
descriptor_sha = hashlib.sha256(descriptor_path.read_bytes()).hexdigest()
bundle_path.write_text(f"descriptor_sha256={descriptor_sha}\n")
bundle_sha = hashlib.sha256(bundle_path.read_bytes()).hexdigest()
reproduction = json.loads(reproduction_path.read_text())
item = reproduction["input_builds"][0]
item["producer_descriptor_sha256"] = descriptor_sha
item["provenance_bundle_sha256"] = bundle_sha
item["producer_id"] = f"github-artifact:{item['artifact_id']}:bundle-sha256:{bundle_sha}"
reproduction_path.write_text(json.dumps(reproduction, sort_keys=True, separators=(",", ":")) + "\n")
PY_WORKFLOW
write_dist_checksums "$DIST"
expect_gate_failure 'untrusted producer workflow rebound into final verified-dist'
cp "$TMP/left-descriptor.valid" "$DIST/REPRODUCIBILITY/left.producer-descriptor.json"
cp "$TMP/left-bundle.valid" "$DIST/REPRODUCIBILITY/left.provenance.bundle.json"
cp "$TMP/reproducibility-workflow.valid" "$DIST/REPRODUCIBILITY.json"
cp "$TMP/dist-workflow-SHA256SUMS.valid" "$DIST/SHA256SUMS"

if NEXAWRT_MAX_APPROVAL_AGE_SECONDS=2592001 \
  "$VERIFY_HARDWARE" "$TMP/evidence" "$DIST" "$TMP/allowed_signers" >/dev/null 2>&1; then
  fail 'approval age limit was allowed to exceed the production maximum'
fi

# The UART transcript must prove the exact conditional hash invocation succeeded; result variables alone are insufficient.
cp "$TMP/evidence/uart-cold-boot.log" "$TMP/uart.valid"
awk '!/^IPQ807x# if hash / && !/^NEXAWRT_HASH_EXECUTION=/' "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'UART result variables without hash execution'
awk '!/^IPQ807x# if hash /' "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'standalone UART hash success marker'
sed 's/hash sha256 ${loadaddr} ${filesize} nexawrt_image_sha256/hash sha256 ${loadaddr} ${filesize} attacker_sha256/' "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'wrong UART hash invocation'
awk '{ if ($0 == "NEXAWRT_HASH_EXECUTION=success") print "NEXAWRT_HASH_EXECUTION=failure"; else print }' "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'failed UART hash execution'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"
printf '%s\n' 'IPQ807x# if hash sha256 ${loadaddr} ${filesize} nexawrt_image_sha256; then echo NEXAWRT_HASH_EXECUTION=success; else echo NEXAWRT_HASH_EXECUTION=failure; fi' >> "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'duplicate UART hash invocation'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"

# Each UART field is independently bound to the verified image, session, and production ethaddr.
sed "s/nexawrt_image_sha256=$sha/nexawrt_image_sha256=1111111111111111111111111111111111111111111111111111111111111111/" "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'wrong UART image SHA'
sed "s/nexawrt_image_size_hex=$image_size_hex/nexawrt_image_size_hex=ff/" "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'wrong UART image size'
sed "s/nexawrt_session_id=$SESSION/nexawrt_session_id=1111111111111111111111111111111111111111111111111111111111111111/" "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'wrong UART session'
sed "s/ethaddr=$ETHADDR/ethaddr=00:11:22:33:44:66/" "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'wrong UART ethaddr'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"; printf 'nexawrt_image_sha256=%s\n' "$sha" >> "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'duplicate UART image SHA'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"; printf 'nexawrt_image_size_hex=%s\n' "$image_size_hex" >> "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'duplicate UART image size'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"; printf 'nexawrt_session_id=%s\n' "$SESSION" >> "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'duplicate UART session'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"; printf 'ethaddr=%s\n' "$ETHADDR" >> "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'duplicate UART ethaddr'
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"

# ram-boot.log is parsed as a single exact identity section and cannot be spliced across sessions/devices.
cp "$TMP/evidence/ram-boot.log" "$TMP/ram.valid"
sed "s/session_id=$SESSION/session_id=1111111111111111111111111111111111111111111111111111111111111111/" "$TMP/ram.valid" > "$TMP/evidence/ram-boot.log"
refresh_approval; expect_gate_failure 'wrong RAM boot session'
sed "s/ethaddr=$ETHADDR/ethaddr=00:11:22:33:44:66/" "$TMP/ram.valid" > "$TMP/evidence/ram-boot.log"
refresh_approval; expect_gate_failure 'wrong RAM boot ethaddr'
sed "s/device_fingerprint_sha256=$FINGERPRINT/device_fingerprint_sha256=2222222222222222222222222222222222222222222222222222222222222222/" "$TMP/ram.valid" > "$TMP/evidence/ram-boot.log"
refresh_approval; expect_gate_failure 'wrong RAM boot fingerprint'
cat "$TMP/ram.valid" "$TMP/ram.valid" > "$TMP/evidence/ram-boot.log"
refresh_approval; expect_gate_failure 'concatenated RAM boot logs'
cp "$TMP/ram.valid" "$TMP/evidence/ram-boot.log"
printf 'session_id=%s\nethaddr=%s\ndevice_fingerprint_sha256=%s\n' "$SESSION" "$ETHADDR" "$FINGERPRINT" >> "$TMP/evidence/ram-boot.log"
refresh_approval; expect_gate_failure 'partially spliced RAM boot identity'
cp "$TMP/ram.valid" "$TMP/evidence/ram-boot.log"

# Strict schemas reject extra/duplicated runtime fields even when the payload is re-signed.
cp "$TMP/evidence/device.txt" "$TMP/device.valid"
printf 'unexpected=value\n' >> "$TMP/evidence/device.txt"
refresh_approval; expect_gate_failure 'extra device schema field'
cp "$TMP/device.valid" "$TMP/evidence/device.txt"
cp "$TMP/evidence/runtime-gate.txt" "$TMP/runtime.valid"
printf 'session_id=%s\n' "$SESSION" >> "$TMP/evidence/runtime-gate.txt"
refresh_approval; expect_gate_failure 'duplicate runtime session field'
cp "$TMP/runtime.valid" "$TMP/evidence/runtime-gate.txt"

# Production U-Boot identity must calculate the same fingerprint as runtime/stress evidence.
cp "$TMP/evidence/uboot-printenv-before.txt" "$TMP/env-before.valid"
cp "$TMP/evidence/uboot-printenv-after.txt" "$TMP/env-after.valid"
printf 'bootcmd=boot_stock\nethaddr=00:11:22:33:44:66\n' > "$TMP/evidence/uboot-printenv-before.txt"
cp "$TMP/evidence/uboot-printenv-before.txt" "$TMP/evidence/uboot-printenv-after.txt"
sed 's/ethaddr=00:11:22:33:44:55/ethaddr=00:11:22:33:44:66/' "$TMP/uart.valid" > "$TMP/evidence/uart-cold-boot.log"
refresh_approval; expect_gate_failure 'production/runtime device splice'
cp "$TMP/env-before.valid" "$TMP/evidence/uboot-printenv-before.txt"
cp "$TMP/env-after.valid" "$TMP/evidence/uboot-printenv-after.txt"
cp "$TMP/uart.valid" "$TMP/evidence/uart-cold-boot.log"

# The approval parser must reject a trusted signature over contradictory duplicate fields.
refresh_approval
printf 'decision=rejected\n' >> "$TMP/evidence/APPROVAL.txt"
rm -f "$TMP/evidence/APPROVAL.txt.sig"
ssh-keygen -q -Y sign -f "$TMP/reviewer-key" -n nexawrt-hardware-approval "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && sha256sum "${required_files[@]}") > "$TMP/evidence/SHA256SUMS"
expect_gate_failure 'trusted signature over contradictory approval fields'

# Exact approval schema and freshness apply even to content signed by a trusted reviewer.
# Replacing a dual-build receipt digest invalidates the candidate even if evidence is re-approved.
cp "$DIST/REPRODUCIBILITY.json" "$TMP/REPRODUCIBILITY.valid"
cp "$DIST/SHA256SUMS" "$TMP/dist-SHA256SUMS.valid"
python3 - "$DIST/REPRODUCIBILITY.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["input_builds"][0]["receipt_sha256"] = "0" * 64
path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")
PY
write_dist_checksums "$DIST"
refresh_approval
expect_gate_failure 'replaced reproducibility input receipt digest'
cp "$TMP/REPRODUCIBILITY.valid" "$DIST/REPRODUCIBILITY.json"
cp "$TMP/dist-SHA256SUMS.valid" "$DIST/SHA256SUMS"

refresh_approval
printf 'unexpected=value\n' >> "$TMP/evidence/APPROVAL.txt"
rm -f "$TMP/evidence/APPROVAL.txt.sig"
ssh-keygen -q -Y sign -f "$TMP/reviewer-key" -n nexawrt-hardware-approval "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && sha256sum "${required_files[@]}") > "$TMP/evidence/SHA256SUMS"
expect_gate_failure 'trusted signature over extra approval field'

# A trusted signature over the legacy, partially bound approval schema must fail closed.
refresh_approval
grep -E '^(decision|reviewer|reviewed_utc|firmware_sha256|evidence_sha256)=' "$TMP/evidence/APPROVAL.txt" > "$TMP/legacy-approval"
mv "$TMP/legacy-approval" "$TMP/evidence/APPROVAL.txt"
rm -f "$TMP/evidence/APPROVAL.txt.sig"
ssh-keygen -q -Y sign -f "$TMP/reviewer-key" -n nexawrt-hardware-approval "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && sha256sum "${required_files[@]}") > "$TMP/evidence/SHA256SUMS"
expect_gate_failure 'approval omitted verified-dist receipt binding'

refresh_approval
sed -i.bak 's/^reviewed_utc=.*/reviewed_utc=2000-01-01T00:00:00Z/'  "$TMP/evidence/APPROVAL.txt"; rm "$TMP/evidence/APPROVAL.txt.bak"
rm -f "$TMP/evidence/APPROVAL.txt.sig"
ssh-keygen -q -Y sign -f "$TMP/reviewer-key" -n nexawrt-hardware-approval "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && sha256sum "${required_files[@]}") > "$TMP/evidence/SHA256SUMS"
expect_gate_failure 'trusted but stale approval'

refresh_approval
cp "$DIST/SHA256SUMS" "$DIST/SHA256SUMS.saved"
grep -v 'BUILD-MANIFEST.txt$' "$DIST/SHA256SUMS.saved" > "$DIST/SHA256SUMS"
expect_gate_failure 'unbound build manifest'
mv "$DIST/SHA256SUMS.saved" "$DIST/SHA256SUMS"

sed -i.bak 's/stress_24h=pass/stress_24h=fail/' "$TMP/evidence/stress-gate.txt"; rm "$TMP/evidence/stress-gate.txt.bak"
refresh_approval; expect_gate_failure 'failed stress gate'
sed -i.bak 's/stress_24h=fail/stress_24h=pass/' "$TMP/evidence/stress-gate.txt"; rm "$TMP/evidence/stress-gate.txt.bak"

refresh_approval
printf 'unexpected=value\n' >> "$TMP/evidence/APPROVAL.txt"
(cd "$TMP/evidence" && sha256sum "${required_files[@]}") > "$TMP/evidence/SHA256SUMS"
expect_gate_failure 'forged approval content'

refresh_approval
grep -v 'thermal.log$' "$TMP/evidence/SHA256SUMS" > "$TMP/incomplete-sums"
mv "$TMP/incomplete-sums" "$TMP/evidence/SHA256SUMS"
expect_gate_failure 'incomplete checksum coverage'

echo 'hardware gate binds dual-build receipts, repository locks, exact artifacts, approval metadata, session/device/UART/stress/post-reboot identity: OK'
