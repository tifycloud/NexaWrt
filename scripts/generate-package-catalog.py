#!/usr/bin/env python3
"""Generate the locked OpenWrt 25.12.5 package catalog.

Only signed ``packages.adb`` indexes below the allow-listed OpenWrt release
namespace are accepted. Metadata is decoded only with apk-tools 3 from the SHA-256 locked x86/64
ImageBuilder. Unlocked external apk binaries are intentionally unsupported.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from component_package_policy import (
    allowed_architectures_for,
    blocked_reason_for,
    risk_for,
)

ROOT = Path(__file__).resolve().parent.parent
VM_LOCK_PATH = ROOT / "manifests" / "vm.lock"
CATALOG_VERSION = "2026.07.21"
OPENWRT_VERSION = "25.12.5"
DOWNLOAD_HOST = "downloads.openwrt.org"
RELEASE_PREFIX = f"/releases/{OPENWRT_VERSION}/"
PROFILE_URL = (
    f"https://{DOWNLOAD_HOST}{RELEASE_PREFIX}targets/qualcommax/ipq807x/profiles.json"
)
PACKAGE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
LOCK_LINE_RE = re.compile(r'^([A-Z0-9_]+)="([^"\r\n]+)"$')
ALLOWED_FEEDS = (
    "target",
    "base",
    "kmods",
    "luci",
    "packages",
    "routing",
    "telephony",
    "video",
)
SHARD_SPECS = (
    ("x86_64", "official", "components/packages/x86_64-official.json"),
    ("xiaomi_ax9000", "official", "components/packages/xiaomi_ax9000-official.json"),
    ("xiaomi_ax9000", "nss", "components/packages/xiaomi_ax9000-nss.json"),
)
FEED_CATEGORY = {
    "target": "official-target",
    "base": "official-base",
    "kmods": "official-kernel",
    "luci": "official-luci",
    "packages": "official-packages",
    "routing": "official-routing",
    "telephony": "official-telephony",
    "video": "official-video",
}



class GenerationError(RuntimeError):
    """The locked catalog could not be generated safely."""


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


MAX_IMAGEBUILDER_BYTES = 1024 * 1024 * 1024
MAX_PROFILE_BYTES = 8 * 1024 * 1024
MAX_PACKAGE_INDEX_BYTES = 64 * 1024 * 1024
MAX_APK_DUMP_BYTES = 192 * 1024 * 1024
IO_CHUNK_SIZE = 1024 * 1024
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
DIRECTORY = getattr(os, "O_DIRECTORY", 0)


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8") + b"\n"


def _safe_url(url: str, *, suffixes: tuple[str, ...]) -> str:
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != DOWNLOAD_HOST
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith(RELEASE_PREFIX)
        or not parsed.path.endswith(suffixes)
        or "//" in parsed.path
        or any(part in {"", ".", ".."} for part in parsed.path.split("/")[1:])
    ):
        raise GenerationError(f"URL is outside the OpenWrt release allow-list: {url!r}")
    return urllib.parse.urlunsplit(parsed)


def _read_regular_file(path: Path, maximum: int, context: str) -> bytes:
    """Read one regular, single-link file through the descriptor we validated."""
    flags = os.O_RDONLY | NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise GenerationError(f"unable to open {context}: {error}") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise GenerationError(f"{context} must be a regular, single-link file")
        if info.st_size > maximum:
            raise GenerationError(f"{context} exceeds the {maximum}-byte limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(IO_CHUNK_SIZE, maximum - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise GenerationError(f"{context} exceeds the {maximum}-byte limit")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _download_limit(url: str) -> int:
    path = urllib.parse.urlsplit(url).path
    if path.endswith(".tar.zst"):
        return MAX_IMAGEBUILDER_BYTES
    if path.endswith("profiles.json"):
        return MAX_PROFILE_BYTES
    if path.endswith("packages.adb"):
        return MAX_PACKAGE_INDEX_BYTES
    raise GenerationError(f"no download size policy for {url}")


def _download(url: str, destination: Path) -> tuple[str, int]:
    """Stream one allow-listed download to a new no-follow file with a hard cap."""
    safe = _safe_url(url, suffixes=("packages.adb", "profiles.json", ".tar.zst"))
    maximum = _download_limit(safe)
    request = urllib.request.Request(safe, headers={"User-Agent": "NexaWrt-catalog/1"})
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW
    descriptor: int | None = None
    digest = hashlib.sha256()
    total = 0
    completed = False
    try:
        destination.parent.mkdir(parents=False, exist_ok=True)
        descriptor = os.open(destination, flags, 0o600)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise GenerationError("download destination must be a regular, single-link file")
        with urllib.request.urlopen(request, timeout=60) as response:
            if response.geturl() != safe:
                raise GenerationError(f"redirects are not allowed while downloading {safe}")
            content_length = response.headers.get("Content-Length")
            if content_length is not None:
                try:
                    declared = int(content_length)
                except ValueError as error:
                    raise GenerationError(f"invalid Content-Length for {safe}") from error
                if declared <= 0 or declared > maximum:
                    raise GenerationError(f"download size for {safe} is outside the allowed limit")
            while True:
                chunk = response.read(IO_CHUNK_SIZE)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    raise GenerationError(f"downloaded file exceeds size limit: {safe}")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(descriptor, view)
                    view = view[written:]
        if total == 0:
            raise GenerationError(f"downloaded empty file: {safe}")
        os.fsync(descriptor)
        final_info = os.fstat(descriptor)
        if not stat.S_ISREG(final_info.st_mode) or final_info.st_nlink != 1:
            raise GenerationError("download destination changed while it was written")
        completed = True
        return digest.hexdigest(), total
    except (OSError, urllib.error.URLError) as error:
        raise GenerationError(f"unable to download {safe}: {error}") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if not completed:
            try:
                destination.unlink()
            except OSError:
                pass


def _open_directory(path: Path, context: str) -> int:
    try:
        descriptor = os.open(path, os.O_RDONLY | DIRECTORY | NOFOLLOW)
    except OSError as error:
        raise GenerationError(f"unable to open {context}: {error}") from error
    info = os.fstat(descriptor)
    if not stat.S_ISDIR(info.st_mode):
        os.close(descriptor)
        raise GenerationError(f"{context} must be a real directory")
    return descriptor


def _open_or_create_child_directory(parent_fd: int, name: str, context: str) -> int:
    flags = os.O_RDONLY | DIRECTORY | NOFOLLOW
    try:
        return os.open(name, flags, dir_fd=parent_fd)
    except FileNotFoundError:
        try:
            os.mkdir(name, mode=0o755, dir_fd=parent_fd)
            return os.open(name, flags, dir_fd=parent_fd)
        except OSError as error:
            raise GenerationError(f"unable to create {context}: {error}") from error
    except OSError as error:
        raise GenerationError(f"unable to open {context}: {error}") from error


def _safe_write_output(output_root: Path, relative_path: str, data: bytes) -> None:
    """Atomically replace an allow-listed output without following filesystem links."""
    relative = Path(relative_path)
    if relative.is_absolute() or not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        raise GenerationError(f"unsafe output path: {relative_path!r}")
    root_fd = _open_directory(output_root, "output root")
    directory_fds = [root_fd]
    try:
        parent_fd = root_fd
        for position, part in enumerate(relative.parts[:-1]):
            child_fd = _open_or_create_child_directory(
                parent_fd, part, f"output directory {'/'.join(relative.parts[: position + 1])}"
            )
            directory_fds.append(child_fd)
            parent_fd = child_fd
        filename = relative.parts[-1]
        try:
            existing = os.stat(filename, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        except OSError as error:
            raise GenerationError(f"unable to inspect output {relative_path}: {error}") from error
        if existing is not None and (
            not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1
        ):
            raise GenerationError(
                f"output {relative_path} must be a regular, single-link file"
            )

        temporary_name = f".{filename}.tmp-{secrets.token_hex(12)}"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW
        temporary_fd: int | None = None
        try:
            temporary_fd = os.open(temporary_name, flags, 0o644, dir_fd=parent_fd)
            info = os.fstat(temporary_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise GenerationError("temporary output must be a regular, single-link file")
            view = memoryview(data)
            while view:
                written = os.write(temporary_fd, view)
                view = view[written:]
            os.fsync(temporary_fd)
            final_info = os.fstat(temporary_fd)
            if not stat.S_ISREG(final_info.st_mode) or final_info.st_nlink != 1:
                raise GenerationError("temporary output changed while it was written")
            os.replace(
                temporary_name,
                filename,
                src_dir_fd=parent_fd,
                dst_dir_fd=parent_fd,
            )
            published = os.stat(filename, dir_fd=parent_fd, follow_symlinks=False)
            if (
                not stat.S_ISREG(published.st_mode)
                or published.st_nlink != 1
                or published.st_size != len(data)
                or (published.st_dev, published.st_ino)
                != (final_info.st_dev, final_info.st_ino)
            ):
                raise GenerationError(f"published output failed verification: {relative_path}")
            os.fsync(parent_fd)
            os.close(temporary_fd)
            temporary_fd = None
        finally:
            if temporary_fd is not None:
                os.close(temporary_fd)
            try:
                os.unlink(temporary_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
    finally:
        for descriptor in reversed(directory_fds):
            os.close(descriptor)



def _read_vm_lock(path: Path = VM_LOCK_PATH) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise GenerationError(f"unable to read {path}: {error}") from error
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = LOCK_LINE_RE.fullmatch(line)
        if not match:
            raise GenerationError(f"unsupported vm.lock syntax: {line!r}")
        key, value = match.groups()
        if key in values:
            raise GenerationError(f"duplicate vm.lock key: {key}")
        values[key] = value
    required = {
        "VM_OPENWRT_VERSION",
        "VM_X86_64_IMAGEBUILDER_URL",
        "VM_X86_64_IMAGEBUILDER_SHA256",
    }
    missing = sorted(required - set(values))
    if missing:
        raise GenerationError(f"vm.lock is missing keys: {missing}")
    if values["VM_OPENWRT_VERSION"] != OPENWRT_VERSION:
        raise GenerationError("vm.lock OpenWrt version does not match the package catalog")
    if not re.fullmatch(r"[0-9a-f]{64}", values["VM_X86_64_IMAGEBUILDER_SHA256"]):
        raise GenerationError("invalid ImageBuilder SHA256 in vm.lock")
    _safe_url(values["VM_X86_64_IMAGEBUILDER_URL"], suffixes=(".tar.zst",))
    return values


def _ensure_regular_executable(path: Path, context: str) -> Path:
    try:
        info = path.lstat()
    except OSError as error:
        raise GenerationError(f"unable to inspect {context}: {error}") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise GenerationError(f"{context} must be a regular, single-link file")
    if not os.access(path, os.X_OK):
        raise GenerationError(f"{context} is not executable: {path}")
    return path


def _validate_archive_members(names: list[str], verbose_lines: list[str]) -> list[str]:
    if not names or len(names) != len(verbose_lines):
        raise GenerationError("ImageBuilder archive listing is empty or inconsistent")
    top_levels: set[str] = set()
    for name, verbose in zip(names, verbose_lines):
        pure = Path(name)
        if (
            pure.is_absolute()
            or not pure.parts
            or any(part in {"", ".", ".."} for part in pure.parts)
        ):
            raise GenerationError(f"unsafe ImageBuilder archive member: {name!r}")
        member_type = verbose[:1]
        if member_type not in {"-", "d"}:
            raise GenerationError(
                f"ImageBuilder archive member must be a directory or regular file: {name!r}"
            )
        top_levels.add(pure.parts[0])
    if len(top_levels) != 1:
        raise GenerationError("ImageBuilder archive must contain exactly one top-level directory")
    return sorted(top_levels)


def _safe_extract_imagebuilder(archive: Path, destination: Path) -> Path:
    """Extract only the regular files needed by apk; archive links are never extracted."""
    base_command = ["tar", "--use-compress-program=unzstd"]
    try:
        names = subprocess.run(
            [*base_command, "-tf", str(archive)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        verbose_lines = subprocess.run(
            [*base_command, "-tvf", str(archive)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        raise GenerationError(f"unable to inspect ImageBuilder archive: {error}") from error
    if not names or len(names) != len(verbose_lines):
        raise GenerationError("ImageBuilder archive listing is empty or inconsistent")

    top_levels: set[str] = set()
    selected_names: list[str] = []
    selected_verbose: list[str] = []
    required_regular = {
        "repositories",
        "staging_dir/host/bin/apk",
        "staging_dir/host/bin/.apk.bin",
    }
    found_required: set[str] = set()
    key_files = 0
    for name, verbose in zip(names, verbose_lines):
        pure = Path(name)
        if (
            pure.is_absolute()
            or not pure.parts
            or any(part in {"", ".", ".."} for part in pure.parts)
        ):
            raise GenerationError(f"unsafe ImageBuilder archive member: {name!r}")
        top_levels.add(pure.parts[0])
    if len(top_levels) != 1:
        raise GenerationError("ImageBuilder archive must contain exactly one top-level directory")
    top_level = next(iter(top_levels))

    for name, verbose in zip(names, verbose_lines):
        pure = Path(name)
        if pure.parts[0] != top_level or len(pure.parts) < 2:
            continue
        relative = "/".join(pure.parts[1:]).rstrip("/")
        member_type = verbose[:1]
        is_regular = member_type == "-"
        wanted = (
            relative in required_regular
            or relative.startswith("keys/")
            or relative.startswith("staging_dir/host/lib/")
        )
        if not wanted or not is_regular:
            continue
        selected_names.append(name)
        selected_verbose.append(verbose)
        if relative in required_regular and member_type == "-":
            found_required.add(relative)
        if relative.startswith("keys/") and member_type == "-":
            key_files += 1

    _validate_archive_members(selected_names, selected_verbose)
    if found_required != required_regular or key_files < 1:
        raise GenerationError("ImageBuilder archive is missing required locked apk inputs")

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=destination, prefix="members-", delete=False
    ) as selection:
        selection.write("\n".join(selected_names) + "\n")
        selection_path = Path(selection.name)
    try:
        subprocess.run(
            [
                *base_command,
                "--no-same-owner",
                "--no-same-permissions",
                "-xf",
                str(archive),
                "-C",
                str(destination),
                "-T",
                str(selection_path),
            ],
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise GenerationError(f"unable to extract ImageBuilder archive: {error}") from error
    finally:
        try:
            selection_path.unlink()
        except OSError:
            pass

    root = destination / top_level
    try:
        root_info = root.lstat()
    except OSError as error:
        raise GenerationError(f"ImageBuilder root was not extracted safely: {error}") from error
    if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        raise GenerationError("ImageBuilder root must be a real directory")
    for candidate in root.rglob("*"):
        try:
            info = candidate.lstat()
        except OSError as error:
            raise GenerationError(f"unable to inspect extracted member {candidate}: {error}") from error
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise GenerationError(
                f"extracted ImageBuilder member is not a regular, single-link file: {candidate}"
            )
    return root


def _obtain_apk(workspace: Path) -> tuple[Path, Path, Path]:
    lock = _read_vm_lock()
    archive = workspace / "imagebuilder.tar.zst"
    actual, _size = _download(lock["VM_X86_64_IMAGEBUILDER_URL"], archive)
    expected = lock["VM_X86_64_IMAGEBUILDER_SHA256"]
    if actual != expected:
        raise GenerationError(
            f"ImageBuilder SHA256 mismatch: expected {expected}, got {actual}"
        )
    extract_root = workspace / "imagebuilder"
    extract_root.mkdir()
    imagebuilder = _safe_extract_imagebuilder(archive, extract_root)
    apk = _ensure_regular_executable(
        imagebuilder / "staging_dir" / "host" / "bin" / "apk", "ImageBuilder apk"
    )
    keys_dir = imagebuilder / "keys"
    repositories = imagebuilder / "repositories"
    if not keys_dir.is_dir() or keys_dir.is_symlink():
        raise GenerationError("locked ImageBuilder keys directory is invalid")
    if not repositories.is_file() or repositories.is_symlink():
        raise GenerationError("locked ImageBuilder repositories file is invalid")
    return apk, keys_dir, imagebuilder



def _run_apk(apk: Path, keys_dir: Path, adb_path: Path) -> list[dict[str, Any]]:
    if not keys_dir.is_dir():
        raise GenerationError(f"apk signing key directory is missing: {keys_dir}")
    try:
        subprocess.run(
            [str(apk), "--keys-dir", str(keys_dir), "verify", str(adb_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        dump = subprocess.run(
            [str(apk), "adbdump", "--format", "json", str(adb_path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        if len(dump.encode("utf-8")) > MAX_APK_DUMP_BYTES:
            raise GenerationError("apk adbdump output exceeds the configured size limit")
    except (OSError, subprocess.CalledProcessError) as error:
        stderr = getattr(error, "stderr", "") or ""
        raise GenerationError(f"apk verification/adbdump failed: {stderr.strip()}") from error
    try:
        payload = json.loads(dump)
    except json.JSONDecodeError as error:
        raise GenerationError(f"apk adbdump returned invalid JSON: {error}") from error
    if not isinstance(payload, dict) or set(payload) != {"packages"}:
        raise GenerationError("apk adbdump root must contain only packages")
    packages = payload["packages"]
    if not isinstance(packages, list) or len(packages) > 100000:
        raise GenerationError("apk adbdump packages must be a list of at most 100000 records")
    return packages


def _feed_from_url(url: str) -> str:
    path = urllib.parse.urlsplit(url).path
    if "/targets/" in path and "/kmods/" in path:
        return "kmods"
    if "/targets/" in path and "/packages/" in path:
        return "target"
    match = re.search(r"/packages/[^/]+/([^/]+)/packages\.adb$", path)
    if match and match.group(1) in ALLOWED_FEEDS:
        return match.group(1)
    raise GenerationError(f"unable to classify package feed URL: {url}")


def _parse_repositories(path: Path) -> list[tuple[str, str]]:
    try:
        lines = _read_regular_file(path, 1024 * 1024, "ImageBuilder repositories").decode(
            "utf-8"
        ).splitlines()
    except UnicodeError as error:
        raise GenerationError(f"unable to read ImageBuilder repositories: {error}") from error
    result: list[tuple[str, str]] = []
    seen: set[str] = set()
    for raw in lines:
        url = raw.strip()
        if not url or url.startswith("#"):
            continue
        url = _safe_url(url, suffixes=("packages.adb",))
        feed = _feed_from_url(url)
        if feed in seen:
            raise GenerationError(f"duplicate ImageBuilder feed: {feed}")
        seen.add(feed)
        result.append((feed, url))
    if set(seen) != set(ALLOWED_FEEDS):
        raise GenerationError(
            f"ImageBuilder repositories differ from required feeds: {sorted(seen)}"
        )
    return result


def _load_profiles(workspace: Path) -> tuple[str, str, str]:
    destination = workspace / "profiles.json"
    _download(PROFILE_URL, destination)
    try:
        payload = json.loads(
            _read_regular_file(destination, MAX_PROFILE_BYTES, "profiles.json").decode("utf-8")
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GenerationError(f"profiles.json is invalid: {error}") from error
    if not isinstance(payload, dict):
        raise GenerationError("profiles.json root must be an object")
    if payload.get("version_number") != OPENWRT_VERSION:
        raise GenerationError("profiles.json version does not match catalog version")
    if payload.get("target") != "qualcommax/ipq807x":
        raise GenerationError("profiles.json target does not match Xiaomi AX9000")
    profiles = payload.get("profiles")
    if not isinstance(profiles, dict) or "xiaomi_ax9000" not in profiles:
        raise GenerationError("profiles.json does not contain xiaomi_ax9000")
    arch = payload.get("arch_packages")
    kernel = payload.get("linux_kernel")
    if not isinstance(arch, str) or not PACKAGE_NAME_RE.fullmatch(arch):
        raise GenerationError("profiles.json contains invalid arch_packages")
    if not isinstance(kernel, dict):
        raise GenerationError("profiles.json contains invalid linux_kernel")
    version = kernel.get("version")
    release = kernel.get("release")
    vermagic = kernel.get("vermagic")
    if not all(isinstance(item, str) and PACKAGE_NAME_RE.fullmatch(item) for item in (version, release, vermagic)):
        raise GenerationError("profiles.json contains invalid kernel identity")
    return arch, version, f"{version}-{release}-{vermagic}"


def _ax_repositories(workspace: Path) -> list[tuple[str, str]]:
    arch, _kernel_version, kernel_id = _load_profiles(workspace)
    base = f"https://{DOWNLOAD_HOST}{RELEASE_PREFIX}"
    return [
        (
            "target",
            f"{base}targets/qualcommax/ipq807x/packages/packages.adb",
        ),
        ("base", f"{base}packages/{arch}/base/packages.adb"),
        (
            "kmods",
            f"{base}targets/qualcommax/ipq807x/kmods/{kernel_id}/packages.adb",
        ),
        ("luci", f"{base}packages/{arch}/luci/packages.adb"),
        ("packages", f"{base}packages/{arch}/packages/packages.adb"),
        ("routing", f"{base}packages/{arch}/routing/packages.adb"),
        ("telephony", f"{base}packages/{arch}/telephony/packages.adb"),
        ("video", f"{base}packages/{arch}/video/packages.adb"),
    ]


def _clean_text(value: Any, fallback: str, maximum: int) -> str:
    if not isinstance(value, str):
        return fallback
    cleaned = " ".join(value.split())
    cleaned = "".join(character for character in cleaned if ord(character) >= 32)
    if not cleaned:
        return fallback
    return cleaned[:maximum]


def _record(raw: Any, feed: str) -> tuple[dict[str, Any], str] | None:
    if not isinstance(raw, dict):
        raise GenerationError(f"{feed} index contains a non-object package record")
    package = raw.get("name")
    if not isinstance(package, str) or not PACKAGE_NAME_RE.fullmatch(package):
        return None
    if package.startswith(("-", "+")):
        return None
    version = _clean_text(raw.get("version"), "unknown", 160)
    description = _clean_text(
        raw.get("description"), f"OpenWrt package {package}.", 1000
    )
    installed_size = raw.get("installed-size", 0)
    if type(installed_size) is not int or installed_size < 0:
        installed_size = 0
    blocked_reason = blocked_reason_for(package)
    selectable = not blocked_reason
    item = {
        "id": "pkg-" + hashlib.sha256(package.encode("utf-8")).hexdigest()[:16],
        "package": package,
        "version": version,
        "description": description,
        "feed": feed,
        "installed_size": installed_size,
        "category": FEED_CATEGORY[feed],
        "arch": raw.get("arch"),
        "risk": risk_for(package, feed),
        "selectable": selectable,
        "blocked_reason": blocked_reason,
    }
    arch = item["arch"]
    if not isinstance(arch, str) or not PACKAGE_NAME_RE.fullmatch(arch):
        raise GenerationError(f"package {package} has no valid architecture")
    return item, arch


def _merge_packages(
    feed_packages: Iterable[tuple[str, list[dict[str, Any]]]], *, target: str, flavor: str
) -> list[dict[str, Any]]:
    allowed_arches = allowed_architectures_for(target, flavor)
    by_package: dict[str, dict[str, Any]] = {}
    id_to_package: dict[str, str] = {}
    for feed, raw_packages in feed_packages:
        for raw in raw_packages:
            parsed = _record(raw, feed)
            if parsed is None:
                continue
            item, arch = parsed
            if flavor == "nss" and arch != "noarch":
                continue
            if arch not in allowed_arches:
                raise GenerationError(
                    f"package {item['package']} has architecture {arch!r} outside "
                    f"the {target}/{flavor} policy"
                )
            package = item["package"]
            existing = by_package.get(package)
            if existing is not None:
                comparable = {key: value for key, value in item.items() if key not in {"feed", "category"}}
                previous = {key: value for key, value in existing.items() if key not in {"feed", "category"}}
                if comparable != previous:
                    raise GenerationError(f"conflicting duplicate package metadata: {package}")
                continue
            package_id = item["id"]
            collision = id_to_package.get(package_id)
            if collision is not None and collision != package:
                raise GenerationError(f"package ID collision: {collision} and {package}")
            id_to_package[package_id] = package
            by_package[package] = item
    return sorted(by_package.values(), key=lambda item: (item["package"], item["version"], item["id"]))


def _fetch_sources(
    repositories: Iterable[tuple[str, str]], apk: Path, keys_dir: Path, workspace: Path
) -> tuple[list[tuple[str, list[dict[str, Any]]]], list[dict[str, str]]]:
    package_sets: list[tuple[str, list[dict[str, Any]]]] = []
    sources: list[dict[str, str]] = []
    for position, (feed, url) in enumerate(repositories):
        if feed not in ALLOWED_FEEDS:
            raise GenerationError(f"unsupported feed: {feed}")
        safe_url = _safe_url(url, suffixes=("packages.adb",))
        path = workspace / f"{position:02d}-{feed}.adb"
        digest, _size = _download(safe_url, path)
        package_sets.append((feed, _run_apk(apk, keys_dir, path)))
        sources.append({"feed": feed, "url": safe_url, "sha256": digest})
    return package_sets, sources


def _write_catalog(output_root: Path, shards: list[dict[str, Any]]) -> None:
    root_payload = {
        "schema_version": 1,
        "catalog_version": CATALOG_VERSION,
        "openwrt_version": OPENWRT_VERSION,
        "shards": shards,
    }
    _safe_write_output(
        output_root, "components/package-catalog.json", _canonical_json(root_payload)
    )


def generate(output_root: Path) -> dict[str, Any]:
    output_root = Path(os.path.abspath(output_root))
    with tempfile.TemporaryDirectory(prefix="nexawrt-package-catalog-") as temporary:
        workspace = Path(temporary)
        apk, keys_dir, imagebuilder = _obtain_apk(workspace)
        x86_repositories = _parse_repositories(imagebuilder / "repositories")
        ax_repositories = _ax_repositories(workspace)

        source_cache: dict[tuple[tuple[str, str], ...], tuple[list[tuple[str, list[dict[str, Any]]]], list[dict[str, str]]]] = {}
        shard_descriptors: list[dict[str, Any]] = []
        for target, flavor, relative_path in SHARD_SPECS:
            repositories = x86_repositories if target == "x86_64" else ax_repositories
            if flavor == "nss":
                repositories = [
                    pair
                    for pair in repositories
                    if pair[0] in {"base", "luci", "packages", "routing", "telephony", "video"}
                ]
            cache_key = tuple(repositories)
            if cache_key not in source_cache:
                source_workspace = workspace / (target + "-" + flavor)
                source_workspace.mkdir()
                source_cache[cache_key] = _fetch_sources(
                    repositories, apk, keys_dir, source_workspace
                )
            package_sets, sources = source_cache[cache_key]
            records = _merge_packages(package_sets, target=target, flavor=flavor)
            shard_payload = {
                "schema_version": 1,
                "catalog_version": CATALOG_VERSION,
                "target": target,
                "flavor": flavor,
                "packages": records,
            }
            shard_bytes = _canonical_json(shard_payload)
            _safe_write_output(output_root, relative_path, shard_bytes)
            shard_descriptors.append(
                {
                    "target": target,
                    "flavor": flavor,
                    "path": relative_path,
                    "sha256": _sha256_bytes(shard_bytes),
                    "package_count": len(records),
                    "selectable_count": sum(item["selectable"] for item in records),
                    "sources": sources,
                }
            )

        _write_catalog(output_root, shard_descriptors)
        return {
            "catalog_version": CATALOG_VERSION,
            "openwrt_version": OPENWRT_VERSION,
            "shards": shard_descriptors,
        }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-root",
        type=Path,
        default=ROOT,
        help="repository root receiving components/package-catalog.json",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        result = generate(arguments.output_root)
    except GenerationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
