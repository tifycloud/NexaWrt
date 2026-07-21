#!/usr/bin/env python3
"""Create and audit NexaWrt custom-build manifests and checksum inventories."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import stat
import subprocess
import sys
from typing import Any

MANIFEST_NAME = "custom-build-manifest.json"
CHECKSUMS_NAME = "SHA256SUMS"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
CHECKSUM_LINE_RE = re.compile(r"([0-9a-f]{64})  (.+)")


class AuditError(RuntimeError):
    """Raised when an artifact tree violates the custom-build contract."""


def digest(path: pathlib.Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def lexical_absolute(raw: str) -> pathlib.Path:
    return pathlib.Path(os.path.abspath(raw))


def require_directory(raw: str) -> pathlib.Path:
    path = lexical_absolute(raw)
    try:
        file_stat = path.lstat()
    except FileNotFoundError as exc:
        raise AuditError(f"artifact directory is missing: {path}") from exc
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISDIR(file_stat.st_mode):
        raise AuditError(f"artifact directory is not a real directory: {path}")
    return path.resolve(strict=True)


def require_regular_file(
    path: pathlib.Path,
    *,
    description: str,
    nonempty: bool = True,
) -> pathlib.Path:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as exc:
        raise AuditError(f"{description} is missing: {path}") from exc
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise AuditError(f"{description} must be a regular non-symlink file: {path}")
    if nonempty and file_stat.st_size == 0:
        raise AuditError(f"{description} must not be empty: {path}")
    return path


def require_direct_child(raw: str, artifact_dir: pathlib.Path, expected_name: str) -> pathlib.Path:
    candidate = lexical_absolute(raw)
    try:
        parent = candidate.parent.resolve(strict=True)
    except OSError as exc:
        raise AuditError(f"{expected_name} parent is unavailable: {candidate.parent}") from exc
    if candidate.name != expected_name or parent != artifact_dir:
        raise AuditError(f"{expected_name} path escapes or does not match the artifact directory")
    return artifact_dir / expected_name


def safe_relative_name(path: pathlib.Path, artifact_dir: pathlib.Path) -> str:
    try:
        relative = path.relative_to(artifact_dir)
    except ValueError as exc:
        raise AuditError(f"artifact path escapes its root: {path}") from exc
    name = relative.as_posix()
    if (
        not relative.parts
        or relative.is_absolute()
        or any(part in {"", ".", ".."} for part in relative.parts)
        or any(character in name for character in ("\\", "\n", "\r", "\0"))
    ):
        raise AuditError(f"unsafe artifact path: {name!r}")
    return name


def inventory_tree(artifact_dir: pathlib.Path) -> dict[str, pathlib.Path]:
    files: dict[str, pathlib.Path] = {}
    for current_raw, directory_names, file_names in os.walk(artifact_dir, followlinks=False):
        current = pathlib.Path(current_raw)
        for name in list(directory_names):
            path = current / name
            file_stat = path.lstat()
            if stat.S_ISLNK(file_stat.st_mode):
                raise AuditError(f"artifact tree contains a symlink: {path}")
            if not stat.S_ISDIR(file_stat.st_mode):
                raise AuditError(f"artifact tree contains a non-directory entry: {path}")
            safe_relative_name(path, artifact_dir)
        for name in file_names:
            path = current / name
            file_stat = path.lstat()
            if stat.S_ISLNK(file_stat.st_mode):
                raise AuditError(f"artifact tree contains a symlink: {path}")
            if not stat.S_ISREG(file_stat.st_mode):
                raise AuditError(f"artifact tree contains a non-regular file: {path}")
            relative = safe_relative_name(path, artifact_dir)
            if relative in files:
                raise AuditError(f"duplicate artifact path: {relative}")
            files[relative] = path
    return files


def read_json(path: pathlib.Path, description: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise AuditError(f"{description} is not valid UTF-8 JSON: {path}") from exc


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
        "build-essential",
        "clang",
        "gcc",
        "g++",
        "make",
        "libc6-dev",
        "python3",
        "git",
        "rsync",
        "zstd",
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


def validate_expected_values(commit: str, target: str, flavor: str, request_hash: str) -> None:
    if COMMIT_RE.fullmatch(commit) is None:
        raise AuditError("expected commit must be a full lowercase Git object ID")
    if target not in {"x86_64", "xiaomi_ax9000"}:
        raise AuditError(f"unsupported expected target: {target}")
    if flavor not in {"official", "nss"}:
        raise AuditError(f"unsupported expected flavor: {flavor}")
    if flavor == "nss" and target != "xiaomi_ax9000":
        raise AuditError("nss flavor is valid only for xiaomi_ax9000")
    if SHA256_RE.fullmatch(request_hash) is None:
        raise AuditError("expected request hash must be a full lowercase SHA256 value")


def validate_request(
    request: Any,
    *,
    expected_target: str,
    expected_flavor: str,
    expected_request_hash: str,
) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise AuditError("normalized request must be a JSON object")
    target = request.get("target")
    if not isinstance(target, dict) or target.get("id") != expected_target:
        raise AuditError("normalized request target does not match the expected target")
    if request.get("flavor") != expected_flavor:
        raise AuditError("normalized request flavor does not match the expected flavor")
    if request.get("request_hash") != expected_request_hash:
        raise AuditError("normalized request hash does not match the expected request hash")
    for field in ("catalog_version", "resolved_components", "packages"):
        if field not in request:
            raise AuditError(f"normalized request is missing {field}")
    components = request["resolved_components"]
    packages = request["packages"]
    if not isinstance(components, list) or not components or any(not isinstance(item, str) or not item for item in components):
        raise AuditError("normalized request components are empty or invalid")
    if not isinstance(packages, list) or not packages or any(not isinstance(item, str) or not item for item in packages):
        raise AuditError("normalized request packages are empty or invalid")
    if len(packages) != len(set(packages)):
        raise AuditError("normalized request packages contain duplicates")
    return request


def actual_packages(artifact_dir: pathlib.Path, target: str) -> list[str]:
    if target == "x86_64":
        record = require_regular_file(
            artifact_dir / "custom-imagebuilder-packages.json",
            description="final ImageBuilder package record",
        )
        packages = read_json(record, "final ImageBuilder package record")
    else:
        config = require_regular_file(artifact_dir / "config.buildinfo", description="config.buildinfo")
        prefix = "CONFIG_PACKAGE_"
        suffix = "=y"
        packages = sorted(
            {
                line[len(prefix) : -len(suffix)]
                for line in config.read_text(encoding="utf-8").splitlines()
                if line.startswith(prefix) and line.endswith(suffix)
            }
        )
    if (
        not isinstance(packages, list)
        or not packages
        or any(not isinstance(package, str) or not package for package in packages)
        or len(packages) != len(set(packages))
    ):
        raise AuditError("final package set is empty, duplicated, or invalid")
    return packages


def write_atomic(path: pathlib.Path, content: str, description: str) -> None:
    if os.path.lexists(path):
        require_regular_file(path, description=description, nonempty=False)
    temporary = path.with_name(f".{path.name}.tmp")
    if os.path.lexists(temporary):
        raise AuditError(f"refusing pre-existing temporary path: {temporary}")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_checksums(path: pathlib.Path, artifact_dir: pathlib.Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = CHECKSUM_LINE_RE.fullmatch(line)
        if match is None:
            raise AuditError(f"invalid SHA256SUMS line {line_number}")
        expected_digest, relative_raw = match.groups()
        relative = pathlib.PurePosixPath(relative_raw)
        if (
            relative.is_absolute()
            or not relative.parts
            or any(part in {"", ".", ".."} for part in relative.parts)
            or any(character in relative_raw for character in ("\\", "\n", "\r", "\0"))
        ):
            raise AuditError(f"unsafe SHA256SUMS path on line {line_number}: {relative_raw!r}")
        normalized = relative.as_posix()
        if normalized in checksums:
            raise AuditError(f"duplicate SHA256SUMS path: {normalized}")
        candidate = artifact_dir.joinpath(*relative.parts)
        try:
            candidate.relative_to(artifact_dir)
        except ValueError as exc:
            raise AuditError(f"SHA256SUMS path escapes artifact directory: {normalized}") from exc
        require_regular_file(candidate, description=f"checksummed artifact {normalized}", nonempty=False)
        checksums[normalized] = expected_digest
    if not checksums:
        raise AuditError("SHA256SUMS contains no entries")
    return checksums


def validate_manifest_artifacts(manifest: dict[str, Any], files: dict[str, pathlib.Path]) -> None:
    records = manifest.get("artifacts")
    if not isinstance(records, list) or not records:
        raise AuditError("manifest artifacts list is empty or invalid")
    expected_names = set(files) - {MANIFEST_NAME, CHECKSUMS_NAME}
    seen: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            raise AuditError("manifest artifact record is not an object")
        name = record.get("name")
        checksum = record.get("sha256")
        size = record.get("size")
        if not isinstance(name, str) or name not in expected_names or name in seen:
            raise AuditError(f"manifest artifact name is missing, duplicated, or unexpected: {name!r}")
        if not isinstance(checksum, str) or SHA256_RE.fullmatch(checksum) is None:
            raise AuditError(f"manifest artifact checksum is invalid: {name}")
        if not isinstance(size, int) or size < 0:
            raise AuditError(f"manifest artifact size is invalid: {name}")
        path = files[name]
        if path.stat().st_size != size or digest(path) != checksum:
            raise AuditError(f"manifest artifact metadata does not match: {name}")
        seen.add(name)
    if seen != expected_names:
        raise AuditError(f"manifest artifact inventory mismatch; missing={sorted(expected_names - seen)}")


def audit(
    *,
    artifact_dir_raw: str,
    manifest_raw: str,
    expected_commit: str,
    expected_target: str,
    expected_flavor: str,
    expected_request_hash: str,
) -> None:
    validate_expected_values(expected_commit, expected_target, expected_flavor, expected_request_hash)
    artifact_dir = require_directory(artifact_dir_raw)
    manifest_path = require_direct_child(manifest_raw, artifact_dir, MANIFEST_NAME)
    checksums_path = artifact_dir / CHECKSUMS_NAME
    require_regular_file(manifest_path, description="custom build manifest")
    require_regular_file(checksums_path, description="SHA256SUMS")
    files = inventory_tree(artifact_dir)
    manifest = read_json(manifest_path, "custom build manifest")
    if not isinstance(manifest, dict):
        raise AuditError("custom build manifest must be a JSON object")
    expected_fields = {
        "request_hash": expected_request_hash,
        "target": expected_target,
        "flavor": expected_flavor,
        "commit": expected_commit,
    }
    for field, expected in expected_fields.items():
        if manifest.get(field) != expected:
            raise AuditError(f"manifest {field} does not match the expected value")
    validate_manifest_artifacts(manifest, files)
    checksums = parse_checksums(checksums_path, artifact_dir)
    expected_checksum_names = set(files) - {CHECKSUMS_NAME}
    if set(checksums) != expected_checksum_names:
        missing = sorted(expected_checksum_names - set(checksums))
        extra = sorted(set(checksums) - expected_checksum_names)
        raise AuditError(f"SHA256SUMS inventory mismatch; missing={missing}, extra={extra}")
    if MANIFEST_NAME not in checksums:
        raise AuditError("SHA256SUMS does not cover custom-build-manifest.json")
    for name, expected_digest in checksums.items():
        if digest(files[name]) != expected_digest:
            raise AuditError(f"SHA256SUMS digest mismatch: {name}")


def finalize(args: argparse.Namespace) -> None:
    validate_expected_values(args.expected_commit, args.expected_target, args.expected_flavor, args.expected_request_hash)
    artifact_dir = require_directory(args.artifact_dir)
    request_path = lexical_absolute(args.request_file)
    require_regular_file(request_path, description="normalized request")
    request = validate_request(
        read_json(request_path, "normalized request"),
        expected_target=args.expected_target,
        expected_flavor=args.expected_flavor,
        expected_request_hash=args.expected_request_hash,
    )
    manifest_path = artifact_dir / MANIFEST_NAME
    checksums_path = artifact_dir / CHECKSUMS_NAME
    request_artifact_path = artifact_dir / "custom-request.json"
    inventory_tree(artifact_dir)
    write_atomic(
        request_artifact_path,
        json.dumps(request, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        "custom request artifact",
    )
    packages = actual_packages(artifact_dir, args.expected_target)
    missing_resolved = sorted(set(request["packages"]) - set(packages))
    if missing_resolved:
        raise AuditError(f"final package set omitted resolved packages: {missing_resolved}")

    files_before_manifest = inventory_tree(artifact_dir)
    artifacts = [
        {"name": name, "sha256": digest(path), "size": path.stat().st_size}
        for name, path in sorted(files_before_manifest.items())
        if name not in {MANIFEST_NAME, CHECKSUMS_NAME}
    ]
    if not artifacts:
        raise AuditError("artifact directory is empty")
    manifest = {
        "schema_version": 1,
        "project": "NexaWrt",
        "commit": args.expected_commit,
        "request_hash": args.expected_request_hash,
        "catalog_version": request["catalog_version"],
        "target": args.expected_target,
        "flavor": args.expected_flavor,
        "build_environment": build_environment(),
        "resolved_components": request["resolved_components"],
        "resolved_packages": request["packages"],
        "packages": packages,
        "artifacts": artifacts,
    }
    write_atomic(
        manifest_path,
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        "custom build manifest",
    )

    files_for_checksums = inventory_tree(artifact_dir)
    checksum_lines = [
        f"{digest(path)}  {name}"
        for name, path in sorted(files_for_checksums.items())
        if name != CHECKSUMS_NAME
    ]
    write_atomic(checksums_path, "\n".join(checksum_lines) + "\n", "SHA256SUMS")
    audit(
        artifact_dir_raw=str(artifact_dir),
        manifest_raw=str(manifest_path),
        expected_commit=args.expected_commit,
        expected_target=args.expected_target,
        expected_flavor=args.expected_flavor,
        expected_request_hash=args.expected_request_hash,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("finalize", "audit"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--artifact-dir", required=True)
        subparser.add_argument("--expected-commit", required=True)
        subparser.add_argument("--expected-target", required=True)
        subparser.add_argument("--expected-flavor", required=True)
        subparser.add_argument("--expected-request-hash", required=True)
        if command == "finalize":
            subparser.add_argument("--request-file", required=True)
        else:
            subparser.add_argument("--manifest", required=True)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "finalize":
            finalize(args)
        else:
            audit(
                artifact_dir_raw=args.artifact_dir,
                manifest_raw=args.manifest,
                expected_commit=args.expected_commit,
                expected_target=args.expected_target,
                expected_flavor=args.expected_flavor,
                expected_request_hash=args.expected_request_hash,
            )
    except (AuditError, OSError, UnicodeError, ValueError, KeyError) as exc:
        print(f"custom artifact audit failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
