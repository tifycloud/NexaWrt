#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLAVOR="${1:-}"
LEFT_RAW="${2:-}"
RIGHT_RAW="${3:-}"
OUTPUT_RAW="${4:-}"

fail() { echo "reproducibility gate failed: $*" >&2; exit 1; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi; }
case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac

canonicalize_input() {
  python3 - "$ROOT_DIR" "$1" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
candidate = pathlib.Path(os.path.abspath(sys.argv[2]))
try:
    relative = candidate.relative_to(root)
except ValueError:
    raise SystemExit("replica is outside the project workspace")
current = root
for part in relative.parts:
    current = current / part
    if os.path.lexists(current) and current.is_symlink():
        raise SystemExit(f"replica path contains a symlink: {current}")
canonical = candidate.resolve(strict=True)
if not canonical.is_dir():
    raise SystemExit("replica is not a directory")
print(canonical)
PY
}

canonicalize_output() {
  python3 - "$ROOT_DIR" "$1" <<'PY'
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
absolute = pathlib.Path(os.path.abspath(sys.argv[2]))
legacy_output = root / "verified-dist"
work_staging_root = root / "release-staging"
if absolute == legacy_output:
    allowed_root = root
    relative = pathlib.Path("verified-dist")
else:
    try:
        relative = absolute.relative_to(work_staging_root)
    except ValueError:
        raise SystemExit("output is outside the project safe staging roots")
    if not relative.parts:
        raise SystemExit("output may not be the release-staging root")
    allowed_root = work_staging_root
if relative.name != "verified-dist":
    raise SystemExit("output must end in verified-dist")
if os.path.lexists(allowed_root) and allowed_root.is_symlink():
    raise SystemExit(f"staging root is a symlink: {allowed_root}")
current = allowed_root
for part in relative.parts:
    current = current / part
    if os.path.lexists(current) and current.is_symlink():
        raise SystemExit(f"output path contains a symlink: {current}")
canonical = absolute.resolve(strict=False)
try:
    canonical.relative_to(allowed_root)
except ValueError:
    raise SystemExit("canonical output is outside the project safe staging root")
print(canonical)
PY
}

LEFT="$(canonicalize_input "$LEFT_RAW")" || fail "unsafe left replica path: $LEFT_RAW"
RIGHT="$(canonicalize_input "$RIGHT_RAW")" || fail "unsafe right replica path: $RIGHT_RAW"
OUTPUT="$(canonicalize_output "$OUTPUT_RAW")" || fail "unsafe output directory: $OUTPUT_RAW"
[[ "$LEFT" != "$RIGHT" ]] || fail "replica directories must be distinct"
case "$OUTPUT/" in "$LEFT/"*|"$RIGHT/"*) fail "output must not be nested in a replica" ;; esac
case "$LEFT/" in "$OUTPUT/"*) fail "left replica must not be nested in output" ;; esac
case "$RIGHT/" in "$OUTPUT/"*) fail "right replica must not be nested in output" ;; esac

EXPECTED_IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
EXPECTED_MANIFEST='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
EXPECTED_SBOM='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'

verify_checksum_manifest() {
  local directory="$1" mode="${2:-replica}"
  python3 - "$directory" "$FLAVOR" "$mode" "$EXPECTED_IMAGE" "$EXPECTED_MANIFEST" "$EXPECTED_SBOM" <<'PY'
import hashlib
import os
import pathlib
import re
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
flavor = sys.argv[2]
mode = sys.argv[3]
image, package_manifest, sbom = sys.argv[4:7]
files = {
    image,
    package_manifest,
    sbom,
    "config.buildinfo",
    "feeds.buildinfo",
    "profiles.json",
    "version.buildinfo",
    "BUILD-MANIFEST.txt",
    "DO-NOT-FLASH.txt",
    "EVIDENCE/build.log",
    "EVIDENCE/resolved.config",
    "EVIDENCE/SOURCE-STATE.txt",
    "EVIDENCE/BUILD-ENVIRONMENT.txt",
    "EVIDENCE/INPUTS.sha256",
    "EVIDENCE/EVIDENCE.sha256",
}
if flavor == "nss":
    files.update({
        "THIRD_PARTY_NOTICES.md",
        "LICENSES/nss-firmware/LICENSE.md",
    })
if mode == "output":
    files.add("REPRODUCIBILITY.json")
expected_all = files | {"SHA256SUMS"}
expected_dirs = {"."}
for name in expected_all:
    parent = pathlib.PurePosixPath(name).parent
    while str(parent) != ".":
        expected_dirs.add(parent.as_posix())
        parent = parent.parent

actual_files = set()
actual_dirs = {"."}
for base, dirs, names in os.walk(root, topdown=True, followlinks=False):
    base_path = pathlib.Path(base)
    relative_base = base_path.relative_to(root)
    if relative_base.parts:
        actual_dirs.add(relative_base.as_posix())
    for name in list(dirs):
        path = base_path / name
        if path.is_symlink():
            raise SystemExit(f"symlink is not allowed in replica: {path.relative_to(root)}")
    for name in names:
        path = base_path / name
        relative = path.relative_to(root).as_posix()
        mode_bits = path.lstat().st_mode
        if stat.S_ISLNK(mode_bits):
            raise SystemExit(f"symlink is not allowed in replica: {relative}")
        if not stat.S_ISREG(mode_bits):
            raise SystemExit(f"non-regular file is not allowed in replica: {relative}")
        actual_files.add(relative)
if actual_files != expected_all:
    missing = sorted(expected_all - actual_files)
    extra = sorted(actual_files - expected_all)
    raise SystemExit(f"unexpected replica file set; missing={missing}, extra={extra}")
if actual_dirs != expected_dirs:
    missing = sorted(expected_dirs - actual_dirs)
    extra = sorted(actual_dirs - expected_dirs)
    raise SystemExit(f"unexpected replica directory set; missing={missing}, extra={extra}")

manifest_path = root / "SHA256SUMS"
try:
    lines = manifest_path.read_text(encoding="ascii").splitlines()
except (UnicodeDecodeError, OSError) as error:
    raise SystemExit(f"cannot read SHA256SUMS safely: {error}")
entry_pattern = re.compile(r"^([0-9a-f]{64})  (\./[^\r\n]+)$")
listed = {}
for line_number, line in enumerate(lines, 1):
    match = entry_pattern.fullmatch(line)
    if match is None:
        raise SystemExit(f"malformed SHA256SUMS line {line_number}")
    expected_hash, raw_name = match.groups()
    pure = pathlib.PurePosixPath(raw_name[2:])
    if not pure.parts or pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise SystemExit(f"unsafe SHA256SUMS path on line {line_number}: {raw_name}")
    name = pure.as_posix()
    if "\\" in raw_name or raw_name != f"./{name}":
        raise SystemExit(f"non-canonical SHA256SUMS path on line {line_number}: {raw_name}")
    if name == "SHA256SUMS":
        raise SystemExit("SHA256SUMS must not checksum itself")
    if name in listed:
        raise SystemExit(f"duplicate SHA256SUMS entry: {name}")
    listed[name] = expected_hash
if set(listed) != files:
    missing = sorted(files - set(listed))
    extra = sorted(set(listed) - files)
    raise SystemExit(f"SHA256SUMS does not name the exact file set; missing={missing}, extra={extra}")
for name, expected_hash in listed.items():
    path = root.joinpath(*pathlib.PurePosixPath(name).parts)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_hash:
        raise SystemExit(f"checksum mismatch: {name}")
PY
}

verify_checksum_manifest "$LEFT" replica || fail "left replica checksum/file policy failed"
verify_checksum_manifest "$RIGHT" replica || fail "right replica checksum/file policy failed"

for file in "$EXPECTED_IMAGE" "$EXPECTED_MANIFEST" config.buildinfo feeds.buildinfo profiles.json version.buildinfo BUILD-MANIFEST.txt DO-NOT-FLASH.txt EVIDENCE/INPUTS.sha256 EVIDENCE/resolved.config; do
  cmp -s "$LEFT/$file" "$RIGHT/$file" || fail "replicas differ: $file"
done
if [[ "$FLAVOR" == nss ]]; then
  for file in THIRD_PARTY_NOTICES.md LICENSES/nss-firmware/LICENSE.md; do
    cmp -s "$LEFT/$file" "$RIGHT/$file" || fail "NSS replicas differ: $file"
  done
fi

normalize_sbom() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
if document.get("bomFormat") != "CycloneDX":
    raise SystemExit("unexpected bomFormat")
components = document.get("components")
if not isinstance(components, list) or not components:
    raise SystemExit("components must be a non-empty list")
document.pop("serialNumber", None)
metadata = document.get("metadata")
if isinstance(metadata, dict):
    metadata.pop("timestamp", None)

def normalize(value):
    if isinstance(value, dict):
        return {key: normalize(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        values = [normalize(item) for item in value]
        if all(isinstance(item, dict) for item in values):
            values.sort(key=lambda item: (
                str(item.get("bom-ref", "")),
                str(item.get("name", "")),
                str(item.get("version", "")),
                json.dumps(item, sort_keys=True, separators=(",", ":")),
            ))
        else:
            values.sort(key=lambda item: json.dumps(item, sort_keys=True, separators=(",", ":")))
        return values
    return value

print(json.dumps(normalize(document), sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
}
left_sbom="$(normalize_sbom "$LEFT/$EXPECTED_SBOM")" || fail "left SBOM normalization failed"
right_sbom="$(normalize_sbom "$RIGHT/$EXPECTED_SBOM")" || fail "right SBOM normalization failed"
[[ "$left_sbom" == "$right_sbom" ]] || fail "normalized CycloneDX SBOMs differ"

image_sha="$(hash_file "$LEFT/$EXPECTED_IMAGE" | awk '{print $1}')"
rm -rf -- "$OUTPUT"
mkdir -p "$OUTPUT"
cp -a "$LEFT"/. "$OUTPUT"/
cat > "$OUTPUT/REPRODUCIBILITY.json" <<JSON
{"schema":1,"flavor":"$FLAVOR","reproducible":true,"firmware":"$EXPECTED_IMAGE","firmware_sha256":"$image_sha","run_id":"${GITHUB_RUN_ID:-local}","run_attempt":"${GITHUB_RUN_ATTEMPT:-local}"}
JSON
(
  cd "$OUTPUT"
  while IFS= read -r file; do hash_file "$file"; done < <(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
) > "$OUTPUT/SHA256SUMS"
verify_checksum_manifest "$OUTPUT" output || fail "verified output checksum/file policy failed"
printf 'Reproducibility gate passed; verified artifact written to %s\n' "$OUTPUT"
