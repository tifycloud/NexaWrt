#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RESOLVER="$ROOT_DIR/scripts/resolve-components.py"
CUSTOM_ARTIFACTS="$ROOT_DIR/scripts/custom-artifacts.py"

fail() {
  printf 'custom build refused: %s\n' "$*" >&2
  exit 2
}

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/custom-build.sh <x86_64|xiaomi_ax9000> <official|nss> <component-id[,component-id...]> <catalog-version> <request-hash>

Only component IDs from components/catalog.json are accepted. An empty component
string selects catalog defaults. Package names, commands, scripts, paths, and
whitespace are never accepted. The catalog version and request hash must exactly
match the repository resolver output for the target, flavor, and selection.
USAGE
}

[[ "$#" -eq 5 ]] || { usage; fail "expected exactly target, flavor, components, catalog version, and request hash"; }
TARGET="$1"
FLAVOR="$2"
COMPONENTS="$3"
SUPPLIED_CATALOG_VERSION="$4"
SUPPLIED_REQUEST_HASH="$5"

case "$TARGET" in
  x86_64|xiaomi_ax9000) ;;
  *) fail "unsupported target: $TARGET" ;;
esac
case "$FLAVOR" in
  official|nss) ;;
  *) fail "unsupported flavor: $FLAVOR" ;;
esac
if [[ "$FLAVOR" == nss && "$TARGET" != xiaomi_ax9000 ]]; then
  fail "nss flavor is supported only for xiaomi_ax9000"
fi
[[ ${#COMPONENTS} -le 1024 ]] || fail "components input is too long"
[[ "$SUPPLIED_CATALOG_VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] ||
  fail "catalog version must use YYYY.MM.DD or YYYY.MM.DD.N"
[[ "$SUPPLIED_REQUEST_HASH" =~ ^[0-9a-f]{64}$ ]] ||
  fail "request hash must be a full lowercase SHA256 value"
if [[ -n "$COMPONENTS" ]]; then
  [[ "$COMPONENTS" =~ ^[a-z0-9][a-z0-9_-]{0,63}(,[a-z0-9][a-z0-9_-]{0,63})*$ ]] ||
    fail "non-empty components must contain only comma-separated catalog component IDs"
fi
[[ -f "$RESOLVER" && ! -L "$RESOLVER" ]] || fail "component resolver is missing or unsafe"
[[ -f "$CUSTOM_ARTIFACTS" && ! -L "$CUSTOM_ARTIFACTS" ]] || fail "custom artifact auditor is missing or unsafe"

RESOLVER_ARGS=(--target "$TARGET" --flavor "$FLAVOR")
if [[ -n "$COMPONENTS" ]]; then
  IFS=',' read -r -a REQUESTED_COMPONENTS <<< "$COMPONENTS"
  for component_id in "${REQUESTED_COMPONENTS[@]}"; do
    RESOLVER_ARGS+=(--component "$component_id")
  done
fi
RESOLVED_JSON="$({ python3 "$RESOLVER" "${RESOLVER_ARGS[@]}"; } 2> >(cat >&2))" ||
  fail "component selection was rejected"

request_fields_output="$(python3 -c '
import json, re, sys
request = json.load(sys.stdin)
request_hash = request.get("request_hash", "")
target = request.get("target", {}).get("id", "")
flavor = request.get("flavor", "")
catalog_version = request.get("catalog_version", "")
packages = request.get("packages")
components = request.get("resolved_components")
if not re.fullmatch(r"[0-9a-f]{64}", request_hash):
    raise SystemExit("resolver returned an invalid request hash")
if target not in {"x86_64", "xiaomi_ax9000"}:
    raise SystemExit("resolver returned an invalid target")
if flavor not in {"official", "nss"}:
    raise SystemExit("resolver returned an invalid flavor")
if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]+)?", catalog_version):
    raise SystemExit("resolver returned an invalid catalog version")
if not isinstance(packages, list) or not packages:
    raise SystemExit("resolver returned no packages")
if not isinstance(components, list) or not components:
    raise SystemExit("resolver returned no components")
print(request_hash)
print(target)
print(flavor)
print(catalog_version)
' <<< "$RESOLVED_JSON")" || fail "resolver output failed validation"
REQUEST_FIELDS=()
while IFS= read -r request_field; do
  REQUEST_FIELDS+=("$request_field")
done <<< "$request_fields_output"
[[ "${#REQUEST_FIELDS[@]}" -eq 4 ]] || fail "resolver output is incomplete"
REQUEST_HASH="${REQUEST_FIELDS[0]}"
CATALOG_VERSION="${REQUEST_FIELDS[3]}"
[[ "${REQUEST_FIELDS[1]}" == "$TARGET" ]] || fail "resolver target mismatch"
[[ "${REQUEST_FIELDS[2]}" == "$FLAVOR" ]] || fail "resolver flavor mismatch"
[[ "$CATALOG_VERSION" == "$SUPPLIED_CATALOG_VERSION" ]] ||
  fail "catalog version does not match the repository catalog"
[[ "$REQUEST_HASH" == "$SUPPLIED_REQUEST_HASH" ]] ||
  fail "request hash does not match the normalized catalog request"
PROJECT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}')" || fail "project commit is unavailable"
[[ "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "project commit must be a full lowercase Git object ID"

BUILD_ROOT="$ROOT_DIR/.work/custom-build/$REQUEST_HASH"
RELEASE_ROOT="$ROOT_DIR/release-staging/custom-$REQUEST_HASH"
python3 - "$ROOT_DIR" "$BUILD_ROOT" "$RELEASE_ROOT" <<'PY' || fail "unsafe custom build staging path"
import os
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
allowed = {
    (root / ".work" / "custom-build").resolve(strict=False): pathlib.Path(sys.argv[2]),
    (root / "release-staging").resolve(strict=False): pathlib.Path(sys.argv[3]),
}
for allowed_root, raw in allowed.items():
    absolute = pathlib.Path(os.path.abspath(raw))
    try:
        relative = absolute.relative_to(allowed_root)
    except ValueError:
        raise SystemExit(f"path escapes its staging root: {absolute}")
    if not relative.parts:
        raise SystemExit(f"refusing staging root itself: {absolute}")
    current = allowed_root
    if os.path.lexists(current) and current.is_symlink():
        raise SystemExit(f"staging root is a symlink: {current}")
    for part in relative.parts:
        current = current / part
        if os.path.lexists(current) and current.is_symlink():
            raise SystemExit(f"staging path contains a symlink: {current}")
    if os.path.lexists(absolute):
        if absolute.is_symlink() or not absolute.is_dir():
            raise SystemExit(f"staging path is not a safe directory: {absolute}")
        shutil.rmtree(absolute)
    absolute.mkdir(parents=True, mode=0o755)
PY

REQUEST_FILE="$BUILD_ROOT/request.json"
printf '%s\n' "$RESOLVED_JSON" > "$REQUEST_FILE"

case "$TARGET" in
  x86_64)
    [[ "$FLAVOR" == official ]] || fail "x86_64 supports the official flavor only"
    VM_OUTPUT_DIR="$RELEASE_ROOT" \
    VM_WORK_DIR="$BUILD_ROOT/vm" \
    NEXAWRT_COMPONENTS="$COMPONENTS" \
    NEXAWRT_COMPONENT_FLAVOR="$FLAVOR" \
    NEXAWRT_COMPONENT_CATALOG_VERSION="$CATALOG_VERSION" \
    NEXAWRT_COMPONENT_REQUEST_HASH="$REQUEST_HASH" \
    NEXAWRT_PROJECT_COMMIT="$PROJECT_COMMIT" \
      "$ROOT_DIR/scripts/build-vm-image.sh" x86-64 custom
    ARTIFACT_DIR="$RELEASE_ROOT/x86-64"
    ;;
  xiaomi_ax9000)
    WORK_DIR="$BUILD_ROOT/openwrt-$FLAVOR"
    BUILD_LOG="$BUILD_ROOT/build-$FLAVOR.log"
    if [[ "$FLAVOR" == official ]]; then
      ARTIFACT_DIR="$RELEASE_ROOT/dist"
      NEXAWRT_FLAVOR=official \
      NEXAWRT_COMPONENT_TARGET=xiaomi_ax9000 \
      NEXAWRT_COMPONENT_FLAVOR=official \
      NEXAWRT_COMPONENT_CATALOG_VERSION="$CATALOG_VERSION" \
      NEXAWRT_COMPONENT_REQUEST_HASH="$REQUEST_HASH" \
      NEXAWRT_COMPONENTS="$COMPONENTS" \
      WORK_DIR="$WORK_DIR" BUILD_LOG="$BUILD_LOG" CLEAN_BUILD=1 \
      DIST_DIR_OVERRIDE="$ARTIFACT_DIR" \
        "$ROOT_DIR/scripts/build.sh"
    else
      ARTIFACT_DIR="$RELEASE_ROOT/dist-nss"
      NEXAWRT_FLAVOR=nss \
      NEXAWRT_COMPONENT_TARGET=xiaomi_ax9000 \
      NEXAWRT_COMPONENT_FLAVOR=nss \
      NEXAWRT_COMPONENT_CATALOG_VERSION="$CATALOG_VERSION" \
      NEXAWRT_COMPONENT_REQUEST_HASH="$REQUEST_HASH" \
      NEXAWRT_COMPONENTS="$COMPONENTS" \
      WORK_DIR="$WORK_DIR" BUILD_LOG="$BUILD_LOG" CLEAN_BUILD=1 \
      DIST_NSS_DIR_OVERRIDE="$ARTIFACT_DIR" \
        "$ROOT_DIR/scripts/build.sh"
    fi
    ;;
esac

[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" ]] || fail "build did not produce a safe artifact directory"
MANIFEST_PATH="$ARTIFACT_DIR/custom-build-manifest.json"
CHECKSUMS_PATH="$ARTIFACT_DIR/SHA256SUMS"
if ! python3 "$CUSTOM_ARTIFACTS" finalize \
  --artifact-dir "$ARTIFACT_DIR" \
  --request-file "$REQUEST_FILE" \
  --expected-commit "$PROJECT_COMMIT" \
  --expected-target "$TARGET" \
  --expected-flavor "$FLAVOR" \
  --expected-request-hash "$REQUEST_HASH"; then
  fail "unable to create and audit custom build manifest"
fi
[[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" && -s "$MANIFEST_PATH" ]] ||
  fail "custom build manifest is missing, empty, symlinked, or not a regular file"
[[ -f "$CHECKSUMS_PATH" && ! -L "$CHECKSUMS_PATH" && -s "$CHECKSUMS_PATH" ]] ||
  fail "SHA256SUMS is missing, empty, symlinked, or not a regular file"
if ! python3 "$CUSTOM_ARTIFACTS" audit \
  --artifact-dir "$ARTIFACT_DIR" \
  --manifest "$MANIFEST_PATH" \
  --expected-commit "$PROJECT_COMMIT" \
  --expected-target "$TARGET" \
  --expected-flavor "$FLAVOR" \
  --expected-request-hash "$REQUEST_HASH"; then
  fail "custom build artifact postcondition audit failed"
fi
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required to verify custom build artifacts"
if ! (cd "$ARTIFACT_DIR" && sha256sum --check --strict SHA256SUMS); then
  fail "custom build SHA256SUMS verification failed"
fi

ARTIFACT_NAME="NexaWrt-custom-${TARGET}-${FLAVOR}-${REQUEST_HASH:0:12}"
printf 'Custom build artifacts: %s\n' "$ARTIFACT_DIR"
printf 'Request hash: %s\n' "$REQUEST_HASH"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'artifact_dir=%s\n' "$ARTIFACT_DIR"
    printf 'artifact_name=%s\n' "$ARTIFACT_NAME"
    printf 'manifest=%s\n' "$MANIFEST_PATH"
    printf 'request_hash=%s\n' "$REQUEST_HASH"
  } >> "$GITHUB_OUTPUT"
fi
