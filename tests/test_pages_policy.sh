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

for path in "$WORKFLOW" "$GENERATOR" "$PROOF_VERIFIER" "$PROOF_TEST" "$DEVICE_VALIDATOR" "$DEVICE_METADATA" "$DEVICE_TEST" "$UI_TEST" "$SITE/index.html" "$SITE/styles.css" "$SITE/app.js" "$SITE/favicon.svg" "$SITE/releases.json" "$SITE/.nojekyll"; do
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
grep -Fq 'const BUILD_WORKFLOW_URL = `https://github.com/${REPOSITORY}/actions/workflows/build.yml`;' "$SITE/app.js"
grep -Fq "device.production_ready !== false" "$SITE/app.js"
grep -Fq "device.image_capabilities.sysupgrade !== false" "$SITE/app.js"
grep -Fq "data.schema_version !== 2" "$SITE/app.js"
grep -Fq '不收集、不生成密码或密钥，不会把任何设置烘焙进下载镜像' "$SITE/index.html"
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
grep -Fq "workflows: ['NexaWrt AX9000 reproducible RAM-test release']" "$WORKFLOW"
grep -Fq 'types: [completed]' "$WORKFLOW"
grep -Fq 'schedule:' "$WORKFLOW"
grep -Fq "cron: '17 */6 * * *'" "$WORKFLOW"
grep -Fq 'workflow_dispatch:' "$WORKFLOW"
grep -Fq "github.repository == 'tifycloud/NexaWrt' &&" "$WORKFLOW"
grep -Fq "github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success'" "$WORKFLOW"
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

same_time = "2026-07-18T01:00:00Z"
releases = [
    release(110, "official", "v1.9.0-rc.1", same_time),
    release(111, "official", "v1.10.0-rc.1", same_time),
    release(120, "nss", "v3.0.0-rc.1", "2026-07-17T12:00:00Z"),
    release(999, "official", "v9.9.9-rc.1", "2026-07-18T02:00:00Z"),
    release(130, "official", "v2.0.0-rc.2", "2026-07-18T03:00:00Z", extra=True),
    release(140, "official", "v4.4.0-rc.1", "2026-07-18T04:00:00Z", immutable=False),
]

def proof(release_id, fill):
    return {
        "release_id": release_id,
        "source_digest": fill * 40,
        "archive_sha256": fill * 64,
        "checksum_sha256": fill * 64,
        "verified_subjects": ["archive", "checksums", "firmware", "sbom"],
    }

proof_document = {
    "schema_version": 1,
    "repository": "tifycloud/NexaWrt",
    "trusted_ref": "refs/heads/main",
    "trusted_main_digest": "a" * 40,
    "signer_workflow": "tifycloud/NexaWrt/.github/workflows/release.yml",
    "releases": {
        "ram-test-v1.9.0-rc.1": proof(110, "b"),
        "ram-test-v1.10.0-rc.1": proof(111, "c"),
        "ram-test-nss-v3.0.0-rc.1": proof(120, "d"),
    },
}
with open(fixture_path, "w", encoding="utf-8") as stream:
    json.dump(releases, stream)
with open(proof_path, "w", encoding="utf-8") as stream:
    json.dump(proof_document, stream)
PY

python3 "$GENERATOR" --input "$fixture" --proofs "$proofs" --output "$output"
python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema_version"] == 2
assert data["repository"] == "tifycloud/NexaWrt"
assert set(data["devices"]) == {"xiaomi-ax9000"}
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
PY

# Without proofs, even an exact immutable lookalike must not enter the catalog.
python3 - "$proofs" "$tmp_dir/no-proofs.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
data["releases"] = {}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(data, stream)
PY
python3 "$GENERATOR" --input "$fixture" --proofs "$tmp_dir/no-proofs.json" --output "$tmp_dir/empty.json"
python3 - "$tmp_dir/empty.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert all(not group["history"] and group["latest"] is None for group in data["flavors"].values())
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
if python3 "$GENERATOR" --input "$fixture" --output "$tmp_dir/missing-proof-arg.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly ran without a proof manifest' >&2
  exit 1
fi
if python3 "$GENERATOR" --input /dev/null --proofs "$proofs" --output "$tmp_dir/invalid.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a non-regular fixture' >&2
  exit 1
fi

echo 'Pages policy: schema-v2 catalog, attestation-gated Releases, semantic ordering, fail-closed UI, and RAM-only safety OK'
