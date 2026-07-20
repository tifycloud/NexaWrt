#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/vm-promote.yml"
SCHEMA="$ROOT_DIR/schemas/vm-esxi-evidence.schema.json"
VERIFIER="$ROOT_DIR/scripts/verify-vm-esxi-evidence.py"
DOC="$ROOT_DIR/docs/VM-ESXI-ACCEPTANCE.md"

fail() {
  printf 'vm promotion policy test failed: %s\n' "$*" >&2
  exit 1
}

for file in "$WORKFLOW" "$SCHEMA" "$VERIFIER" "$DOC"; do
  test -s "$file" || fail "missing required file: $file"
done
test -x "$VERIFIER" || fail "verifier must be executable"

python3 - "$SCHEMA" "$VERIFIER" "$WORKFLOW" <<'PY'
import json
import re
import sys
from pathlib import Path

schema_path, verifier_path, workflow_path = map(Path, sys.argv[1:])
schema = json.loads(schema_path.read_text(encoding="utf-8"))
if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("schema must declare JSON Schema 2020-12")
if schema.get("additionalProperties") is not False:
    raise SystemExit("top-level schema must reject unknown fields")
compile(verifier_path.read_text(encoding="utf-8"), str(verifier_path), "exec")
workflow = workflow_path.read_text(encoding="utf-8")
uses = re.findall(r"(?m)^\s*-?\s*uses:\s*([^\s#]+)", workflow)
if not uses:
    raise SystemExit("workflow must use a pinned checkout action")
for use in uses:
    if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", use):
        raise SystemExit(f"workflow action is not pinned to a full SHA: {use}")
if "require_missing" in workflow:
    raise SystemExit("promotion must not reject a strictly matching retryable draft")
markers = [
    "Existing stable release identity does not exactly match",
    "Stable draft changed before asset reset; refusing to delete anything",
    "--method DELETE",
    "Upload the unchanged RC asset bytes to the empty stable draft",
    'cmp -s "$RC_DIR/$asset_name" "$STABLE_DIR/$asset_name"',
    '--method PATCH "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID"',
]
positions = [workflow.find(marker) for marker in markers]
if any(position < 0 for position in positions) or positions != sorted(positions):
    raise SystemExit("trusted identity check, reset, upload, compare, publish ordering is not fail-closed")
if workflow.count('.target_commitish == $expected[0].target_commitish') < 6:
    raise SystemExit("stable target/source identity is not rechecked at every mutation boundary")
if workflow.count('.body == $expected[0].body') < 6:
    raise SystemExit("stable source notes are not rechecked at every mutation boundary")
PY

required_workflow_patterns=(
  'workflow_dispatch:'
  'rc_tag:'
  'evidence_path:'
  'permissions: {}'
  "github.ref == 'refs/heads/main'"
  "github.repository == 'tifycloud/NexaWrt'"
  'contents: write'
  'persist-credentials: false'
  'immutable-releases'
  'source release must be a published prerelease'
  'source RC release is not immutable'
  'RC release does not contain exactly 21 assets'
  'scripts/verify-vm-esxi-evidence.py'
  'sha256sum --check SHA256SUMS'
  'cmp -s "$RC_DIR/$asset_name" "$STABLE_DIR/$asset_name"'
  'stable_tag="vm-x86_64-${stable_version}"'
  'draft:true,prerelease:false'
  "'{draft:false,prerelease:false,make_latest:\"true\"}'"
  'No firmware or VM image was rebuilt.'
  'Real VMware ESXi validation scope'
  'not Xiaomi AX9000 firmware or AX9000 hardware validation'
  'Create or resume only the strictly matching stable draft'
  'releases?per_page=100'
  'multiple releases claim the stable tag; refusing recovery'
  'Existing stable tag does not point to the exact RC commit; refusing recovery'
  'Existing stable release has no matching stable tag; refusing recovery'
  'Existing stable release identity does not exactly match this RC/evidence run; refusing recovery'
  '.target_commitish == $expected[0].target_commitish'
  '.name == $expected[0].name'
  '.body == $expected[0].body'
  '.draft == true'
  '.prerelease == false'
  'Reset only the trusted stable draft assets for an idempotent retry'
  'Stable draft changed before asset reset; refusing to delete anything'
  'repos/$GITHUB_REPOSITORY/releases/assets/$asset_id'
  'stable-assets-after-reset.txt'
  'test ! -s "$RUNNER_TEMP/stable-assets-after-reset.txt"'
  'Upload the unchanged RC asset bytes to the empty stable draft'
  'stable draft asset ids/names changed after byte comparison'
)
for pattern in "${required_workflow_patterns[@]}"; do
  grep -Fq -- "$pattern" "$WORKFLOW" || fail "workflow missing policy text: $pattern"
done

if grep -Eq 'scripts/build-vm-image\.sh|qemu-system|docker[[:space:]]+build|(^|[[:space:]])make([[:space:]]|$)' "$WORKFLOW"; then
  fail "promotion workflow must not build, convert, or QEMU-test images"
fi
if grep -Eq 'id-token:|attestations:|packages:|actions:[[:space:]]+write|security-events:' "$WORKFLOW"; then
  fail "promotion workflow requests permissions outside the minimal contents write scope"
fi

required_schema_patterns=(
  '"additionalProperties": false'
  '"performed_by_human": { "const": true }'
  '"assets"'
  '"minItems": 21'
  '"maxItems": 21'
  '"vmdk_import"'
  '"two_nics"'
  '"https"'
  '"http_redirect"'
  '"firewall"'
  '"wan_dhcp"'
  '"lan_dhcp"'
  '"nat"'
  '"dns"'
  '"persistence"'
  '"installation_id_before"'
  '"configuration_sha256_before"'
)
for pattern in "${required_schema_patterns[@]}"; do
  grep -Fq -- "$pattern" "$SCHEMA" || fail "schema missing required policy: $pattern"
done

grep -Fq '自动化、维护者或 AI 不得' "$DOC" || fail "documentation must prohibit fabricated evidence"
grep -Fq '删除该可信草稿内的**全部已有资产**' "$DOC" || fail "documentation must describe idempotent asset reset"
grep -Fq 'Release 存在但 tag 不存在' "$DOC" || fail "documentation must describe mismatched-object rejection"
grep -Fq 'Re-run failed jobs' "$DOC" || fail "documentation must describe safe same-run retry"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
REPO="$TMP_DIR/repo"
RELEASE_DIR="$TMP_DIR/release"
mkdir -p "$REPO/evidence/vm-esxi" "$REPO/schemas" "$RELEASE_DIR"
cp "$SCHEMA" "$REPO/schemas/vm-esxi-evidence.schema.json"
git -C "$REPO" init -q
git -C "$REPO" config user.name 'NexaWrt policy test'
git -C "$REPO" config user.email 'policy-test@example.invalid'

RC_TAG='vm-x86_64-v1.2.3-rc.4'
VERSION='v1.2.3-rc.4'
RC_COMMIT='0123456789abcdef0123456789abcdef01234567'
EVIDENCE_REL='evidence/vm-esxi/v1.2.3-rc.4.json'

python3 - "$RELEASE_DIR" "$REPO/$EVIDENCE_REL" "$RC_TAG" "$VERSION" "$RC_COMMIT" "$TMP_DIR/timestamps.env" <<'PY'
import datetime as dt
import hashlib
import json
import sys
from pathlib import Path

release_dir, evidence_path, rc_tag, version, rc_commit, timestamps_path = sys.argv[1:]
release_dir = Path(release_dir)
evidence_path = Path(evidence_path)
prefix = f"NexaWrt-x86_64-{version}"
raw = f"{prefix}-generic-ext4-combined.img.gz"
iso_bios = f"{prefix}-generic-image.iso"
iso_efi = f"{prefix}-generic-image-efi.iso"
vmdk_bios = f"{prefix}-generic-ext4-combined.vmdk"
vmdk_efi = f"{prefix}-generic-ext4-combined-efi.vmdk"
manifest = f"{prefix}-generic.manifest"
images = [raw, iso_bios, iso_efi, vmdk_bios, vmdk_efi]
base = images + [
    manifest,
    "artifact-labels.env",
    "README-VM.txt",
    "smoke-report.txt",
    "raw-bios.provenance.bundle.json",
    "iso-bios.provenance.bundle.json",
    "iso-efi.provenance.bundle.json",
    "vmdk-bios.provenance.bundle.json",
    "vmdk-efi.provenance.bundle.json",
    "checksums.provenance.bundle.json",
]
for index, name in enumerate(base, 1):
    content = f"fixture:{index}:{name}\n".encode()
    if name == "artifact-labels.env":
        content = (
            'ARTIFACT_CLASS="x86_64-vm"\n'
            'RELEASE_CONTRACT="vm-x86_64/v2"\n'
            f'RELEASE_TAG="{rc_tag}"\n'
            f'RELEASE_VERSION="{version}"\n'
            f'PROJECT_COMMIT="{rc_commit}"\n'
        ).encode()
    (release_dir / name).write_bytes(content)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

for name in images:
    (release_dir / f"{name}.sha256").write_text(f"{digest(release_dir / name)}  {name}\n", encoding="utf-8")

ordered = [
    raw, f"{raw}.sha256",
    iso_bios, f"{iso_bios}.sha256",
    iso_efi, f"{iso_efi}.sha256",
    vmdk_bios, f"{vmdk_bios}.sha256",
    vmdk_efi, f"{vmdk_efi}.sha256",
    manifest, "artifact-labels.env", "README-VM.txt", "smoke-report.txt",
]
(release_dir / "SHA256SUMS").write_text(
    "".join(f"{digest(release_dir / name)}  {name}\n" for name in ordered),
    encoding="utf-8",
)
assets = ordered + [
    "SHA256SUMS",
    "raw-bios.provenance.bundle.json",
    "iso-bios.provenance.bundle.json",
    "iso-efi.provenance.bundle.json",
    "vmdk-bios.provenance.bundle.json",
    "vmdk-efi.provenance.bundle.json",
    "checksums.provenance.bundle.json",
]
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
published = now - dt.timedelta(hours=1)
fmt = lambda value: value.isoformat().replace("+00:00", "Z")
evidence = {
    "schema_version": 1,
    "evidence_type": "nexawrt-vm-esxi-acceptance",
    "rc_tag": rc_tag,
    "rc_commit": rc_commit,
    "release_version": version,
    "release_contract": "vm-x86_64/v2",
    "tested_at": fmt(now),
    "tester": {"github_login": "fixture-tester", "performed_by_human": True},
    "esxi": {
        "version": "8.0 U3",
        "build": "fixture-build",
        "host_model": "fixture-host",
        "virtual_hardware_version": "vmx-21",
        "firmware": "bios",
        "disk_controller": "LSI Logic SAS",
        "network_adapter_model": "vmxnet3",
        "memory_mb": 1024,
        "vcpu_count": 2,
    },
    "assets": [
        {"name": name, "sha256": digest(release_dir / name), "size": (release_dir / name).stat().st_size}
        for name in assets
    ],
    "checks": {
        "vmdk_import": {
            "passed": True,
            "asset_name": vmdk_bios,
            "datastore_disk_created": True,
            "powered_on": True,
        },
        "two_nics": {
            "passed": True,
            "nic_count": 2,
            "lan_interface": "eth0",
            "wan_interface": "eth1",
            "lan_port_group": "NexaWrt-LAN",
            "wan_port_group": "WAN",
        },
        "https": {
            "passed": True,
            "url": "https://192.168.8.1/cgi-bin/luci/",
            "status_code": 200,
            "certificate_sha256": "a" * 64,
        },
        "http_redirect": {
            "passed": True,
            "url": "http://192.168.8.1/",
            "status_code": 302,
            "location": "https://192.168.8.1/",
        },
        "firewall": {
            "passed": True,
            "enabled": True,
            "running": True,
            "wan_management_blocked": True,
        },
        "wan_dhcp": {
            "passed": True,
            "interface": "eth1",
            "address": "192.0.2.10",
            "gateway": "192.0.2.1",
        },
        "lan_dhcp": {
            "passed": True,
            "interface": "eth0",
            "client_mac": "02:00:00:00:00:02",
            "client_address": "192.168.8.100",
            "lease_obtained": True,
        },
        "nat": {
            "passed": True,
            "client_address": "192.168.8.100",
            "destination": "198.51.100.10",
            "client_reached_wan": True,
        },
        "dns": {
            "passed": True,
            "client_address": "192.168.8.100",
            "query_name": "example.com",
            "resolved_addresses": ["93.184.216.34"],
        },
        "persistence": {
            "passed": True,
            "reboot_count": 1,
            "installation_id_before": "0123456789abcdef0123456789abcdef",
            "installation_id_after": "0123456789abcdef0123456789abcdef",
            "configuration_sha256_before": "b" * 64,
            "configuration_sha256_after": "b" * 64,
            "hostname_before": "nexawrt-vm",
            "hostname_after": "nexawrt-vm",
            "lan_address_before": "192.168.8.1",
            "lan_address_after": "192.168.8.1",
        },
    },
}
evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
Path(timestamps_path).write_text(f"RC_PUBLISHED_AT={fmt(published)}\n", encoding="utf-8")
PY
# shellcheck disable=SC1090
source "$TMP_DIR/timestamps.env"
cp "$REPO/$EVIDENCE_REL" "$TMP_DIR/valid-evidence.json"
git -C "$REPO" add "$EVIDENCE_REL" schemas/vm-esxi-evidence.schema.json
git -C "$REPO" commit -qm 'add real-fixture evidence shape'

verify=(
  python3 "$VERIFIER"
  --schema schemas/vm-esxi-evidence.schema.json
  --evidence "$EVIDENCE_REL"
  --repo-root "$REPO"
  --release-dir "$RELEASE_DIR"
  --rc-tag "$RC_TAG"
  --rc-commit "$RC_COMMIT"
  --rc-published-at "$RC_PUBLISHED_AT"
)
"${verify[@]}" | grep -Fq '"status":"PASS"' || fail "valid fixture was rejected"

commit_fixture() {
  cp "$1" "$REPO/$EVIDENCE_REL"
  git -C "$REPO" add "$EVIDENCE_REL"
  git -C "$REPO" commit -qm "$2"
}

expect_rejected() {
  local label="$1"
  shift
  if "$@" >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
    fail "$label was unexpectedly accepted"
  fi
  grep -Fq 'ESXi evidence verification failed:' "$TMP_DIR/$label.err" || fail "$label did not fail closed"
}

python3 - "$TMP_DIR/valid-evidence.json" "$TMP_DIR/unknown.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
value["unknown_field"] = "must be rejected"
json.dump(value, open(sys.argv[2], "w"), indent=2)
PY
commit_fixture "$TMP_DIR/unknown.json" 'negative unknown field'
expect_rejected unknown-field "${verify[@]}"

python3 - "$TMP_DIR/valid-evidence.json" "$TMP_DIR/false-check.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
value["checks"]["firewall"]["passed"] = False
json.dump(value, open(sys.argv[2], "w"), indent=2)
PY
commit_fixture "$TMP_DIR/false-check.json" 'negative false check'
expect_rejected false-check "${verify[@]}"

python3 - "$TMP_DIR/valid-evidence.json" "$TMP_DIR/persistence.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
value["checks"]["persistence"]["installation_id_after"] = "f" * 32
json.dump(value, open(sys.argv[2], "w"), indent=2)
PY
commit_fixture "$TMP_DIR/persistence.json" 'negative persistence mismatch'
expect_rejected persistence "${verify[@]}"

commit_fixture "$TMP_DIR/valid-evidence.json" 'restore valid evidence'
expect_rejected wrong-tag "${verify[@]/$RC_TAG/vm-x86_64-v1.2.3-rc.5}"
expect_rejected wrong-commit "${verify[@]/$RC_COMMIT/ffffffffffffffffffffffffffffffffffffffff}"

cp "$TMP_DIR/valid-evidence.json" "$REPO/evidence/vm-esxi/untracked.json"
expect_rejected untracked \
  python3 "$VERIFIER" --schema schemas/vm-esxi-evidence.schema.json --evidence evidence/vm-esxi/untracked.json \
  --repo-root "$REPO" --release-dir "$RELEASE_DIR" --rc-tag "$RC_TAG" \
  --rc-commit "$RC_COMMIT" --rc-published-at "$RC_PUBLISHED_AT"
expect_rejected unsafe-path \
  python3 "$VERIFIER" --schema schemas/vm-esxi-evidence.schema.json --evidence ../escape.json \
  --repo-root "$REPO" --release-dir "$RELEASE_DIR" --rc-tag "$RC_TAG" \
  --rc-commit "$RC_COMMIT" --rc-published-at "$RC_PUBLISHED_AT"

ln -s "$EVIDENCE_REL" "$REPO/evidence/vm-esxi/symlink.json"
git -C "$REPO" add evidence/vm-esxi/symlink.json
git -C "$REPO" commit -qm 'negative symlink evidence'
expect_rejected symlink \
  python3 "$VERIFIER" --schema schemas/vm-esxi-evidence.schema.json --evidence evidence/vm-esxi/symlink.json \
  --repo-root "$REPO" --release-dir "$RELEASE_DIR" --rc-tag "$RC_TAG" \
  --rc-commit "$RC_COMMIT" --rc-published-at "$RC_PUBLISHED_AT"

printf 'unexpected\n' > "$RELEASE_DIR/unexpected.asset"
expect_rejected extra-asset "${verify[@]}"
rm "$RELEASE_DIR/unexpected.asset"
mv "$RELEASE_DIR/checksums.provenance.bundle.json" "$TMP_DIR/missing.asset"
expect_rejected missing-asset "${verify[@]}"
mv "$TMP_DIR/missing.asset" "$RELEASE_DIR/checksums.provenance.bundle.json"

printf 'vm promotion policy tests: PASS\n'
