#!/usr/bin/env python3
"""Generate the fail-closed GitHub release index consumed by the NexaWrt site."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from device_metadata import (
    REPOSITORY,
    load_device_metadata,
    public_device,
    validate_request,
)

API_URL = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100"
WEB_ROOT = f"https://github.com/{REPOSITORY}"
MAX_RESPONSE_BYTES = 5 * 1024 * 1024
DEFAULT_HISTORY_LIMIT = 12
CHANNEL = "ram-test"
VERSION_PATTERN = re.compile(
    r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-rc\.(?:0|[1-9][0-9]*)$"
)
PROOF_SCHEMA_VERSION = 3
TRUSTED_REF = "refs/heads/main"
SIGNER_WORKFLOW = f"{REPOSITORY}/.github/workflows/release.yml"
VM_SIGNER_WORKFLOW = f"{REPOSITORY}/.github/workflows/vm-release.yml"
VM_PLATFORM = "x86_64"
VM_WORKFLOW_URL = f"{WEB_ROOT}/actions/workflows/vm-release.yml"
VM_DOCS_URL = f"{WEB_ROOT}/blob/main/docs/VM-X86_64.md"
HEX_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERIFIED_SUBJECTS = ["archive", "checksums", "firmware", "sbom"]
VM_VERIFIED_SUBJECTS = ["image", "checksums"]
PROVENANCE_ASSETS = {
    "provenance_archive": "archive.provenance.bundle.json",
    "provenance_checksums": "checksums.provenance.bundle.json",
    "provenance_firmware": "firmware.provenance.bundle.json",
    "provenance_sbom": "sbom.provenance.bundle.json",
}
VM_PROVENANCE_ASSETS = {
    "provenance_image": "image.provenance.bundle.json",
    "provenance_checksums": "checksums.provenance.bundle.json",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        help="read a saved GitHub releases API response instead of making a request",
    )
    parser.add_argument(
        "--proofs",
        type=Path,
        required=True,
        help="strict proof manifest produced by scripts/verify-pages-releases.py",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("site/releases.json"),
        help="output path (default: site/releases.json)",
    )
    parser.add_argument(
        "--history-limit",
        type=int,
        default=DEFAULT_HISTORY_LIMIT,
        choices=range(1, 21),
        metavar="1..20",
    )
    return parser.parse_args()


def read_limited(stream: Any) -> bytes:
    payload = stream.read(MAX_RESPONSE_BYTES + 1)
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ValueError("GitHub releases response exceeds the size limit")
    return payload


def fetch_releases(token: str | None) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "NexaWrt-Pages-Release-Index/3",
        "X-GitHub-Api-Version": "2026-03-10",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(API_URL, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.status != 200:
                raise ValueError(f"GitHub API returned HTTP {response.status}")
            return json.loads(read_limited(response))
    except urllib.error.HTTPError as exc:
        raise ValueError(f"GitHub API returned HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ValueError(f"GitHub API request failed: {exc.reason}") from exc


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json_file(path: Path, label: str) -> Any:
    if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError(f"{label} must be a regular file, not a symlink or hard link")
    with path.open("rb") as stream:
        return json.loads(read_limited(stream), object_pairs_hook=reject_duplicate_keys)


def load_fixture(path: Path) -> Any:
    return load_json_file(path, "fixture input")


def validate_digest_map(value: Any, expected_keys: set[str], tag: str) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise ValueError(f"proof asset digest map is invalid: {tag}")
    for key, digest in value.items():
        if not isinstance(digest, str) or not HEX_SHA256_RE.fullmatch(digest):
            raise ValueError(f"proof asset digest is invalid: {tag}:{key}")
    return value


def validate_vm_asset_proofs(value: Any, expected: dict[str, str], tag: str) -> dict[str, dict[str, Any]]:
    if not isinstance(value, dict) or set(value) != set(expected):
        raise ValueError(f"VM proof asset map is invalid: {tag}")
    validated: dict[str, dict[str, Any]] = {}
    seen_ids: set[int] = set()
    for key, expected_name in expected.items():
        asset = value[key]
        if not isinstance(asset, dict) or set(asset) != {"id", "name", "size", "sha256"}:
            raise ValueError(f"VM proof asset identity is invalid: {tag}:{key}")
        asset_id, name, size, digest = asset["id"], asset["name"], asset["size"], asset["sha256"]
        if (isinstance(asset_id, bool) or not isinstance(asset_id, int) or asset_id <= 0 or asset_id in seen_ids or
                name != expected_name or isinstance(size, bool) or not isinstance(size, int) or size <= 0 or
                not isinstance(digest, str) or not HEX_SHA256_RE.fullmatch(digest)):
            raise ValueError(f"VM proof asset identity is invalid: {tag}:{key}")
        seen_ids.add(asset_id)
        validated[key] = asset
    return validated


def load_proofs(path: Path, metadata: dict[str, Any]) -> dict[str, dict[str, dict[str, Any]]]:
    document = load_json_file(path, "proof manifest")
    expected_top = {
        "schema_version", "repository", "trusted_ref", "trusted_main_digest",
        "signer_workflows", "releases", "virtual_images",
    }
    if not isinstance(document, dict) or set(document) != expected_top:
        raise ValueError("proof manifest schema is invalid")
    if document["schema_version"] != PROOF_SCHEMA_VERSION or document["repository"] != REPOSITORY:
        raise ValueError("proof manifest identity is invalid")
    if document["trusted_ref"] != TRUSTED_REF:
        raise ValueError("proof manifest trust policy is invalid")
    workflows = document["signer_workflows"]
    if not isinstance(workflows, dict) or workflows != {"ax9000": SIGNER_WORKFLOW, "vm_x86_64": VM_SIGNER_WORKFLOW}:
        raise ValueError("proof manifest signer workflow policy is invalid")
    if not isinstance(document["trusted_main_digest"], str) or not HEX_SHA_RE.fullmatch(document["trusted_main_digest"]):
        raise ValueError("proof manifest trusted main digest is invalid")

    releases = document["releases"]
    if not isinstance(releases, dict) or len(releases) > 100:
        raise ValueError("proof manifest releases must be an object of at most 100 entries")
    expected_proof = {
        "release_id", "source_digest", "archive_sha256", "checksum_sha256", "verified_subjects",
    }
    validated: dict[str, dict[str, Any]] = {}
    for tag, proof in releases.items():
        if release_identity(tag, metadata) is None or not isinstance(proof, dict) or set(proof) != expected_proof:
            raise ValueError(f"proof entry is invalid: {tag}")
        release_id = proof["release_id"]
        if isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0:
            raise ValueError(f"proof release ID is invalid: {tag}")
        if not isinstance(proof["source_digest"], str) or not HEX_SHA_RE.fullmatch(proof["source_digest"]):
            raise ValueError(f"proof source digest is invalid: {tag}")
        if any(not isinstance(proof[key], str) or not HEX_SHA256_RE.fullmatch(proof[key])
               for key in ("archive_sha256", "checksum_sha256")):
            raise ValueError(f"proof asset digest is invalid: {tag}")
        if proof["verified_subjects"] != VERIFIED_SUBJECTS:
            raise ValueError(f"proof subjects are incomplete: {tag}")
        validated[tag] = proof

    virtual_images = document["virtual_images"]
    if not isinstance(virtual_images, dict) or set(virtual_images) != {VM_PLATFORM}:
        raise ValueError("proof manifest virtual image schema is invalid")
    vm_entries = virtual_images[VM_PLATFORM]
    if not isinstance(vm_entries, dict) or len(vm_entries) > 100:
        raise ValueError("proof manifest VM releases must be an object of at most 100 entries")
    vm_expected_proof = {"release_id", "source_digest", "assets", "verified_subjects"}
    vm_validated: dict[str, dict[str, Any]] = {}
    seen_vm_release_ids: set[int] = set()
    seen_vm_asset_ids: set[int] = set()
    for tag, proof in vm_entries.items():
        version = vm_identity(tag)
        if version is None or not isinstance(proof, dict) or set(proof) != vm_expected_proof:
            raise ValueError(f"VM proof entry is invalid: {tag}")
        release_id = proof["release_id"]
        if (isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0 or
                release_id in seen_vm_release_ids):
            raise ValueError(f"VM proof release ID is invalid or replayed: {tag}")
        seen_vm_release_ids.add(release_id)
        if not isinstance(proof["source_digest"], str) or not HEX_SHA_RE.fullmatch(proof["source_digest"]):
            raise ValueError(f"VM proof source digest is invalid: {tag}")
        if proof["verified_subjects"] != VM_VERIFIED_SUBJECTS:
            raise ValueError(f"VM proof subjects are incomplete: {tag}")
        validated_assets = validate_vm_asset_proofs(proof["assets"], vm_expected_assets(version), tag)
        asset_ids = {asset["id"] for asset in validated_assets.values()}
        if asset_ids & seen_vm_asset_ids:
            raise ValueError(f"VM proof asset ID is replayed across releases: {tag}")
        seen_vm_asset_ids.update(asset_ids)
        vm_validated[tag] = proof
    return {"releases": validated, "virtual_images": {VM_PLATFORM: vm_validated}}


def normalize_timestamp(value: Any) -> str | None:
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def tag_for(flavor: str, version: str) -> str:
    return f"{CHANNEL}-{version}" if flavor == "official" else f"{CHANNEL}-{flavor}-{version}"


def release_identity(tag: Any, metadata: dict[str, Any]) -> tuple[str, str] | None:
    if not isinstance(tag, str) or len(tag) > 100:
        return None
    for flavor in metadata["flavors"]:
        prefix = f"{CHANNEL}-" if flavor == "official" else f"{CHANNEL}-{flavor}-"
        if tag.startswith(prefix):
            version = tag[len(prefix) :]
            if VERSION_PATTERN.fullmatch(version) and tag == tag_for(flavor, version):
                return flavor, version
    return None


def vm_identity(tag: Any) -> str | None:
    prefix = f"vm-{VM_PLATFORM}-"
    if not isinstance(tag, str) or len(tag) > 100 or not tag.startswith(prefix):
        return None
    version = tag[len(prefix):]
    if VERSION_PATTERN.fullmatch(version) and tag == f"{prefix}{version}":
        return version
    return None


def expected_assets(metadata: dict[str, Any], flavor: str, version: str) -> dict[str, str]:
    archive = f'NexaWrt-{metadata["model"]}-{flavor}-{version}-verified-dist.tar.gz'
    return {
        "archive": archive,
        "checksum": f"{archive}.sha256",
        **PROVENANCE_ASSETS,
    }


def vm_expected_assets(version: str) -> dict[str, str]:
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


def safe_download_url(tag: str, asset_name: str) -> str:
    return f"{WEB_ROOT}/releases/download/{quote(tag, safe='')}/{quote(asset_name, safe='')}"


def sanitize_release(
    raw: Any,
    metadata: dict[str, Any],
    proofs: dict[str, dict[str, Any]],
) -> tuple[str, dict[str, Any]] | None:
    if (
        not isinstance(raw, dict)
        or raw.get("draft") is not False
        or raw.get("prerelease") is not True
        or raw.get("immutable") is not True
    ):
        return None

    tag = raw.get("tag_name")
    identity = release_identity(tag, metadata)
    published_at = normalize_timestamp(raw.get("published_at"))
    if identity is None or published_at is None:
        return None
    proof = proofs.get(tag)
    release_id = raw.get("id")
    if proof is None or isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0:
        return None
    if proof["release_id"] != release_id:
        return None
    flavor, version = identity
    validate_request(metadata, device=metadata["id"], flavor=flavor, channel=CHANNEL)

    assets = raw.get("assets")
    if not isinstance(assets, list) or len(assets) != 6:
        return None

    allowed = expected_assets(metadata, flavor, version)
    allowed_by_name = {name: key for key, name in allowed.items()}
    present: dict[str, dict[str, Any]] = {}
    remote_names: set[str] = set()
    for asset in assets:
        if not isinstance(asset, dict):
            return None
        name = asset.get("name")
        if not isinstance(name, str) or name in remote_names:
            return None
        remote_names.add(name)
        key = allowed_by_name.get(name)
        if key is None or asset.get("state") != "uploaded":
            return None
        size = asset.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            return None
        present[key] = {"name": name, "url": safe_download_url(tag, name), "size": size}

    if remote_names != set(allowed.values()) or set(present) != set(allowed):
        return None

    device = public_device(metadata)
    return flavor, {
        "device_id": device["id"],
        "device_name": device["display_name"],
        "flavor": flavor,
        "flavor_experimental": metadata["flavors"][flavor]["experimental"],
        "channel": CHANNEL,
        "hardware_status": device["hardware_status"],
        "production_ready": False,
        "ram_only": True,
        "version": version,
        "tag": tag,
        "published_at": published_at,
        "release_url": f"{WEB_ROOT}/releases/tag/{quote(tag, safe='')}",
        "browser_build_workflow_url": device["browser_build_workflow_url"],
        "recovery_url": device["recovery_url"],
        "testing_url": device["testing_url"],
        "assets": {key: present[key] for key in allowed},
    }


def sanitize_vm_release(raw: Any, proofs: dict[str, dict[str, Any]]) -> dict[str, Any] | None:
    if (
        not isinstance(raw, dict)
        or raw.get("draft") is not False
        or raw.get("prerelease") is not True
        or raw.get("immutable") is not True
    ):
        return None
    tag = raw.get("tag_name")
    version = vm_identity(tag)
    published_at = normalize_timestamp(raw.get("published_at"))
    if version is None or published_at is None:
        return None
    proof = proofs.get(tag)
    release_id = raw.get("id")
    if proof is None or isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0:
        return None
    if proof["release_id"] != release_id:
        return None
    assets = raw.get("assets")
    expected = vm_expected_assets(version)
    if not isinstance(assets, list) or len(assets) != len(expected):
        return None
    allowed_by_name = {name: key for key, name in expected.items()}
    proof_assets = proof["assets"]
    present: dict[str, dict[str, Any]] = {}
    remote_names: set[str] = set()
    remote_ids: set[int] = set()
    for asset in assets:
        if not isinstance(asset, dict):
            return None
        name, asset_id, size = asset.get("name"), asset.get("id"), asset.get("size")
        if (not isinstance(name, str) or name in remote_names or "AX9000" in name or "ax9000" in name or
                isinstance(asset_id, bool) or not isinstance(asset_id, int) or asset_id <= 0 or asset_id in remote_ids):
            return None
        remote_names.add(name)
        remote_ids.add(asset_id)
        key = allowed_by_name.get(name)
        if key is None or asset.get("state") != "uploaded":
            return None
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            return None
        identity = proof_assets[key]
        if identity["id"] != asset_id or identity["name"] != name or identity["size"] != size:
            return None
        remote_digest = asset.get("digest")
        if remote_digest is not None and remote_digest != f"sha256:{identity['sha256']}":
            return None
        present[key] = {"name": name, "url": safe_download_url(tag, name), "size": size}
    if remote_names != set(expected.values()) or set(present) != set(expected):
        return None
    return {
        "platform": VM_PLATFORM,
        "artifact_class": "VM_DISTRIBUTION_IMAGE",
        "vm_only": True,
        "not_ax9000_firmware": True,
        "hardware_validation": False,
        "nss_validation": False,
        "qemu_validated": True,
        "ssh_default": "disabled",
        "version": version,
        "tag": tag,
        "published_at": published_at,
        "release_url": f"{WEB_ROOT}/releases/tag/{quote(tag, safe='')}",
        "browser_build_workflow_url": VM_WORKFLOW_URL,
        "docs_url": VM_DOCS_URL,
        "assets": {key: present[key] for key in expected},
    }


def version_order(version: str) -> tuple[int, int, int, int]:
    match = re.fullmatch(r"v([0-9]+)\.([0-9]+)\.([0-9]+)-rc\.([0-9]+)", version)
    if match is None:
        raise ValueError(f"invalid release version: {version}")
    return tuple(int(part) for part in match.groups())


def build_document(
    raw_releases: Any,
    history_limit: int,
    metadata: dict[str, Any] | None = None,
    proofs: dict[str, dict[str, dict[str, Any]]] | None = None,
) -> dict[str, Any]:
    if not isinstance(raw_releases, list) or len(raw_releases) > 100:
        raise ValueError("GitHub releases payload must be a list of at most 100 entries")

    metadata = metadata if metadata is not None else load_device_metadata()
    if proofs is None:
        raise ValueError("a verified release proof manifest is required")
    for flavor in metadata["flavors"]:
        validate_request(metadata, device=metadata["id"], flavor=flavor, channel=CHANNEL)

    release_proofs = proofs["releases"]
    vm_proofs = proofs["virtual_images"][VM_PLATFORM]
    grouped: dict[str, list[dict[str, Any]]] = {flavor: [] for flavor in metadata["flavors"]}
    vm_releases: list[dict[str, Any]] = []
    seen_tags: set[str] = set()
    for raw in raw_releases:
        sanitized = sanitize_release(raw, metadata, release_proofs)
        if sanitized is not None:
            flavor, release = sanitized
            if release["tag"] in seen_tags:
                raise ValueError(f"duplicate allowlisted release tag: {release['tag']}")
            seen_tags.add(release["tag"])
            grouped[flavor].append(release)
            continue
        vm_release = sanitize_vm_release(raw, vm_proofs)
        if vm_release is not None:
            if vm_release["tag"] in seen_tags:
                raise ValueError(f"duplicate allowlisted release tag: {vm_release['tag']}")
            seen_tags.add(vm_release["tag"])
            vm_releases.append(vm_release)

    unused_proofs = (set(release_proofs) | set(vm_proofs)) - seen_tags
    if unused_proofs:
        raise ValueError(f"proof manifest contains unmatched releases: {', '.join(sorted(unused_proofs))}")

    for releases in grouped.values():
        releases.sort(key=lambda release: (release["published_at"], version_order(release["version"])), reverse=True)
        del releases[history_limit:]
    vm_releases.sort(key=lambda release: (release["published_at"], version_order(release["version"])), reverse=True)
    del vm_releases[history_limit:]

    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    device = public_device(metadata)
    devices = {device["id"]: device} if device["website_visible"] else {}
    return {
        "schema_version": 3,
        "repository": REPOSITORY,
        "generated_at": generated_at,
        "devices": devices,
        "flavors": {
            flavor: {"latest": releases[0] if releases else None, "history": releases}
            for flavor, releases in grouped.items()
        },
        "virtual_images": {
            VM_PLATFORM: {"latest": vm_releases[0] if vm_releases else None, "history": vm_releases}
        },
    }


def write_document(path: Path, document: dict[str, Any]) -> None:
    if path.exists() and (path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1):
        raise ValueError("output path must be a regular file, not a symlink or hard link")
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    args = parse_args()
    try:
        metadata = load_device_metadata()
        proofs = load_proofs(args.proofs, metadata)
        raw_releases = load_fixture(args.input) if args.input else fetch_releases(os.environ.get("GITHUB_TOKEN"))
        write_document(args.output, build_document(raw_releases, args.history_limit, metadata, proofs))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"generate-pages-data: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
