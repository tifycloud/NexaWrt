#!/usr/bin/env python3
"""Create a strict proof manifest for Releases eligible for the Pages catalog."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote

from device_metadata import REPOSITORY, load_device_metadata

MAX_INPUT_BYTES = 5 * 1024 * 1024
MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
MAX_CHECKSUM_BYTES = 4096
MAX_PROVENANCE_BYTES = 16 * 1024 * 1024
MAX_TOTAL_DOWNLOAD_BYTES = 1536 * 1024 * 1024
MAX_CANDIDATES_PER_FLAVOR = 12
MAX_ARCHIVE_MEMBERS = 4096
MAX_TOTAL_MEMBER_BYTES = 256 * 1024 * 1024
MAX_MEMBER_BYTES = 128 * 1024 * 1024
MAX_TAR_STREAM_BYTES = 320 * 1024 * 1024
TAR_BLOCK_BYTES = 512
MAX_INTERNAL_CHECKSUM_BYTES = 1024 * 1024
MAX_FIRMWARE_BYTES = 128 * 1024 * 1024
MAX_SBOM_BYTES = 32 * 1024 * 1024
CHANNEL = "ram-test"
SIGNER_WORKFLOW = f"{REPOSITORY}/.github/workflows/release.yml"
VM_SIGNER_WORKFLOW = f"{REPOSITORY}/.github/workflows/vm-release.yml"
VM_TAG_PREFIX = "vm-x86_64-"
VM_PLATFORM = "x86_64"
MAX_VM_IMAGE_BYTES = 1024 * 1024 * 1024
MAX_VM_TEXT_BYTES = 2 * 1024 * 1024
VM_PROVENANCE_ASSETS = {
    "provenance_image": "image.provenance.bundle.json",
    "provenance_checksums": "checksums.provenance.bundle.json",
}
VM_VERIFIED_SUBJECTS = ["image", "checksums"]
VM_ARTIFACT_LABEL_KEYS = {
    "ARTIFACT_CLASS", "OPENWRT_VERSION", "TARGET", "MODE", "VM_ONLY",
    "NOT_AX9000_FIRMWARE", "HARDWARE_VALIDATION", "NSS_VALIDATION",
    "VALIDATION_SCOPE", "IMAGEBUILDER_URL", "IMAGEBUILDER_SHA256",
    "RELEASE_TAG", "RELEASE_VERSION", "SSH_DEFAULT", "SSH_AUTHORIZED_KEYS",
}
VM_SMOKE_REPORT_KEYS = {
    "status", "target", "image", "vm_only", "not_ax9000_firmware",
    "hardware_validation", "nss_validation", "exact_release_image", "qemu_boot",
    "serial_labels", "http", "ssh_runtime_evidence", "ssh_port_probe", "ssh",
    "authorized_keys", "dropbear_enabled", "dropbear_running", "http_status",
    "auth_challenge", "http_host_port", "ssh_host_port", "serial_log", "ssh_probe_log",
}
VM_RESULT_ROOT = PurePosixPath("/home/runner/work/NexaWrt/NexaWrt/vm-release-results/x86-64")
TRUSTED_REF = "refs/heads/main"
VERSION_RE = re.compile(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-rc\.(?:0|[1-9][0-9]*)$")
HEX_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FIRMWARE = "openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb"
SBOM = "openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json"
INTERNAL_CHECKSUMS = "SHA256SUMS"
PROVENANCE = {
    "archive": "archive.provenance.bundle.json",
    "checksums": "checksums.provenance.bundle.json",
    "firmware": "firmware.provenance.bundle.json",
    "sbom": "sbom.provenance.bundle.json",
}
VERIFIED_SUBJECTS = ["archive", "checksums", "firmware", "sbom"]


class VerificationError(ValueError):
    """A candidate release did not satisfy the trusted publication policy."""


class DownloadBudget:
    """Bound total release bytes fetched during one Pages verification run."""

    def __init__(self, limit: int = MAX_TOTAL_DOWNLOAD_BYTES) -> None:
        self.limit = limit
        self.used = 0

    def reserve(self, size: int) -> None:
        if self.used + size > self.limit:
            raise ValueError(f"release download budget exceeds {self.limit} bytes")
        self.used += size


def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError(f"input must be a regular file: {path}")
    if path.stat().st_size > MAX_INPUT_BYTES:
        raise ValueError(f"input exceeds {MAX_INPUT_BYTES} bytes: {path}")
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="saved GitHub releases API response")
    parser.add_argument("--output", type=Path, required=True, help="strict proof manifest output")
    parser.add_argument("--trusted-main", default="HEAD", help="checked-out trusted main commit (default: HEAD)")
    parser.add_argument("--gh-bin", type=Path, help="GitHub CLI path (default: NEXAWRT_ATTESTATION_VERIFIER or gh)")
    return parser.parse_args()


def executable_path(requested: Path | None) -> Path:
    candidate = str(requested) if requested else os.environ.get("NEXAWRT_ATTESTATION_VERIFIER") or shutil.which("gh")
    if not candidate:
        raise ValueError("GitHub CLI was not found")
    path = Path(candidate).resolve()
    if not path.is_file() or path.is_symlink() or not os.access(path, os.X_OK):
        raise ValueError("GitHub CLI must be an executable regular file")
    expected_digest = os.environ.get("NEXAWRT_ATTESTATION_VERIFIER_SHA256")
    if expected_digest is not None:
        if not HEX_SHA256_RE.fullmatch(expected_digest) or sha256(path) != expected_digest:
            raise ValueError("GitHub CLI digest does not match the pinned verifier")
    return path


def run(command: list[str], *, stdout: Any = subprocess.PIPE, timeout: int = 120) -> subprocess.CompletedProcess[Any]:
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=subprocess.PIPE,
                              check=True, timeout=timeout)
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.decode("utf-8", errors="replace") if isinstance(exc.stderr, bytes) else str(exc.stderr or "")
        raise VerificationError(f"command failed: {' '.join(command[:3])}: {detail.strip()}") from exc
    except subprocess.TimeoutExpired as exc:
        raise VerificationError(f"command timed out: {' '.join(command[:3])}") from exc


def run_text(command: list[str], timeout: int = 120) -> str:
    result = run(command, timeout=timeout)
    output = result.stdout.decode("utf-8", errors="strict") if isinstance(result.stdout, bytes) else result.stdout
    return str(output).strip()


def git_output(*args: str) -> str:
    git = shutil.which("git")
    if not git:
        raise ValueError("git was not found")
    return run_text([git, *args], timeout=30)


def trusted_main_digest(revision: str) -> str:
    digest = git_output("rev-parse", "--verify", f"{revision}^{{commit}}")
    if not HEX_SHA_RE.fullmatch(digest):
        raise ValueError("trusted main digest is invalid")
    return digest


def tag_identity(tag: Any, metadata: dict[str, Any]) -> tuple[str, str] | None:
    if not isinstance(tag, str) or len(tag) > 100:
        return None
    for flavor in metadata["flavors"]:
        prefix = f"{CHANNEL}-" if flavor == "official" else f"{CHANNEL}-{flavor}-"
        if tag.startswith(prefix):
            version = tag[len(prefix):]
            if VERSION_RE.fullmatch(version):
                return flavor, version
    return None


def expected_names(metadata: dict[str, Any], flavor: str, version: str) -> dict[str, str]:
    archive = f'NexaWrt-{metadata["model"]}-{flavor}-{version}-verified-dist.tar.gz'
    return {
        "archive": archive,
        "checksum": f"{archive}.sha256",
        **{f"provenance_{key}": value for key, value in PROVENANCE.items()},
    }


def vm_identity(tag: Any) -> str | None:
    if not isinstance(tag, str) or not tag.startswith(VM_TAG_PREFIX):
        return None
    version = tag[len(VM_TAG_PREFIX):]
    return version if VERSION_RE.fullmatch(version) else None


def vm_expected_names(version: str) -> dict[str, str]:
    image = f"NexaWrt-x86_64-{version}-generic-ext4-combined.img.gz"
    manifest = f"{image[:-len('.img.gz')]}.manifest"
    return {
        "image": image,
        "image_checksum": f"{image}.sha256",
        "manifest": manifest,
        "artifact_labels": "artifact-labels.env",
        "readme": "README-VM.txt",
        "smoke_report": "smoke-report.txt",
        "checksums": "SHA256SUMS",
        **VM_PROVENANCE_ASSETS,
    }


def vm_candidate_assets(raw: Any) -> tuple[int, str, str, str, dict[str, dict[str, Any]]] | None:
    if not isinstance(raw, dict) or raw.get("draft") is not False or raw.get("prerelease") is not True or raw.get("immutable") is not True:
        return None
    release_id, tag = raw.get("id"), raw.get("tag_name")
    version = vm_identity(tag)
    published_at = normalized_timestamp(raw.get("published_at"))
    if isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0 or version is None or published_at is None:
        return None
    expected = vm_expected_names(version)
    assets = raw.get("assets")
    if not isinstance(assets, list) or len(assets) != len(expected):
        return None
    limits = {
        expected["image"]: MAX_VM_IMAGE_BYTES,
        **{name: MAX_VM_TEXT_BYTES for key, name in expected.items() if key != "image"},
    }
    by_name: dict[str, dict[str, Any]] = {}
    for asset in assets:
        if not isinstance(asset, dict):
            return None
        name, asset_id, size = asset.get("name"), asset.get("id"), asset.get("size")
        if name not in expected.values() or name in by_name or asset.get("state") != "uploaded":
            return None
        if isinstance(asset_id, bool) or not isinstance(asset_id, int) or asset_id <= 0 or isinstance(size, bool) or not isinstance(size, int) or size <= 0 or size > limits[name]:
            return None
        by_name[name] = asset
    return (release_id, tag, version, published_at, by_name) if set(by_name) == set(expected.values()) else None


def normalized_timestamp(value: Any) -> str | None:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def version_order(version: str) -> tuple[int, int, int, int]:
    match = re.fullmatch(r"v([0-9]+)\.([0-9]+)\.([0-9]+)-rc\.([0-9]+)", version)
    if match is None:
        raise ValueError(f"invalid release version: {version}")
    return tuple(int(part) for part in match.groups())


def candidate_assets(raw: Any, metadata: dict[str, Any]) -> tuple[int, str, str, str, str, dict[str, dict[str, Any]]] | None:
    if not isinstance(raw, dict) or raw.get("draft") is not False or raw.get("prerelease") is not True or raw.get("immutable") is not True:
        return None
    release_id = raw.get("id")
    if isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0:
        return None
    tag = raw.get("tag_name")
    identity = tag_identity(tag, metadata)
    if identity is None:
        return None
    flavor, version = identity
    published_at = normalized_timestamp(raw.get("published_at"))
    if published_at is None:
        return None
    expected = expected_names(metadata, flavor, version)
    assets = raw.get("assets")
    if not isinstance(assets, list) or len(assets) != len(expected):
        return None
    size_limits = {
        expected["archive"]: MAX_ARCHIVE_BYTES,
        expected["checksum"]: MAX_CHECKSUM_BYTES,
        **{expected[f"provenance_{key}"]: MAX_PROVENANCE_BYTES for key in PROVENANCE},
    }
    by_name: dict[str, dict[str, Any]] = {}
    for asset in assets:
        if not isinstance(asset, dict):
            return None
        name, asset_id, size = asset.get("name"), asset.get("id"), asset.get("size")
        if name not in expected.values() or name in by_name or asset.get("state") != "uploaded":
            return None
        if isinstance(asset_id, bool) or not isinstance(asset_id, int) or asset_id <= 0:
            return None
        if (isinstance(size, bool) or not isinstance(size, int) or size <= 0 or
                size > size_limits[name]):
            return None
        by_name[name] = asset
    if set(by_name) != set(expected.values()):
        return None
    return release_id, tag, flavor, version, published_at, by_name


def resolve_tag_commit(gh: Path, tag: str) -> str:
    endpoint = f"repos/{REPOSITORY}/git/ref/tags/{quote(tag, safe='')}"
    payload = json.loads(run_text([str(gh), "api", "-H", "Accept: application/vnd.github+json",
                                  "-H", "X-GitHub-Api-Version: 2026-03-10", endpoint]),
                         object_pairs_hook=reject_duplicates)
    if not isinstance(payload, dict) or "object" not in payload or not isinstance(payload["object"], dict):
        raise VerificationError("tag reference response is invalid")
    obj = payload["object"]
    digest = obj.get("sha")
    if obj.get("type") != "commit" or not isinstance(digest, str) or not HEX_SHA_RE.fullmatch(digest):
        raise VerificationError("release tag is not a lightweight commit reference")
    return digest


def require_main_ancestor(commit: str, trusted_main: str) -> None:
    git = shutil.which("git")
    if not git:
        raise ValueError("git was not found")
    run([git, "cat-file", "-e", f"{commit}^{{commit}}"], timeout=30)
    run([git, "merge-base", "--is-ancestor", commit, trusted_main], timeout=30)


def download_asset(gh: Path, asset: dict[str, Any], destination: Path, budget: DownloadBudget) -> None:
    budget.reserve(asset["size"])
    endpoint = f"repos/{REPOSITORY}/releases/assets/{asset['id']}"
    with destination.open("wb") as stream:
        run([str(gh), "api", "-H", "Accept: application/octet-stream",
             "-H", "X-GitHub-Api-Version: 2026-03-10", endpoint], stdout=stream, timeout=600)
    if destination.stat().st_size != asset["size"]:
        raise VerificationError(f"downloaded asset size mismatch: {asset['name']}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_external_checksum(checksum: Path, archive: Path) -> None:
    if checksum.stat().st_size > MAX_CHECKSUM_BYTES:
        raise VerificationError("archive checksum asset is too large")
    lines = checksum.read_text(encoding="ascii").splitlines()
    expected = f"{sha256(archive)}  {archive.name}"
    if lines != [expected]:
        raise VerificationError("archive checksum asset does not exactly match the archive")


def safe_member(member: tarfile.TarInfo) -> bool:
    path = PurePosixPath(member.name)
    return (not path.is_absolute() and path.parts and path.parts[0] == "verified-dist" and
            ".." not in path.parts and not member.issym() and not member.islnk() and
            not member.isdev() and (member.isfile() or member.isdir()) and
            0 <= member.size <= MAX_MEMBER_BYTES)


def parse_tar_octal(field: bytes, label: str, *, allow_empty: bool = True) -> int:
    if field and field[0] & 0x80:
        raise VerificationError(f"tar {label} uses forbidden base-256 encoding")
    value = field.strip(b" \0")
    if not value:
        if allow_empty:
            return 0
        raise VerificationError(f"tar {label} is empty")
    if any(byte < ord("0") or byte > ord("7") for byte in value):
        raise VerificationError(f"tar {label} is not strict octal")
    return int(value, 8)


def scan_tar_stream(raw_archive: Path) -> None:
    stream_size = raw_archive.stat().st_size
    if stream_size > MAX_TAR_STREAM_BYTES:
        raise VerificationError("decompressed tar stream exceeds the limit")
    if stream_size % TAR_BLOCK_BYTES != 0:
        raise VerificationError("tar stream is not block aligned")

    member_count = 0
    offset = 0
    with raw_archive.open("rb") as stream:
        while offset < stream_size:
            stream.seek(offset)
            header = stream.read(TAR_BLOCK_BYTES)
            if len(header) != TAR_BLOCK_BYTES:
                raise VerificationError("tar header is truncated")
            if header == bytes(TAR_BLOCK_BYTES):
                second = stream.read(TAR_BLOCK_BYTES)
                if len(second) != TAR_BLOCK_BYTES or second != bytes(TAR_BLOCK_BYTES):
                    raise VerificationError("tar end marker is incomplete")
                for trailing in iter(lambda: stream.read(1024 * 1024), b""):
                    if any(trailing):
                        raise VerificationError("tar trailing bytes are not zero")
                return

            member_count += 1
            if member_count > MAX_ARCHIVE_MEMBERS:
                raise VerificationError("archive has too many physical tar headers")

            stored_checksum = parse_tar_octal(header[148:156], "header checksum", allow_empty=False)
            calculated_checksum = sum(header[:148]) + 8 * ord(" ") + sum(header[156:])
            if stored_checksum != calculated_checksum:
                raise VerificationError("tar header checksum mismatch")

            magic = header[257:263]
            if magic not in (b"ustar\0", b"ustar "):
                raise VerificationError("tar header does not use a supported ustar format")

            size = parse_tar_octal(header[124:136], "member size")
            if size > MAX_MEMBER_BYTES:
                raise VerificationError("tar physical member exceeds the size limit")

            typeflag = header[156:157]
            if typeflag in (b"x", b"g", b"L", b"K", b"S"):
                raise VerificationError("tar extension headers are forbidden")
            if typeflag not in (b"\0", b"0", b"5"):
                raise VerificationError("tar member type is forbidden")
            if typeflag == b"5" and size != 0:
                raise VerificationError("tar directory has a non-zero size")

            padded_size = ((size + TAR_BLOCK_BYTES - 1) // TAR_BLOCK_BYTES) * TAR_BLOCK_BYTES
            next_offset = offset + TAR_BLOCK_BYTES + padded_size
            if next_offset > stream_size:
                raise VerificationError("tar member data is truncated")
            offset = next_offset

    raise VerificationError("tar end marker is missing")


def decompress_tar_stream(archive: Path, raw_archive: Path) -> None:
    total = 0
    try:
        with archive.open("rb") as source, gzip.GzipFile(fileobj=source, mode="rb") as compressed, \
                raw_archive.open("xb") as destination:
            for chunk in iter(lambda: compressed.read(1024 * 1024), b""):
                total += len(chunk)
                if total > MAX_TAR_STREAM_BYTES:
                    raise VerificationError("decompressed tar stream exceeds the limit")
                destination.write(chunk)
    except (gzip.BadGzipFile, EOFError, OSError) as exc:
        raise VerificationError(f"invalid verified-dist gzip stream: {exc}") from exc
    scan_tar_stream(raw_archive)


def extract_subjects(archive: Path, directory: Path) -> dict[str, Path]:
    wanted = {
        f"verified-dist/{INTERNAL_CHECKSUMS}": ("checksums", MAX_INTERNAL_CHECKSUM_BYTES),
        f"verified-dist/{FIRMWARE}": ("firmware", MAX_FIRMWARE_BYTES),
        f"verified-dist/{SBOM}": ("sbom", MAX_SBOM_BYTES),
    }
    extracted: dict[str, Path] = {}
    seen: set[str] = set()
    member_count = 0
    total_member_bytes = 0
    try:
        with tempfile.TemporaryDirectory(prefix=".verified-tar-", dir=directory.parent) as temporary:
            raw_archive = Path(temporary) / "archive.tar"
            decompress_tar_stream(archive, raw_archive)
            with tarfile.open(raw_archive, "r:") as bundle:
                for member in bundle:
                    member_count += 1
                    if member_count > MAX_ARCHIVE_MEMBERS:
                        raise VerificationError("archive has too many members")
                    if member.name in seen or not safe_member(member):
                        raise VerificationError(f"unsafe or duplicate archive member: {member.name}")
                    seen.add(member.name)
                    total_member_bytes += member.size
                    if total_member_bytes > MAX_TOTAL_MEMBER_BYTES:
                        raise VerificationError("archive uncompressed member total exceeds the limit")
                    wanted_entry = wanted.get(member.name)
                    if wanted_entry is None:
                        continue
                    key, subject_limit = wanted_entry
                    if not member.isfile() or member.size <= 0 or member.size > subject_limit:
                        raise VerificationError(f"required archive subject size is invalid: {member.name}")
                    source = bundle.extractfile(member)
                    if source is None:
                        raise VerificationError(f"unable to read archive subject: {member.name}")
                    destination = directory / Path(member.name).name
                    with destination.open("xb") as stream:
                        shutil.copyfileobj(source, stream, length=1024 * 1024)
                    if destination.stat().st_size != member.size:
                        raise VerificationError(f"archive subject size changed while reading: {member.name}")
                    extracted[key] = destination
    except (tarfile.TarError, OSError) as exc:
        raise VerificationError(f"invalid verified-dist archive: {exc}") from exc
    if set(extracted) != {key for key, _ in wanted.values()}:
        raise VerificationError("archive is missing required attested subjects")
    return extracted


def verify_internal_checksums(subjects: dict[str, Path]) -> None:
    entries: dict[str, str] = {}
    for line in subjects["checksums"].read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  \./([^/]+)", line)
        if match:
            if match.group(2) in entries:
                raise VerificationError(f"duplicate internal checksum entry: {match.group(2)}")
            entries[match.group(2)] = match.group(1)
    for key, name in (("firmware", FIRMWARE), ("sbom", SBOM)):
        if entries.get(name) != sha256(subjects[key]):
            raise VerificationError(f"internal SHA256SUMS does not bind {name}")


def attestation_command(gh: Path, subject: Path, bundle: Path, tag: str, source_digest: str) -> list[str]:
    return [
        str(gh), "attestation", "verify", str(subject), "--bundle", str(bundle),
        "--repo", REPOSITORY, "--signer-workflow", SIGNER_WORKFLOW,
        "--source-ref", f"refs/tags/{tag}", "--source-digest", source_digest,
        "--predicate-type", "https://slsa.dev/provenance/v1",
        "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
        "--deny-self-hosted-runners",
    ]


def verify_attestation(gh: Path, subject: Path, bundle: Path, tag: str, source_digest: str) -> None:
    run(attestation_command(gh, subject, bundle, tag, source_digest), timeout=180)


def verify_candidate(
    gh: Path,
    candidate: tuple[int, str, str, str, str, dict[str, dict[str, Any]]],
    metadata: dict[str, Any],
    trusted_main: str,
    budget: DownloadBudget,
) -> tuple[str, dict[str, Any]]:
    release_id, tag, flavor, version, _published_at, assets = candidate
    names = expected_names(metadata, flavor, version)
    source_digest = resolve_tag_commit(gh, tag)
    require_main_ancestor(source_digest, trusted_main)
    with tempfile.TemporaryDirectory(prefix="nexawrt-pages-proof-") as temporary:
        work = Path(temporary)
        downloaded: dict[str, Path] = {}

        # Only fetch the archive and its proof until the largest untrusted input is authenticated.
        for key in ("archive", "provenance_archive"):
            name = names[key]
            destination = work / name
            download_asset(gh, assets[name], destination, budget)
            downloaded[key] = destination
        verify_attestation(gh, downloaded["archive"], downloaded["provenance_archive"], tag, source_digest)

        for key in ("checksum", "provenance_checksums", "provenance_firmware", "provenance_sbom"):
            name = names[key]
            destination = work / name
            download_asset(gh, assets[name], destination, budget)
            downloaded[key] = destination
        verify_external_checksum(downloaded["checksum"], downloaded["archive"])
        subjects_dir = work / "subjects"
        subjects_dir.mkdir()
        subjects = extract_subjects(downloaded["archive"], subjects_dir)
        for key in ("checksums", "firmware", "sbom"):
            verify_attestation(gh, subjects[key], downloaded[f"provenance_{key}"], tag, source_digest)
        verify_internal_checksums(subjects)
        proof = {
            "release_id": release_id,
            "source_digest": source_digest,
            "archive_sha256": sha256(downloaded["archive"]),
            "checksum_sha256": sha256(downloaded["checksum"]),
            "verified_subjects": VERIFIED_SUBJECTS,
        }
    return tag, proof


def parse_vm_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise VerificationError(f"invalid VM evidence line in {path.name}")
        key, value = line.split("=", 1)
        key = key.strip()
        if key in values or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", key):
            raise VerificationError(f"invalid or duplicate VM evidence key in {path.name}")
        values[key] = value.strip().strip('"').strip("'")
    return values


def parse_vm_host_port(value: str, field: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]{3,4}", value):
        raise VerificationError(f"VM smoke report contains an invalid {field}")
    port = int(value)
    if port < 1024 or port > 65535 or str(port) != value:
        raise VerificationError(f"VM smoke report contains an invalid {field}")
    return port


def require_vm_result_path(value: str, filename: str, field: str) -> None:
    path = PurePosixPath(value)
    expected = VM_RESULT_ROOT / filename
    if not path.is_absolute() or path != expected:
        raise VerificationError(f"VM smoke report contains an unsafe or unexpected {field}")


def verify_sha256sums(checksums: Path, expected_subjects: dict[str, Path]) -> None:
    if checksums.stat().st_size > MAX_VM_TEXT_BYTES:
        raise VerificationError("VM SHA256SUMS asset is too large")
    lines = checksums.read_text(encoding="ascii").splitlines()
    expected_lines = [f"{sha256(path)}  {path.name}" for path in expected_subjects.values()]
    if lines != expected_lines:
        raise VerificationError("VM SHA256SUMS does not exactly match published non-provenance assets")


def vm_attestation_command(gh: Path, subject: Path, bundle: Path, source_ref: str, source_digest: str) -> list[str]:
    return [
        str(gh), "attestation", "verify", str(subject), "--bundle", str(bundle),
        "--repo", REPOSITORY, "--signer-workflow", VM_SIGNER_WORKFLOW,
        "--source-ref", source_ref, "--source-digest", source_digest,
        "--predicate-type", "https://slsa.dev/provenance/v1",
        "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
        "--deny-self-hosted-runners",
    ]


def verify_vm_attestation(gh: Path, subject: Path, bundle: Path, tag: str, source_digest: str) -> None:
    errors: list[str] = []
    for source_ref in (f"refs/tags/{tag}", TRUSTED_REF):
        try:
            run(vm_attestation_command(gh, subject, bundle, source_ref, source_digest), timeout=180)
            return
        except VerificationError as exc:
            errors.append(f"{source_ref}: {exc}")
    raise VerificationError("VM attestation source-ref did not match tag or main: " + "; ".join(errors))


def verify_vm_candidate(gh: Path, candidate: tuple[int, str, str, str, dict[str, dict[str, Any]]],
                        trusted_main: str, budget: DownloadBudget) -> tuple[str, dict[str, Any]]:
    release_id, tag, version, _published_at, assets = candidate
    names = vm_expected_names(version)
    source_digest = resolve_tag_commit(gh, tag)
    require_main_ancestor(source_digest, trusted_main)
    with tempfile.TemporaryDirectory(prefix="nexawrt-pages-vm-proof-") as temporary:
        work = Path(temporary)
        downloaded: dict[str, Path] = {}
        for key, name in names.items():
            destination = work / name
            download_asset(gh, assets[name], destination, budget)
            downloaded[key] = destination
        verify_external_checksum(downloaded["image_checksum"], downloaded["image"])
        checksum_subjects = {
            "image": downloaded["image"],
            "image_checksum": downloaded["image_checksum"],
            "manifest": downloaded["manifest"],
            "artifact_labels": downloaded["artifact_labels"],
            "readme": downloaded["readme"],
            "smoke_report": downloaded["smoke_report"],
        }
        verify_sha256sums(downloaded["checksums"], checksum_subjects)
        labels = parse_vm_key_values(downloaded["artifact_labels"])
        if set(labels) != VM_ARTIFACT_LABEL_KEYS:
            raise VerificationError("VM artifact labels do not have the exact required key set")
        expected_labels = {
            "ARTIFACT_CLASS": "VM_DISTRIBUTION_IMAGE",
            "TARGET": "x86-64",
            "MODE": "release",
            "VM_ONLY": "true",
            "NOT_AX9000_FIRMWARE": "true",
            "HARDWARE_VALIDATION": "false",
            "NSS_VALIDATION": "false",
            "VALIDATION_SCOPE": "QEMU_BOOT_AND_USERSPACE_ONLY",
            "RELEASE_TAG": tag,
            "RELEASE_VERSION": version,
            "SSH_DEFAULT": "disabled",
            "SSH_AUTHORIZED_KEYS": "absent",
        }
        if any(labels[key] != value for key, value in expected_labels.items()):
            raise VerificationError("VM artifact labels do not exactly match the release safety contract")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9]+)*", labels["OPENWRT_VERSION"]):
            raise VerificationError("VM artifact labels contain an invalid OpenWrt version")
        if not labels["IMAGEBUILDER_URL"].startswith("https://downloads.openwrt.org/"):
            raise VerificationError("VM artifact labels contain an untrusted ImageBuilder URL")
        if not HEX_SHA256_RE.fullmatch(labels["IMAGEBUILDER_SHA256"]):
            raise VerificationError("VM artifact labels contain an invalid ImageBuilder digest")

        smoke = parse_vm_key_values(downloaded["smoke_report"])
        if set(smoke) != VM_SMOKE_REPORT_KEYS:
            raise VerificationError("VM smoke report does not have the exact required key set")
        expected_smoke = {
            "status": "PASS",
            "target": "x86-64",
            "vm_only": "true",
            "not_ax9000_firmware": "true",
            "hardware_validation": "false",
            "nss_validation": "false",
            "exact_release_image": "true",
            "qemu_boot": "PASS",
            "serial_labels": "PASS",
            "http": "PASS",
            "ssh_runtime_evidence": "PASS",
            "ssh_port_probe": "PASS",
            "ssh": "DISABLED_BY_DEFAULT",
            "authorized_keys": "ABSENT",
            "dropbear_enabled": "NO",
            "dropbear_running": "NO",
        }
        if any(smoke[key] != value for key, value in expected_smoke.items()):
            raise VerificationError("VM smoke report does not exactly prove the release safety contract")
        if Path(smoke["image"]).name != names["image"]:
            raise VerificationError("VM smoke report did not test the exact published image")
        if (smoke["http_status"], smoke["auth_challenge"]) not in {("200", "false"), ("403", "true")}:
            raise VerificationError("VM smoke report contains an invalid LuCI HTTP result")
        http_port = parse_vm_host_port(smoke["http_host_port"], "HTTP host port")
        ssh_port = parse_vm_host_port(smoke["ssh_host_port"], "SSH host port")
        if http_port == ssh_port:
            raise VerificationError("VM smoke report reuses the same HTTP and SSH host port")
        require_vm_result_path(smoke["serial_log"], "serial.log", "serial log path")
        require_vm_result_path(smoke["ssh_probe_log"], "ssh-port-probe.txt", "SSH probe log path")
        verify_vm_attestation(gh, downloaded["image"], downloaded["provenance_image"], tag, source_digest)
        verify_vm_attestation(gh, downloaded["checksums"], downloaded["provenance_checksums"], tag, source_digest)
        proof = {
            "release_id": release_id,
            "source_digest": source_digest,
            "assets": {
                key: {
                    "id": assets[name]["id"],
                    "name": name,
                    "size": assets[name]["size"],
                    "sha256": sha256(downloaded[key]),
                }
                for key, name in names.items()
            },
            "verified_subjects": VM_VERIFIED_SUBJECTS,
        }
    return tag, proof


def select_vm_candidates(raw: list[Any]) -> list[tuple[int, str, str, str, dict[str, dict[str, Any]]]]:
    candidates = [candidate for item in raw if (candidate := vm_candidate_assets(item)) is not None]
    tags = [candidate[1] for candidate in candidates]
    if len(tags) != len(set(tags)):
        raise ValueError("duplicate VM candidate release tag")
    candidates.sort(key=lambda item: (item[3], version_order(item[2])), reverse=True)
    return candidates[:MAX_CANDIDATES_PER_FLAVOR]


def select_candidates(raw: list[Any], metadata: dict[str, Any]) -> list[tuple[int, str, str, str, str, dict[str, dict[str, Any]]]]:
    grouped: dict[str, list[tuple[int, str, str, str, str, dict[str, dict[str, Any]]]]] = {
        flavor: [] for flavor in metadata["flavors"]
    }
    seen: set[str] = set()
    for item in raw:
        candidate = candidate_assets(item, metadata)
        if candidate is None:
            continue
        tag, flavor = candidate[1], candidate[2]
        if tag in seen:
            raise ValueError(f"duplicate candidate release tag: {tag}")
        seen.add(tag)
        grouped[flavor].append(candidate)
    selected: list[tuple[int, str, str, str, str, dict[str, dict[str, Any]]]] = []
    for flavor in metadata["flavors"]:
        candidates = grouped[flavor]
        candidates.sort(key=lambda item: (item[4], version_order(item[3])), reverse=True)
        selected.extend(candidates[:MAX_CANDIDATES_PER_FLAVOR])
    return selected


def write_json(path: Path, value: Any) -> None:
    if path.exists() and (path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1):
        raise ValueError("output path must be a regular file, not a symlink or hard link")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    try:
        raw = load_json(args.input)
        if not isinstance(raw, list) or len(raw) > 100:
            raise ValueError("GitHub releases payload must be a list of at most 100 entries")
        metadata = load_device_metadata()
        gh = executable_path(args.gh_bin)
        main_digest = trusted_main_digest(args.trusted_main)
        proofs: dict[str, dict[str, Any]] = {}
        vm_proofs: dict[str, dict[str, Any]] = {}
        budget = DownloadBudget()
        for candidate in select_candidates(raw, metadata):
            tag = candidate[1]
            try:
                verified_tag, proof = verify_candidate(gh, candidate, metadata, main_digest, budget)
            except VerificationError as exc:
                print(f"verify-pages-releases: excluded {tag}: {exc}", file=sys.stderr)
                continue
            proofs[verified_tag] = proof
        for candidate in select_vm_candidates(raw):
            tag = candidate[1]
            try:
                verified_tag, proof = verify_vm_candidate(gh, candidate, main_digest, budget)
            except VerificationError as exc:
                print(f"verify-pages-releases: excluded {tag}: {exc}", file=sys.stderr)
                continue
            vm_proofs[verified_tag] = proof
        write_json(args.output, {
            "schema_version": 3,
            "repository": REPOSITORY,
            "trusted_ref": TRUSTED_REF,
            "trusted_main_digest": main_digest,
            "signer_workflows": {"ax9000": SIGNER_WORKFLOW, "vm_x86_64": VM_SIGNER_WORKFLOW},
            "releases": proofs,
            "virtual_images": {"x86_64": vm_proofs},
        })
    except (OSError, ValueError, json.JSONDecodeError, UnicodeError) as exc:
        print(f"verify-pages-releases: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
