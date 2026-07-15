#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EVIDENCE_DIR="${1:-}"
DIST_DIR="${2:-}"
TRUSTED_REVIEWERS="${3:-${NEXAWRT_TRUSTED_REVIEWERS:-}}"
COMPARE_SCRIPT="$ROOT_DIR/scripts/compare-reproducible-builds.sh"
SIGNATURE_NAMESPACE='nexawrt-hardware-approval'
DEFAULT_MAX_APPROVAL_AGE_SECONDS=2592000
MAX_APPROVAL_AGE_SECONDS="${NEXAWRT_MAX_APPROVAL_AGE_SECONDS:-$DEFAULT_MAX_APPROVAL_AGE_SECONDS}"
fail() { echo "hardware gate failed: $*" >&2; exit 1; }
[[ -d "$EVIDENCE_DIR" && -d "$DIST_DIR" && -f "$TRUSTED_REVIEWERS" ]] ||
  fail "usage: $0 EVIDENCE_DIR DIST_DIR TRUSTED_REVIEWERS_ALLOWED_SIGNERS"
[[ ! -L "$EVIDENCE_DIR" && ! -L "$DIST_DIR" && ! -L "$TRUSTED_REVIEWERS" ]] ||
  fail "evidence, distribution, and trusted reviewer paths must not be symlinks"
[[ "$MAX_APPROVAL_AGE_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "approval age limit must be a positive integer"
(( MAX_APPROVAL_AGE_SECONDS <= DEFAULT_MAX_APPROVAL_AGE_SECONDS )) ||
  fail "approval age limit may be shortened but not extended beyond $DEFAULT_MAX_APPROVAL_AGE_SECONDS seconds"
command -v ssh-keygen >/dev/null || fail "ssh-keygen with SSH signature support is required"
[[ -f "$COMPARE_SCRIPT" && ! -L "$COMPARE_SCRIPT" ]] || fail "reproducibility verifier is missing or unsafe"
candidate_metadata="$(bash "$COMPARE_SCRIPT" --verify-verified-dist "$DIST_DIR")" ||
  fail "candidate is not a repository-locked compare-generated verified-dist"
[[ -n "$candidate_metadata" ]] || fail "verified candidate metadata is empty"
python3 - "$DIST_DIR/REPRODUCIBILITY.json" <<'PY' || fail "candidate lacks two distinct descriptor-bound GitHub-attested producer identities"
import json
import pathlib
import re
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if value.get("schema") != 4:
    raise SystemExit(1)
items = value.get("input_builds")
if not isinstance(items, list) or len(items) != 2:
    raise SystemExit(1)
pattern = re.compile(r"github-artifact:[1-9][0-9]*:bundle-sha256:[0-9a-f]{64}")
producer_ids = [item.get("producer_id") for item in items if isinstance(item, dict)]
if len(producer_ids) != 2 or len(set(producer_ids)) != 2 or any(not isinstance(item, str) or not pattern.fullmatch(item) for item in producer_ids):
    raise SystemExit(1)
PY

payload_files=(
  SESSION.txt
  CANDIDATE.txt
  device.txt
  uart-cold-boot.log
  uboot-help.txt
  uboot-printenv-before.txt
  uboot-printenv-after.txt
  production-cmdline-before.txt
  production-cmdline-after.txt
  production-capture-before.txt
  production-capture-after.txt
  mtd-layout-before.txt
  mtd-layout-after.txt
  production-identity-before.txt
  production-identity-after.txt
  ram-boot.log
  runtime-gate.txt
  post-reboot-gate.txt
  stress-gate.txt
  stress-24h.log
  network-regression.log
  thermal.log
  kernel-health.log
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
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/verify-post-reboot-state.sh" \
  "$EVIDENCE_DIR" --check-only >/dev/null || fail "post-reboot raw state comparison failed"
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/verify-stress-evidence.sh" \
  "$EVIDENCE_DIR" >/dev/null || fail "24-hour stress evidence verification failed"

printf '%s\n' "$candidate_metadata" | cmp -s - "$EVIDENCE_DIR/CANDIDATE.txt" ||
  fail "hardware session candidate metadata does not match the selected verified-dist"
image_sha="$(awk -F= '$1 == "firmware_sha256" { print $2 }' <<<"$candidate_metadata")"
image_size="$(awk -F= '$1 == "firmware_size" { print $2 }' <<<"$candidate_metadata")"
flavor="$(awk -F= '$1 == "flavor" { print $2 }' <<<"$candidate_metadata")"
case "$flavor" in official|nss) ;; *) fail "verified candidate flavor is invalid" ;; esac
probe_sha="$(sha256sum "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/ax9000-runtime-probe.sh" | awk '{print $1}')"
python3 - "$EVIDENCE_DIR" "$image_sha" "$image_size" "$flavor" "$probe_sha" <<'PY' || \
  fail "boot measurement, hardware session, runtime schema, or device identity binding failed"
import hashlib, pathlib, re, sys
root=pathlib.Path(sys.argv[1]); image_sha=sys.argv[2]; image_size=int(sys.argv[3]); flavor=sys.argv[4]; probe_sha=sys.argv[5]

def key_values(name, expected_keys=None):
    path=root / name
    values={}
    for line in path.read_text(encoding="utf-8", errors="strict").replace("\r\n", "\n").splitlines():
        if not line or "=" not in line: raise SystemExit(f"malformed field in {name}")
        key,value=line.split("=",1)
        if not key or key in values: raise SystemExit(f"duplicate field in {name}: {key}")
        values[key]=value
    if expected_keys is not None and set(values) != set(expected_keys):
        raise SystemExit(f"unexpected schema in {name}: {sorted(values)}")
    return values

session=key_values("SESSION.txt", {"session_id"})["session_id"]
if not re.fullmatch(r"[0-9a-f]{64}", session): raise SystemExit("invalid session ID")
device_keys={"model","image_sha256","flavor","probe_sha256","session_id","device_fingerprint_sha256"}
device=key_values("device.txt", device_keys)
base_runtime={
    "root","persistent_ubi_attached","persistent_mounts","all_mtd_partitions_readonly",
    "raw_mtd_write_probe","sysupgrade_guard_exit","factoryreset_guard_exit","firstboot_guard_exit",
    "jffs2reset_guard_exit","jffs2mark_guard_exit","mount_root_guard_exit","flavor","probe_sha256",
    "session_id","device_fingerprint_sha256","fw_printenv_available","uboot_env_write_tools",
}
runtime_keys=base_runtime | ({"nss_driver_loaded","nss_ecm_loaded","nss_firmware_present"} if flavor == "nss" else {"third_party_nss_components"})
runtime=key_values("runtime-gate.txt", runtime_keys)
expected_common={
    "root":"/dev/ram0", "persistent_ubi_attached":"no", "persistent_mounts":"no",
    "all_mtd_partitions_readonly":"yes", "raw_mtd_write_probe":"blocked",
    "sysupgrade_guard_exit":"74", "factoryreset_guard_exit":"74", "firstboot_guard_exit":"74",
    "jffs2reset_guard_exit":"74", "jffs2mark_guard_exit":"74", "mount_root_guard_exit":"74",
    "flavor":flavor, "probe_sha256":probe_sha, "session_id":session,
    "fw_printenv_available":"yes", "uboot_env_write_tools":"absent",
}
for key,value in expected_common.items():
    if runtime.get(key) != value: raise SystemExit(f"runtime mismatch: {key}")
if flavor == "nss":
    for key in ("nss_driver_loaded","nss_ecm_loaded","nss_firmware_present"):
        if runtime.get(key) != "yes": raise SystemExit(f"missing NSS runtime marker: {key}")
elif runtime.get("third_party_nss_components") != "absent":
    raise SystemExit("official runtime contains third-party NSS components")
if device != {
    "model":"xiaomi,ax9000", "image_sha256":image_sha, "flavor":flavor,
    "probe_sha256":probe_sha, "session_id":session,
    "device_fingerprint_sha256":runtime.get("device_fingerprint_sha256", ""),
}: raise SystemExit("device evidence schema or values mismatch")
fingerprint=device["device_fingerprint_sha256"]
if not re.fullmatch(r"[0-9a-f]{64}", fingerprint): raise SystemExit("invalid device fingerprint")

def env(name):
    values={}
    for line in (root/name).read_text(encoding="utf-8", errors="strict").replace("\r\n","\n").splitlines():
        line=line.strip()
        if not line or line.startswith("#"): continue
        if "=" not in line: raise SystemExit(f"malformed U-Boot environment: {name}")
        key,value=line.split("=",1)
        if not key or key in values: raise SystemExit(f"duplicate U-Boot environment key: {key}")
        values[key]=value
    return values
before=env("uboot-printenv-before.txt"); after=env("uboot-printenv-after.txt")
if before != after: raise SystemExit("U-Boot environment changed")
ethaddr=before.get("ethaddr", "").lower()
if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", ethaddr): raise SystemExit("stable U-Boot ethaddr is missing")
calculated=hashlib.sha256(f"xiaomi,ax9000\nethaddr={ethaddr}\n".encode()).hexdigest()
if calculated != fingerprint: raise SystemExit("runtime device differs from production device")
uart=(root/"uart-cold-boot.log").read_text(encoding="utf-8", errors="strict").replace("\r\n","\n")
def exactly_one(pattern, label):
    matches=list(re.finditer(pattern, uart, flags=re.MULTILINE))
    if len(matches) != 1: raise SystemExit(f"UART measurement count for {label} is {len(matches)}")
    return matches[0]
hash_command=(
    r"^(?:=>|[^\r\n]*[#>]) if hash sha256 \$\{loadaddr\} \$\{filesize\} "
    r"nexawrt_image_sha256; then echo NEXAWRT_HASH_EXECUTION=success; "
    r"else echo NEXAWRT_HASH_EXECUTION=failure; fi$"
)
hash_invocation=exactly_one(hash_command, "hash command")
hash_success=exactly_one(r"^NEXAWRT_HASH_EXECUTION=success$", "hash success")
if re.search(r"^NEXAWRT_HASH_EXECUTION=failure$", uart, flags=re.MULTILINE):
    raise SystemExit("U-Boot hash command reported failure")
image_match=exactly_one(r"^nexawrt_image_sha256=([0-9a-fA-F]{64})$", "image sha")
size_match=exactly_one(r"^nexawrt_image_size_hex=([0-9a-fA-F]+)$", "image size")
session_match=exactly_one(r"^nexawrt_session_id=([0-9a-f]{64})$", "session")
ethaddr_match=exactly_one(r"^ethaddr=([0-9a-fA-F:]{17})$", "ethaddr")
measurements=(image_match, size_match, session_match, ethaddr_match)
if not hash_invocation.end() < hash_success.start() or any(match.start() <= hash_success.start() for match in measurements):
    raise SystemExit("UART measured values do not follow a successful hash execution")
if image_match.group(1).lower() != image_sha:
    raise SystemExit("bootloader measured a different image")
if int(size_match.group(1), 16) != image_size: raise SystemExit("bootloader measured a different image size")
if session_match.group(1) != session:
    raise SystemExit("UART session differs from runtime session")
if ethaddr_match.group(1).lower() != ethaddr:
    raise SystemExit("UART device differs from production/runtime device")

ram=(root/"ram-boot.log").read_text(encoding="utf-8", errors="strict").replace("\r\n","\n").splitlines()
identity_header="=== hardware session and identity ==="
header_indexes=[index for index,line in enumerate(ram) if line == identity_header]
if len(header_indexes) != 1: raise SystemExit("RAM boot identity section is missing, duplicated, or concatenated")
start=header_indexes[0] + 1
end=next((index for index in range(start, len(ram)) if re.fullmatch(r"=== .+ ===", ram[index])), len(ram))
expected_ram_identity=[
    f"session_id={session}",
    f"ethaddr={ethaddr}",
    f"device_fingerprint_sha256={fingerprint}",
]
if ram[start:end] != expected_ram_identity:
    raise SystemExit("RAM boot log belongs to a different session/device or has an invalid identity section")
for prefix in ("session_id=", "ethaddr=", "device_fingerprint_sha256="):
    if sum(line.startswith(prefix) for line in ram) != 1:
        raise SystemExit(f"RAM boot identity field is missing, duplicated, or spliced: {prefix}")
post=key_values("post-reboot-gate.txt", {"reboot_to_production","session_id","device_fingerprint_sha256","mtd_layout_unchanged","uboot_env_unchanged"})
if post != {
    "reboot_to_production":"pass", "session_id":session, "device_fingerprint_sha256":fingerprint,
    "mtd_layout_unchanged":"pass", "uboot_env_unchanged":"pass",
}: raise SystemExit("post-reboot gate belongs to a different session/device or has an invalid schema")
PY
for marker in 'reboot_to_production=pass' 'mtd_layout_unchanged=pass' 'uboot_env_unchanged=pass'; do
  grep -Fxq "$marker" "$EVIDENCE_DIR/post-reboot-gate.txt" || fail "post-reboot gate marker missing: $marker"
done
for marker in 'stress_24h=pass' 'network_regression=pass' 'panic_oops=none' 'thermal_throttle=none'; do
  grep -Fxq "$marker" "$EVIDENCE_DIR/stress-gate.txt" || fail "stress gate marker missing: $marker"
done

payload_manifest="$(cd "$EVIDENCE_DIR" && sha256sum "${payload_files[@]}")"
evidence_sha="$(printf '%s\n' "$payload_manifest" | sha256sum | awk '{print $1}')"
approval="$EVIDENCE_DIR/APPROVAL.txt"
approval_identity="$(python3 - "$approval" "$evidence_sha" "$EVIDENCE_DIR/CANDIDATE.txt" <<'PY'
import pathlib, re, sys
approval_path=pathlib.Path(sys.argv[1]); expected_evidence=sys.argv[2]; candidate_path=pathlib.Path(sys.argv[3])

def parse(path):
    values={}
    for line in path.read_text(encoding="utf-8", errors="strict").splitlines():
        if not line or "=" not in line: raise SystemExit(1)
        key,value=line.split("=",1)
        if not key or key in values or value == "": raise SystemExit(1)
        values[key]=value
    return values

candidate=parse(candidate_path)
candidate_keys={
    "schema", "flavor", "firmware_filename", "firmware_sha256", "firmware_size",
    "verified_dist_sha256sums_sha256", "reproducibility_sha256", "build_manifest_sha256",
    "repository_inputs_sha256", "comparison_receipt_sha256",
}
if set(candidate) != candidate_keys or candidate["schema"] != "1": raise SystemExit(1)
values=parse(approval_path)
expected_keys={
    "decision", "reviewer", "reviewed_utc", "evidence_sha256", "candidate_schema",
    "flavor", "firmware_filename", "firmware_sha256", "firmware_size",
    "verified_dist_sha256sums_sha256", "reproducibility_sha256", "build_manifest_sha256",
    "repository_inputs_sha256", "comparison_receipt_sha256",
}
if set(values) != expected_keys: raise SystemExit(1)
if values["decision"] != "approved-for-ram-boot-only" or values["evidence_sha256"] != expected_evidence:
    raise SystemExit(1)
if values["candidate_schema"] != candidate["schema"]: raise SystemExit(1)
for key in candidate_keys - {"schema"}:
    if values[key] != candidate[key]: raise SystemExit(1)
if not re.fullmatch(r"[^\s]+", values["reviewer"]): raise SystemExit(1)
print(values["reviewer"] + "\t" + values["reviewed_utc"])
PY
)" || fail "approval schema is ambiguous, incomplete, or not bound to this exact verified-dist receipt and evidence"
IFS=$'\t' read -r reviewer reviewed_utc <<<"$approval_identity"
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
echo 'hardware gate: signed approval verified for this exact repository-locked reproducible verified-dist, receipt, and evidence payload, RAM boot only'
