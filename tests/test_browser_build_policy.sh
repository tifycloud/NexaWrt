#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$ROOT_DIR/.github/workflows/build.yml"
COMPARATOR="$ROOT_DIR/scripts/compare-reproducible-builds.sh"
HARDWARE_GATE="$ROOT_DIR/scripts/verify-hardware-evidence.sh"
fail() { echo "test_browser_build_policy: $*" >&2; exit 1; }
require_fixed() { grep -Fq -- "$2" "$1" || fail "missing policy text in ${1#$ROOT_DIR/}: $2"; }
reject_pattern() { if grep -Eiq -- "$2" "$1"; then fail "forbidden policy pattern in ${1#$ROOT_DIR/}: $2"; fi; }

[[ -f "$WORKFLOW" && ! -L "$WORKFLOW" ]] || fail 'browser build workflow is missing or unsafe'
[[ -x "$COMPARATOR" && -x "$HARDWARE_GATE" ]] || fail 'verification scripts are missing or not executable'

require_fixed "$WORKFLOW" 'workflow_dispatch:'
require_fixed "$WORKFLOW" 'options: [official, nss]'
require_fixed "$WORKFLOW" 'matrix:'
require_fixed "$WORKFLOW" 'replica: [a, b]'
require_fixed "$WORKFLOW" "CLEAN_BUILD: '1'"
require_fixed "$WORKFLOW" 'WORK_DIR: .work/${{ needs.preflight.outputs.work_basename }}-${{ matrix.replica }}'
require_fixed "$WORKFLOW" 'BUILD_LOG: ${{ github.workspace }}/build-browser-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}.log'
require_fixed "$WORKFLOW" "if: github.event_name == 'workflow_dispatch'"
require_fixed "$WORKFLOW" 'NEXAWRT_APK_SIGNING_PROFILE: production'
require_fixed "$WORKFLOW" 'manifests/apk-signing-public.pem'
require_fixed "$WORKFLOW" 'NEXAWRT_APK_SIGNING_PUBLIC_KEY_FILE="$public_key"'
require_fixed "$WORKFLOW" 'browser-build-${{ github.run_id }}-${{ github.run_attempt }}-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}'
require_fixed "$WORKFLOW" '"workflow": "tifycloud/NexaWrt/.github/workflows/build.yml"'
require_fixed "$WORKFLOW" 'test "$GITHUB_REF" = refs/heads/main'
require_fixed "$WORKFLOW" "test \"\$GITHUB_WORKFLOW_REF\" = 'tifycloud/NexaWrt/.github/workflows/build.yml@refs/heads/main'"
require_fixed "$WORKFLOW" 'test "$GITHUB_WORKFLOW_SHA" = "$GITHUB_SHA"'
require_fixed "$WORKFLOW" '"schema": 2'
for field in source_ref source_digest workflow_ref signer_digest; do
  require_fixed "$WORKFLOW" "\"$field\""
done
require_fixed "$WORKFLOW" 'actions/attest-build-provenance@'
require_fixed "$WORKFLOW" 'artifact-metadata: write'
require_fixed "$WORKFLOW" 'producer-descriptor.provenance.bundle.json'
require_fixed "$WORKFLOW" 'Download browser replica A'
require_fixed "$WORKFLOW" 'Download browser replica B'
require_fixed "$WORKFLOW" 'Enforce browser reproducibility gate'
require_fixed "$WORKFLOW" './scripts/compare-reproducible-builds.sh "$BUILD_FLAVOR"'
require_fixed "$WORKFLOW" './scripts/compare-reproducible-builds.sh --verify-verified-dist'
require_fixed "$WORKFLOW" 'NexaWrt-AX9000-${{ needs.preflight.outputs.flavor }}-verified-dist-${{ github.sha }}'
require_fixed "$WORKFLOW" 'GITHUB_STEP_SUMMARY'
require_fixed "$WORKFLOW" '仍需 AX9000 真机 RAM 启动、UART、恢复路径、重启与压力验收'
require_fixed "$WORKFLOW" '当前不要直接刷写到闪存'

# Each replica runs on its own runner with replica-qualified work, staging and log paths.
python3 - "$WORKFLOW" <<'PY' || fail 'browser workflow isolation or event policy is incomplete'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if text.count("replica: [a, b]") != 1:
    raise SystemExit(1)
if text.count("      artifact-metadata: write") != 1:
    raise SystemExit(1)
for token in (
    ".work/${{ needs.preflight.outputs.work_basename }}-${{ matrix.replica }}",
    "browser-replica-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}",
    "build-browser-${{ needs.preflight.outputs.flavor }}-${{ matrix.replica }}.log",
):
    if token not in text:
        raise SystemExit(1)
for job in ("build", "compare"):
    match = re.search(rf"(?ms)^  {job}:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)", text)
    if not match or "if: github.event_name == 'workflow_dispatch'" not in match.group("body"):
        raise SystemExit(1)
policy = re.search(r"(?ms)^  policy:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)", text)
if not policy or "./tests/test_static.sh" not in policy.group("body") or "./scripts/build.sh" in policy.group("body"):
    raise SystemExit(1)
PY

# Browser builds must never ingest a signing private key or share mutable download/build caches.
reject_pattern "$WORKFLOW" 'NEXAWRT_APK_SIGNING_PRIVATE|PRIVATE[_-]?KEY|secrets\.'
reject_pattern "$WORKFLOW" 'actions/cache@|\.work/.*/dl'

# Producer workflow identity comes from the immutable GitHub context and is restricted to two exact workflows.
require_fixed "$COMPARATOR" 'GITHUB_WORKFLOW_REF'
require_fixed "$COMPARATOR" 'tifycloud/NexaWrt/.github/workflows/release.yml'
require_fixed "$COMPARATOR" 'tifycloud/NexaWrt/.github/workflows/build.yml'
require_fixed "$COMPARATOR" '"--signer-workflow", actual_workflow'
require_fixed "$COMPARATOR" '"--signer-workflow", descriptor_workflow'
require_fixed "$COMPARATOR" '"--source-digest", descriptor_source_digest'
require_fixed "$COMPARATOR" '"--source-ref", descriptor_source_ref'
require_fixed "$COMPARATOR" '"--signer-digest", descriptor_signer_digest'
require_fixed "$COMPARATOR" 'descriptor_source_ref != "refs/heads/main"'
require_fixed "$COMPARATOR" 'apk_signing_mode=public-key-only'
require_fixed "$COMPARATOR" 'apk_index_signed=false'
require_fixed "$COMPARATOR" 'sys.executable'
reject_pattern "$COMPARATOR" '/usr/bin/python3'
require_fixed "$COMPARATOR" 'platform producer descriptors must bind one trusted workflow'
reject_pattern "$COMPARATOR" 'NEXAWRT_(TRUSTED_)?PRODUCER_WORKFLOW'

require_fixed "$HARDWARE_GATE" 'tifycloud/NexaWrt/.github/workflows/release.yml'
require_fixed "$HARDWARE_GATE" 'tifycloud/NexaWrt/.github/workflows/build.yml'
require_fixed "$HARDWARE_GATE" 'producer_workflows, producer_source_refs, producer_source_digests, producer_workflow_refs, producer_signer_digests'
require_fixed "$HARDWARE_GATE" 'source_digest != project_commit or signer_digest != project_commit or workflow_ref != f"{workflow}@{source_ref}"'
require_fixed "$HARDWARE_GATE" '[[ "$candidate_signing_mode" == public-key-only ]]'
require_fixed "$HARDWARE_GATE" '[[ "$candidate_index_signed" == false ]]'
require_fixed "$HARDWARE_GATE" 'candidate lacks two distinct producer identities bound to one trusted GitHub workflow'

echo 'test_browser_build_policy: passed'
