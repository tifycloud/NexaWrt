#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FLAVOR="${1:-}"
case "$FLAVOR" in official|nss) ;; *) echo "build input listing refused: flavor must be official or nss" >&2; exit 1 ;; esac

python3 - "$ROOT_DIR" "$FLAVOR" <<'PY'
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
flavor = sys.argv[2]
inputs = [
    "Makefile",
    ".github/workflows/build.yml",
    ".github/workflows/release.yml",
    "scripts/build.sh",
    "scripts/apk-signing-key.sh",
    "scripts/prepare.sh",
    "scripts/validate.sh",
    "scripts/collect-build-evidence.sh",
    "scripts/list-build-inputs.sh",
    "scripts/sanitize-git-environment.sh",
    "scripts/git-metadata-policy.sh",
    "scripts/lock-file-policy.sh",
    "scripts/check-kernel-build-identity.sh",
    "scripts/compare-reproducible-builds.sh",
    "scripts/ax9000-runtime-probe.sh",
    "scripts/collect-production-state.sh",
    "scripts/collect-runtime-evidence.sh",
    "scripts/create-hardware-session.sh",
    "scripts/run-ax9000-stress-gate.sh",
    "scripts/verify-hardware-evidence.sh",
    "scripts/verify-post-reboot-state.sh",
    "scripts/verify-stress-evidence.sh",
    "files",
    "manifests/upstream.lock",
    "manifests/apk-signing.lock",
    "manifests/feeds.lock",
    "patches",
]
if flavor == "official":
    inputs.extend(["configs/ax9000-single-ubi.config", "scripts/release.sh"])
else:
    inputs.extend([
        "configs/ax9000-single-ubi-nss.config",
        "manifests/nss.lock",
        "files-nss",
        "scripts/stage-nss-artifact.sh",
        "THIRD_PARTY_NOTICES.md",
    ])

def checked_path(relative, label):
    current = root
    for part in relative.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            raise SystemExit(f"{label} is missing: {relative.as_posix()}")
        if stat.S_ISLNK(mode):
            raise SystemExit(f"symlink is not allowed in build input path: {current.relative_to(root).as_posix()}")
    return current

files = set()
for raw in inputs:
    relative = pathlib.PurePosixPath(raw)
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        raise SystemExit(f"unsafe declared build input: {raw}")
    path = checked_path(relative, "declared build input")
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        raise SystemExit(f"declared build input is a symlink: {raw}")
    if stat.S_ISREG(mode):
        files.add(relative.as_posix())
        continue
    if not stat.S_ISDIR(mode):
        raise SystemExit(f"declared build input is not a regular file or directory: {raw}")
    for base, dirs, names in os.walk(path, topdown=True, followlinks=False):
        base_path = pathlib.Path(base)
        for name in list(dirs):
            child = base_path / name
            child_relative = child.relative_to(root).as_posix()
            child_mode = child.lstat().st_mode
            if stat.S_ISLNK(child_mode):
                raise SystemExit(f"symlink is not allowed in build inputs: {child_relative}")
            if not stat.S_ISDIR(child_mode):
                raise SystemExit(f"non-directory entry encountered in build input tree: {child_relative}")
        for name in names:
            child = base_path / name
            child_relative = child.relative_to(root).as_posix()
            child_mode = child.lstat().st_mode
            if stat.S_ISLNK(child_mode):
                raise SystemExit(f"symlink is not allowed in build inputs: {child_relative}")
            if not stat.S_ISREG(child_mode):
                raise SystemExit(f"non-regular file is not allowed in build inputs: {child_relative}")
            files.add(child_relative)

for name in sorted(files):
    sys.stdout.buffer.write(name.encode("utf-8") + b"\0")
PY
