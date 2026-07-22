#!/usr/bin/env python3
"""Build and safely stage a locked NexaWrt APK package repository archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / "manifests/package-repository.lock"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
KEY_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
SAFE_VALUE_RE = re.compile(r"^[A-Za-z0-9._/:@+-]+$")
SAFE_COMPONENT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
APK_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]*\.apk$")
MAX_LOCK_BYTES = 64 * 1024
MAX_JSON_BYTES = 1024 * 1024
MAX_PUBLIC_KEY_BYTES = 64 * 1024
DEFAULT_MAX_ARCHIVE_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_MAX_MEMBER_BYTES = 512 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
DEFAULT_MAX_MEMBERS = 20_000
COPY_CHUNK = 1024 * 1024
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class RepositoryError(RuntimeError):
    """A repository input failed a safety or integrity check."""


def fail(message: str) -> "NoReturn":
    raise RepositoryError(message)


def _regular_file(path: Path, context: str, maximum: int | None = None) -> os.stat_result:
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"unable to inspect {context}: {error}")
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        fail(f"{context} must be a regular, single-link file")
    if maximum is not None and (info.st_size <= 0 or info.st_size > maximum):
        fail(f"{context} size is outside the allowed limit")
    return info


def _real_directory(path: Path, context: str) -> Path:
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"unable to inspect {context}: {error}")
    if not stat.S_ISDIR(info.st_mode) or path.is_symlink():
        fail(f"{context} must be a real directory")
    return path.resolve(strict=True)


def _safe_existing_parent(path: Path, context: str) -> Path:
    parent = path.parent
    resolved = _real_directory(parent, f"{context} parent")
    if os.path.lexists(path):
        fail(f"{context} already exists")
    return resolved / path.name


def _ensure_real_children(root: Path, parts: Iterable[str], context: str) -> Path:
    current = _real_directory(root, context)
    for part in parts:
        child = current / part
        if os.path.lexists(child):
            info = child.lstat()
            if not stat.S_ISDIR(info.st_mode) or child.is_symlink():
                fail(f"{context} contains a non-directory or symbolic link")
        else:
            try:
                child.mkdir(mode=0o755)
            except OSError as error:
                fail(f"unable to create {context}: {error}")
        current = child.resolve(strict=True)
    return current


def _read_bounded_regular(path: Path, context: str, maximum: int) -> bytes:
    expected = _regular_file(path, context, maximum)
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | NOFOLLOW)
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            fail(f"{context} changed while opening")
        data = bytearray()
        while True:
            chunk = os.read(descriptor, min(COPY_CHUNK, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > maximum:
                fail(f"{context} exceeds the allowed limit")
        final = os.fstat(descriptor)
        if (final.st_dev, final.st_ino, final.st_size) != (
            expected.st_dev,
            expected.st_ino,
            expected.st_size,
        ):
            fail(f"{context} changed while reading")
        return bytes(data)
    except OSError as error:
        fail(f"unable to read {context}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def parse_lock(path: Path) -> dict[str, str]:
    raw = _read_bounded_regular(path, "package repository lock", MAX_LOCK_BYTES)
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as error:
        fail(f"package repository lock must be ASCII: {error}")
    values: dict[str, str] = {}
    for number, original in enumerate(text.splitlines(), 1):
        line = original.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"invalid lock line {number}: expected key=value")
        key, encoded = line.split("=", 1)
        if key != key.strip() or not KEY_RE.fullmatch(key) or key in values:
            fail(f"invalid or duplicate lock key on line {number}")
        if encoded.startswith(('"', "'")):
            quote = encoded[0]
            if len(encoded) < 2 or encoded[-1] != quote:
                fail(f"unterminated quoted lock value on line {number}")
            value = encoded[1:-1]
            if quote in value or "\\" in value or "$" in value or "`" in value:
                fail(f"unsafe quoted lock value on line {number}")
        else:
            value = encoded
        if not value or not SAFE_VALUE_RE.fullmatch(value):
            fail(f"invalid lock value on line {number}")
        values[key] = value
    return values


def _locked(values: dict[str, str], field: str, aliases: Iterable[str]) -> str:
    found = {values[name] for name in aliases if name in values}
    if not found:
        fail(f"package repository lock is missing {field}")
    if len(found) != 1:
        fail(f"package repository lock has conflicting {field} values")
    return found.pop()


def _optional_locked(values: dict[str, str], aliases: Iterable[str]) -> str | None:
    found = {values[name] for name in aliases if name in values}
    if len(found) > 1:
        fail("package repository lock contains conflicting aliases")
    return found.pop() if found else None


def repository_config(lock_path: Path) -> dict[str, Any]:
    values = parse_lock(lock_path)
    prefix = "NEXAWRT_PACKAGE_REPOSITORY_"
    schema = _optional_locked(values, ("NEXAWRT_REPOSITORY_SCHEMA", prefix + "SCHEMA"))
    if schema is not None and schema != "1":
        fail("package repository lock uses an unsupported schema")

    release = _locked(
        values,
        "release",
        ("NEXAWRT_REPOSITORY_RELEASE", prefix + "RELEASE", prefix + "VERSION", "REPOSITORY_VERSION"),
    )
    series = _optional_locked(values, ("NEXAWRT_REPOSITORY_SERIES", prefix + "SERIES")) or release
    channel = _locked(
        values,
        "channel",
        ("NEXAWRT_REPOSITORY_CHANNEL", prefix + "CHANNEL", prefix + "TARGET", "REPOSITORY_TARGET"),
    )
    architecture = _locked(
        values,
        "architecture",
        (
            "NEXAWRT_REPOSITORY_ARCH",
            "NEXAWRT_REPOSITORY_ARCHITECTURE",
            prefix + "ARCHITECTURE",
            prefix + "ARCH",
            "REPOSITORY_ARCHITECTURE",
        ),
    )
    asset_name = _locked(
        values,
        "asset name",
        ("NEXAWRT_REPOSITORY_ASSET", "NEXAWRT_REPOSITORY_ASSET_NAME", prefix + "ASSET_NAME", "REPOSITORY_ASSET_NAME"),
    )
    derived_directory = f"{series}/{channel}/{architecture}"
    directory = _optional_locked(
        values,
        (prefix + "DIRECTORY", prefix + "PATH", "NEXAWRT_REPOSITORY_DIRECTORY", "REPOSITORY_DIRECTORY"),
    ) or derived_directory
    if directory != derived_directory:
        fail("locked repository directory is inconsistent with series, channel, and architecture")

    for label, value in (("series", series), ("release", release), ("channel", channel), ("architecture", architecture)):
        if not SAFE_COMPONENT_RE.fullmatch(value):
            fail(f"locked repository {label} is unsafe")
    directory_path = PurePosixPath(directory)
    if directory_path.is_absolute() or not directory_path.parts or any(
        part in ("", ".", "..") or not SAFE_COMPONENT_RE.fullmatch(part) for part in directory_path.parts
    ):
        fail("locked repository directory is unsafe")
    if not SAFE_COMPONENT_RE.fullmatch(asset_name):
        fail("locked repository asset name is unsafe")

    base_url = _optional_locked(values, ("NEXAWRT_REPOSITORY_BASE_URL", prefix + "BASE_URL"))
    index_url = _optional_locked(values, ("NEXAWRT_REPOSITORY_INDEX_URL", prefix + "INDEX_URL"))
    if base_url is not None:
        expected_suffix = "/packages/" + directory_path.as_posix()
        if not base_url.startswith("https://") or not base_url.endswith(expected_suffix):
            fail("locked repository base URL is inconsistent with its directory")
        if index_url != base_url + "/packages.adb":
            fail("locked repository index URL is inconsistent with its base URL")
    elif index_url is not None:
        fail("locked repository index URL requires a base URL")

    def limit(name: str, default: int) -> int:
        raw = _optional_locked(values, (prefix + name, "NEXAWRT_REPOSITORY_" + name))
        if raw is None:
            return default
        if not raw.isdecimal():
            fail(f"locked {name.lower()} must be a decimal integer")
        value = int(raw)
        if value <= 0 or value > DEFAULT_MAX_TOTAL_BYTES:
            fail(f"locked {name.lower()} is outside the allowed limit")
        return value

    config = {
        "series": series,
        "release": release,
        "version": release,
        "channel": channel,
        "target": channel,
        "architecture": architecture,
        "asset_name": asset_name,
        "directory": directory_path.as_posix(),
        "base_url": base_url,
        "index_url": index_url,
        "release_tag": _optional_locked(values, ("NEXAWRT_REPOSITORY_RELEASE_TAG", prefix + "RELEASE_TAG")),
        "public_sha256": _optional_locked(values, ("NEXAWRT_REPOSITORY_PUBLIC_SHA256", prefix + "PUBLIC_SHA256")),
        "package_set_sha256": _optional_locked(values, ("NEXAWRT_REPOSITORY_PACKAGE_SET_SHA256", prefix + "PACKAGE_SET_SHA256")),
        "max_archive_bytes": limit("MAX_ARCHIVE_BYTES", DEFAULT_MAX_ARCHIVE_BYTES),
        "max_member_bytes": limit("MAX_MEMBER_BYTES", DEFAULT_MAX_MEMBER_BYTES),
        "max_total_bytes": limit("MAX_TOTAL_BYTES", DEFAULT_MAX_TOTAL_BYTES),
        "max_members": limit("MAX_MEMBERS", DEFAULT_MAX_MEMBERS),
    }
    if config["max_member_bytes"] > config["max_total_bytes"]:
        fail("locked member limit exceeds total extraction limit")
    return config


def sha256_file(path: Path, maximum: int | None = None) -> tuple[str, int]:
    expected = _regular_file(path, str(path), maximum)
    digest = hashlib.sha256()
    descriptor = -1
    total = 0
    try:
        descriptor = os.open(path, os.O_RDONLY | NOFOLLOW)
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            fail(f"file changed while hashing: {path}")
        while True:
            chunk = os.read(descriptor, COPY_CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if maximum is not None and total > maximum:
                fail(f"file exceeds size limit: {path}")
            digest.update(chunk)
        final = os.fstat(descriptor)
        if (final.st_dev, final.st_ino, final.st_size) != (expected.st_dev, expected.st_ino, expected.st_size):
            fail(f"file changed while hashing: {path}")
    except OSError as error:
        fail(f"unable to hash {path}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest(), total


def copy_regular(source: Path, destination: Path, maximum: int) -> tuple[str, int]:
    expected = _regular_file(source, f"APK {source.name}", maximum)
    source_fd = destination_fd = -1
    digest = hashlib.sha256()
    total = 0
    try:
        source_fd = os.open(source, os.O_RDONLY | NOFOLLOW)
        opened = os.fstat(source_fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            fail(f"APK changed while opening: {source.name}")
        destination_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o644)
        while True:
            chunk = os.read(source_fd, COPY_CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                fail(f"APK exceeds size limit: {source.name}")
            digest.update(chunk)
            view = memoryview(chunk)
            while view:
                view = view[os.write(destination_fd, view):]
        os.fsync(destination_fd)
        final = os.fstat(source_fd)
        if (final.st_dev, final.st_ino, final.st_size) != (expected.st_dev, expected.st_ino, expected.st_size):
            fail(f"APK changed while copying: {source.name}")
    except OSError as error:
        fail(f"unable to copy APK {source.name}: {error}")
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        if destination_fd >= 0:
            os.close(destination_fd)
    return digest.hexdigest(), total


def _write_new(path: Path, data: bytes, mode: int = 0o644) -> None:
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, mode)
        view = memoryview(data)
        while view:
            view = view[os.write(descriptor, view):]
        os.fsync(descriptor)
    except OSError as error:
        fail(f"unable to write {path.name}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _load_locked_public_key(
    public_key_source: Path,
    expected_public_sha256: str | None,
    timeout: int,
) -> bytes:
    if expected_public_sha256 is None or not SHA256_RE.fullmatch(expected_public_sha256):
        fail("locked repository public key SHA-256 is missing or invalid")
    public_key_data = _read_bounded_regular(public_key_source, "APK public key", MAX_PUBLIC_KEY_BYTES)
    try:
        parsed = subprocess.run(
            ["openssl", "pkey", "-pubin", "-inform", "PEM", "-outform", "DER"],
            input=public_key_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            close_fds=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"public key validation failed: {type(error).__name__}")
    if parsed.returncode != 0 or not parsed.stdout:
        fail("APK public key is not a valid PEM public key")
    if hashlib.sha256(parsed.stdout).hexdigest() != expected_public_sha256:
        fail("APK public key does not match the locked public key SHA-256")
    return public_key_data


def _resolve_executable(path: Path, context: str) -> Path:
    candidate = path
    if not candidate.is_absolute() and len(candidate.parts) == 1:
        located = shutil.which(str(candidate))
        if located is None:
            fail(f"unable to locate {context}")
        candidate = Path(located)
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        fail(f"unable to canonicalize {context}: {error}")
    _regular_file(resolved, context)
    if not os.access(resolved, os.X_OK):
        fail(f"{context} is not executable")
    return resolved


def _verify_signed_index(
    apk_executable: Path,
    repository: Path,
    public_key_data: bytes,
    timeout: int,
) -> None:
    with tempfile.TemporaryDirectory(prefix="nexawrt-apk-verify.") as raw_keys_dir:
        keys_dir = Path(raw_keys_dir)
        os.chmod(keys_dir, 0o700)
        verification_key = keys_dir / "nexawrt-repository.pem"
        _write_new(verification_key, public_key_data, 0o644)
        verify_command = [
            str(apk_executable),
            "--keys-dir",
            str(keys_dir),
            "verify",
            "packages.adb",
        ]
        try:
            verified = subprocess.run(
                verify_command,
                cwd=repository,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                close_fds=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            fail(f"apk verify execution failed: {type(error).__name__}")
        if verified.returncode != 0:
            fail("apk verify refused or failed for packages.adb")


def _archive_repository(source: Path, archive: Path, repository_directory: str) -> None:
    mode = "x:gz" if archive.name.endswith(".tar.gz") or archive.name.endswith(".tgz") else "x"
    with tarfile.open(archive, mode=mode, format=tarfile.PAX_FORMAT) as output:
        for path in sorted(source.iterdir(), key=lambda item: item.name):
            _regular_file(path, f"repository file {path.name}")
            info = output.gettarinfo(str(path), arcname=f"{repository_directory}/{path.name}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            info.mode = 0o644
            with path.open("rb") as stream:
                output.addfile(info, stream)


def command_build(args: argparse.Namespace) -> None:
    config = repository_config(args.lock)
    apk_executable = _resolve_executable(args.apk_executable, "apk executable")
    input_dir = _real_directory(args.input_dir, "APK input directory")
    output_dir = _safe_existing_parent(args.output_dir, "repository output directory")
    archive = _safe_existing_parent(args.archive, "repository archive")
    if archive.name != config["asset_name"]:
        fail("archive filename does not match the locked GitHub asset name")
    _regular_file(args.private_key, "APK private key")  # Inspect metadata only; never read key bytes.
    public_key_data = _load_locked_public_key(
        args.public_key,
        config["public_sha256"],
        args.apk_timeout,
    )
    try:
        private_key = args.private_key.resolve(strict=True)
    except OSError as error:
        fail(f"unable to canonicalize APK private key: {error}")
    apk_files = sorted((path for path in input_dir.iterdir() if path.name.endswith(".apk")), key=lambda item: item.name)
    if not apk_files:
        fail("APK input directory contains no packages")
    if len(apk_files) + 3 > config["max_members"]:
        fail("APK input contains too many packages")
    seen: set[str] = set()
    for path in apk_files:
        if not APK_NAME_RE.fullmatch(path.name) or path.name in seen:
            fail(f"unsafe or duplicate APK filename: {path.name}")
        seen.add(path.name)
        _regular_file(path, f"APK {path.name}", config["max_member_bytes"])

    temporary = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent))
    completed = False
    try:
        package_records: list[dict[str, Any]] = []
        for source in apk_files:
            digest, size = copy_regular(source, temporary / source.name, config["max_member_bytes"])
            package_records.append({"filename": source.name, "sha256": digest, "size": size})
        command = [
            str(apk_executable),
            "mkndx",
            "--allow-untrusted",
            "--sign",
            str(private_key),
            "--output",
            "packages.adb",
        ]
        command.extend(record["filename"] for record in package_records)
        try:
            result = subprocess.run(
                command,
                cwd=temporary,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                close_fds=True,
                timeout=args.apk_timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            fail(f"apk mkndx execution failed: {type(error).__name__}")
        if result.returncode != 0:
            fail("apk mkndx refused or failed")
        for record in package_records:
            digest, size = sha256_file(temporary / record["filename"], config["max_member_bytes"])
            if digest != record["sha256"] or size != record["size"]:
                fail(f"apk mkndx modified repository payload: {record['filename']}")
        index_path = temporary / "packages.adb"
        _regular_file(index_path, "packages.adb", config["max_member_bytes"])
        _verify_signed_index(
            apk_executable,
            temporary,
            public_key_data,
            args.apk_timeout,
        )
        index_digest, index_size = sha256_file(index_path, config["max_member_bytes"])
        checksums = [(record["filename"], record["sha256"]) for record in package_records]
        checksums.append(("packages.adb", index_digest))
        checksums.sort()
        checksum_data = "".join(f"{digest}  {name}\n" for name, digest in checksums).encode("ascii")
        _write_new(temporary / "SHA256SUMS", checksum_data)
        descriptor = {
            "schema_version": 1,
            "repository_version": config["release"],
            "version": config["release"],
            "series": config["series"],
            "release": config["release"],
            "channel": config["channel"],
            "target": config["target"],
            "architecture": config["architecture"],
            "directory": config["directory"],
            "base_url": config["base_url"],
            "index_url": config["index_url"],
            "release_tag": config["release_tag"],
            "asset_name": config["asset_name"],
            "public_sha256": config["public_sha256"],
            "package_set_sha256": config["package_set_sha256"],
            "packages": package_records,
            "index": {
                "filename": "packages.adb",
                "sha256": index_digest,
                "size": index_size,
                "signature_verified": True,
            },
            "checksums": "SHA256SUMS",
        }
        _write_new(
            temporary / "repository.json",
            (json.dumps(descriptor, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii"),
        )
        os.replace(temporary, output_dir)
        completed = True
        try:
            _archive_repository(output_dir, archive, config["directory"])
        except (OSError, tarfile.TarError) as error:
            fail(f"unable to create repository archive: {error}")
        archive_digest, archive_size = sha256_file(archive, config["max_archive_bytes"])
        print(json.dumps({"archive": str(archive), "sha256": archive_digest, "size": archive_size}, sort_keys=True))
    finally:
        if not completed:
            shutil.rmtree(temporary, ignore_errors=True)


def _normalize_digest(value: str, context: str) -> str:
    digest = value.removeprefix("sha256:").lower()
    if not SHA256_RE.fullmatch(digest):
        fail(f"{context} is not a valid SHA-256 digest")
    return digest


def _github_asset_digest(path: Path, expected_name: str) -> str:
    raw = _read_bounded_regular(path, "GitHub API asset JSON", MAX_JSON_BYTES)
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid GitHub API asset JSON: {error}")
    assets = document.get("assets") if isinstance(document, dict) else None
    if assets is None:
        assets = [document]
    if not isinstance(assets, list):
        fail("GitHub API asset JSON has no asset list")
    matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == expected_name]
    if len(matches) != 1:
        fail("GitHub API response does not contain exactly one locked repository asset")
    digest = matches[0].get("digest")
    if not isinstance(digest, str):
        fail("GitHub API asset has no digest")
    return _normalize_digest(digest, "GitHub API asset digest")


def _safe_tar_name(name: str) -> str:
    if not name or name.startswith("/") or "\\" in name or "\x00" in name:
        fail("archive contains an unsafe absolute or malformed path")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail("archive contains path traversal")
    normalized = path.as_posix()
    if normalized != name.rstrip("/"):
        fail("archive contains a non-canonical path")
    return normalized


def _validated_members(archive: tarfile.TarFile, config: dict[str, Any]) -> list[tarfile.TarInfo]:
    members: list[tarfile.TarInfo] = []
    for member in archive:
        members.append(member)
        if len(members) > config["max_members"]:
            fail("archive member count is outside the allowed limit")
    if not members:
        fail("archive member count is outside the allowed limit")
    seen: set[str] = set()
    total = 0
    prefix = config["directory"] + "/"
    result: list[tarfile.TarInfo] = []
    for member in members:
        name = _safe_tar_name(member.name)
        if name in seen:
            fail("archive contains duplicate paths")
        seen.add(name)
        if member.issym() or member.islnk():
            fail("archive contains a symbolic or hard link")
        if member.isdev() or member.isfifo() or not (member.isfile() or member.isdir()):
            fail("archive contains a device or unsupported special file")
        if not (name == config["directory"] or name.startswith(prefix)):
            fail("archive member is outside the locked repository directory")
        if member.isfile():
            relative = name[len(prefix):]
            if not relative or "/" in relative:
                fail("repository archive contains nested or misplaced files")
            if relative not in ("SHA256SUMS", "repository.json", "packages.adb") and not APK_NAME_RE.fullmatch(relative):
                fail("repository archive contains an unexpected file")
            if member.size <= 0 or member.size > config["max_member_bytes"]:
                fail("archive member size is outside the allowed limit")
            total += member.size
            if total > config["max_total_bytes"]:
                fail("archive expands beyond the allowed total size")
        result.append(member)
    required = {f"{config['directory']}/{name}" for name in ("SHA256SUMS", "repository.json", "packages.adb")}
    if not required.issubset(seen):
        fail("archive is missing required repository metadata")
    return result


def _extract_validated(archive: tarfile.TarFile, members: list[tarfile.TarInfo], destination: Path) -> None:
    _real_directory(destination, "temporary extraction directory")
    for member in members:
        target = destination.joinpath(*PurePosixPath(member.name).parts)
        if member.isdir():
            target.mkdir(mode=0o755, parents=True, exist_ok=True)
            continue
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        source = archive.extractfile(member)
        if source is None:
            fail("unable to read archive member")
        descriptor = -1
        written = 0
        try:
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o644)
            while True:
                chunk = source.read(COPY_CHUNK)
                if not chunk:
                    break
                written += len(chunk)
                if written > member.size:
                    fail("archive member exceeds its declared size")
                view = memoryview(chunk)
                while view:
                    view = view[os.write(descriptor, view):]
            if written != member.size:
                fail("archive member is truncated")
            os.fsync(descriptor)
        finally:
            source.close()
            if descriptor >= 0:
                os.close(descriptor)


def _load_repository_json(path: Path, config: dict[str, Any]) -> dict[str, Any]:
    raw = _read_bounded_regular(path, "repository.json", MAX_JSON_BYTES)
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"invalid repository.json: {error}")
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        fail("repository.json uses an unsupported schema")
    expected = {
        "repository_version": config["release"],
        "version": config["release"],
        "series": config["series"],
        "release": config["release"],
        "channel": config["channel"],
        "target": config["target"],
        "architecture": config["architecture"],
        "directory": config["directory"],
        "base_url": config["base_url"],
        "index_url": config["index_url"],
        "release_tag": config["release_tag"],
        "asset_name": config["asset_name"],
        "public_sha256": config["public_sha256"],
        "package_set_sha256": config["package_set_sha256"],
        "checksums": "SHA256SUMS",
    }
    for key, value in expected.items():
        if document.get(key) != value:
            fail(f"repository.json has the wrong {key}")
    return document


def _validate_extracted(root: Path, config: dict[str, Any]) -> None:
    repository = root.joinpath(*PurePosixPath(config["directory"]).parts)
    _real_directory(repository, "extracted repository directory")
    document = _load_repository_json(repository / "repository.json", config)
    actual_files = {path.name for path in repository.iterdir() if path.is_file() and not path.is_symlink()}
    if any(path.is_dir() or path.is_symlink() for path in repository.iterdir()):
        fail("extracted repository contains links or nested directories")
    apk_names = sorted(name for name in actual_files if name.endswith(".apk"))
    expected_files = set(apk_names) | {"packages.adb", "SHA256SUMS", "repository.json"}
    if actual_files != expected_files or not apk_names:
        fail("repository file set is incomplete or unexpected")

    checksum_raw = _read_bounded_regular(repository / "SHA256SUMS", "SHA256SUMS", MAX_JSON_BYTES)
    try:
        lines = checksum_raw.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        fail(f"SHA256SUMS must be ASCII: {error}")
    checksums: dict[str, str] = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+~-]*)", line)
        if not match or match.group(2) in checksums:
            fail("SHA256SUMS contains a malformed or duplicate entry")
        checksums[match.group(2)] = match.group(1)
    payload_names = set(apk_names) | {"packages.adb"}
    if set(checksums) != payload_names:
        fail("SHA256SUMS does not exactly cover repository payloads")
    payload_details: dict[str, tuple[str, int]] = {}
    for name in sorted(payload_names):
        digest, size = sha256_file(repository / name, config["max_member_bytes"])
        if digest != checksums[name]:
            fail(f"repository payload digest mismatch: {name}")
        payload_details[name] = (digest, size)

    packages = document.get("packages")
    if not isinstance(packages, list) or len(packages) != len(apk_names):
        fail("repository.json package list is invalid")
    records: dict[str, dict[str, Any]] = {}
    for record in packages:
        if not isinstance(record, dict) or set(record) != {"filename", "sha256", "size"}:
            fail("repository.json contains a malformed package record")
        name = record.get("filename")
        if not isinstance(name, str) or name in records:
            fail("repository.json contains a duplicate package record")
        records[name] = record
    if set(records) != set(apk_names):
        fail("repository.json package list does not match archive APKs")
    for name in apk_names:
        digest, size = payload_details[name]
        if records[name] != {"filename": name, "sha256": digest, "size": size}:
            fail(f"repository.json package metadata mismatch: {name}")
    index = document.get("index")
    index_digest, index_size = payload_details["packages.adb"]
    if not isinstance(index, dict) or set(index) != {"filename", "sha256", "size", "signature_verified"}:
        fail("repository.json index metadata is invalid")
    if index.get("signature_verified") is not True:
        fail("repository.json does not contain a valid signature verification receipt")
    if (index.get("filename"), index.get("sha256"), index.get("size")) != (
        "packages.adb",
        index_digest,
        index_size,
    ):
        fail("repository.json index metadata is invalid")


def command_stage_pages(args: argparse.Namespace) -> None:
    config = repository_config(args.lock)
    archive_info = _regular_file(args.archive, "repository archive", config["max_archive_bytes"])
    if args.archive.name != config["asset_name"]:
        fail("archive filename does not match the locked GitHub asset name")
    archive_digest, archive_size = sha256_file(args.archive, config["max_archive_bytes"])
    expected_archive_digest = _normalize_digest(args.archive_sha256, "archive SHA-256")
    if archive_digest != expected_archive_digest:
        fail("repository archive SHA-256 mismatch")
    if args.github_asset_json is not None:
        api_digest = _github_asset_digest(args.github_asset_json, config["asset_name"])
    else:
        api_digest = _normalize_digest(args.github_asset_digest, "GitHub API asset digest")
    if archive_digest != api_digest:
        fail("GitHub API asset digest does not match repository archive")
    if archive_info.st_size != archive_size:
        fail("repository archive changed while being verified")

    site_root = _real_directory(args.site_dir, "site directory")
    packages_root = site_root / "packages"
    if packages_root.exists() or packages_root.is_symlink():
        packages_root = _real_directory(packages_root, "site packages directory")
    else:
        packages_root.mkdir(mode=0o755)
        packages_root = packages_root.resolve(strict=True)
    directory_parts = PurePosixPath(config["directory"]).parts
    destination_parent = _ensure_real_children(packages_root, directory_parts[:-1], "Pages repository path")
    destination = destination_parent / directory_parts[-1]
    if os.path.lexists(destination):
        fail("locked Pages repository destination already exists")
    temporary = Path(tempfile.mkdtemp(prefix=".repository-stage.", dir=packages_root))
    try:
        try:
            with tarfile.open(args.archive, mode="r:*") as source:
                members = _validated_members(source, config)
                _extract_validated(source, members, temporary)
        except (OSError, tarfile.TarError) as error:
            fail(f"unable to validate repository archive: {error}")
        post_digest, post_size = sha256_file(args.archive, config["max_archive_bytes"])
        if post_digest != archive_digest or post_size != archive_size:
            fail("repository archive changed during validation")
        _validate_extracted(temporary, config)
        staged_repository = temporary.joinpath(*PurePosixPath(config["directory"]).parts)
        if os.path.lexists(destination):
            fail("locked Pages repository destination appeared during staging")
        os.replace(staged_repository, destination)
        print(json.dumps({"staged": str(destination), "sha256": archive_digest, "size": archive_size}, sort_keys=True))
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    subcommands = result.add_subparsers(dest="command", required=True)

    build = subcommands.add_parser("build", help="build and archive a signed APK repository")
    build.add_argument("--input-dir", type=Path, required=True)
    build.add_argument("--output-dir", type=Path, required=True)
    build.add_argument("--archive", type=Path, required=True)
    build.add_argument("--private-key", type=Path, required=True)
    build.add_argument("--public-key", type=Path, required=True)
    build.add_argument("--apk-executable", type=Path, default=Path("apk"))
    build.add_argument("--apk-timeout", type=int, default=300)
    build.set_defaults(handler=command_build)

    stage = subcommands.add_parser("stage-pages", help="verify and safely stage a repository archive for Pages")
    stage.add_argument("--archive", type=Path, required=True)
    stage.add_argument("--archive-sha256", "--sha256", required=True)
    digest_group = stage.add_mutually_exclusive_group(required=True)
    digest_group.add_argument("--github-asset-json", "--asset-json", type=Path)
    digest_group.add_argument("--github-asset-digest")
    stage.add_argument("--site-dir", "--site-root", type=Path, required=True)
    stage.set_defaults(handler=command_stage_pages)
    return result


def main() -> int:
    try:
        arguments = parser().parse_args()
        if getattr(arguments, "apk_timeout", 1) <= 0:
            fail("apk timeout must be positive")
        arguments.handler(arguments)
        return 0
    except RepositoryError as error:
        print(f"package repository refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
