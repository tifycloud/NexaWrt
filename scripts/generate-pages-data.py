#!/usr/bin/env python3
"""Generate the allowlisted GitHub release data consumed by the NexaWrt site."""

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

REPOSITORY = "tifycloud/NexaWrt"
API_URL = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100"
WEB_ROOT = f"https://github.com/{REPOSITORY}"
MAX_RESPONSE_BYTES = 5 * 1024 * 1024
DEFAULT_HISTORY_LIMIT = 12

VERSION_PATTERN = r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)-rc\.(?:0|[1-9][0-9]*)"
TAG_PATTERNS = {
    "official": re.compile(rf"^ram-test-(?P<version>{VERSION_PATTERN})$"),
    "nss": re.compile(rf"^ram-test-nss-(?P<version>{VERSION_PATTERN})$"),
}

PROVENANCE_ASSETS = {
    "archive": "archive.provenance.bundle.json",
    "checksums": "checksums.provenance.bundle.json",
    "firmware": "firmware.provenance.bundle.json",
    "sbom": "sbom.provenance.bundle.json",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        help="read a saved GitHub releases API response instead of making a request",
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
        "User-Agent": "NexaWrt-Pages-Release-Index/1",
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


def load_fixture(path: Path) -> Any:
    if path.is_symlink() or not path.is_file():
        raise ValueError("fixture input must be a regular file, not a symlink")
    with path.open("rb") as stream:
        return json.loads(read_limited(stream))


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


def release_identity(tag: Any) -> tuple[str, str] | None:
    if not isinstance(tag, str):
        return None
    for flavor in ("official", "nss"):
        match = TAG_PATTERNS[flavor].fullmatch(tag)
        if match:
            return flavor, match.group("version")
    return None


def expected_assets(flavor: str, version: str) -> dict[str, str]:
    archive = f"NexaWrt-AX9000-{flavor}-{version}-verified-dist.tar.gz"
    return {
        "archive": archive,
        "checksum": f"{archive}.sha256",
        **{f"provenance_{key}": name for key, name in PROVENANCE_ASSETS.items()},
    }


def safe_download_url(tag: str, asset_name: str) -> str:
    return f"{WEB_ROOT}/releases/download/{quote(tag, safe='')}/{quote(asset_name, safe='')}"


def sanitize_release(raw: Any) -> tuple[str, dict[str, Any]] | None:
    if (
        not isinstance(raw, dict)
        or raw.get("draft") is not False
        or raw.get("prerelease") is not True
        or raw.get("immutable") is not True
    ):
        return None

    tag = raw.get("tag_name")
    identity = release_identity(tag)
    published_at = normalize_timestamp(raw.get("published_at"))
    if identity is None or published_at is None:
        return None
    flavor, version = identity

    assets = raw.get("assets")
    if not isinstance(assets, list) or len(assets) > 100:
        return None

    allowed = expected_assets(flavor, version)
    allowed_by_name = {name: key for key, name in allowed.items()}
    if len(assets) != len(allowed):
        return None

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
        present[key] = {
            "name": name,
            "url": safe_download_url(tag, name),
            "size": size,
        }

    # Fail closed unless the remote release contains exactly the six expected assets.
    if remote_names != set(allowed.values()) or set(present) != set(allowed):
        return None

    return flavor, {
        "tag": tag,
        "version": version,
        "published_at": published_at,
        "url": f"{WEB_ROOT}/releases/tag/{quote(tag, safe='')}",
        "assets": {key: present[key] for key in allowed},
    }


def build_document(raw_releases: Any, history_limit: int) -> dict[str, Any]:
    if not isinstance(raw_releases, list) or len(raw_releases) > 100:
        raise ValueError("GitHub releases payload must be a list of at most 100 entries")

    grouped: dict[str, list[dict[str, Any]]] = {"official": [], "nss": []}
    seen_tags: set[str] = set()
    for raw in raw_releases:
        sanitized = sanitize_release(raw)
        if sanitized is None:
            continue
        flavor, release = sanitized
        if release["tag"] in seen_tags:
            raise ValueError(f"duplicate allowlisted release tag: {release['tag']}")
        seen_tags.add(release["tag"])
        grouped[flavor].append(release)

    for releases in grouped.values():
        releases.sort(key=lambda release: (release["published_at"], release["tag"]), reverse=True)
        del releases[history_limit:]

    generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return {
        "schema_version": 1,
        "repository": REPOSITORY,
        "generated_at": generated_at,
        "flavors": {
            flavor: {
                "latest": releases[0] if releases else None,
                "history": releases,
            }
            for flavor, releases in grouped.items()
        },
    }


def write_document(path: Path, document: dict[str, Any]) -> None:
    if path.exists() and path.is_symlink():
        raise ValueError("output path must not be a symlink")
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
        raw_releases = load_fixture(args.input) if args.input else fetch_releases(os.environ.get("GITHUB_TOKEN"))
        write_document(args.output, build_document(raw_releases, args.history_limit))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"generate-pages-data: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
