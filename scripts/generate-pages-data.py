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
PROOF_SCHEMA_VERSION = 1
TRUSTED_REF = "refs/heads/main"
SIGNER_WORKFLOW = f"{REPOSITORY}/.github/workflows/release.yml"
HEX_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HEX_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERIFIED_SUBJECTS = ["archive", "checksums", "firmware", "sbom"]
PROVENANCE_ASSETS = {
    "provenance_archive": "archive.provenance.bundle.json",
    "provenance_checksums": "checksums.provenance.bundle.json",
    "provenance_firmware": "firmware.provenance.bundle.json",
    "provenance_sbom": "sbom.provenance.bundle.json",
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
        "User-Agent": "NexaWrt-Pages-Release-Index/2",
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


def load_proofs(path: Path, metadata: dict[str, Any]) -> dict[str, dict[str, Any]]:
    document = load_json_file(path, "proof manifest")
    expected_top = {
        "schema_version", "repository", "trusted_ref", "trusted_main_digest",
        "signer_workflow", "releases",
    }
    if not isinstance(document, dict) or set(document) != expected_top:
        raise ValueError("proof manifest schema is invalid")
    if document["schema_version"] != PROOF_SCHEMA_VERSION or document["repository"] != REPOSITORY:
        raise ValueError("proof manifest identity is invalid")
    if document["trusted_ref"] != TRUSTED_REF or document["signer_workflow"] != SIGNER_WORKFLOW:
        raise ValueError("proof manifest trust policy is invalid")
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
    return validated


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


def expected_assets(metadata: dict[str, Any], flavor: str, version: str) -> dict[str, str]:
    archive = f'NexaWrt-{metadata["model"]}-{flavor}-{version}-verified-dist.tar.gz'
    return {
        "archive": archive,
        "checksum": f"{archive}.sha256",
        **PROVENANCE_ASSETS,
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


def version_order(version: str) -> tuple[int, int, int, int]:
    match = re.fullmatch(r"v([0-9]+)\.([0-9]+)\.([0-9]+)-rc\.([0-9]+)", version)
    if match is None:
        raise ValueError(f"invalid release version: {version}")
    return tuple(int(part) for part in match.groups())


def build_document(
    raw_releases: Any,
    history_limit: int,
    metadata: dict[str, Any] | None = None,
    proofs: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    if not isinstance(raw_releases, list) or len(raw_releases) > 100:
        raise ValueError("GitHub releases payload must be a list of at most 100 entries")

    metadata = metadata if metadata is not None else load_device_metadata()
    if proofs is None:
        raise ValueError("a verified release proof manifest is required")
    for flavor in metadata["flavors"]:
        validate_request(metadata, device=metadata["id"], flavor=flavor, channel=CHANNEL)

    grouped: dict[str, list[dict[str, Any]]] = {flavor: [] for flavor in metadata["flavors"]}
    seen_tags: set[str] = set()
    for raw in raw_releases:
        sanitized = sanitize_release(raw, metadata, proofs)
        if sanitized is None:
            continue
        flavor, release = sanitized
        if release["tag"] in seen_tags:
            raise ValueError(f"duplicate allowlisted release tag: {release['tag']}")
        seen_tags.add(release["tag"])
        grouped[flavor].append(release)

    unused_proofs = set(proofs) - seen_tags
    if unused_proofs:
        raise ValueError(f"proof manifest contains unmatched releases: {', '.join(sorted(unused_proofs))}")

    for releases in grouped.values():
        releases.sort(key=lambda release: (release["published_at"], version_order(release["version"])), reverse=True)
        del releases[history_limit:]

    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    device = public_device(metadata)
    devices = {device["id"]: device} if device["website_visible"] else {}
    return {
        "schema_version": 2,
        "repository": REPOSITORY,
        "generated_at": generated_at,
        "devices": devices,
        "flavors": {
            flavor: {"latest": releases[0] if releases else None, "history": releases}
            for flavor, releases in grouped.items()
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
