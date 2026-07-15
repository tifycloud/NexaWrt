#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=sanitize-git-environment.sh
source "$ROOT_DIR/scripts/sanitize-git-environment.sh"
nexawrt_sanitize_git_environment
EXPECTED_IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
EXPECTED_MANIFEST='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
EXPECTED_SBOM='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'

fail() { echo "reproducibility gate failed: $*" >&2; exit 1; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi; }

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

verify_distribution() {
  local directory="$1" flavor="$2" mode="$3"
  python3 - "$ROOT_DIR" "$directory" "$flavor" "$mode" "$EXPECTED_IMAGE" "$EXPECTED_MANIFEST" "$EXPECTED_SBOM" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

repo = pathlib.Path(sys.argv[1]).resolve(strict=True)
raw_dist = pathlib.Path(os.path.abspath(sys.argv[2]))
flavor = sys.argv[3]
mode = sys.argv[4]
image, package_manifest, sbom = sys.argv[5:8]
if flavor not in {"official", "nss"} or mode not in {"replica", "output"}:
    raise SystemExit("invalid validation mode")
if raw_dist.is_symlink():
    raise SystemExit("distribution directory must not be a symlink")
dist = raw_dist.resolve(strict=True)
if not dist.is_dir():
    raise SystemExit("distribution is not a directory")
if mode == "output" and dist.name != "verified-dist":
    raise SystemExit("verified output directory must be named verified-dist")

base_files = {
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
    "EVIDENCE/BUILD-IDENTITY.txt",
    "EVIDENCE/INPUTS.sha256",
    "EVIDENCE/EVIDENCE.sha256",
}
if flavor == "nss":
    base_files.update({
        "THIRD_PARTY_NOTICES.md",
        "LICENSES/nss-firmware/LICENSE.md",
    })
files = set(base_files)
platform_provenance_expected = False
if mode == "output":
    try:
        preliminary = json.loads(
            (dist / "REPRODUCIBILITY.json").read_text(encoding="utf-8", errors="strict"),
            object_pairs_hook=lambda pairs: dict(pairs),
        )
        preliminary_ids = [item.get("producer_id") for item in preliminary.get("input_builds", []) if isinstance(item, dict)]
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        preliminary_ids = []
    github_pattern = re.compile(r"github-artifact:[1-9][0-9]*:bundle-sha256:[0-9a-f]{64}")
    local_ids = ["local-unattested:a", "local-unattested:b"]
    if len(preliminary_ids) == 2 and all(isinstance(item, str) and github_pattern.fullmatch(item) for item in preliminary_ids):
        platform_provenance_expected = True
    elif preliminary_ids != local_ids:
        raise SystemExit("cannot determine strict producer provenance file set")
    files.update({
        "REPRODUCIBILITY.json",
        "REPRODUCIBILITY/left.SHA256SUMS",
        "REPRODUCIBILITY/right.SHA256SUMS",
        "REPRODUCIBILITY/left.BUILD-IDENTITY.txt",
        "REPRODUCIBILITY/right.BUILD-IDENTITY.txt",
        "REPRODUCIBILITY/left.EVIDENCE.sha256",
        "REPRODUCIBILITY/right.EVIDENCE.sha256",
    })
    if platform_provenance_expected:
        files.update({
            "REPRODUCIBILITY/left.producer-descriptor.json",
            "REPRODUCIBILITY/right.producer-descriptor.json",
            "REPRODUCIBILITY/left.provenance.bundle.json",
            "REPRODUCIBILITY/right.provenance.bundle.json",
        })
expected_all = files | {"SHA256SUMS"}
expected_dirs = {"."}
for name in expected_all:
    parent = pathlib.PurePosixPath(name).parent
    while str(parent) != ".":
        expected_dirs.add(parent.as_posix())
        parent = parent.parent

actual_files = set()
actual_dirs = {"."}
for base, dirs, names in os.walk(dist, topdown=True, followlinks=False):
    base_path = pathlib.Path(base)
    relative_base = base_path.relative_to(dist)
    if relative_base.parts:
        actual_dirs.add(relative_base.as_posix())
    for name in list(dirs):
        path = base_path / name
        if path.is_symlink():
            raise SystemExit(f"symlink is not allowed in distribution: {path.relative_to(dist)}")
    for name in names:
        path = base_path / name
        relative = path.relative_to(dist).as_posix()
        mode_bits = path.lstat().st_mode
        if stat.S_ISLNK(mode_bits):
            raise SystemExit(f"symlink is not allowed in distribution: {relative}")
        if not stat.S_ISREG(mode_bits):
            raise SystemExit(f"non-regular file is not allowed in distribution: {relative}")
        actual_files.add(relative)
if actual_files != expected_all:
    missing = sorted(expected_all - actual_files)
    extra = sorted(actual_files - expected_all)
    raise SystemExit(f"unexpected distribution file set; missing={missing}, extra={extra}")
if actual_dirs != expected_dirs:
    missing = sorted(expected_dirs - actual_dirs)
    extra = sorted(actual_dirs - expected_dirs)
    raise SystemExit(f"unexpected distribution directory set; missing={missing}, extra={extra}")

def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def parse_checksum_lines(lines, expected, label, prefix="./"):
    pattern = re.compile(r"^([0-9a-f]{64})  (\./[^\r\n]+)$" if prefix == "./" else r"^([0-9a-f]{64})  ([^\r\n]+)$")
    listed = {}
    for line_number, line in enumerate(lines, 1):
        match = pattern.fullmatch(line)
        if match is None:
            raise SystemExit(f"malformed {label} line {line_number}")
        expected_hash, raw_name = match.groups()
        name_text = raw_name[2:] if prefix == "./" else raw_name
        pure = pathlib.PurePosixPath(name_text)
        if not pure.parts or pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
            raise SystemExit(f"unsafe {label} path on line {line_number}: {raw_name}")
        name = pure.as_posix()
        canonical = f"./{name}" if prefix == "./" else name
        if "\\" in raw_name or raw_name != canonical:
            raise SystemExit(f"non-canonical {label} path on line {line_number}: {raw_name}")
        if name in listed:
            raise SystemExit(f"duplicate {label} entry: {name}")
        listed[name] = expected_hash
    if set(listed) != set(expected):
        missing = sorted(set(expected) - set(listed))
        extra = sorted(set(listed) - set(expected))
        raise SystemExit(f"{label} does not name the exact file set; missing={missing}, extra={extra}")
    return listed

try:
    checksum_lines = (dist / "SHA256SUMS").read_text(encoding="ascii").splitlines()
except (UnicodeDecodeError, OSError) as error:
    raise SystemExit(f"cannot read SHA256SUMS safely: {error}")
listed = parse_checksum_lines(checksum_lines, files, "SHA256SUMS")
for name, expected_hash in listed.items():
    if digest_file(dist.joinpath(*pathlib.PurePosixPath(name).parts)) != expected_hash:
        raise SystemExit(f"checksum mismatch: {name}")

evidence_payload = {
    "build.log",
    "resolved.config",
    "SOURCE-STATE.txt",
    "BUILD-ENVIRONMENT.txt",
    "BUILD-IDENTITY.txt",
    "INPUTS.sha256",
}
try:
    evidence_lines = (dist / "EVIDENCE/EVIDENCE.sha256").read_text(encoding="ascii").splitlines()
except (UnicodeDecodeError, OSError) as error:
    raise SystemExit(f"cannot read EVIDENCE.sha256 safely: {error}")
evidence_receipt = parse_checksum_lines(evidence_lines, evidence_payload, "EVIDENCE.sha256")
for name, expected_hash in evidence_receipt.items():
    evidence_path = dist.joinpath("EVIDENCE", *pathlib.PurePosixPath(name).parts)
    if digest_file(evidence_path) != expected_hash:
        raise SystemExit(f"evidence checksum mismatch: {name}")

def parse_key_values(path, expected_keys, label):
    values = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    except OSError as error:
        raise SystemExit(f"cannot read {label}: {error}")
    for line_number, line in enumerate(lines, 1):
        if not line or "=" not in line:
            raise SystemExit(f"malformed {label} line {line_number}")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", key) or key in values or value == "":
            raise SystemExit(f"invalid or duplicate {label} field: {key}")
        values[key] = value
    if set(values) != set(expected_keys):
        missing = sorted(set(expected_keys) - set(values))
        extra = sorted(set(values) - set(expected_keys))
        raise SystemExit(f"{label} schema mismatch; missing={missing}, extra={extra}")
    return values

def parse_shell_lock(path, expected_keys, label):
    values = {}
    assignment = re.compile(r'^([A-Z][A-Z0-9_]*)="([^"\r\n]+)"$')
    for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="strict").splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        match = assignment.fullmatch(line)
        if match is None or match.group(1) in values:
            raise SystemExit(f"malformed or duplicate {label} line {line_number}")
        values[match.group(1)] = match.group(2)
    if set(values) != set(expected_keys):
        raise SystemExit(f"{label} schema mismatch")
    return values

upstream = parse_shell_lock(
    repo / "manifests/upstream.lock",
    {"OPENWRT_REPO", "OPENWRT_TAG", "OPENWRT_COMMIT", "LAYOUT_ID", "ROOTFS_MTD_OFFSET_HEX", "ROOTFS_MTD_SIZE_HEX", "ROOTFS_MTD_ERASE_SIZE_HEX"},
    "upstream lock",
)
nss = parse_shell_lock(
    repo / "manifests/nss.lock",
    {"NSS_OPENWRT_REPO", "NSS_OPENWRT_BRANCH", "NSS_OPENWRT_COMMIT", "NSS_PACKAGES_FEED", "NSS_PACKAGES_REPO", "NSS_PACKAGES_COMMIT", "NSS_SQM_FEED", "NSS_SQM_REPO", "NSS_SQM_COMMIT"},
    "NSS lock",
)
feeds = {}
feed_pattern = re.compile(r"^([a-z][a-z0-9_]*) (https://[^\s]+) ([0-9a-f]{40})$")
for line_number, line in enumerate((repo / "manifests/feeds.lock").read_text(encoding="utf-8", errors="strict").splitlines(), 1):
    if not line or line.startswith("#"):
        continue
    match = feed_pattern.fullmatch(line)
    if match is None or match.group(1) in feeds:
        raise SystemExit(f"malformed or duplicate feeds lock line {line_number}")
    feeds[match.group(1)] = (match.group(2), match.group(3))
if not feeds:
    raise SystemExit("feeds lock is empty")

if flavor == "official":
    manifest_keys = {
        "project", "flavor", "project_commit", "layout", "source_repository", "source_tag", "source_commit",
        "source_date_epoch", "stage", "real_device_boot_approved", "image", "package_manifest", "sbom",
        "rootfs_mtd_offset", "rootfs_mtd_size",
    }
else:
    manifest_keys = {
        "project", "flavor", "project_commit", "source_repository", "source_branch", "source_commit",
        "source_date_epoch", "nss_packages_feed_repository", "nss_packages_feed_commit",
        "nss_sqm_feed_repository", "nss_sqm_feed_commit", "stage", "real_device_boot_approved",
        "image", "package_manifest", "sbom",
    }
manifest = parse_key_values(dist / "BUILD-MANIFEST.txt", manifest_keys, "BUILD-MANIFEST.txt")
if manifest["project"] != "NexaWrt" or manifest["flavor"] != flavor:
    raise SystemExit("build manifest project or flavor mismatch")
if not re.fullmatch(r"[0-9a-f]{40}", manifest["project_commit"]):
    raise SystemExit("build manifest project_commit is invalid")
try:
    current_project_commit = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
    ).strip()
except (OSError, subprocess.CalledProcessError):
    raise SystemExit("cannot determine verifier repository commit")
if manifest["project_commit"] != current_project_commit:
    raise SystemExit("build manifest project_commit does not match verifier repository HEAD")
if not re.fullmatch(r"[1-9][0-9]*", manifest["source_date_epoch"]):
    raise SystemExit("build manifest source_date_epoch is invalid")
if manifest["stage"] != "initramfs-ram-boot-only" or manifest["real_device_boot_approved"] != "no":
    raise SystemExit("build manifest safety stage is invalid")
if (manifest["image"], manifest["package_manifest"], manifest["sbom"]) != (image, package_manifest, sbom):
    raise SystemExit("build manifest artifact names are invalid")
if flavor == "official":
    expected_manifest = {
        "layout": upstream["LAYOUT_ID"],
        "source_repository": upstream["OPENWRT_REPO"],
        "source_tag": upstream["OPENWRT_TAG"],
        "source_commit": upstream["OPENWRT_COMMIT"],
        "rootfs_mtd_offset": upstream["ROOTFS_MTD_OFFSET_HEX"],
        "rootfs_mtd_size": upstream["ROOTFS_MTD_SIZE_HEX"],
    }
else:
    expected_manifest = {
        "source_repository": nss["NSS_OPENWRT_REPO"],
        "source_branch": nss["NSS_OPENWRT_BRANCH"],
        "source_commit": nss["NSS_OPENWRT_COMMIT"],
        "nss_packages_feed_repository": nss["NSS_PACKAGES_REPO"],
        "nss_packages_feed_commit": nss["NSS_PACKAGES_COMMIT"],
        "nss_sqm_feed_repository": nss["NSS_SQM_REPO"],
        "nss_sqm_feed_commit": nss["NSS_SQM_COMMIT"],
    }
for key, expected_value in expected_manifest.items():
    if manifest[key] != expected_value:
        raise SystemExit(f"build manifest does not match repository lock: {key}")

expected_feeds = dict(feeds)
feed_patch_hashes = {name: hashlib.sha256(b"").hexdigest() for name in feeds}
if flavor == "nss":
    expected_feeds[nss["NSS_PACKAGES_FEED"]] = (nss["NSS_PACKAGES_REPO"], nss["NSS_PACKAGES_COMMIT"])
    expected_feeds[nss["NSS_SQM_FEED"]] = (nss["NSS_SQM_REPO"], nss["NSS_SQM_COMMIT"])
    feed_patch_hashes[nss["NSS_PACKAGES_FEED"]] = digest_file(repo / "patches/nss/001-pin-codelinaro-source-archives.patch")
    feed_patch_hashes[nss["NSS_SQM_FEED"]] = hashlib.sha256(b"").hexdigest()
source_keys = {"flavor", "project_commit", "project_tree_state", "source_commit", "source_origin"}
for name in expected_feeds:
    source_keys.update({f"feed.{name}.commit", f"feed.{name}.origin", f"feed.{name}.worktree_diff_sha256"})
source_state = parse_key_values(dist / "EVIDENCE/SOURCE-STATE.txt", source_keys, "SOURCE-STATE.txt")
if source_state["flavor"] != flavor or source_state["project_commit"] != manifest["project_commit"]:
    raise SystemExit("source state flavor or project commit mismatch")
if source_state["project_tree_state"] != "clean":
    raise SystemExit("source state must come from a clean project tree")
if source_state["source_commit"] != manifest["source_commit"] or source_state["source_origin"] != manifest["source_repository"]:
    raise SystemExit("source state does not match locked source")
build_identity = parse_key_values(
    dist / "EVIDENCE/BUILD-IDENTITY.txt",
    {"schema", "flavor", "replica_id", "run_id", "run_attempt", "project_commit", "source_commit"},
    "BUILD-IDENTITY.txt",
)
if build_identity["schema"] != "1" or build_identity["flavor"] != flavor:
    raise SystemExit("build identity schema or flavor mismatch")
if build_identity["replica_id"] not in {"a", "b"}:
    raise SystemExit("build identity replica_id must be a or b")
for key in ("run_id", "run_attempt"):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", build_identity[key]):
        raise SystemExit(f"build identity {key} is invalid")
if build_identity["project_commit"] != manifest["project_commit"] or build_identity["source_commit"] != manifest["source_commit"]:
    raise SystemExit("build identity commit binding mismatch")
for name, (repository, commit) in expected_feeds.items():
    if source_state[f"feed.{name}.origin"] != repository or source_state[f"feed.{name}.commit"] != commit:
        raise SystemExit(f"source state does not match locked feed: {name}")
    if source_state[f"feed.{name}.worktree_diff_sha256"] != feed_patch_hashes[name]:
        raise SystemExit(f"source state feed patch digest mismatch: {name}")

input_lines = (dist / "EVIDENCE/INPUTS.sha256").read_text(encoding="ascii").splitlines()
input_pattern = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9_.+/-]+)$")
inputs = {}
for line_number, line in enumerate(input_lines, 1):
    match = input_pattern.fullmatch(line)
    if match is None:
        raise SystemExit(f"malformed INPUTS.sha256 line {line_number}")
    digest, raw_name = match.groups()
    pure = pathlib.PurePosixPath(raw_name)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts) or pure.as_posix() != raw_name or raw_name in inputs:
        raise SystemExit(f"unsafe or duplicate INPUTS.sha256 path: {raw_name}")
    inputs[raw_name] = digest

def checked_repository_path(pure, label):
    current = repo
    for part in pure.parts:
        current = current / part
        try:
            mode_bits = current.lstat().st_mode
        except OSError as error:
            raise SystemExit(f"cannot inspect {label} {pure.as_posix()}: {error}")
        if stat.S_ISLNK(mode_bits):
            raise SystemExit(f"symlink is not allowed in {label} path: {current.relative_to(repo).as_posix()}")
    return current

input_lister = checked_repository_path(pathlib.PurePosixPath("scripts/list-build-inputs.sh"), "build input lister")
lister_mode = input_lister.lstat().st_mode
if not stat.S_ISREG(lister_mode):
    raise SystemExit("build input lister must be a regular file")
try:
    listed_bytes = subprocess.check_output([str(input_lister), flavor], cwd=repo, stderr=subprocess.PIPE)
except (OSError, subprocess.CalledProcessError) as error:
    raise SystemExit(f"cannot enumerate expected build inputs: {error}")
if not listed_bytes or not listed_bytes.endswith(b"\0"):
    raise SystemExit("build input lister returned malformed output")
try:
    expected_names = [item.decode("utf-8", errors="strict") for item in listed_bytes[:-1].split(b"\0")]
except UnicodeDecodeError as error:
    raise SystemExit(f"build input lister returned invalid UTF-8: {error}")
if expected_names != sorted(set(expected_names)):
    raise SystemExit("build input lister returned duplicate or unsorted paths")
expected_inputs = {}
for name in expected_names:
    pure = pathlib.PurePosixPath(name)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts) or pure.as_posix() != name:
        raise SystemExit(f"build input lister returned unsafe path: {name}")
    path = checked_repository_path(pure, "expected build input")
    mode_bits = path.lstat().st_mode
    if not stat.S_ISREG(mode_bits):
        raise SystemExit(f"expected build input is not a regular file: {name}")
    expected_inputs[name] = digest_file(path)
if set(inputs) != set(expected_inputs):
    missing = sorted(set(expected_inputs) - set(inputs))
    extra = sorted(set(inputs) - set(expected_inputs))
    raise SystemExit(f"repository build input set mismatch; missing={missing}, extra={extra}")
for name in sorted(expected_inputs):
    if inputs[name] != expected_inputs[name]:
        raise SystemExit(f"repository build input digest mismatch: {name}")

source_ref = f"tag:{upstream['OPENWRT_TAG']}" if flavor == "official" else f"branch:{nss['NSS_OPENWRT_BRANCH']}"
repository_lines = [
    "schema=1",
    f"flavor={flavor}",
    f"source_repository={manifest['source_repository']}",
    f"source_commit={manifest['source_commit']}",
    f"source_ref={source_ref}",
]
for name in sorted(expected_inputs):
    repository_lines.append(f"input.{name}.sha256={inputs[name]}")
for name in sorted(expected_feeds):
    repository, commit = expected_feeds[name]
    repository_lines.extend([
        f"feed.{name}.repository={repository}",
        f"feed.{name}.commit={commit}",
        f"feed.{name}.patch_sha256={feed_patch_hashes[name]}",
    ])
repository_inputs_sha256 = hashlib.sha256(("\n".join(repository_lines) + "\n").encode()).hexdigest()

if mode == "replica":
    print(f"repository_inputs_sha256={repository_inputs_sha256}")
    raise SystemExit(0)

def reject_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")
def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result
try:
    reproduction = json.loads(
        (dist / "REPRODUCIBILITY.json").read_text(encoding="utf-8", errors="strict"),
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )
except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid REPRODUCIBILITY.json: {error}")
expected_root_keys = {
    "schema", "generator", "flavor", "reproducible", "firmware", "input_builds",
    "repository_inputs_sha256", "comparison_receipt_sha256", "run_id", "run_attempt",
}
if not isinstance(reproduction, dict) or set(reproduction) != expected_root_keys:
    raise SystemExit("REPRODUCIBILITY.json root schema mismatch")
if reproduction["schema"] != 4 or reproduction["generator"] != "scripts/compare-reproducible-builds.sh":
    raise SystemExit("REPRODUCIBILITY.json generator schema mismatch")
if reproduction["flavor"] != flavor or reproduction["reproducible"] is not True:
    raise SystemExit("REPRODUCIBILITY.json does not assert this reproducible flavor")
firmware = reproduction["firmware"]
if not isinstance(firmware, dict) or set(firmware) != {"filename", "sha256", "size"}:
    raise SystemExit("REPRODUCIBILITY.json firmware schema mismatch")
actual_image_sha = digest_file(dist / image)
actual_image_size = (dist / image).stat().st_size
if firmware != {"filename": image, "sha256": actual_image_sha, "size": actual_image_size}:
    raise SystemExit("REPRODUCIBILITY.json firmware binding mismatch")
if manifest["flavor"] != reproduction["flavor"] or manifest["image"] != firmware["filename"]:
    raise SystemExit("reproducibility metadata and build manifest disagree")
if reproduction["repository_inputs_sha256"] != repository_inputs_sha256:
    raise SystemExit("REPRODUCIBILITY.json repository input binding mismatch")
if not isinstance(reproduction["run_id"], str) or not re.fullmatch(r"[A-Za-z0-9._-]+", reproduction["run_id"]):
    raise SystemExit("REPRODUCIBILITY.json run_id is invalid")
if not isinstance(reproduction["run_attempt"], str) or not re.fullmatch(r"[A-Za-z0-9._-]+", reproduction["run_attempt"]):
    raise SystemExit("REPRODUCIBILITY.json run_attempt is invalid")
if os.environ.get("GITHUB_ACTIONS") == "true":
    if reproduction["run_id"] != os.environ.get("GITHUB_RUN_ID") or reproduction["run_attempt"] != os.environ.get("GITHUB_RUN_ATTEMPT"):
        raise SystemExit("REPRODUCIBILITY.json does not bind the current workflow run")
input_builds = reproduction["input_builds"]
if not isinstance(input_builds, list) or len(input_builds) != 2:
    raise SystemExit("REPRODUCIBILITY.json must bind exactly two input builds")
by_slot = {}
for item in input_builds:
    if not isinstance(item, dict) or set(item) != {
        "slot", "receipt_filename", "receipt_sha256", "evidence_receipt_filename", "evidence_receipt_sha256",
        "identity_filename", "identity_sha256", "replica_id", "producer_id", "artifact_id", "artifact_name",
        "producer_descriptor_filename", "producer_descriptor_sha256",
        "provenance_bundle_filename", "provenance_bundle_sha256",
    }:
        raise SystemExit("REPRODUCIBILITY.json input build schema mismatch")
    slot = item["slot"]
    if slot not in {"left", "right"} or slot in by_slot:
        raise SystemExit("REPRODUCIBILITY.json input build slots are invalid")
    expected_receipt_name = f"REPRODUCIBILITY/{slot}.SHA256SUMS"
    if item["receipt_filename"] != expected_receipt_name:
        raise SystemExit("REPRODUCIBILITY.json input receipt filename mismatch")
    if not re.fullmatch(r"[0-9a-f]{64}", item["receipt_sha256"] or "") or not re.fullmatch(r"[0-9a-f]{64}", item["evidence_receipt_sha256"] or ""):
        raise SystemExit("REPRODUCIBILITY.json input receipt digest is invalid")
    receipt_path = dist / expected_receipt_name
    if digest_file(receipt_path) != item["receipt_sha256"]:
        raise SystemExit("input build receipt file digest mismatch")
    receipt_lines = receipt_path.read_text(encoding="ascii").splitlines()
    receipt = parse_checksum_lines(receipt_lines, base_files, f"{slot} input receipt")
    expected_evidence_receipt_name = f"REPRODUCIBILITY/{slot}.EVIDENCE.sha256"
    if item["evidence_receipt_filename"] != expected_evidence_receipt_name:
        raise SystemExit("input build evidence receipt filename mismatch")
    evidence_receipt_path = dist / expected_evidence_receipt_name
    if receipt["EVIDENCE/EVIDENCE.sha256"] != item["evidence_receipt_sha256"] or digest_file(evidence_receipt_path) != item["evidence_receipt_sha256"]:
        raise SystemExit("input build evidence receipt digest mismatch")
    input_evidence_receipt = parse_checksum_lines(
        evidence_receipt_path.read_text(encoding="ascii").splitlines(), evidence_payload, f"{slot} evidence receipt"
    )
    expected_identity_name = f"REPRODUCIBILITY/{slot}.BUILD-IDENTITY.txt"
    if item["identity_filename"] != expected_identity_name:
        raise SystemExit("input build identity filename mismatch")
    identity_path = dist / expected_identity_name
    if not re.fullmatch(r"[0-9a-f]{64}", item["identity_sha256"] or "") or digest_file(identity_path) != item["identity_sha256"]:
        raise SystemExit("input build identity digest mismatch")
    if receipt["EVIDENCE/BUILD-IDENTITY.txt"] != item["identity_sha256"] or input_evidence_receipt["BUILD-IDENTITY.txt"] != item["identity_sha256"]:
        raise SystemExit("input build receipts do not bind the build identity")
    identity = parse_key_values(
        identity_path,
        {"schema", "flavor", "replica_id", "run_id", "run_attempt", "project_commit", "source_commit"},
        f"{slot} build identity",
    )
    expected_replica_id = "a" if slot == "left" else "b"
    if identity["schema"] != "1" or identity["flavor"] != flavor or identity["replica_id"] != expected_replica_id:
        raise SystemExit("input build identity slot binding mismatch")
    if item["replica_id"] != expected_replica_id or identity["run_id"] != reproduction["run_id"] or identity["run_attempt"] != reproduction["run_attempt"]:
        raise SystemExit("input build identity run binding mismatch")
    producer_id = item["producer_id"]
    if not isinstance(producer_id, str) or not re.fullmatch(
        r"(?:github-artifact:[1-9][0-9]*:bundle-sha256:[0-9a-f]{64}|local-unattested:[ab])", producer_id
    ):
        raise SystemExit("input build producer identity is invalid")
    descriptor_filename = item["producer_descriptor_filename"]
    descriptor_sha256 = item["producer_descriptor_sha256"]
    bundle_filename = item["provenance_bundle_filename"]
    bundle_sha256 = item["provenance_bundle_sha256"]
    artifact_id = item["artifact_id"]
    artifact_name = item["artifact_name"]
    if producer_id.startswith("github-artifact:"):
        expected_descriptor = f"REPRODUCIBILITY/{slot}.producer-descriptor.json"
        expected_bundle = f"REPRODUCIBILITY/{slot}.provenance.bundle.json"
        if descriptor_filename != expected_descriptor or not re.fullmatch(r"[0-9a-f]{64}", descriptor_sha256 or ""):
            raise SystemExit("platform producer descriptor binding is invalid")
        if bundle_filename != expected_bundle or not re.fullmatch(r"[0-9a-f]{64}", bundle_sha256 or ""):
            raise SystemExit("platform producer provenance bundle binding is invalid")
        descriptor_path = dist / expected_descriptor
        bundle_path = dist / expected_bundle
        if digest_file(descriptor_path) != descriptor_sha256:
            raise SystemExit("platform producer descriptor digest mismatch")
        if digest_file(bundle_path) != bundle_sha256 or not producer_id.endswith(f":bundle-sha256:{bundle_sha256}"):
            raise SystemExit("platform producer provenance bundle digest mismatch")
        try:
            descriptor_raw = descriptor_path.read_text(encoding="utf-8", errors="strict")
            descriptor = json.loads(descriptor_raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
            raise SystemExit(f"invalid platform producer descriptor: {error}")
        descriptor_keys = {
            "schema", "repository", "workflow", "run_id", "run_attempt", "flavor", "replica_id",
            "artifact_id", "artifact_name", "receipt_filename", "receipt_sha256",
        }
        if not isinstance(descriptor, dict) or set(descriptor) != descriptor_keys or descriptor.get("schema") != 1:
            raise SystemExit("platform producer descriptor schema mismatch")
        canonical_descriptor = json.dumps(descriptor, sort_keys=True, separators=(",", ":")) + "\n"
        if descriptor_raw != canonical_descriptor:
            raise SystemExit("platform producer descriptor is not canonical JSON")
        expected_artifact_name = f"release-{reproduction['run_id']}-{reproduction['run_attempt']}-{flavor}-{expected_replica_id}"
        expected_descriptor_values = {
            "repository": "tifycloud/NexaWrt",
            "workflow": "tifycloud/NexaWrt/.github/workflows/release.yml",
            "run_id": reproduction["run_id"],
            "run_attempt": reproduction["run_attempt"],
            "flavor": flavor,
            "replica_id": expected_replica_id,
            "artifact_id": artifact_id,
            "artifact_name": artifact_name,
            "receipt_filename": "SHA256SUMS",
            "receipt_sha256": item["receipt_sha256"],
        }
        if any(descriptor.get(key) != value for key, value in expected_descriptor_values.items()):
            raise SystemExit("platform producer descriptor binding mismatch")
        if not isinstance(artifact_id, str) or not re.fullmatch(r"[1-9][0-9]*", artifact_id):
            raise SystemExit("platform artifact id is invalid")
        if artifact_name != expected_artifact_name or producer_id != f"github-artifact:{artifact_id}:bundle-sha256:{bundle_sha256}":
            raise SystemExit("platform artifact identity is not canonical")
        verifier_raw = os.environ.get("NEXAWRT_ATTESTATION_VERIFIER", "")
        verifier_hash = os.environ.get("NEXAWRT_ATTESTATION_VERIFIER_SHA256", "")
        verifier_path = pathlib.Path(verifier_raw)
        if not verifier_path.is_absolute() or not re.fullmatch(r"[0-9a-f]{64}", verifier_hash):
            raise SystemExit("explicit attestation verifier path and SHA256 are required")
        try:
            verifier_mode = verifier_path.lstat().st_mode
        except OSError as error:
            raise SystemExit(f"cannot inspect attestation verifier: {error}")
        if stat.S_ISLNK(verifier_mode) or not stat.S_ISREG(verifier_mode):
            raise SystemExit("attestation verifier must be a non-symlink regular file")
        if digest_file(verifier_path) != verifier_hash:
            raise SystemExit("attestation verifier SHA256 mismatch")
        try:
            subprocess.run([
                str(verifier_path), "attestation", "verify", str(descriptor_path),
                "--repo", "tifycloud/NexaWrt",
                "--bundle", str(bundle_path),
                "--signer-workflow", "tifycloud/NexaWrt/.github/workflows/release.yml",
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        except (FileNotFoundError, PermissionError) as error:
            raise SystemExit(f"cannot execute attestation verifier: {error}")
        except subprocess.CalledProcessError as error:
            raise SystemExit(f"platform producer provenance verification failed: {error.stderr.strip()}")
    elif any(value != "" for value in (artifact_id, artifact_name, descriptor_filename, descriptor_sha256, bundle_filename, bundle_sha256)):
        raise SystemExit("local-unattested producer must not claim platform provenance")
    if identity["project_commit"] != manifest["project_commit"] or identity["source_commit"] != manifest["source_commit"]:
        raise SystemExit("input build identity commit binding mismatch")
    if receipt[image] != actual_image_sha or receipt["BUILD-MANIFEST.txt"] != digest_file(dist / "BUILD-MANIFEST.txt"):
        raise SystemExit("input build receipt is not bound to the selected artifact and manifest")
    by_slot[slot] = (item, receipt)
if by_slot["left"][0]["receipt_sha256"] == by_slot["right"][0]["receipt_sha256"]:
    raise SystemExit("input build receipts must be distinct")
if by_slot["left"][0]["evidence_receipt_sha256"] == by_slot["right"][0]["evidence_receipt_sha256"]:
    raise SystemExit("input build evidence receipts must be distinct")
if by_slot["left"][0]["producer_id"] == by_slot["right"][0]["producer_id"]:
    raise SystemExit("input build producer identities must be distinct")
for name, expected_hash in by_slot["left"][1].items():
    if digest_file(dist.joinpath(*pathlib.PurePosixPath(name).parts)) != expected_hash:
        raise SystemExit(f"left input receipt no longer matches verified output: {name}")
exact_compared = {
    image, package_manifest, "config.buildinfo", "feeds.buildinfo", "profiles.json", "version.buildinfo",
    "BUILD-MANIFEST.txt", "DO-NOT-FLASH.txt", "EVIDENCE/INPUTS.sha256", "EVIDENCE/resolved.config",
}
if flavor == "nss":
    exact_compared.update({"THIRD_PARTY_NOTICES.md", "LICENSES/nss-firmware/LICENSE.md"})
for name in exact_compared:
    if by_slot["right"][1][name] != by_slot["left"][1][name]:
        raise SystemExit(f"input receipts disagree for exact compared file: {name}")
comparison_lines = [
    "schema=4",
    "generator=scripts/compare-reproducible-builds.sh",
    f"flavor={flavor}",
    f"firmware_filename={image}",
    f"firmware_sha256={actual_image_sha}",
    f"firmware_size={actual_image_size}",
    f"repository_inputs_sha256={repository_inputs_sha256}",
]
for slot in ("left", "right"):
    item = by_slot[slot][0]
    comparison_lines.extend([
        f"{slot}_receipt_filename={item['receipt_filename']}",
        f"{slot}_receipt_sha256={item['receipt_sha256']}",
        f"{slot}_evidence_receipt_filename={item['evidence_receipt_filename']}",
        f"{slot}_evidence_receipt_sha256={item['evidence_receipt_sha256']}",
        f"{slot}_identity_filename={item['identity_filename']}",
        f"{slot}_identity_sha256={item['identity_sha256']}",
        f"{slot}_replica_id={item['replica_id']}",
        f"{slot}_producer_id={item['producer_id']}",
        f"{slot}_artifact_id={item['artifact_id']}",
        f"{slot}_artifact_name={item['artifact_name']}",
        f"{slot}_producer_descriptor_filename={item['producer_descriptor_filename']}",
        f"{slot}_producer_descriptor_sha256={item['producer_descriptor_sha256']}",
        f"{slot}_provenance_bundle_filename={item['provenance_bundle_filename']}",
        f"{slot}_provenance_bundle_sha256={item['provenance_bundle_sha256']}",
    ])
comparison_lines.extend([
    f"run_id={reproduction['run_id']}",
    f"run_attempt={reproduction['run_attempt']}",
])
comparison_receipt_sha256 = hashlib.sha256(("\n".join(comparison_lines) + "\n").encode()).hexdigest()
if reproduction["comparison_receipt_sha256"] != comparison_receipt_sha256:
    raise SystemExit("REPRODUCIBILITY.json comparison receipt digest mismatch")

candidate = [
    "schema=1",
    f"flavor={flavor}",
    f"firmware_filename={image}",
    f"firmware_sha256={actual_image_sha}",
    f"firmware_size={actual_image_size}",
    f"verified_dist_sha256sums_sha256={digest_file(dist / 'SHA256SUMS')}",
    f"reproducibility_sha256={digest_file(dist / 'REPRODUCIBILITY.json')}",
    f"build_manifest_sha256={digest_file(dist / 'BUILD-MANIFEST.txt')}",
    f"repository_inputs_sha256={repository_inputs_sha256}",
    f"comparison_receipt_sha256={comparison_receipt_sha256}",
]
print("\n".join(candidate))
PY
}

if [[ "${1:-}" == "--verify-verified-dist" ]]; then
  [[ $# -eq 2 ]] || fail "usage: $0 --verify-verified-dist VERIFIED_DIST_DIRECTORY"
  DIST_DIR="$2"
  [[ -d "$DIST_DIR" && ! -L "$DIST_DIR" ]] || fail "verified-dist directory is missing or unsafe"
  FLAVOR="$(python3 - "$DIST_DIR/REPRODUCIBILITY.json" <<'PY'
import json
import pathlib
import sys
try:
    value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["flavor"]
except (OSError, UnicodeError, ValueError, KeyError, TypeError):
    raise SystemExit(1)
if value not in {"official", "nss"}:
    raise SystemExit(1)
print(value)
PY
  )" || fail "cannot determine verified flavor from REPRODUCIBILITY.json"
  verify_distribution "$DIST_DIR" "$FLAVOR" output || fail "verified-dist policy validation failed"
  exit 0
fi

FLAVOR="${1:-}"
LEFT_RAW="${2:-}"
RIGHT_RAW="${3:-}"
OUTPUT_RAW="${4:-}"
[[ $# -eq 4 ]] || fail "usage: $0 FLAVOR LEFT_REPLICA RIGHT_REPLICA OUTPUT_VERIFIED_DIST"
case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac

LEFT="$(canonicalize_input "$LEFT_RAW")" || fail "unsafe left replica path: $LEFT_RAW"
RIGHT="$(canonicalize_input "$RIGHT_RAW")" || fail "unsafe right replica path: $RIGHT_RAW"
OUTPUT="$(canonicalize_output "$OUTPUT_RAW")" || fail "unsafe output directory: $OUTPUT_RAW"
[[ "$LEFT" != "$RIGHT" ]] || fail "replica directories must be distinct"
case "$OUTPUT/" in "$LEFT/"*|"$RIGHT/"*) fail "output must not be nested in a replica" ;; esac
case "$LEFT/" in "$OUTPUT/"*) fail "left replica must not be nested in output" ;; esac
case "$RIGHT/" in "$OUTPUT/"*) fail "right replica must not be nested in output" ;; esac

left_lock="$(verify_distribution "$LEFT" "$FLAVOR" replica)" || fail "left replica checksum, manifest, or repository-lock policy failed"
right_lock="$(verify_distribution "$RIGHT" "$FLAVOR" replica)" || fail "right replica checksum, manifest, or repository-lock policy failed"
[[ "$left_lock" == "$right_lock" ]] || fail "replicas bind different repository inputs"
repository_inputs_sha256="${left_lock#repository_inputs_sha256=}"
[[ "$repository_inputs_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "repository input receipt is invalid"

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

read_build_identity() {
  python3 - "$1" <<'PY'
import pathlib
import re
import sys
values = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict").splitlines():
    if not line or "=" not in line:
        raise SystemExit(1)
    key, value = line.split("=", 1)
    if key in values:
        raise SystemExit(1)
    values[key] = value
expected = {"schema", "flavor", "replica_id", "run_id", "run_attempt", "project_commit", "source_commit"}
if set(values) != expected or values["schema"] != "1":
    raise SystemExit(1)
if values["replica_id"] not in {"a", "b"}:
    raise SystemExit(1)
if not re.fullmatch(r"[A-Za-z0-9._-]+", values["run_id"]) or not re.fullmatch(r"[A-Za-z0-9._-]+", values["run_attempt"]):
    raise SystemExit(1)
print("\t".join(values[key] for key in ("replica_id", "run_id", "run_attempt")))
PY
}
IFS=$'\t' read -r left_replica_id left_identity_run_id left_identity_run_attempt < <(read_build_identity "$LEFT/EVIDENCE/BUILD-IDENTITY.txt") || fail "left build identity is invalid"
IFS=$'\t' read -r right_replica_id right_identity_run_id right_identity_run_attempt < <(read_build_identity "$RIGHT/EVIDENCE/BUILD-IDENTITY.txt") || fail "right build identity is invalid"
[[ "$left_replica_id" == a && "$right_replica_id" == b ]] || fail "build identities must bind left=a and right=b"
[[ "$left_identity_run_id" == "$right_identity_run_id" && "$left_identity_run_attempt" == "$right_identity_run_attempt" ]] || fail "build identities come from different runs"

run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-local}"
[[ "$run_id" =~ ^[A-Za-z0-9._-]+$ && "$run_attempt" =~ ^[A-Za-z0-9._-]+$ ]] || fail "run identity contains unsupported characters"
[[ "$left_identity_run_id" == "$run_id" && "$left_identity_run_attempt" == "$run_attempt" ]] || fail "build identities do not match comparison run"
[[ -z "${NEXAWRT_LEFT_PRODUCER_ID:-}${NEXAWRT_RIGHT_PRODUCER_ID:-}" ]] || fail "producer identities must be derived from signed descriptors"

left_receipt_sha="$(hash_file "$LEFT/SHA256SUMS" | awk '{print $1}')"
right_receipt_sha="$(hash_file "$RIGHT/SHA256SUMS" | awk '{print $1}')"
left_evidence_receipt_sha="$(awk '$2 == "./EVIDENCE/EVIDENCE.sha256" { count++; value=$1 } END { if (count != 1) exit 1; print value }' "$LEFT/SHA256SUMS")" || fail "left evidence receipt is missing"
right_evidence_receipt_sha="$(awk '$2 == "./EVIDENCE/EVIDENCE.sha256" { count++; value=$1 } END { if (count != 1) exit 1; print value }' "$RIGHT/SHA256SUMS")" || fail "right evidence receipt is missing"
left_identity_sha="$(hash_file "$LEFT/EVIDENCE/BUILD-IDENTITY.txt" | awk '{print $1}')"
right_identity_sha="$(hash_file "$RIGHT/EVIDENCE/BUILD-IDENTITY.txt" | awk '{print $1}')"
[[ "$left_receipt_sha" != "$right_receipt_sha" ]] || fail "input build receipts must be distinct"
[[ "$left_evidence_receipt_sha" != "$right_evidence_receipt_sha" ]] || fail "input build evidence receipts must be distinct"

platform_requested=false
for value in \
  "${NEXAWRT_LEFT_ARTIFACT_ID:-}" "${NEXAWRT_RIGHT_ARTIFACT_ID:-}" \
  "${NEXAWRT_LEFT_ARTIFACT_NAME:-}" "${NEXAWRT_RIGHT_ARTIFACT_NAME:-}" \
  "${NEXAWRT_LEFT_PRODUCER_DESCRIPTOR:-}" "${NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR:-}" \
  "${NEXAWRT_LEFT_PROVENANCE_BUNDLE:-}" "${NEXAWRT_RIGHT_PROVENANCE_BUNDLE:-}"; do
  [[ -z "$value" ]] || platform_requested=true
done
if [[ "${GITHUB_ACTIONS:-false}" == true && "$platform_requested" != true ]]; then
  fail "GitHub comparison requires signed producer descriptors"
fi

left_producer_id="local-unattested:a"
right_producer_id="local-unattested:b"
left_artifact_id=""
right_artifact_id=""
left_artifact_name=""
right_artifact_name=""
left_descriptor=""
right_descriptor=""
left_descriptor_sha=""
right_descriptor_sha=""
left_bundle=""
right_bundle=""
left_bundle_sha=""
right_bundle_sha=""

canonicalize_provenance_file() {
  /usr/bin/python3 - "$ROOT_DIR" "$1" <<'PY'
import os
import pathlib
import stat
import sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
raw = pathlib.Path(os.path.abspath(sys.argv[2]))
if raw.is_symlink():
    raise SystemExit(1)
resolved = raw.resolve(strict=True)
mode = resolved.lstat().st_mode
if not stat.S_ISREG(mode):
    raise SystemExit(1)
resolved.relative_to(root / "release-staging")
print(resolved)
PY
}

validate_platform_descriptor() {
  /usr/bin/python3 - "$@" <<'PY'
import hashlib
import json
import pathlib
import re
import stat
import subprocess
import sys
(
    slot, descriptor_raw_path, bundle_raw_path, receipt_raw_path, flavor, replica_id,
    run_id, run_attempt, expected_artifact_id, expected_artifact_name,
    verifier_raw_path, verifier_expected_hash,
) = sys.argv[1:]

def digest(path):
    value = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

def reject_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")

descriptor_path = pathlib.Path(descriptor_raw_path)
bundle_path = pathlib.Path(bundle_raw_path)
receipt_path = pathlib.Path(receipt_raw_path)
verifier_path = pathlib.Path(verifier_raw_path)
if slot not in {"left", "right"} or replica_id not in {"a", "b"} or flavor not in {"official", "nss"}:
    raise SystemExit("invalid platform producer coordinates")
if not re.fullmatch(r"[1-9][0-9]*", expected_artifact_id):
    raise SystemExit("platform artifact id is invalid")
canonical_name = f"release-{run_id}-{run_attempt}-{flavor}-{replica_id}"
if expected_artifact_name != canonical_name:
    raise SystemExit("platform artifact name is not canonical")
try:
    descriptor_raw = descriptor_path.read_text(encoding="utf-8", errors="strict")
    descriptor = json.loads(descriptor_raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid platform producer descriptor: {error}")
expected_keys = {
    "schema", "repository", "workflow", "run_id", "run_attempt", "flavor", "replica_id",
    "artifact_id", "artifact_name", "receipt_filename", "receipt_sha256",
}
if not isinstance(descriptor, dict) or set(descriptor) != expected_keys or descriptor.get("schema") != 1:
    raise SystemExit("platform producer descriptor schema mismatch")
if descriptor_raw != json.dumps(descriptor, sort_keys=True, separators=(",", ":")) + "\n":
    raise SystemExit("platform producer descriptor is not canonical JSON")
expected = {
    "repository": "tifycloud/NexaWrt",
    "workflow": "tifycloud/NexaWrt/.github/workflows/release.yml",
    "run_id": run_id,
    "run_attempt": run_attempt,
    "flavor": flavor,
    "replica_id": replica_id,
    "artifact_id": expected_artifact_id,
    "artifact_name": expected_artifact_name,
    "receipt_filename": "SHA256SUMS",
    "receipt_sha256": digest(receipt_path),
}
if any(descriptor.get(key) != value for key, value in expected.items()):
    raise SystemExit("platform producer descriptor binding mismatch")
if not verifier_path.is_absolute() or not re.fullmatch(r"[0-9a-f]{64}", verifier_expected_hash):
    raise SystemExit("explicit attestation verifier path and SHA256 are required")
try:
    verifier_mode = verifier_path.lstat().st_mode
except OSError as error:
    raise SystemExit(f"cannot inspect attestation verifier: {error}")
if stat.S_ISLNK(verifier_mode) or not stat.S_ISREG(verifier_mode):
    raise SystemExit("attestation verifier must be a non-symlink regular file")
if digest(verifier_path) != verifier_expected_hash:
    raise SystemExit("attestation verifier SHA256 mismatch")
try:
    subprocess.run([
        str(verifier_path), "attestation", "verify", str(descriptor_path),
        "--repo", "tifycloud/NexaWrt", "--bundle", str(bundle_path),
        "--signer-workflow", "tifycloud/NexaWrt/.github/workflows/release.yml",
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
except (FileNotFoundError, PermissionError) as error:
    raise SystemExit(f"cannot execute attestation verifier: {error}")
except subprocess.CalledProcessError as error:
    raise SystemExit(f"platform producer provenance verification failed: {error.stderr.strip()}")
descriptor_sha = digest(descriptor_path)
bundle_sha = digest(bundle_path)
producer_id = f"github-artifact:{expected_artifact_id}:bundle-sha256:{bundle_sha}"
print("\t".join((producer_id, descriptor_sha, bundle_sha)))
PY
}

if [[ "$platform_requested" == true ]]; then
  [[ -n "${NEXAWRT_ATTESTATION_VERIFIER:-}" && -n "${NEXAWRT_ATTESTATION_VERIFIER_SHA256:-}" ]] ||
    fail "explicit attestation verifier path and SHA256 are required"
  [[ "${NEXAWRT_ATTESTATION_VERIFIER}" == /* ]] || fail "attestation verifier path must be absolute"
  left_artifact_id="${NEXAWRT_LEFT_ARTIFACT_ID:-}"
  right_artifact_id="${NEXAWRT_RIGHT_ARTIFACT_ID:-}"
  left_artifact_name="${NEXAWRT_LEFT_ARTIFACT_NAME:-}"
  right_artifact_name="${NEXAWRT_RIGHT_ARTIFACT_NAME:-}"
  left_descriptor="$(canonicalize_provenance_file "${NEXAWRT_LEFT_PRODUCER_DESCRIPTOR:-}")" || fail "left producer descriptor is missing, unsafe, or outside release-staging"
  right_descriptor="$(canonicalize_provenance_file "${NEXAWRT_RIGHT_PRODUCER_DESCRIPTOR:-}")" || fail "right producer descriptor is missing, unsafe, or outside release-staging"
  left_bundle="$(canonicalize_provenance_file "${NEXAWRT_LEFT_PROVENANCE_BUNDLE:-}")" || fail "left provenance bundle is missing, unsafe, or outside release-staging"
  right_bundle="$(canonicalize_provenance_file "${NEXAWRT_RIGHT_PROVENANCE_BUNDLE:-}")" || fail "right provenance bundle is missing, unsafe, or outside release-staging"
  IFS=$'\t' read -r left_producer_id left_descriptor_sha left_bundle_sha < <(
    validate_platform_descriptor left "$left_descriptor" "$left_bundle" "$LEFT/SHA256SUMS" "$FLAVOR" a \
      "$run_id" "$run_attempt" "$left_artifact_id" "$left_artifact_name" \
      "$NEXAWRT_ATTESTATION_VERIFIER" "$NEXAWRT_ATTESTATION_VERIFIER_SHA256"
  ) || fail "left platform producer descriptor validation failed"
  IFS=$'\t' read -r right_producer_id right_descriptor_sha right_bundle_sha < <(
    validate_platform_descriptor right "$right_descriptor" "$right_bundle" "$RIGHT/SHA256SUMS" "$FLAVOR" b \
      "$run_id" "$run_attempt" "$right_artifact_id" "$right_artifact_name" \
      "$NEXAWRT_ATTESTATION_VERIFIER" "$NEXAWRT_ATTESTATION_VERIFIER_SHA256"
  ) || fail "right platform producer descriptor validation failed"
  [[ "$left_artifact_id" != "$right_artifact_id" && "$left_artifact_name" != "$right_artifact_name" ]] || fail "platform artifact identities must be distinct"
  [[ "$left_descriptor_sha" != "$right_descriptor_sha" && "$left_bundle_sha" != "$right_bundle_sha" ]] || fail "platform producer provenance must be distinct"
fi
[[ "$left_producer_id" != "$right_producer_id" ]] || fail "producer identities must be distinct"
image_sha="$(hash_file "$LEFT/$EXPECTED_IMAGE" | awk '{print $1}')"
image_size="$(python3 - "$LEFT/$EXPECTED_IMAGE" <<'PY'
import os
import sys
print(os.path.getsize(sys.argv[1]))
PY
)"
rm -rf -- "$OUTPUT"
mkdir -p "$OUTPUT"
cp -a "$LEFT"/. "$OUTPUT"/
mkdir -p "$OUTPUT/REPRODUCIBILITY"
cp "$LEFT/SHA256SUMS" "$OUTPUT/REPRODUCIBILITY/left.SHA256SUMS"
cp "$RIGHT/SHA256SUMS" "$OUTPUT/REPRODUCIBILITY/right.SHA256SUMS"
cp "$LEFT/EVIDENCE/BUILD-IDENTITY.txt" "$OUTPUT/REPRODUCIBILITY/left.BUILD-IDENTITY.txt"
cp "$RIGHT/EVIDENCE/BUILD-IDENTITY.txt" "$OUTPUT/REPRODUCIBILITY/right.BUILD-IDENTITY.txt"
cp "$LEFT/EVIDENCE/EVIDENCE.sha256" "$OUTPUT/REPRODUCIBILITY/left.EVIDENCE.sha256"
cp "$RIGHT/EVIDENCE/EVIDENCE.sha256" "$OUTPUT/REPRODUCIBILITY/right.EVIDENCE.sha256"
if [[ -n "$left_bundle" ]]; then
  cp "$left_descriptor" "$OUTPUT/REPRODUCIBILITY/left.producer-descriptor.json"
  cp "$right_descriptor" "$OUTPUT/REPRODUCIBILITY/right.producer-descriptor.json"
  cp "$left_bundle" "$OUTPUT/REPRODUCIBILITY/left.provenance.bundle.json"
  cp "$right_bundle" "$OUTPUT/REPRODUCIBILITY/right.provenance.bundle.json"
fi
python3 - "$OUTPUT/REPRODUCIBILITY.json" "$FLAVOR" "$EXPECTED_IMAGE" "$image_sha" "$image_size" \
  "$repository_inputs_sha256" "$left_receipt_sha" "$left_evidence_receipt_sha" \
  "$right_receipt_sha" "$right_evidence_receipt_sha" "$left_identity_sha" "$right_identity_sha" \
  "$run_id" "$run_attempt" "$left_producer_id" "$right_producer_id" \
  "$left_artifact_id" "$right_artifact_id" "$left_artifact_name" "$right_artifact_name" \
  "$left_descriptor_sha" "$right_descriptor_sha" "$left_bundle_sha" "$right_bundle_sha" <<'PY'
import hashlib
import json
import pathlib
import sys

(path, flavor, image, image_sha, image_size, repository_inputs_sha256,
 left_receipt_sha, left_evidence_receipt_sha, right_receipt_sha,
 right_evidence_receipt_sha, left_identity_sha, right_identity_sha,
 run_id, run_attempt, left_producer_id, right_producer_id,
 left_artifact_id, right_artifact_id, left_artifact_name, right_artifact_name,
 left_descriptor_sha, right_descriptor_sha, left_bundle_sha, right_bundle_sha) = sys.argv[1:]
lines = [
    "schema=4",
    "generator=scripts/compare-reproducible-builds.sh",
    f"flavor={flavor}",
    f"firmware_filename={image}",
    f"firmware_sha256={image_sha}",
    f"firmware_size={image_size}",
    f"repository_inputs_sha256={repository_inputs_sha256}",
    "left_receipt_filename=REPRODUCIBILITY/left.SHA256SUMS",
    f"left_receipt_sha256={left_receipt_sha}",
    "left_evidence_receipt_filename=REPRODUCIBILITY/left.EVIDENCE.sha256",
    f"left_evidence_receipt_sha256={left_evidence_receipt_sha}",
    "left_identity_filename=REPRODUCIBILITY/left.BUILD-IDENTITY.txt",
    f"left_identity_sha256={left_identity_sha}",
    "left_replica_id=a",
    f"left_producer_id={left_producer_id}",
    f"left_artifact_id={left_artifact_id}",
    f"left_artifact_name={left_artifact_name}",
    f"left_producer_descriptor_filename={'REPRODUCIBILITY/left.producer-descriptor.json' if left_descriptor_sha else ''}",
    f"left_producer_descriptor_sha256={left_descriptor_sha}",
    f"left_provenance_bundle_filename={'REPRODUCIBILITY/left.provenance.bundle.json' if left_bundle_sha else ''}",
    f"left_provenance_bundle_sha256={left_bundle_sha}",
    "right_receipt_filename=REPRODUCIBILITY/right.SHA256SUMS",
    f"right_receipt_sha256={right_receipt_sha}",
    "right_evidence_receipt_filename=REPRODUCIBILITY/right.EVIDENCE.sha256",
    f"right_evidence_receipt_sha256={right_evidence_receipt_sha}",
    "right_identity_filename=REPRODUCIBILITY/right.BUILD-IDENTITY.txt",
    f"right_identity_sha256={right_identity_sha}",
    "right_replica_id=b",
    f"right_producer_id={right_producer_id}",
    f"right_artifact_id={right_artifact_id}",
    f"right_artifact_name={right_artifact_name}",
    f"right_producer_descriptor_filename={'REPRODUCIBILITY/right.producer-descriptor.json' if right_descriptor_sha else ''}",
    f"right_producer_descriptor_sha256={right_descriptor_sha}",
    f"right_provenance_bundle_filename={'REPRODUCIBILITY/right.provenance.bundle.json' if right_bundle_sha else ''}",
    f"right_provenance_bundle_sha256={right_bundle_sha}",
    f"run_id={run_id}",
    f"run_attempt={run_attempt}",
]
comparison_receipt_sha256 = hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()
document = {
    "schema": 4,
    "generator": "scripts/compare-reproducible-builds.sh",
    "flavor": flavor,
    "reproducible": True,
    "firmware": {"filename": image, "sha256": image_sha, "size": int(image_size)},
    "input_builds": [
        {
            "slot": "left",
            "receipt_filename": "REPRODUCIBILITY/left.SHA256SUMS",
            "receipt_sha256": left_receipt_sha,
            "evidence_receipt_filename": "REPRODUCIBILITY/left.EVIDENCE.sha256",
            "evidence_receipt_sha256": left_evidence_receipt_sha,
            "identity_filename": "REPRODUCIBILITY/left.BUILD-IDENTITY.txt",
            "identity_sha256": left_identity_sha,
            "replica_id": "a",
            "producer_id": left_producer_id,
            "artifact_id": left_artifact_id,
            "artifact_name": left_artifact_name,
            "producer_descriptor_filename": "REPRODUCIBILITY/left.producer-descriptor.json" if left_descriptor_sha else "",
            "producer_descriptor_sha256": left_descriptor_sha,
            "provenance_bundle_filename": "REPRODUCIBILITY/left.provenance.bundle.json" if left_bundle_sha else "",
            "provenance_bundle_sha256": left_bundle_sha,
        },
        {
            "slot": "right",
            "receipt_filename": "REPRODUCIBILITY/right.SHA256SUMS",
            "receipt_sha256": right_receipt_sha,
            "evidence_receipt_filename": "REPRODUCIBILITY/right.EVIDENCE.sha256",
            "evidence_receipt_sha256": right_evidence_receipt_sha,
            "identity_filename": "REPRODUCIBILITY/right.BUILD-IDENTITY.txt",
            "identity_sha256": right_identity_sha,
            "replica_id": "b",
            "producer_id": right_producer_id,
            "artifact_id": right_artifact_id,
            "artifact_name": right_artifact_name,
            "producer_descriptor_filename": "REPRODUCIBILITY/right.producer-descriptor.json" if right_descriptor_sha else "",
            "producer_descriptor_sha256": right_descriptor_sha,
            "provenance_bundle_filename": "REPRODUCIBILITY/right.provenance.bundle.json" if right_bundle_sha else "",
            "provenance_bundle_sha256": right_bundle_sha,
        },
    ],
    "repository_inputs_sha256": repository_inputs_sha256,
    "comparison_receipt_sha256": comparison_receipt_sha256,
    "run_id": run_id,
    "run_attempt": run_attempt,
}
pathlib.Path(path).write_text(json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
(
  cd "$OUTPUT"
  while IFS= read -r file; do hash_file "$file"; done < <(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
) > "$OUTPUT/SHA256SUMS"
verify_distribution "$OUTPUT" "$FLAVOR" output >/dev/null || fail "verified output policy validation failed"
printf 'Reproducibility gate passed; verified artifact written to %s\n' "$OUTPUT"
