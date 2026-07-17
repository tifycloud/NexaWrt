#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/pages.yml"
GENERATOR="$ROOT_DIR/scripts/generate-pages-data.py"
SITE="$ROOT_DIR/site"

for path in "$WORKFLOW" "$GENERATOR" "$SITE/index.html" "$SITE/styles.css" "$SITE/app.js" "$SITE/releases.json" "$SITE/.nojekyll"; do
  test -f "$path" || { echo "missing Pages file: $path" >&2; exit 1; }
done

test -x "$GENERATOR"
python3 -m py_compile "$GENERATOR"
grep -Fq '"X-GitHub-Api-Version": "2026-03-10"' "$GENERATOR"
if command -v node >/dev/null 2>&1; then
  node --check "$SITE/app.js"
fi

# The public page must make the hardware and non-flashable safety boundary unmistakable.
grep -Fq 'Xiaomi AX9000' "$SITE/index.html"
grep -Fq '仅限 RAM 测试 · RAM TEST ONLY' "$SITE/index.html"
grep -Fq '严禁刷写 · DO NOT FLASH' "$SITE/index.html"
grep -Fq '不是 sysupgrade / factory 固件' "$SITE/index.html"
grep -Fq 'https://github.com/tifycloud/NexaWrt/actions/workflows/build.yml' "$SITE/index.html"
grep -Fq '不收集、不生成密码或密钥，不会把任何设置烘焙进下载镜像' "$SITE/index.html"
if grep -Eiq '<input[^>]+(password|secret|token|key)' "$SITE/index.html"; then
  echo 'secret-bearing configuration field found in site UI' >&2
  exit 1
fi
if grep -Eiq '(sysupgrade|factory).*(href|download=)|(href|download=).*(sysupgrade|factory)' "$SITE/index.html"; then
  echo 'flash image download link found in site UI' >&2
  exit 1
fi
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
grep -Fq 'contents: read' "$WORKFLOW"
grep -Fq 'pages: write' "$WORKFLOW"
grep -Fq 'id-token: write' "$WORKFLOW"
grep -Fq 'name: github-pages' "$WORKFLOW"
# GitHub expression is intentionally matched literally.
# shellcheck disable=SC2016
grep -Fq 'url: ${{ steps.deployment.outputs.page_url }}' "$WORKFLOW"
grep -Fq 'python3 scripts/generate-pages-data.py --output site/releases.json' "$WORKFLOW"
grep -Fq 'actions/configure-pages@45bfe0192ca1faeb007ade9deae92b16b8254a0d' "$WORKFLOW"
grep -Fq 'actions/upload-pages-artifact@fc324d3547104276b827a68afc52ff2a11cc49c9' "$WORKFLOW"
grep -Fq 'actions/deploy-pages@cd2ce8fcbc39b97be8ca5fce6e763baed58fa128' "$WORKFLOW"
while IFS= read -r action; do
  [[ "$action" =~ ^actions/(checkout|configure-pages|upload-pages-artifact|deploy-pages)@[0-9a-f]{40}$ ]] || {
    echo "unapproved or unpinned Pages action: $action" >&2
    exit 1
  }
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*/\1/p' "$WORKFLOW")

# Exercise immutable releases against exact, extra, missing, duplicate, non-uploaded, and invalid-size assets.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fixture="$tmp_dir/releases.json"
output="$tmp_dir/pages.json"
cat > "$fixture" <<'JSON'
[
  {
    "tag_name": "ram-test-v2.0.0-rc.2",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-02T12:00:00Z",
    "assets": [
      {"name": "NexaWrt-AX9000-official-v2.0.0-rc.2-verified-dist.tar.gz", "state": "uploaded", "size": 100},
      {"name": "NexaWrt-AX9000-official-v2.0.0-rc.2-verified-dist.tar.gz.sha256", "state": "uploaded", "size": 101},
      {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 102},
      {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 103},
      {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 104},
      {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 105},
      {"name": "openwrt-ax9000-sysupgrade.bin", "state": "uploaded", "size": 999}
    ]
  },
  {
    "tag_name": "ram-test-v1.9.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-06-01T12:00:00Z",
    "html_url": "https://attacker.invalid/release",
    "assets": [
      {"name": "NexaWrt-AX9000-official-v1.9.0-rc.1-verified-dist.tar.gz", "state": "uploaded", "size": 90, "browser_download_url": "https://attacker.invalid/archive"},
      {"name": "NexaWrt-AX9000-official-v1.9.0-rc.1-verified-dist.tar.gz.sha256", "state": "uploaded", "size": 91},
      {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 92},
      {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 93},
      {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 94},
      {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 95}
    ]
  },
  {
    "tag_name": "ram-test-nss-v3.0.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-03T12:00:00+00:00",
    "assets": [
      {"name": "NexaWrt-AX9000-nss-v3.0.0-rc.1-verified-dist.tar.gz", "state": "uploaded", "size": 200},
      {"name": "NexaWrt-AX9000-nss-v3.0.0-rc.1-verified-dist.tar.gz.sha256", "state": "uploaded", "size": 201},
      {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 202},
      {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 203},
      {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 204},
      {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 205}
    ]
  },
  {
    "tag_name": "ram-test-v4.0.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-04T12:00:00Z",
    "assets": [
      {"name": "NexaWrt-AX9000-official-v4.0.0-rc.1-verified-dist.tar.gz", "state": "uploaded", "size": 300}
    ]
  },
  {
    "tag_name": "ram-test-v4.1.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-04T13:00:00Z",
    "assets": [
      {"name": "NexaWrt-AX9000-official-v4.1.0-rc.1-verified-dist.tar.gz", "state": "uploaded", "size": 300},
      {"name": "NexaWrt-AX9000-official-v4.1.0-rc.1-verified-dist.tar.gz.sha256", "state": "uploaded", "size": 301},
      {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 302},
      {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 303},
      {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 304},
      {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 305}
    ]
  },
  {
    "tag_name": "ram-test-v4.2.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-04T14:00:00Z",
    "assets": [
      {"name": "NexaWrt-AX9000-official-v4.2.0-rc.1-verified-dist.tar.gz", "state": "uploaded", "size": 300},
      {"name": "NexaWrt-AX9000-official-v4.2.0-rc.1-verified-dist.tar.gz.sha256", "state": "uploaded", "size": 301},
      {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 302},
      {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 303},
      {"name": "firmware.provenance.bundle.json", "state": "new", "size": 304},
      {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 305}
    ]
  },
  {
    "tag_name": "ram-test-v4.3.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-04T15:00:00Z",
    "assets": [
      {"name": "NexaWrt-AX9000-official-v4.3.0-rc.1-verified-dist.tar.gz", "state": "uploaded", "size": 300},
      {"name": "NexaWrt-AX9000-official-v4.3.0-rc.1-verified-dist.tar.gz.sha256", "state": "uploaded", "size": 301},
      {"name": "archive.provenance.bundle.json", "state": "uploaded", "size": 302},
      {"name": "checksums.provenance.bundle.json", "state": "uploaded", "size": 303},
      {"name": "firmware.provenance.bundle.json", "state": "uploaded", "size": 0},
      {"name": "sbom.provenance.bundle.json", "state": "uploaded", "size": 305}
    ]
  },
  {
    "tag_name": "ram-test-v4.4.0-rc.1",
    "draft": false,
    "prerelease": true,
    "immutable": false,
    "published_at": "2026-07-04T16:00:00Z",
    "assets": []
  },
  {
    "tag_name": "ram-test-v2.0.0",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-05T11:00:00Z",
    "assets": []
  },
  {
    "tag_name": "evil-v9<script>",
    "draft": false,
    "prerelease": true,
    "immutable": true,
    "published_at": "2026-07-05T12:00:00Z",
    "assets": []
  }
]
JSON

python3 "$GENERATOR" --input "$fixture" --output "$output"
python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["schema_version"] == 1
assert data["repository"] == "tifycloud/NexaWrt"
official = data["flavors"]["official"]
nss = data["flavors"]["nss"]
assert official["latest"]["tag"] == "ram-test-v1.9.0-rc.1"
assert official["latest"]["version"] == "v1.9.0-rc.1"
assert [item["tag"] for item in official["history"]] == ["ram-test-v1.9.0-rc.1"]
assert nss["latest"]["tag"] == "ram-test-nss-v3.0.0-rc.1"
assert nss["latest"]["version"] == "v3.0.0-rc.1"
for group in (official, nss):
    for release in group["history"]:
        assert set(release["assets"]) == {
            "archive", "checksum", "provenance_archive", "provenance_checksums",
            "provenance_firmware", "provenance_sbom"
        }
        assert release["url"].startswith("https://github.com/tifycloud/NexaWrt/releases/tag/")
        for asset in release["assets"].values():
            assert asset["url"].startswith("https://github.com/tifycloud/NexaWrt/releases/download/")
            assert "attacker.invalid" not in asset["url"]
            assert "sysupgrade" not in asset["name"]
serialized = json.dumps(data)
for rejected in (
    "ram-test-v2.0.0-rc.2",  # extra sysupgrade asset
    "ram-test-v4.0.0-rc.1",  # missing assets
    "ram-test-v4.1.0-rc.1",  # duplicate asset
    "ram-test-v4.2.0-rc.1",  # non-uploaded asset
    "ram-test-v4.3.0-rc.1",  # invalid size
    "ram-test-v4.4.0-rc.1",  # mutable release
):
    assert rejected not in serialized
all_tags = {release["tag"] for group in (official, nss) for release in group["history"]}
assert "ram-test-v2.0.0" not in all_tags
assert "evil-v9" not in json.dumps(data)
PY

if python3 "$GENERATOR" --input /dev/null --output "$tmp_dir/invalid.json" >/dev/null 2>&1; then
  echo 'generator unexpectedly accepted a non-regular fixture' >&2
  exit 1
fi

echo 'Pages policy: safe static UI, pinned deployment, release allowlist, and secret-free RAM configuration OK'
