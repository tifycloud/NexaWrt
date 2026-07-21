#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/pages.yml"
GENERATOR="$ROOT_DIR/scripts/generate-pages-data.py"
PROOF_VERIFIER="$ROOT_DIR/scripts/verify-pages-releases.py"
PROOF_TEST="$ROOT_DIR/tests/test_pages_provenance.py"
DEVICE_VALIDATOR="$ROOT_DIR/scripts/device_metadata.py"
DEVICE_METADATA="$ROOT_DIR/devices/xiaomi-ax9000/device.json"
DEVICE_TEST="$ROOT_DIR/tests/test_device_metadata.py"
UI_TEST="$ROOT_DIR/tests/test_pages_ui.js"
SITE="$ROOT_DIR/site"
CATALOG="$ROOT_DIR/components/catalog.json"

for path in "$WORKFLOW" "$GENERATOR" "$PROOF_VERIFIER" "$PROOF_TEST" "$DEVICE_VALIDATOR" "$DEVICE_METADATA" "$DEVICE_TEST" "$UI_TEST" "$CATALOG" "$SITE/index.html" "$SITE/styles.css" "$SITE/app.js" "$SITE/favicon.svg" "$SITE/releases.json" "$SITE/.nojekyll"; do
  test -f "$path" || { echo "missing Pages file: $path" >&2; exit 1; }
done

test -x "$GENERATOR"
test -x "$PROOF_VERIFIER"
test -x "$PROOF_TEST"
test -x "$DEVICE_VALIDATOR"
test -x "$DEVICE_TEST"
python3 -m py_compile "$GENERATOR" "$PROOF_VERIFIER" "$PROOF_TEST" "$DEVICE_VALIDATOR" "$DEVICE_TEST"
python3 "$PROOF_TEST"
python3 "$DEVICE_TEST"
python3 "$DEVICE_VALIDATOR" --device xiaomi-ax9000 --flavor official --channel ram-test >/dev/null
python3 "$DEVICE_VALIDATOR" --device xiaomi-ax9000 --flavor nss --channel ram-test >/dev/null
if python3 "$DEVICE_VALIDATOR" --device xiaomi-ax9000 --flavor official --channel stable >/dev/null 2>&1; then
  echo 'device metadata validator unexpectedly accepted a stable channel' >&2
  exit 1
fi
grep -Fq '"X-GitHub-Api-Version": "2026-03-10"' "$GENERATOR"
if command -v node >/dev/null 2>&1; then
  node --check "$SITE/app.js"
  node "$UI_TEST"
fi

# The public page must make the hardware and non-flashable safety boundary unmistakable.
grep -Fq 'Xiaomi AX9000' "$SITE/index.html"
grep -Fq '仅限 RAM 测试 · RAM TEST ONLY' "$SITE/index.html"
grep -Fq '严禁刷写 · DO NOT FLASH' "$SITE/index.html"
grep -Fq '不是 sysupgrade / factory 固件' "$SITE/index.html"
grep -Fq 'id="browser-build-link"' "$SITE/index.html"
# GitHub expression is intentionally matched literally.
# shellcheck disable=SC2016
grep -Fq 'const BUILD_WORKFLOW_URL = `https://github.com/${REPOSITORY}/actions/workflows/build.yml`;' "$SITE/app.js"
grep -Fq 'id="custom-build"' "$SITE/index.html"
grep -Fq 'id="component-target"' "$SITE/index.html"
grep -Fq 'id="component-flavor"' "$SITE/index.html"
grep -Fq 'id="component-search"' "$SITE/index.html"
grep -Fq 'id="component-category"' "$SITE/index.html"
grep -Fq 'id="component-list"' "$SITE/index.html"
grep -Fq 'id="component-packages"' "$SITE/index.html"
grep -Fq 'id="component-normalized"' "$SITE/index.html"
grep -Fq 'id="component-request-hash"' "$SITE/index.html"
grep -Fq 'id="component-actions-inputs"' "$SITE/index.html"
grep -Fq 'id="custom-build-workflow-link"' "$SITE/index.html"
grep -Fq '静态 Pages 不保存 GitHub token' "$SITE/index.html"
grep -Fq '目前不支持匿名一键构建' "$SITE/index.html"
grep -Fq 'Run workflow' "$SITE/index.html"
grep -Fq "const COMPONENT_CATALOG_URL = 'components/catalog.json';" "$SITE/app.js"
grep -Fq "const CUSTOM_BUILD_WORKFLOW_FILE = 'custom-build.yml';" "$SITE/app.js"
grep -Fq 'function validateComponentCatalog(catalog)' "$SITE/app.js"
grep -Fq 'function resolveComponentSelection(catalog, targetId, requestedIds)' "$SITE/app.js"
grep -Fq 'function componentHashPayload(catalog, targetId, flavorId, resolved)' "$SITE/app.js"
grep -Fq 'globalThis.crypto.subtle.digest' "$SITE/app.js"
grep -Fq 'components: [...resolved.resolved_components]' "$SITE/app.js"
grep -Fq 'flavor: flavorId' "$SITE/app.js"
grep -Fq 'packages: [...resolved.packages]' "$SITE/app.js"
grep -Fq 'group.history.filter((release) => validVmRelease(release, schemaVersion))' "$SITE/app.js"
if grep -Eq 'innerHTML|insertAdjacentHTML|document\.write|eval\(' "$SITE/app.js"; then
  echo 'unsafe DOM/code execution API found in Pages app' >&2
  exit 1
fi
if grep -Eq 'localStorage|sessionStorage|Authorization:|Bearer |ghp_' "$SITE/app.js"; then
  echo 'browser selector must not persist or embed credentials' >&2
  exit 1
fi
if grep -Fq 'href="https://github.com/tifycloud/NexaWrt/actions/workflows/custom-build.yml"' "$SITE/index.html"; then
  echo 'static custom-build workflow link bypasses fail-closed catalog validation' >&2
  exit 1
fi
grep -Fq "device.production_ready !== false" "$SITE/app.js"
grep -Fq "device.image_capabilities.sysupgrade !== false" "$SITE/app.js"
grep -Fq "[3, 4].includes(data.schema_version)" "$SITE/app.js"
grep -Fq '不收集、不生成密码或密钥，不会把任何设置烘焙进下载镜像' "$SITE/index.html"
grep -Fq 'id="vm-releases"' "$SITE/index.html"
grep -Fq 'data-vm-platform="x86_64"' "$SITE/index.html"
grep -Fq 'VM ONLY · 不是 AX9000 固件' "$SITE/index.html"
grep -Fq 'id="vm-history"' "$SITE/index.html"
grep -Fq 'id="vm-history-actions"' "$SITE/index.html"
grep -Fq 'ISO 是 Live 启动盘，不是安装盘' "$SITE/index.html"
grep -Fq 'ESXi compatibility not yet validated' "$SITE/index.html"
grep -Fq 'const VM_RELEASE_WORKFLOW_URL' "$SITE/app.js"
grep -Fq 'function resetVmHistoryActions()' "$SITE/app.js"
if grep -Fq 'href="https://github.com/tifycloud/NexaWrt/actions/workflows/vm-release.yml"' "$SITE/index.html"; then
  echo 'static VM workflow link bypasses fail-closed UI state' >&2
  exit 1
fi
grep -Fq 'release.not_ax9000_firmware !== true' "$SITE/app.js"
grep -Fq 'VM_ARTIFACT_LABEL_KEYS' "$PROOF_VERIFIER"
grep -Fq '"SSH_AUTHORIZED_KEYS": "absent"' "$PROOF_VERIFIER"
grep -Fq '"PUBLISHED_VARIANTS": VM_PUBLISHED_VARIANTS' "$PROOF_VERIFIER"

# Validate the exported VM smoke contracts instead of depending on a particular
# Python assignment or formatting shape. The provenance test executed above
# exercises the corresponding strict values, status pairs, ports, and paths.
python3 - "$ROOT_DIR" <<'PYCONTRACT'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
scripts = root / "scripts"
sys.path.insert(0, str(scripts))
spec = importlib.util.spec_from_file_location("verify_pages_releases", scripts / "verify-pages-releases.py")
module = importlib.util.module_from_spec(spec)
if spec.loader is None:
    raise SystemExit("Pages verifier module loader is unavailable")
spec.loader.exec_module(module)

expected_v1 = {
    "status", "target", "image", "vm_only", "not_ax9000_firmware",
    "hardware_validation", "nss_validation", "exact_release_image", "qemu_boot",
    "serial_labels", "http", "ssh_runtime_evidence", "ssh_port_probe", "ssh",
    "authorized_keys", "dropbear_enabled", "dropbear_running", "http_status",
    "auth_challenge", "http_host_port", "ssh_host_port", "serial_log", "ssh_probe_log",
}
expected_v2 = {
    "status", "target", "release_contract", "vm_only", "not_ax9000_firmware",
    "hardware_validation", "nss_validation", "exact_release_image", "serial_labels",
    "https", "http_redirect", "runtime_evidence", "production_runtime",
    "raw_bios_persistence", "vmdk_import_persistence", "ssh_port_probe", "ssh",
    "authorized_keys", "dropbear_enabled", "dropbear_running", "http_redirect_status",
    "https_status", "auth_challenge", "http_host_port", "https_host_port",
    "ssh_host_port", "serial_log", "ssh_probe_log", "raw_bios_file", "raw_bios_qemu",
    "iso_bios_file", "iso_bios_qemu", "iso_efi_file", "iso_efi_qemu",
    "vmdk_bios_file", "vmdk_bios_qemu", "vmdk_efi_file", "vmdk_efi_qemu",
    "esxi_validation",
}
contracts = module.VM_SMOKE_REPORT_KEYS
if set(contracts) != {module.VM_CONTRACT_V1, module.VM_CONTRACT_V2}:
    raise SystemExit(f"unexpected VM smoke contract versions: {sorted(contracts)!r}")
if contracts[module.VM_CONTRACT_V1] != expected_v1:
    raise SystemExit(f"v1 VM smoke contract changed: {sorted(contracts[module.VM_CONTRACT_V1] ^ expected_v1)!r}")
if contracts[module.VM_CONTRACT_V2] != expected_v2:
    raise SystemExit(f"v2 VM smoke contract changed: {sorted(contracts[module.VM_CONTRACT_V2] ^ expected_v2)!r}")
PYCONTRACT
grep -Fq 'identity["id"] != asset_id' "$GENERATOR"
if grep -Eiq '<input[^>]+(password|secret|token|key)' "$SITE/index.html"; then
  echo 'secret-bearing configuration field found in site UI' >&2
  exit 1
fi
if grep -Eiq '(sysupgrade|factory).*(href|download=)|(href|download=).*(sysupgrade|factory)' "$SITE/index.html"; then
  echo 'flash image download link found in site UI' >&2
  exit 1
fi
grep -Fq 'href="favicon.svg"' "$SITE/index.html"
grep -Fq "default-src 'self'" "$SITE/index.html"

# Pages deployment uses only official actions pinned to immutable commit SHAs.
grep -Fq 'permissions: {}' "$WORKFLOW"
grep -Fq "workflows: ['NexaWrt AX9000 reproducible RAM-test release', 'NexaWrt x86_64 VM release', 'Promote ESXi-accepted VM RC']" "$WORKFLOW"
grep -Fq 'types: [completed]' "$WORKFLOW"
grep -Fq 'schedule:' "$WORKFLOW"
grep -Fq "cron: '17 */6 * * *'" "$WORKFLOW"
grep -Fq 'workflow_dispatch:' "$WORKFLOW"
grep -Fq "github.repository == 'tifycloud/NexaWrt' &&" "$WORKFLOW"
grep -Fq "github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success'" "$WORKFLOW"
grep -Fq "'Promote ESXi-accepted VM RC'" "$WORKFLOW"
grep -Fq "VM_PROMOTION_WORKFLOW" "$GENERATOR"
grep -Fq "VM_PROMOTION_WORKFLOW" "$PROOF_VERIFIER"
grep -Fq 'ref: refs/heads/main' "$WORKFLOW"
grep -Fq 'fetch-depth: 0' "$WORKFLOW"
grep -Fq 'timeout-minutes: 30' "$WORKFLOW"
grep -Fq 'contents: read' "$WORKFLOW"
grep -Fq 'attestations: read' "$WORKFLOW"
grep -Fq 'pages: write' "$WORKFLOW"
grep -Fq 'id-token: write' "$WORKFLOW"
grep -Fq 'name: github-pages' "$WORKFLOW"
# GitHub expression is intentionally matched literally.
# shellcheck disable=SC2016
grep -Fq 'url: ${{ steps.deployment.outputs.page_url }}' "$WORKFLOW"
grep -Fq -- "- 'devices/**'" "$WORKFLOW"
grep -Fq -- "- 'scripts/device_metadata.py'" "$WORKFLOW"
grep -Fq -- "- 'scripts/verify-pages-releases.py'" "$WORKFLOW"
grep -Fq -- "- 'components/**'" "$WORKFLOW"
grep -Fq -- "- 'tests/test_pages_ui.js'" "$WORKFLOW"
grep -Fq -- "- 'tests/test_pages_policy.sh'" "$WORKFLOW"
grep -Fq 'node tests/test_pages_ui.js' "$WORKFLOW"
grep -Fq 'bash tests/test_pages_policy.sh' "$WORKFLOW"
grep -Fq 'cp components/catalog.json site/components/catalog.json' "$WORKFLOW"
grep -Fq 'python3 -m json.tool site/components/catalog.json' "$WORKFLOW"
grep -Fq 'NEXAWRT_ATTESTATION_VERIFIER=/usr/bin/gh' "$WORKFLOW"
grep -Fq 'python3 scripts/verify-pages-releases.py' "$WORKFLOW"
grep -Fq -- '--trusted-main HEAD' "$WORKFLOW"
grep -Fq 'python3 scripts/generate-pages-data.py' "$WORKFLOW"
grep -Fq -- '--proofs .pages-index/release-proofs.json' "$WORKFLOW"
grep -Fq 'actions/configure-pages@45bfe0192ca1faeb007ade9deae92b16b8254a0d' "$WORKFLOW"
grep -Fq 'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9' "$WORKFLOW"
grep -Fq 'actions/deploy-pages@cd2ce8fcbc39b97be8ca5fce6e763baed58fa128' "$WORKFLOW"
while IFS= read -r action; do
  [[ "$action" =~ ^actions/(checkout|configure-pages|upload-pages-artifact|deploy-pages)@[0-9a-f]{40}$ ]] || {
    echo "unapproved or unpinned Pages action: $action" >&2
    exit 1
  }
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*/\1/p' "$WORKFLOW")

# Exercise proof-gated releases, semantic ordering, and attacker lookalikes.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fixture="$tmp_dir/releases.json"
proofs="$tmp_dir/proofs.json"
output="$tmp_dir/pages.json"
python3 - "$fixture" "$proofs" <<'PY'
import json
import sys

fixture_path, proof_path = sys.argv[1:]
next_asset_id = 1000

def release(release_id, flavor, version, published_at, *, extra=False, immutable=True):
    global next_asset_id
    tag = f"ram-test-{version}" if flavor == "official" else f"ram-test-{flavor}-{version}"
    archive = f"NexaWrt-AX9000-{flavor}-{version}-verified-dist.tar.gz"
    names = [
        archive, f"{archive}.sha256", "archive.provenance.bundle.json",
        "checksums.provenance.bundle.json", "firmware.provenance.bundle.json",
        "sbom.provenance.bundle.json",
    ]
    if extra:
        names.append("openwrt-ax9000-sysupgrade.bin")
    assets = []
    for offset, name in enumerate(names, 1):
        next_asset_id += 1
        assets.append({
            "id": next_asset_id,
            "name": name,
            "state": "uploaded",
            "size": 80 + offset,
            "browser_download_url": "https://attacker.invalid/untrusted-field",
        })
    return {
        "id": release_id,
        "tag_name": tag,
        "draft": False,
        "prerelease": True,
        "immutable": immutable,
        "published_at": published_at,
        "html_url": "https://attacker.invalid/untrusted-field",
        "assets": assets,
    }

def vm_names(version, contract_version):
    prefix = f"NexaWrt-x86_64-{version}"
    raw = f"{prefix}-generic-ext4-combined.img.gz"
    if contract_version == 1:
        return {
            "image": raw, "image_checksum": f"{raw}.sha256",
            "manifest": f"{prefix}-generic-ext4-combined.manifest",
            "artifact_labels": "artifact-labels.env", "readme": "README-VM.txt",
            "smoke_report": "smoke-report.txt", "checksums": "SHA256SUMS",
            "provenance_image": "image.provenance.bundle.json",
            "provenance_checksums": "checksums.provenance.bundle.json",
        }
    variants = {
        "raw_bios": raw,
        "iso_bios": f"{prefix}-generic-image.iso",
        "iso_efi": f"{prefix}-generic-image-efi.iso",
        "vmdk_bios": f"{prefix}-generic-ext4-combined.vmdk",
        "vmdk_efi": f"{prefix}-generic-ext4-combined-efi.vmdk",
    }
    names = {}
    for key, name in variants.items():
        names[key] = name
        names[f"{key}_checksum"] = f"{name}.sha256"
    names.update({
        "manifest": f"{prefix}-generic.manifest", "artifact_labels": "artifact-labels.env",
        "readme": "README-VM.txt", "smoke_report": "smoke-report.txt", "checksums": "SHA256SUMS",
        "provenance_raw_bios": "raw-bios.provenance.bundle.json",
        "provenance_iso_bios": "iso-bios.provenance.bundle.json",
        "provenance_iso_efi": "iso-efi.provenance.bundle.json",
        "provenance_vmdk_bios": "vmdk-bios.provenance.bundle.json",
        "provenance_vmdk_efi": "vmdk-efi.provenance.bundle.json",
        "provenance_checksums": "checksums.provenance.bundle.json",
    })
    return names

def vm_release(release_id, version, published_at, contract_version, *, extra=False):
    global next_asset_id
    tag = f"vm-x86_64-{version}"
    names = list(vm_names(version, contract_version).values())
    if extra:
        names.append("NexaWrt-AX9000-sysupgrade.bin")
    assets = []
    for offset, name in enumerate(names, 1):
        next_asset_id += 1
        assets.append({
            "id": next_asset_id, "name": name, "state": "uploaded", "size": 160 + offset,
            "browser_download_url": "https://attacker.invalid/untrusted-field",
        })
    return {
        "id": release_id, "tag_name": tag, "draft": False, "prerelease": True,
        "immutable": True, "published_at": published_at,
        "html_url": "https://attacker.invalid/untrusted-field", "assets": assets,
    }

same_time = "2026-07-18T01:00:00Z"
releases = [
    release(110, "official", "v1.9.0-rc.1", same_time),
    release(111, "official", "v1.10.0-rc.1", same_time),
    release(120, "nss", "v3.0.0-rc.1", "2026-07-17T12:00:00Z"),
    release(999, "official", "v9.9.9-rc.1", "2026-07-18T02:00:00Z"),
    release(130, "official", "v2.0.0-rc.2", "2026-07-18T03:00:00Z", extra=True),
    release(140, "official", "v4.4.0-rc.1", "2026-07-18T04:00:00Z", immutable=False),
    vm_release(210, "v0.1.0-rc.3", "2026-07-18T05:00:00Z", 1),
    vm_release(211, "v0.2.0-rc.1", "2026-07-18T06:00:00Z", 2),
    vm_release(212, "v0.3.0-rc.1", "2026-07-18T07:00:00Z", 2, extra=True),
]

def proof(release_id, fill):
    return {
        "release_id": release_id,
        "source_digest": fill * 40,
        "archive_sha256": fill * 64,
        "checksum_sha256": fill * 64,
        "verified_subjects": ["archive", "checksums", "firmware", "sbom"],
    }

def vm_proof(release_id, version, fill, contract_version):
    names = vm_names(version, contract_version)
    raw = next(item for item in releases if item["id"] == release_id)
    by_name = {asset["name"]: asset for asset in raw["assets"]}
    proof_assets = {}
    for key, name in names.items():
        asset = by_name[name]
        digest = fill * 64
        asset["digest"] = f"sha256:{digest}"
        proof_assets[key] = {"id": asset["id"], "name": name, "size": asset["size"], "sha256": digest}
    variants = ["raw_bios"] if contract_version == 1 else [
        "raw_bios", "iso_bios", "iso_efi", "vmdk_bios", "vmdk_efi",
    ]
    return {
        "release_id": release_id,
        "source_digest": fill * 40,
        "contract_version": contract_version,
        "assets": proof_assets,
        "verified_subjects": ["image", "checksums"] if contract_version == 1 else [*variants, "checksums"],
        "validation": {"qemu": {variant: "runtime-pass" for variant in variants}, "esxi": "not-tested"},
    }

source_v2_proof = vm_proof(211, "v0.2.0-rc.1", "f", 2)
source_v2_release = next(item for item in releases if item["id"] == 211)
stable_assets = []
for source_asset in source_v2_release["assets"]:
    next_asset_id += 1
    stable_assets.append({
        "id": next_asset_id, "name": source_asset["name"], "state": "uploaded", "size": source_asset["size"],
        "digest": source_asset["digest"], "browser_download_url": "https://attacker.invalid/untrusted-field",
    })
stable_release = {
    "id": 213, "tag_name": "vm-x86_64-v0.2.0", "target_commitish": "f" * 40,
    "name": "NexaWrt x86_64 VM v0.2.0", "body": "promotion bindings verified upstream",
    "draft": False, "prerelease": False, "immutable": True, "published_at": "2026-07-18T06:30:00Z",
    "html_url": "https://attacker.invalid/untrusted-field", "assets": stable_assets,
}
releases.append(stable_release)
stable_by_name = {asset["name"]: asset for asset in stable_assets}
stable_proof_assets = {
    key: {"id": stable_by_name[value["name"]]["id"], "name": value["name"], "size": value["size"], "sha256": value["sha256"]}
    for key, value in source_v2_proof["assets"].items()
}
stable_proof = {
    "release_id": 213, "source_digest": "f" * 40, "contract_version": 2, "assets": stable_proof_assets,
    "verified_subjects": ["raw_bios", "iso_bios", "iso_efi", "vmdk_bios", "vmdk_efi", "checksums"],
    "validation": {"qemu": dict(source_v2_proof["validation"]["qemu"]), "esxi": "validated"},
    "source_rc_tag": "vm-x86_64-v0.2.0-rc.1", "source_rc_release_id": 211,
    "evidence_path": "evidence/vm-esxi/vm-x86_64-v0.2.0-rc.1.json", "evidence_commit": "a" * 40,
}

proof_document = {
    "schema_version": 5,
    "repository": "tifycloud/NexaWrt",
    "trusted_ref": "refs/heads/main",
    "trusted_main_digest": "a" * 40,
    "signer_workflows": {
        "ax9000": "tifycloud/NexaWrt/.github/workflows/release.yml",
        "vm_x86_64": "tifycloud/NexaWrt/.github/workflows/vm-release.yml",
        "vm_x86_64_promotion": "tifycloud/NexaWrt/.github/workflows/vm-promote.yml",
    },
    "releases": {
        "ram-test-v1.9.0-rc.1": proof(110, "b"),
        "ram-test-v1.10.0-rc.1": proof(111, "c"),
        "ram-test-nss-v3.0.0-rc.1": proof(120, "d"),
    },
    "virtual_images": {"x86_64": {
        "vm-x86_64-v0.1.0-rc.3": vm_proof(210, "v0.1.0-rc.3", "e", 1),
        "vm-x86_64-v0.2.0-rc.1": source_v2_proof,
        "vm-x86_64-v0.2.0": stable_proof,
    }},
}
with open(fixture_path, "w", encoding="utf-8") as stream:
    json.dump(releases, stream)
with open(proof_path, "w", encoding="utf-8") as stream:
    json.dump(proof_document, stream, sort_keys=True)
PY

python3 "$GENERATOR" --input "$fixture" --proofs "$proofs" --output "$output"
python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema_version"] == 4
assert data["repository"] == "tifycloud/NexaWrt"
assert set(data["devices"]) == {"xiaomi-ax9000"}
vm = data["virtual_images"]["x86_64"]
assert vm["latest"] == vm["history"][0]
assert [item["tag"] for item in vm["history"]] == [
    "vm-x86_64-v0.2.0", "vm-x86_64-v0.2.0-rc.1", "vm-x86_64-v0.1.0-rc.3",
]
vm_release_entry = vm["latest"]
assert vm_release_entry["artifact_class"] == "VM_DISTRIBUTION_SET"
assert vm_release_entry["contract_version"] == 2
assert vm_release_entry["release_contract"] == "vm-x86_64/v2"
assert vm_release_entry["vm_only"] is True
assert vm_release_entry["not_ax9000_firmware"] is True
assert vm_release_entry["hardware_validation"] is False
assert vm_release_entry["nss_validation"] is False
assert vm_release_entry["qemu_validated"] is True
assert vm_release_entry["esxi_validation"] == "validated"
assert vm_release_entry["ssh_default"] == "disabled"
assert vm_release_entry["validation"] == {
    "qemu": {key: "runtime-pass" for key in ("raw_bios", "iso_bios", "iso_efi", "vmdk_bios", "vmdk_efi")},
    "esxi": "validated",
}
assert vm_release_entry["version"] == "v0.2.0"
assert all("v0.2.0-rc.1" in asset["name"] or asset["name"] in {"artifact-labels.env", "README-VM.txt", "smoke-report.txt", "SHA256SUMS", "raw-bios.provenance.bundle.json", "iso-bios.provenance.bundle.json", "iso-efi.provenance.bundle.json", "vmdk-bios.provenance.bundle.json", "vmdk-efi.provenance.bundle.json", "checksums.provenance.bundle.json"} for asset in vm_release_entry["assets"].values())
assert len(vm_release_entry["assets"]) == 21
assert all(set(asset) == {"name", "url", "size", "sha256"} for asset in vm_release_entry["assets"].values())
source_rc = vm["history"][1]
assert source_rc["tag"] == "vm-x86_64-v0.2.0-rc.1"
assert source_rc["esxi_validation"] == "not-tested"
legacy = vm["history"][2]
assert legacy["tag"] == "vm-x86_64-v0.1.0-rc.3"
assert legacy["contract_version"] == 1
assert legacy["artifact_class"] == "VM_DISTRIBUTION_IMAGE"
assert set(legacy["assets"]) == {
    "image", "image_checksum", "manifest", "artifact_labels", "readme", "smoke_report",
    "checksums", "provenance_image", "provenance_checksums",
}
device = data["devices"]["xiaomi-ax9000"]
assert device["display_name"] == "Xiaomi AX9000"
assert device["hardware_status"] == "unverified"
assert device["production_ready"] is False
assert device["image_capabilities"] == {"ram_boot": True, "factory": False, "sysupgrade": False}
assert device["channels"] == ["ram-test"]
official = data["flavors"]["official"]
nss = data["flavors"]["nss"]
assert [item["tag"] for item in official["history"]] == [
    "ram-test-v1.10.0-rc.1", "ram-test-v1.9.0-rc.1"
]
assert official["latest"] == official["history"][0]
assert nss["latest"]["tag"] == "ram-test-nss-v3.0.0-rc.1"
for flavor, group in (("official", official), ("nss", nss)):
    for release in group["history"]:
        assert release["device_id"] == "xiaomi-ax9000"
        assert release["flavor"] == flavor
        assert release["hardware_status"] == "unverified"
        assert release["production_ready"] is False
        assert release["ram_only"] is True
        assert set(release["assets"]) == {
            "archive", "checksum", "provenance_archive", "provenance_checksums",
            "provenance_firmware", "provenance_sbom",
        }
        for asset in release["assets"].values():
            assert asset["url"].startswith("https://github.com/tifycloud/NexaWrt/releases/download/")
            assert "attacker.invalid" not in asset["url"]
            assert "sysupgrade" not in asset["name"]
serialized = json.dumps(data)
assert "ram-test-v9.9.9-rc.1" not in serialized
assert "ram-test-v2.0.0-rc.2" not in serialized
assert "ram-test-v4.4.0-rc.1" not in serialized
assert "vm-x86_64-v0.3.0-rc.1" not in serialized
assert "NexaWrt-AX9000-sysupgrade.bin" not in serialized
PY

# Without proofs, even an exact immutable lookalike must not enter the catalog.
python3 - "$proofs" "$tmp_dir/no-proofs.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["releases"] = {}
data["virtual_images"] = {"x86_64": {}}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
python3 "$GENERATOR" --input "$fixture" --proofs "$tmp_dir/no-proofs.json" --output "$tmp_dir/empty.json"
python3 - "$tmp_dir/empty.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert all(not group["history"] and group["latest"] is None for group in data["flavors"].values())
assert data["virtual_images"] == {"x86_64": {"latest": None, "history": []}}
PY

# A mismatched/replayed proof is a hard error rather than a silent verified listing.
python3 - "$proofs" "$tmp_dir/bad-proofs.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["releases"]["ram-test-v1.10.0-rc.1"]["release_id"] = 999999
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$fixture" --proofs "$tmp_dir/bad-proofs.json" --output "$tmp_dir/bad.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a mismatched release proof' >&2
  exit 1
fi
# VM proof replay, asset-ID substitution, and trusted digest mismatch must fail closed.
python3 - "$proofs" "$tmp_dir/replayed-vm-proofs.json" <<'PY'
import copy, json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
entry = copy.deepcopy(data["virtual_images"]["x86_64"]["vm-x86_64-v0.1.0-rc.3"])
data["virtual_images"]["x86_64"]["vm-x86_64-v0.1.1-rc.1"] = entry
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$fixture" --proofs "$tmp_dir/replayed-vm-proofs.json" --output "$tmp_dir/replayed.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a replayed VM release proof' >&2
  exit 1
fi
python3 - "$fixture" "$tmp_dir/replaced-asset-id.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
vm = next(item for item in data if item["tag_name"] == "vm-x86_64-v0.1.0-rc.3")
vm["assets"][0]["id"] += 999999
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$tmp_dir/replaced-asset-id.json" --proofs "$proofs" --output "$tmp_dir/replaced-id.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a replaced VM asset ID' >&2
  exit 1
fi
python3 - "$fixture" "$tmp_dir/bad-vm-digest.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
vm = next(item for item in data if item["tag_name"] == "vm-x86_64-v0.1.0-rc.3")
vm["assets"][0]["digest"] = "sha256:" + "0" * 64
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$tmp_dir/bad-vm-digest.json" --proofs "$proofs" --output "$tmp_dir/bad-digest.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a mismatched trusted VM asset digest' >&2
  exit 1
fi
python3 - "$fixture" "$tmp_dir/missing-v2-digest.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
vm = next(item for item in data if item["tag_name"] == "vm-x86_64-v0.2.0-rc.1")
vm["assets"][0].pop("digest")
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$tmp_dir/missing-v2-digest.json" --proofs "$proofs" --output "$tmp_dir/missing-v2-digest-output.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a v2 asset without its Release API digest' >&2
  exit 1
fi
python3 - "$proofs" "$tmp_dir/bad-v2-validation.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["virtual_images"]["x86_64"]["vm-x86_64-v0.2.0-rc.1"]["validation"]["esxi"] = "validated"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$fixture" --proofs "$tmp_dir/bad-v2-validation.json" --output "$tmp_dir/bad-v2-validation-output.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a proof claiming ESXi validation' >&2
  exit 1
fi
python3 - "$proofs" "$tmp_dir/bad-stable-link.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
stable = data["virtual_images"]["x86_64"]["vm-x86_64-v0.2.0"]
stable["assets"]["raw_bios"]["sha256"] = "0" * 64
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
if python3 "$GENERATOR" --input "$fixture" --proofs "$tmp_dir/bad-stable-link.json" --output "$tmp_dir/bad-stable-link-output.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted stable VM bytes that differ from the source RC proof' >&2
  exit 1
fi
if python3 "$GENERATOR" --input "$fixture" --output "$tmp_dir/missing-proof-arg.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly ran without a proof manifest' >&2
  exit 1
fi
if python3 "$GENERATOR" --input /dev/null --proofs "$proofs" --output "$tmp_dir/invalid.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a non-regular fixture' >&2
  exit 1
fi

echo 'Pages policy: release provenance plus fail-closed component catalog selector, normalized request hashing, authenticated Actions handoff, and safe DOM policy OK'
