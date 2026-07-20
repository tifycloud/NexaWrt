#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RESOLVER="$ROOT_DIR/scripts/resolve-components.py"

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
cp "$REQUEST_FILE" "$ARTIFACT_DIR/custom-request.json"
MANIFEST_PATH="$ARTIFACT_DIR/custom-build-manifest.json"
python3 - "$ARTIFACT_DIR" "$REQUEST_FILE" "$PROJECT_COMMIT" "$FLAVOR" <<'PY' ||
  fail "unable to create custom build manifest"
import hashlib
import json
import os
import pathlib
import platform
import shutil
import stat
import subprocess
import sys

artifact_dir = pathlib.Path(sys.argv[1]).resolve(strict=True)
request_path = pathlib.Path(sys.argv[2]).resolve(strict=True)
project_commit = sys.argv[3]
flavor = sys.argv[4]
request = json.loads(request_path.read_text(encoding="utf-8"))
manifest_path = artifact_dir / "custom-build-manifest.json"
checksums_path = artifact_dir / "SHA256SUMS"


def digest(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def command_version(command: str, *arguments: str) -> str | None:
    executable = shutil.which(command)
    if executable is None:
        return None
    try:
        result = subprocess.run(
            [executable, *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    output = result.stdout.strip().splitlines()
    return output[0][:500] if output else None


def dpkg_versions() -> dict[str, str]:
    if shutil.which("dpkg-query") is None:
        return {}
    packages = [
        "build-essential", "clang", "gcc", "g++", "make", "libc6-dev",
        "python3", "git", "rsync", "zstd",
    ]
    versions: dict[str, str] = {}
    for package in packages:
        try:
            result = subprocess.run(
                ["dpkg-query", "-W", "-f=${Status}\t${Version}\n", package],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        fields = result.stdout.strip().split("\t", 1)
        if result.returncode == 0 and len(fields) == 2 and fields[0] == "install ok installed":
            versions[package] = fields[1][:200]
    return versions


def os_release() -> dict[str, str]:
    path = pathlib.Path("/etc/os-release")
    if not path.is_file() or path.is_symlink():
        return {}
    allowed = {"ID", "VERSION_ID", "PRETTY_NAME"}
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if separator and key in allowed:
            values[key.lower()] = value.strip().strip('"')[:300]
    return values


def build_environment() -> dict[str, object]:
    release = os_release()
    tools = {
        "bash": command_version("bash", "--version"),
        "clang": command_version("clang", "--version"),
        "gcc": command_version("gcc", "--version"),
        "git": command_version("git", "--version"),
        "make": command_version("make", "--version"),
        "python3": command_version("python3", "--version"),
        "tar": command_version("tar", "--version"),
        "zstd": command_version("zstd", "--version"),
    }
    return {
        "scope": "informational host metadata; not a reproducible-build guarantee",
        "runner": {
            "provider": "github-actions" if os.environ.get("GITHUB_ACTIONS") == "true" else "local",
            "name": os.environ.get("RUNNER_NAME", "local"),
            "image_os": os.environ.get("ImageOS") or release.get("pretty_name") or platform.system(),
            "image_version": os.environ.get("ImageVersion") or release.get("version_id") or "unknown",
            "os": os.environ.get("RUNNER_OS", platform.system()),
            "arch": os.environ.get("RUNNER_ARCH", platform.machine()),
        },
        "host": {
            "platform": platform.platform(),
            "os_release": release,
        },
        "dpkg_packages": dpkg_versions(),
        "tools": {name: version for name, version in tools.items() if version is not None},
    }


artifacts = []
for path in sorted(artifact_dir.rglob("*")):
    if path == manifest_path or path == checksums_path:
        continue
    file_stat = path.lstat()
    if stat.S_ISLNK(file_stat.st_mode):
        raise SystemExit(f"artifact tree contains a symlink: {path}")
    if not stat.S_ISREG(file_stat.st_mode):
        continue
    relative = path.relative_to(artifact_dir).as_posix()
    artifacts.append({"name": relative, "sha256": digest(path), "size": file_stat.st_size})
if not artifacts:
    raise SystemExit("artifact directory is empty")

target = request["target"]["id"]
if request.get("flavor") != flavor:
    raise SystemExit("manifest flavor does not match the normalized request")
resolved_packages = request["packages"]
if target == "x86_64":
    package_record = artifact_dir / "custom-imagebuilder-packages.json"
    if not package_record.is_file() or package_record.is_symlink():
        raise SystemExit("x86 custom build is missing its final ImageBuilder package record")
    actual_packages = json.loads(package_record.read_text(encoding="utf-8"))
else:
    config_buildinfo = artifact_dir / "config.buildinfo"
    if not config_buildinfo.is_file() or config_buildinfo.is_symlink():
        raise SystemExit("AX9000 custom build is missing config.buildinfo")
    prefix = "CONFIG_PACKAGE_"
    suffix = "=y"
    actual_packages = sorted({
        line[len(prefix):-len(suffix)]
        for line in config_buildinfo.read_text(encoding="utf-8").splitlines()
        if line.startswith(prefix) and line.endswith(suffix)
    })
if (
    not isinstance(actual_packages, list)
    or not actual_packages
    or any(not isinstance(package, str) or not package for package in actual_packages)
    or len(actual_packages) != len(set(actual_packages))
):
    raise SystemExit("final package set is empty, duplicated, or invalid")
missing_resolved = sorted(set(resolved_packages) - set(actual_packages))
if missing_resolved:
    raise SystemExit(f"final package set omitted resolved packages: {missing_resolved}")

manifest = {
    "schema_version": 1,
    "project": "NexaWrt",
    "commit": project_commit,
    "request_hash": request["request_hash"],
    "catalog_version": request["catalog_version"],
    "target": target,
    "flavor": flavor,
    "build_environment": build_environment(),
    "resolved_components": request["resolved_components"],
    "resolved_packages": resolved_packages,
    "packages": actual_packages,
    "artifacts": artifacts,
}
temporary = manifest_path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(temporary, manifest_path)

checksum_lines = []
for path in sorted(artifact_dir.rglob("*")):
    if path == checksums_path or not path.is_file():
        continue
    if path.is_symlink():
        raise SystemExit(f"artifact tree contains a symlink: {path}")
    checksum_lines.append(f"{digest(path)}  {path.relative_to(artifact_dir).as_posix()}")
checksums_path.write_text("\n".join(checksum_lines) + "\n", encoding="utf-8")
PY

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
