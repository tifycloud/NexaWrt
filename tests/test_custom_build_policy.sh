#!/usr/bin/env bash
# shellcheck disable=SC2016 # Fixed strings intentionally inspect literal shell source.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKFLOW="$ROOT_DIR/.github/workflows/custom-build.yml"
CUSTOM_BUILD="$ROOT_DIR/scripts/custom-build.sh"
PREPARE="$ROOT_DIR/scripts/prepare.sh"
VM_BUILD="$ROOT_DIR/scripts/build-vm-image.sh"

fail() {
  printf 'custom build policy test failed: %s\n' "$*" >&2
  exit 1
}

require_fixed() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "missing required policy text in ${file#"$ROOT_DIR"/}: $text"
}

for file in "$WORKFLOW" "$CUSTOM_BUILD" "$PREPARE" "$VM_BUILD"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "required file is missing or symlinked: ${file#"$ROOT_DIR"/}"
done
[[ -x "$CUSTOM_BUILD" ]] || fail "scripts/custom-build.sh is not executable"
bash -n "$CUSTOM_BUILD"
bash -n "$PREPARE"
bash -n "$VM_BUILD"

python3 - "$WORKFLOW" <<'PY' || fail "workflow inputs/actions are not strictly allow-listed"
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if not re.search(r"(?m)^  workflow_dispatch:\s*$", text):
    raise SystemExit("workflow_dispatch is missing")
if re.search(r"(?m)^  (push|pull_request|schedule|repository_dispatch|workflow_call):", text):
    raise SystemExit("unexpected workflow trigger")
inputs_match = re.search(
    r"(?ms)^    inputs:\n(?P<body>.*?)(?=^permissions:|^jobs:)", text
)
if not inputs_match:
    raise SystemExit("inputs block is missing")
input_keys = set(re.findall(r"(?m)^      ([a-z][a-z0-9_-]*):\s*$", inputs_match.group("body")))
if input_keys != {"target", "flavor", "components", "catalog_version", "request_hash"}:
    raise SystemExit(f"unexpected workflow inputs: {sorted(input_keys)}")
for forbidden in ("package", "packages", "script", "command", "path", "config", "kconfig"):
    if re.search(rf"(?m)^      {re.escape(forbidden)}:\s*$", inputs_match.group("body")):
        raise SystemExit(f"forbidden workflow input: {forbidden}")
for action in re.findall(r"(?m)^\s*uses:\s*([^\s#]+)", text):
    if not re.fullmatch(r"[^@\s]+@[0-9a-f]{40}", action):
        raise SystemExit(f"action is not pinned to a full commit SHA: {action}")
for run_block in re.findall(r"(?ms)^\s+run: \|\n(?P<body>(?:\s{10}.*\n?)*)", text):
    if "${{ inputs." in run_block:
        raise SystemExit("workflow input interpolation is forbidden inside run blocks")
PY

require_fixed "$WORKFLOW" 'type: choice'
require_fixed "$WORKFLOW" '          - x86_64'
require_fixed "$WORKFLOW" '          - xiaomi_ax9000'
require_fixed "$WORKFLOW" '          - official'
require_fixed "$WORKFLOW" '          - nss'
require_fixed "$WORKFLOW" 'required: false'
require_fixed "$WORKFLOW" "default: ''"
require_fixed "$WORKFLOW" "test \"\$GITHUB_REF\" = 'refs/heads/main'"
require_fixed "$WORKFLOW" "test \"\$GITHUB_WORKFLOW_SHA\" = \"\$GITHUB_SHA\""
require_fixed "$WORKFLOW" 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683'
require_fixed "$WORKFLOW" 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
require_fixed "$WORKFLOW" 'REQUESTED_CATALOG_VERSION: ${{ inputs.catalog_version }}'
require_fixed "$WORKFLOW" 'REQUESTED_REQUEST_HASH: ${{ inputs.request_hash }}'
require_fixed "$WORKFLOW" '[[ "$REQUESTED_REQUEST_HASH" =~ ^[0-9a-f]{64}$ ]]'
require_fixed "$WORKFLOW" './scripts/custom-build.sh'
require_fixed "$WORKFLOW" 'if-no-files-found: error'
require_fixed "$WORKFLOW" 'compression-level: 0'

require_fixed "$CUSTOM_BUILD" 'scripts/resolve-components.py'
require_fixed "$CUSTOM_BUILD" 'An empty component'
require_fixed "$CUSTOM_BUILD" 'x86_64|xiaomi_ax9000'
require_fixed "$CUSTOM_BUILD" 'official|nss'
require_fixed "$CUSTOM_BUILD" 'nss flavor is supported only for xiaomi_ax9000'
require_fixed "$CUSTOM_BUILD" 'RESOLVER_ARGS=(--target "$TARGET" --flavor "$FLAVOR")'
require_fixed "$CUSTOM_BUILD" 'catalog version does not match the repository catalog'
require_fixed "$CUSTOM_BUILD" 'request hash does not match the normalized catalog request'
require_fixed "$CUSTOM_BUILD" 'NEXAWRT_COMPONENT_FLAVOR="$FLAVOR"'
require_fixed "$CUSTOM_BUILD" 'NEXAWRT_COMPONENT_CATALOG_VERSION="$CATALOG_VERSION"'
require_fixed "$CUSTOM_BUILD" 'NEXAWRT_COMPONENT_REQUEST_HASH="$REQUEST_HASH"'
require_fixed "$CUSTOM_BUILD" '"$ROOT_DIR/scripts/build-vm-image.sh" x86-64 custom'
require_fixed "$CUSTOM_BUILD" 'NEXAWRT_COMPONENT_TARGET=xiaomi_ax9000'
require_fixed "$CUSTOM_BUILD" 'DIST_DIR_OVERRIDE="$ARTIFACT_DIR"'
require_fixed "$CUSTOM_BUILD" 'DIST_NSS_DIR_OVERRIDE="$ARTIFACT_DIR"'
for manifest_field in commit catalog_version request_hash resolved_components resolved_packages packages sha256 build_environment runner image_os image_version os arch dpkg_packages tools scope; do
  require_fixed "$CUSTOM_BUILD" "\"$manifest_field\""
done
if grep -Eq '(^|[^[:alnum:]_])(eval|bash[[:space:]]+-c|sh[[:space:]]+-c)([^[:alnum:]_]|$)' "$CUSTOM_BUILD"; then
  fail "custom build script contains a shell evaluation primitive"
fi

require_fixed "$PREPARE" 'NEXAWRT_COMPONENT_TARGET must be xiaomi_ax9000'
require_fixed "$PREPARE" 'NEXAWRT_COMPONENT_FLAVOR must be official or nss'
require_fixed "$PREPARE" 'NEXAWRT_COMPONENT_CATALOG_VERSION must be a valid catalog version'
require_fixed "$PREPARE" 'NEXAWRT_COMPONENT_REQUEST_HASH must be a full lowercase SHA256 value'
require_fixed "$PREPARE" 'scripts/resolve-components.py'
require_fixed "$PREPARE" 'request["kconfig_fragment"]'
python3 - "$PREPARE" <<'PY' || fail "component Kconfig fragment is not merged immediately before defconfig"
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
if not re.search(r'cp "\$SEED_CONFIG" \.config\n\s*apply_component_kconfig\n\s*make defconfig', text):
    raise SystemExit(1)
PY

require_fixed "$VM_BUILD" 'build-vm-image.sh x86-64 custom'
require_fixed "$VM_BUILD" 'NEXAWRT_COMPONENTS'
require_fixed "$VM_BUILD" 'NEXAWRT_COMPONENT_FLAVOR'
require_fixed "$VM_BUILD" 'NEXAWRT_COMPONENT_CATALOG_VERSION'
require_fixed "$VM_BUILD" 'NEXAWRT_COMPONENT_REQUEST_HASH'
require_fixed "$VM_BUILD" 'VM_SMOKE_AUTHORIZED_KEY_FILE must not be set in custom mode'
require_fixed "$VM_BUILD" 'CUSTOM_RESOLVED_COMPONENTS="${custom_resolution_fields[3]}"'
require_fixed "$VM_BUILD" 'CUSTOM_PACKAGES=("${custom_resolution_fields[@]:4}")'
require_fixed "$VM_BUILD" 'VM_BASELINE_PACKAGES=('
require_fixed "$VM_BUILD" '  dropbear'
require_fixed "$VM_BUILD" 'VM_PACKAGES+=("$custom_package")'
require_fixed "$VM_BUILD" 'custom-imagebuilder-packages.json'
require_fixed "$VM_BUILD" '"PACKAGES=$PACKAGE_LIST"'
for file in "$WORKFLOW" "$CUSTOM_BUILD" "$PREPARE" "$VM_BUILD"; do
  if grep -Fq -- '--no-defaults' "$file"; then
    fail "custom build chain exposes --no-defaults in ${file#"$ROOT_DIR"/}"
  fi
done

default_request="$(python3 "$ROOT_DIR/scripts/resolve-components.py" --target x86_64 --flavor official)" ||
  fail "empty component selection did not resolve catalog defaults"
python3 -c '
import json, sys
request = json.load(sys.stdin)
assert request["flavor"] == "official"
assert request["requested_components"] == []
assert request["default_components"]
assert "web-ui" in request["resolved_components"]
assert request["packages"]
' <<< "$default_request" || fail "empty component selection did not preserve catalog defaults"
default_hash="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["request_hash"])' <<< "$default_request")"
catalog_version="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["catalog_version"])' <<< "$default_request")"
web_ui_hash="$(python3 "$ROOT_DIR/scripts/resolve-components.py" --target x86_64 --flavor official --component web-ui | python3 -c 'import json, sys; print(json.load(sys.stdin)["request_hash"])')"
empty_default_log="$(mktemp "${TMPDIR:-/tmp}/nexawrt-empty-components.XXXXXX")"
trap 'rm -f "$empty_default_log"' EXIT
if VM_ROOTFS_PARTSIZE=0 \
  NEXAWRT_COMPONENTS='' \
  NEXAWRT_COMPONENT_FLAVOR=official \
  NEXAWRT_COMPONENT_CATALOG_VERSION="$catalog_version" \
  NEXAWRT_COMPONENT_REQUEST_HASH="$default_hash" \
  "$VM_BUILD" x86-64 custom >"$empty_default_log" 2>&1; then
  fail "empty component selection unexpectedly completed the no-build fixture"
fi
grep -Fq 'VM_ROOTFS_PARTSIZE must be a positive integer' "$empty_default_log" ||
  fail "empty component selection did not pass catalog resolution before the no-build fixture stopped"

expect_rejected() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description was unexpectedly accepted"
  fi
}

expect_rejected "missing arguments" "$CUSTOM_BUILD"
expect_rejected "nss x86 request" "$CUSTOM_BUILD" x86_64 nss web-ui "$catalog_version" "$web_ui_hash"
expect_rejected "path-like component input" "$CUSTOM_BUILD" x86_64 official 'web-ui,../dropbear' "$catalog_version" "$web_ui_hash"
expect_rejected "space-containing component input" "$CUSTOM_BUILD" x86_64 official 'web-ui, wireguard' "$catalog_version" "$web_ui_hash"
expect_rejected "unknown component" "$CUSTOM_BUILD" x86_64 official definitely-not-a-component "$catalog_version" "$web_ui_hash"
expect_rejected "duplicate component" "$CUSTOM_BUILD" x86_64 official web-ui,web-ui "$catalog_version" "$web_ui_hash"
expect_rejected "conflicting components" "$CUSTOM_BUILD" xiaomi_ax9000 official sqm,qosify "$catalog_version" "$web_ui_hash"
expect_rejected "stale catalog version" "$CUSTOM_BUILD" x86_64 official web-ui 2026.07.20.999 "$web_ui_hash"
expect_rejected "forged browser request hash" "$CUSTOM_BUILD" x86_64 official web-ui "$catalog_version" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_rejected "flavor-bound request hash" "$CUSTOM_BUILD" xiaomi_ax9000 nss '' "$catalog_version" "$default_hash"
expect_rejected "custom VM build without catalog request" "$VM_BUILD" x86-64 custom
expect_rejected "custom VM build with forged hash" env \
  NEXAWRT_COMPONENTS=web-ui \
  NEXAWRT_COMPONENT_FLAVOR=official \
  NEXAWRT_COMPONENT_CATALOG_VERSION="$catalog_version" \
  NEXAWRT_COMPONENT_REQUEST_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$VM_BUILD" x86-64 custom
expect_rejected "prepare path-like component input" env \
  NEXAWRT_COMPONENT_TARGET=xiaomi_ax9000 \
  NEXAWRT_COMPONENT_FLAVOR=official \
  NEXAWRT_COMPONENT_CATALOG_VERSION="$catalog_version" \
  NEXAWRT_COMPONENT_REQUEST_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  NEXAWRT_COMPONENTS='../dropbear' \
  "$PREPARE" --no-feeds
expect_rejected "prepare non-AX target" env \
  NEXAWRT_COMPONENT_TARGET=x86_64 NEXAWRT_COMPONENTS=web-ui \
  "$PREPARE" --no-feeds

echo 'custom build policy: strict catalog inputs, pinned Actions, safe routing, Kconfig merge, and manifest fields OK'
