#!/usr/bin/env python3
"""Resolve an allow-listed NexaWrt component selection into build inputs.

The command intentionally accepts component IDs only. Package names, shell
fragments, alternate catalogs, file overlays, and arbitrary build arguments are
not accepted from callers.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Iterable

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from component_package_policy import (
    allowed_architectures_for,
    blocked_reason_for_record,
    risk_for,
)

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "components" / "catalog.json"
PACKAGE_CATALOG_PATH = ROOT / "components" / "package-catalog.json"
PACKAGE_SHARD_ROOT = ROOT / "components" / "packages"
COMMUNITY_LOCK_PATH = ROOT / "manifests" / "community-feeds.lock"
OPENWRT_VERSION = "25.12.5"
REQUEST_SCHEMA_VERSION = 2
REQUIRED_TARGETS = {"x86_64", "xiaomi_ax9000"}
ALLOWED_FLAVORS = {"official", "nss"}
MAX_COMPONENT_CATALOG_BYTES = 2 * 1024 * 1024
MAX_PACKAGE_CATALOG_BYTES = 2 * 1024 * 1024
MAX_PACKAGE_SHARD_BYTES = 16 * 1024 * 1024
MAX_PACKAGE_RECORDS = 50000
MAX_COMMUNITY_LOCK_BYTES = 16 * 1024
IO_CHUNK_SIZE = 1024 * 1024
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
DIRECTORY = getattr(os, "O_DIRECTORY", 0)

TOP_LEVEL_KEYS = {
    "schema_version",
    "catalog_version",
    "max_selected_components",
    "targets",
    "categories",
    "components",
}
TARGET_KEYS = {
    "id",
    "display_name",
    "openwrt_target",
    "openwrt_subtarget",
    "profile",
}
CATEGORY_KEYS = {"id", "title", "description", "order"}
COMPONENT_KEYS = {
    "id",
    "name",
    "description",
    "category",
    "packages",
    "depends",
    "conflicts",
    "supported_targets",
    "default_for",
}

ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
OPENWRT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
CATALOG_VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]+)?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
LOCK_LINE_RE = re.compile(r'^([A-Z][A-Z0-9_]*)="([^"\\]*)"$')
PACKAGE_ID_RE = re.compile(r"^pkg-[0-9a-f]{16}$")
PACKAGE_SHARD_PATH_RE = re.compile(r"^components/packages/[a-z0-9][a-z0-9_-]{0,63}\.json$")
PACKAGE_CATALOG_KEYS = {"schema_version", "catalog_version", "openwrt_version", "purpose_catalog", "shards"}
PACKAGE_PURPOSE_DESCRIPTOR_KEYS = {"locale", "path", "sha256", "package_count"}
PACKAGE_PURPOSE_CATALOG_RELATIVE_PATH = "components/package-purpose-zh.json"
PACKAGE_DESCRIPTOR_KEYS = {
    "target", "flavor", "path", "sha256", "package_count", "selectable_count", "sources"
}
OFFICIAL_PACKAGE_SOURCE_KEYS = {"feed", "url", "sha256"}
COMMUNITY_PACKAGE_SOURCE_KEYS = {
    "feed", "url", "sha256", "metadata_format", "metadata_signed",
    "candidate_repository", "candidate_commit", "catalog_sha256",
}
PACKAGE_SHARD_KEYS = {"schema_version", "catalog_version", "target", "flavor", "packages"}
PACKAGE_RECORD_KEYS = {
    "id", "package", "version", "description", "feed", "source", "installed_size", "category",
    "arch", "risk", "selectable", "blocked_reason"
}
PACKAGE_FEEDS = {"target", "base", "kmods", "luci", "packages", "routing", "telephony", "video"}
COMMUNITY_FEED = "kiddin9"
PACKAGE_FEED_CATEGORIES = {
    "target": "official-target",
    "base": "official-base",
    "kmods": "official-kernel",
    "luci": "official-luci",
    "packages": "official-packages",
    "routing": "official-routing",
    "telephony": "official-telephony",
    "video": "official-video",
    COMMUNITY_FEED: "community-kiddin9",
}
EXPECTED_PACKAGE_SHARDS = {
    ("x86_64", "official"): "components/packages/x86_64-official.json",
    ("xiaomi_ax9000", "official"): "components/packages/xiaomi_ax9000-official.json",
    ("xiaomi_ax9000", "nss"): "components/packages/xiaomi_ax9000-nss.json",
}


class CatalogError(ValueError):
    """The repository-owned component catalog is invalid."""


class RequestError(ValueError):
    """A caller supplied an invalid component selection."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _exact_keys(value: dict[str, Any], expected: set[str], context: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise CatalogError(f"{context} keys differ: missing={missing}, extra={extra}")


def _nonempty_text(value: Any, context: str, maximum: int = 240) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        raise CatalogError(f"{context} must be a non-empty trimmed string")
    if len(value) > maximum or any(ord(character) < 32 for character in value):
        raise CatalogError(f"{context} contains invalid text")
    return value


def _identifier(value: Any, context: str) -> str:
    value = _nonempty_text(value, context, 64)
    if not ID_RE.fullmatch(value):
        raise CatalogError(f"{context} is not a valid identifier: {value!r}")
    return value


def _openwrt_name(value: Any, context: str) -> str:
    value = _nonempty_text(value, context, 128)
    if not OPENWRT_NAME_RE.fullmatch(value):
        raise CatalogError(f"{context} is not an allow-listed OpenWrt token: {value!r}")
    return value


def _unique_string_list(
    value: Any,
    context: str,
    *,
    allow_empty: bool,
    validator: Any = _identifier,
    maximum: int = 64,
) -> list[str]:
    if not isinstance(value, list) or (not allow_empty and not value):
        qualifier = "a list" if allow_empty else "a non-empty list"
        raise CatalogError(f"{context} must be {qualifier}")
    if len(value) > maximum:
        raise CatalogError(f"{context} exceeds the maximum of {maximum} entries")
    result = [validator(item, f"{context}[]") for item in value]
    if len(set(result)) != len(result):
        raise CatalogError(f"{context} contains duplicate entries")
    return result


def _index_by_id(items: list[dict[str, Any]], context: str) -> dict[str, dict[str, Any]]:
    index: dict[str, dict[str, Any]] = {}
    for item in items:
        item_id = item["id"]
        if item_id in index:
            raise CatalogError(f"duplicate {context} id: {item_id}")
        index[item_id] = item
    return index


def _validate_dependency_graph(components: dict[str, dict[str, Any]]) -> None:
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(component_id: str, chain: list[str]) -> None:
        if component_id in visiting:
            raise CatalogError("component dependency cycle: " + " -> ".join(chain + [component_id]))
        if component_id in visited:
            return
        visiting.add(component_id)
        for dependency in components[component_id]["depends"]:
            visit(dependency, chain + [component_id])
        visiting.remove(component_id)
        visited.add(component_id)

    for component_id in components:
        visit(component_id, [])


def validate_catalog(payload: Any) -> dict[str, Any]:
    """Validate the complete catalog using an exact, closed schema."""
    if not isinstance(payload, dict):
        raise CatalogError("catalog root must be an object")
    _exact_keys(payload, TOP_LEVEL_KEYS, "catalog")

    if type(payload["schema_version"]) is not int or payload["schema_version"] != 1:
        raise CatalogError("schema_version must be integer 1")
    catalog_version = _nonempty_text(payload["catalog_version"], "catalog_version", 32)
    if not CATALOG_VERSION_RE.fullmatch(catalog_version):
        raise CatalogError("catalog_version must use YYYY.MM.DD or YYYY.MM.DD.N format")
    maximum = payload["max_selected_components"]
    if type(maximum) is not int or not 1 <= maximum <= 32:
        raise CatalogError("max_selected_components must be an integer from 1 to 32")

    raw_targets = payload["targets"]
    if not isinstance(raw_targets, list) or not raw_targets or len(raw_targets) > 32:
        raise CatalogError("targets must be a non-empty list with at most 32 entries")
    targets: list[dict[str, Any]] = []
    for position, raw in enumerate(raw_targets):
        if not isinstance(raw, dict):
            raise CatalogError(f"targets[{position}] must be an object")
        _exact_keys(raw, TARGET_KEYS, f"targets[{position}]")
        targets.append(
            {
                "id": _identifier(raw["id"], f"targets[{position}].id"),
                "display_name": _nonempty_text(
                    raw["display_name"], f"targets[{position}].display_name", 100
                ),
                "openwrt_target": _openwrt_name(
                    raw["openwrt_target"], f"targets[{position}].openwrt_target"
                ),
                "openwrt_subtarget": _openwrt_name(
                    raw["openwrt_subtarget"], f"targets[{position}].openwrt_subtarget"
                ),
                "profile": _openwrt_name(raw["profile"], f"targets[{position}].profile"),
            }
        )
    target_index = _index_by_id(targets, "target")
    missing_targets = sorted(REQUIRED_TARGETS - set(target_index))
    if missing_targets:
        raise CatalogError(f"catalog is missing required targets: {missing_targets}")

    raw_categories = payload["categories"]
    if not isinstance(raw_categories, list) or not raw_categories or len(raw_categories) > 64:
        raise CatalogError("categories must be a non-empty list with at most 64 entries")
    categories: list[dict[str, Any]] = []
    category_orders: set[int] = set()
    for position, raw in enumerate(raw_categories):
        if not isinstance(raw, dict):
            raise CatalogError(f"categories[{position}] must be an object")
        _exact_keys(raw, CATEGORY_KEYS, f"categories[{position}]")
        order = raw["order"]
        if type(order) is not int or not 0 <= order <= 10000:
            raise CatalogError(f"categories[{position}].order must be an integer from 0 to 10000")
        if order in category_orders:
            raise CatalogError(f"duplicate category order: {order}")
        category_orders.add(order)
        categories.append(
            {
                "id": _identifier(raw["id"], f"categories[{position}].id"),
                "title": _nonempty_text(raw["title"], f"categories[{position}].title", 100),
                "description": _nonempty_text(
                    raw["description"], f"categories[{position}].description", 240
                ),
                "order": order,
            }
        )
    category_index = _index_by_id(categories, "category")

    raw_components = payload["components"]
    if not isinstance(raw_components, list) or not raw_components or len(raw_components) > 256:
        raise CatalogError("components must be a non-empty list with at most 256 entries")
    components: list[dict[str, Any]] = []
    for position, raw in enumerate(raw_components):
        if not isinstance(raw, dict):
            raise CatalogError(f"components[{position}] must be an object")
        _exact_keys(raw, COMPONENT_KEYS, f"components[{position}]")
        component = {
            "id": _identifier(raw["id"], f"components[{position}].id"),
            "name": _nonempty_text(raw["name"], f"components[{position}].name", 100),
            "description": _nonempty_text(
                raw["description"], f"components[{position}].description", 300
            ),
            "category": _identifier(raw["category"], f"components[{position}].category"),
            "packages": _unique_string_list(
                raw["packages"],
                f"components[{position}].packages",
                allow_empty=False,
                validator=_openwrt_name,
                maximum=32,
            ),
            "depends": _unique_string_list(
                raw["depends"], f"components[{position}].depends", allow_empty=True, maximum=32
            ),
            "conflicts": _unique_string_list(
                raw["conflicts"], f"components[{position}].conflicts", allow_empty=True, maximum=32
            ),
            "supported_targets": _unique_string_list(
                raw["supported_targets"],
                f"components[{position}].supported_targets",
                allow_empty=False,
                maximum=32,
            ),
            "default_for": _unique_string_list(
                raw["default_for"],
                f"components[{position}].default_for",
                allow_empty=True,
                maximum=32,
            ),
        }
        if component["category"] not in category_index:
            raise CatalogError(f"component {component['id']} references unknown category")
        components.append(component)
    component_index = _index_by_id(components, "component")

    known_targets = set(target_index)
    for component in components:
        component_id = component["id"]
        supported = set(component["supported_targets"])
        defaults = set(component["default_for"])
        unknown_targets = sorted((supported | defaults) - known_targets)
        if unknown_targets:
            raise CatalogError(f"component {component_id} references unknown targets: {unknown_targets}")
        if not defaults <= supported:
            raise CatalogError(f"component {component_id} defaults must be supported targets")

        references = set(component["depends"]) | set(component["conflicts"])
        unknown_components = sorted(references - set(component_index))
        if unknown_components:
            raise CatalogError(
                f"component {component_id} references unknown components: {unknown_components}"
            )
        if component_id in references:
            raise CatalogError(f"component {component_id} cannot reference itself")
        overlap = sorted(set(component["depends"]) & set(component["conflicts"]))
        if overlap:
            raise CatalogError(f"component {component_id} both depends on and conflicts with {overlap}")

        for dependency_id in component["depends"]:
            dependency_targets = set(component_index[dependency_id]["supported_targets"])
            unsupported = sorted(supported - dependency_targets)
            if unsupported:
                raise CatalogError(
                    f"component {component_id} dependency {dependency_id} is unsupported on {unsupported}"
                )
        for conflict_id in component["conflicts"]:
            if component_id not in component_index[conflict_id]["conflicts"]:
                raise CatalogError(
                    f"component conflict must be symmetric: {component_id} <-> {conflict_id}"
                )

    _validate_dependency_graph(component_index)

    normalized = {
        "schema_version": payload["schema_version"],
        "catalog_version": catalog_version,
        "max_selected_components": maximum,
        "targets": targets,
        "categories": categories,
        "components": components,
    }
    for target_id in target_index:
        defaults = [item["id"] for item in components if target_id in item["default_for"]]
        if len(defaults) > maximum:
            raise CatalogError(f"default components exceed selection limit for target {target_id}")
    return normalized


def load_catalog() -> dict[str, Any]:
    """Load only the repository-owned catalog; alternate paths are forbidden."""
    payload, _digest = _load_repository_json(
        CATALOG_PATH,
        ROOT / "components",
        "component catalog",
        MAX_COMPONENT_CATALOG_BYTES,
    )
    return validate_catalog(payload)


def _optional_text(value: Any, context: str, maximum: int) -> str:
    if not isinstance(value, str) or value != value.strip():
        raise CatalogError(f"{context} must be a trimmed string")
    if len(value) > maximum or any(ord(character) < 32 for character in value):
        raise CatalogError(f"{context} contains invalid text")
    return value


def _load_repository_json(
    path: Path, expected_parent: Path, context: str, maximum_bytes: int
) -> tuple[Any, str]:
    """Open, validate, bound, hash, and parse one repository file via one fd."""
    if path.parent != expected_parent or path.name in {"", ".", ".."}:
        raise CatalogError(f"{context} is outside its repository allow-list")
    parent_fd: int | None = None
    descriptor: int | None = None
    try:
        parent_fd = os.open(expected_parent, os.O_RDONLY | DIRECTORY | NOFOLLOW)
        parent_info = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent_info.st_mode):
            raise CatalogError(f"{context} parent must be a real directory")
        descriptor = os.open(path.name, os.O_RDONLY | NOFOLLOW, dir_fd=parent_fd)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise CatalogError(f"{context} must be a regular, single-link file")
        if info.st_size > maximum_bytes:
            raise CatalogError(f"{context} exceeds the {maximum_bytes}-byte limit")
        digest = hashlib.sha256()
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(IO_CHUNK_SIZE, maximum_bytes - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise CatalogError(f"{context} exceeds the {maximum_bytes}-byte limit")
            digest.update(chunk)
            chunks.append(chunk)
        raw = b"".join(chunks)
        payload = json.loads(
            raw.decode("utf-8"), object_pairs_hook=_reject_duplicate_keys
        )
        return payload, digest.hexdigest()
    except CatalogError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CatalogError(f"unable to load {context}: {error}") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if parent_fd is not None:
            os.close(parent_fd)


def _load_repository_text(
    path: Path, expected_parent: Path, context: str, maximum_bytes: int
) -> str:
    """Open and decode one bounded repository text file without following links."""
    if path.parent != expected_parent or path.name in {"", ".", ".."}:
        raise CatalogError(f"{context} is outside its repository allow-list")
    parent_fd: int | None = None
    descriptor: int | None = None
    try:
        parent_fd = os.open(expected_parent, os.O_RDONLY | DIRECTORY | NOFOLLOW)
        parent_info = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent_info.st_mode):
            raise CatalogError(f"{context} parent must be a real directory")
        descriptor = os.open(path.name, os.O_RDONLY | NOFOLLOW, dir_fd=parent_fd)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise CatalogError(f"{context} must be a regular, single-link file")
        if info.st_size > maximum_bytes:
            raise CatalogError(f"{context} exceeds the {maximum_bytes}-byte limit")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(IO_CHUNK_SIZE, maximum_bytes - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise CatalogError(f"{context} exceeds the {maximum_bytes}-byte limit")
            chunks.append(chunk)
        return b"".join(chunks).decode("utf-8")
    except CatalogError:
        raise
    except (OSError, UnicodeError) as error:
        raise CatalogError(f"unable to load {context}: {error}") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if parent_fd is not None:
            os.close(parent_fd)


def _read_community_lock() -> dict[str, str]:
    text = _load_repository_text(
        COMMUNITY_LOCK_PATH, ROOT / "manifests", "community feed lock",
        MAX_COMMUNITY_LOCK_BYTES,
    )
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = LOCK_LINE_RE.fullmatch(line)
        if not match:
            raise CatalogError(f"unsupported community lock syntax: {line!r}")
        key, value = match.groups()
        if key in values:
            raise CatalogError(f"duplicate community lock key: {key}")
        values[key] = value
    required = {
        "KIDDIN9_FEED", "KIDDIN9_REPO", "KIDDIN9_COMMIT",
        "KIDDIN9_PACKAGES_URL", "KIDDIN9_PACKAGES_SHA256",
        "KIDDIN9_PACKAGES_SIGNED", "KIDDIN9_CATALOG_SHA256",
    }
    if set(values) != required:
        raise CatalogError("community feed lock schema mismatch")
    if values["KIDDIN9_FEED"] != COMMUNITY_FEED:
        raise CatalogError("unexpected community feed name in lock")
    if values["KIDDIN9_REPO"] != "https://github.com/kiddin9/op-packages.git":
        raise CatalogError("unexpected community repository in lock")
    if not GIT_COMMIT_RE.fullmatch(values["KIDDIN9_COMMIT"]):
        raise CatalogError("invalid community commit in lock")
    _community_packages_url(values["KIDDIN9_PACKAGES_URL"], "community lock URL")
    if not SHA256_RE.fullmatch(values["KIDDIN9_PACKAGES_SHA256"]):
        raise CatalogError("invalid community metadata SHA256 in lock")
    if values["KIDDIN9_PACKAGES_SIGNED"] != "0":
        raise CatalogError("community metadata must remain explicitly unsigned")
    if not SHA256_RE.fullmatch(values["KIDDIN9_CATALOG_SHA256"]):
        raise CatalogError("invalid community catalog projection SHA256 in lock")
    return values


def _community_catalog_sha256(records: list[dict[str, Any]]) -> str:
    ordered = sorted(
        records,
        key=lambda item: (item["package"], item["source"], item["version"], item["id"]),
    )
    payload = json.dumps(
        ordered, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _official_packages_url(value: Any, context: str) -> str:
    value = _nonempty_text(value, context, 500)
    parsed = urllib.parse.urlsplit(value)
    prefix = f"/releases/{OPENWRT_VERSION}/"
    if (
        parsed.scheme != "https"
        or parsed.hostname != "downloads.openwrt.org"
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith(prefix)
        or not parsed.path.endswith("/packages.adb")
        or "//" in parsed.path
        or any(part in {"", ".", ".."} for part in parsed.path.split("/")[1:])
    ):
        raise CatalogError(f"{context} is outside the OpenWrt packages allow-list")
    return urllib.parse.urlunsplit(parsed)


def _community_packages_url(value: Any, context: str) -> str:
    value = _nonempty_text(value, context, 500)
    expected = (
        "https://dl.openwrt.ai/releases/25.12/packages/"
        "aarch64_cortex-a53/kiddin9/Packages.gz"
    )
    if value != expected:
        raise CatalogError(f"{context} is not the locked kiddin9 metadata URL")
    return value


def validate_package_catalog_index(payload: Any, catalog: dict[str, Any]) -> dict[str, Any]:
    """Validate the exact package-catalog root index."""
    if not isinstance(payload, dict):
        raise CatalogError("package catalog root must be an object")
    _exact_keys(payload, PACKAGE_CATALOG_KEYS, "package catalog")
    if type(payload["schema_version"]) is not int or payload["schema_version"] != 3:
        raise CatalogError("package catalog schema_version must be integer 3")
    if payload["catalog_version"] != catalog["catalog_version"]:
        raise CatalogError("package catalog version differs from component catalog")
    if payload["openwrt_version"] != OPENWRT_VERSION:
        raise CatalogError(f"package catalog openwrt_version must be {OPENWRT_VERSION}")
    community_lock = _read_community_lock()

    purpose = payload["purpose_catalog"]
    if not isinstance(purpose, dict):
        raise CatalogError("package purpose descriptor must be an object")
    _exact_keys(purpose, PACKAGE_PURPOSE_DESCRIPTOR_KEYS, "package purpose descriptor")
    if purpose["locale"] != "zh-CN" or purpose["path"] != PACKAGE_PURPOSE_CATALOG_RELATIVE_PATH:
        raise CatalogError("package purpose descriptor identity is invalid")
    purpose_digest = _nonempty_text(purpose["sha256"], "package purpose descriptor.sha256", 64)
    if not SHA256_RE.fullmatch(purpose_digest):
        raise CatalogError("package purpose descriptor.sha256 is invalid")
    purpose_count = purpose["package_count"]
    if type(purpose_count) is not int or purpose_count < 1 or purpose_count > MAX_PACKAGE_RECORDS:
        raise CatalogError("package purpose descriptor.package_count is invalid")

    raw_shards = payload["shards"]
    if not isinstance(raw_shards, list) or len(raw_shards) != len(EXPECTED_PACKAGE_SHARDS):
        raise CatalogError("package catalog must contain exactly three target/flavor shards")
    target_ids = {target["id"] for target in catalog["targets"]}
    descriptors: list[dict[str, Any]] = []
    seen_pairs: set[tuple[str, str]] = set()
    seen_paths: set[str] = set()
    for position, raw in enumerate(raw_shards):
        context = f"package catalog shards[{position}]"
        if not isinstance(raw, dict):
            raise CatalogError(f"{context} must be an object")
        _exact_keys(raw, PACKAGE_DESCRIPTOR_KEYS, context)
        target = _identifier(raw["target"], f"{context}.target")
        flavor = _identifier(raw["flavor"], f"{context}.flavor")
        pair = (target, flavor)
        if target not in target_ids or flavor not in ALLOWED_FLAVORS:
            raise CatalogError(f"{context} has unsupported target/flavor")
        if pair not in EXPECTED_PACKAGE_SHARDS:
            raise CatalogError(f"{context} has unsupported target/flavor pair: {pair}")
        path = _nonempty_text(raw["path"], f"{context}.path", 160)
        if not PACKAGE_SHARD_PATH_RE.fullmatch(path) or path != EXPECTED_PACKAGE_SHARDS[pair]:
            raise CatalogError(f"{context}.path is outside the package shard allow-list")
        digest = _nonempty_text(raw["sha256"], f"{context}.sha256", 64)
        if not SHA256_RE.fullmatch(digest):
            raise CatalogError(f"{context}.sha256 is invalid")
        package_count = raw["package_count"]
        selectable_count = raw["selectable_count"]
        if type(package_count) is not int or not 1 <= package_count <= MAX_PACKAGE_RECORDS:
            raise CatalogError(f"{context}.package_count must be an integer from 1 to MAX_PACKAGE_RECORDS")
        if type(selectable_count) is not int or not 0 <= selectable_count <= package_count:
            raise CatalogError(f"{context}.selectable_count is invalid")
        raw_sources = raw["sources"]
        if not isinstance(raw_sources, list) or not 1 <= len(raw_sources) <= 16:
            raise CatalogError(f"{context}.sources must contain 1 to 16 entries")
        sources: list[dict[str, str]] = []
        source_feeds: set[str] = set()
        source_urls: set[str] = set()
        for source_position, source in enumerate(raw_sources):
            source_context = f"{context}.sources[{source_position}]"
            if not isinstance(source, dict):
                raise CatalogError(f"{source_context} must be an object")
            feed = _identifier(source["feed"], f"{source_context}.feed")
            if feed not in PACKAGE_FEEDS | {COMMUNITY_FEED} or feed in source_feeds:
                raise CatalogError(f"{source_context}.feed is invalid or duplicated")
            if feed == COMMUNITY_FEED:
                _exact_keys(source, COMMUNITY_PACKAGE_SOURCE_KEYS, source_context)
                if pair != ("xiaomi_ax9000", "official"):
                    raise CatalogError("kiddin9 metadata is allowed only for AX9000 official")
                url = _community_packages_url(source["url"], f"{source_context}.url")
                if source["metadata_format"] != "opkg-packages-gzip":
                    raise CatalogError(f"{source_context}.metadata_format is invalid")
                if source["metadata_signed"] is not False:
                    raise CatalogError(f"{source_context} must remain explicitly unsigned")
                expected_community_source = {
                    "feed": community_lock["KIDDIN9_FEED"],
                    "url": community_lock["KIDDIN9_PACKAGES_URL"],
                    "sha256": community_lock["KIDDIN9_PACKAGES_SHA256"],
                    "metadata_format": "opkg-packages-gzip",
                    "metadata_signed": False,
                    "candidate_repository": community_lock["KIDDIN9_REPO"],
                    "candidate_commit": community_lock["KIDDIN9_COMMIT"],
                    "catalog_sha256": community_lock["KIDDIN9_CATALOG_SHA256"],
                }
                if source != expected_community_source:
                    raise CatalogError(f"{source_context} differs from the reviewed community lock")
            else:
                _exact_keys(source, OFFICIAL_PACKAGE_SOURCE_KEYS, source_context)
                url = _official_packages_url(source["url"], f"{source_context}.url")
            if url in source_urls:
                raise CatalogError(f"duplicate package source URL: {url}")
            source_digest = _nonempty_text(source["sha256"], f"{source_context}.sha256", 64)
            if not SHA256_RE.fullmatch(source_digest):
                raise CatalogError(f"{source_context}.sha256 is invalid")
            source_feeds.add(feed)
            source_urls.add(url)
            sources.append(dict(source))
        if pair == ("xiaomi_ax9000", "nss"):
            expected_feeds = {"base", "luci", "packages", "routing", "telephony", "video"}
        elif pair == ("xiaomi_ax9000", "official"):
            expected_feeds = PACKAGE_FEEDS | {COMMUNITY_FEED}
        else:
            expected_feeds = PACKAGE_FEEDS
        if source_feeds != expected_feeds:
            raise CatalogError(f"{context}.sources feeds differ from the target/flavor contract")
        if pair in seen_pairs or path in seen_paths:
            raise CatalogError(f"duplicate package shard descriptor: {pair}")
        seen_pairs.add(pair)
        seen_paths.add(path)
        descriptors.append(
            {
                "target": target,
                "flavor": flavor,
                "path": path,
                "sha256": digest,
                "package_count": package_count,
                "selectable_count": selectable_count,
                "sources": sources,
            }
        )
    if seen_pairs != set(EXPECTED_PACKAGE_SHARDS):
        raise CatalogError("package catalog is missing required target/flavor shards")
    return {
        "schema_version": 3,
        "catalog_version": payload["catalog_version"],
        "openwrt_version": payload["openwrt_version"],
        "purpose_catalog": {
            "locale": "zh-CN",
            "path": PACKAGE_PURPOSE_CATALOG_RELATIVE_PATH,
            "sha256": purpose_digest,
            "package_count": purpose_count,
        },
        "shards": descriptors,
    }


def load_package_catalog_index(catalog: dict[str, Any]) -> dict[str, Any]:
    payload, _digest = _load_repository_json(
        PACKAGE_CATALOG_PATH,
        ROOT / "components",
        "package catalog",
        MAX_PACKAGE_CATALOG_BYTES,
    )
    return validate_package_catalog_index(payload, catalog)


def validate_package_shard(
    payload: Any, descriptor: dict[str, Any], catalog: dict[str, Any]
) -> dict[str, Any]:
    """Validate one exact target/flavor package shard."""
    if not isinstance(payload, dict):
        raise CatalogError("package shard root must be an object")
    _exact_keys(payload, PACKAGE_SHARD_KEYS, "package shard")
    if type(payload["schema_version"]) is not int or payload["schema_version"] != 2:
        raise CatalogError("package shard schema_version must be integer 2")
    if payload["catalog_version"] != catalog["catalog_version"]:
        raise CatalogError("package shard version differs from component catalog")
    if payload["target"] != descriptor["target"] or payload["flavor"] != descriptor["flavor"]:
        raise CatalogError("package shard target/flavor differs from root index")
    raw_packages = payload["packages"]
    if not isinstance(raw_packages, list) or len(raw_packages) != descriptor["package_count"]:
        raise CatalogError("package shard package_count differs from root index")
    if len(raw_packages) > MAX_PACKAGE_RECORDS:
        raise CatalogError(f"package shard exceeds {MAX_PACKAGE_RECORDS} records")

    category_ids = {category["id"] for category in catalog["categories"]}
    bundle_ids = {component["id"] for component in catalog["components"]}
    allowed_feeds = {source["feed"] for source in descriptor["sources"]}
    allowed_arches = allowed_architectures_for(
        descriptor["target"], descriptor["flavor"]
    )
    records: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_packages: set[tuple[str, str]] = set()
    official_packages = frozenset(
        raw.get("package")
        for raw in raw_packages
        if isinstance(raw, dict) and raw.get("source") == "official" and isinstance(raw.get("package"), str)
    )
    selectable_count = 0
    for position, raw in enumerate(raw_packages):
        context = f"package shard packages[{position}]"
        if not isinstance(raw, dict):
            raise CatalogError(f"{context} must be an object")
        _exact_keys(raw, PACKAGE_RECORD_KEYS, context)
        package_id = _nonempty_text(raw["id"], f"{context}.id", 20)
        if not PACKAGE_ID_RE.fullmatch(package_id) or package_id in bundle_ids:
            raise CatalogError(f"{context}.id is invalid")
        package = _openwrt_name(raw["package"], f"{context}.package")
        source = _identifier(raw["source"], f"{context}.source")
        if source not in {"official", "kiddin9"}:
            raise CatalogError(f"{context}.source is invalid")
        expected_id = "pkg-" + hashlib.sha256(
            (package if source == "official" else f"{source}\0{package}").encode("utf-8")
        ).hexdigest()[:16]
        if package_id != expected_id:
            raise CatalogError(f"{context}.id does not match its package name")
        version = _nonempty_text(raw["version"], f"{context}.version", 160)
        description = _nonempty_text(raw["description"], f"{context}.description", 1000)
        feed = _identifier(raw["feed"], f"{context}.feed")
        if feed not in allowed_feeds:
            raise CatalogError(f"{context}.feed is not declared by the shard")
        if (source == "kiddin9") != (feed == COMMUNITY_FEED):
            raise CatalogError(f"{context}.source does not match its feed")
        if source == "kiddin9" and (
            descriptor["target"], descriptor["flavor"]
        ) != ("xiaomi_ax9000", "official"):
            raise CatalogError(f"{context} enables community packages outside AX9000 official")
        installed_size = raw["installed_size"]
        if type(installed_size) is not int or not 0 <= installed_size <= 2**63 - 1:
            raise CatalogError(f"{context}.installed_size is invalid")
        category = _identifier(raw["category"], f"{context}.category")
        if category not in category_ids or category != PACKAGE_FEED_CATEGORIES[feed]:
            raise CatalogError(f"{context}.category does not match its feed")
        arch = _openwrt_name(raw["arch"], f"{context}.arch")
        if arch not in allowed_arches:
            raise CatalogError(
                f"{context}.arch violates the {descriptor['target']}/{descriptor['flavor']} policy"
            )
        risk = _nonempty_text(raw["risk"], f"{context}.risk", 16)
        selectable = raw["selectable"]
        if type(selectable) is not bool:
            raise CatalogError(f"{context}.selectable must be boolean")
        blocked_reason = _optional_text(
            raw["blocked_reason"], f"{context}.blocked_reason", 240
        )
        expected_reason = blocked_reason_for_record(
            package,
            source,
            duplicates_official=source == "kiddin9" and package in official_packages,
        )
        expected_selectable = not expected_reason
        expected_risk = risk_for(package, feed)
        if blocked_reason != expected_reason:
            raise CatalogError(f"{context}.blocked_reason differs from the shared policy")
        if selectable != expected_selectable:
            raise CatalogError(f"{context}.selectable differs from the shared policy")
        if risk != expected_risk:
            raise CatalogError(f"{context}.risk differs from the shared policy")
        if package.startswith("kmod-") and descriptor["flavor"] != "official":
            raise CatalogError(f"{context} violates the official-only kmod policy")
        if descriptor["flavor"] == "nss" and (
            arch != "noarch" or feed in {"target", "kmods"}
        ):
            raise CatalogError(f"{context} violates the NSS userspace-only policy")
        package_key = (source, package)
        if package_id in seen_ids or package_key in seen_packages:
            raise CatalogError(f"duplicate package record: {source}/{package}")
        seen_ids.add(package_id)
        seen_packages.add(package_key)
        selectable_count += int(selectable)
        records.append(
            {
                "id": package_id,
                "package": package,
                "version": version,
                "description": description,
                "feed": feed,
                "source": source,
                "installed_size": installed_size,
                "category": category,
                "arch": arch,
                "risk": risk,
                "selectable": selectable,
                "blocked_reason": blocked_reason,
            }
        )
    expected_order = sorted(
        records,
        key=lambda item: (item["package"], item["source"], item["version"], item["id"]),
    )
    if records != expected_order:
        raise CatalogError("package shard is not deterministically sorted")
    community_source = next(
        (source for source in descriptor["sources"] if source["feed"] == COMMUNITY_FEED),
        None,
    )
    community_records = [record for record in records if record["source"] == "kiddin9"]
    if community_source is None:
        if community_records:
            raise CatalogError("package shard contains undeclared community candidates")
    elif _community_catalog_sha256(community_records) != community_source["catalog_sha256"]:
        raise CatalogError("community candidate projection differs from its reviewed lock")
    if selectable_count != descriptor["selectable_count"]:
        raise CatalogError("package shard selectable_count differs from root index")
    return {
        "schema_version": 2,
        "catalog_version": payload["catalog_version"],
        "target": payload["target"],
        "flavor": payload["flavor"],
        "packages": records,
    }


def load_package_shard(
    index: dict[str, Any], catalog: dict[str, Any], target_id: str, flavor_id: str
) -> dict[str, Any]:
    descriptor = next(
        (
            item
            for item in index["shards"]
            if item["target"] == target_id and item["flavor"] == flavor_id
        ),
        None,
    )
    if descriptor is None:
        raise RequestError(f"no package shard for {target_id}/{flavor_id}")
    relative_path = descriptor["path"]
    if not PACKAGE_SHARD_PATH_RE.fullmatch(relative_path):
        raise CatalogError("package shard path is outside the repository allow-list")
    shard_path = ROOT / relative_path
    payload, actual_digest = _load_repository_json(
        shard_path,
        PACKAGE_SHARD_ROOT,
        f"package shard {target_id}/{flavor_id}",
        MAX_PACKAGE_SHARD_BYTES,
    )
    if actual_digest != descriptor["sha256"]:
        raise CatalogError(
            f"package shard SHA256 mismatch for {target_id}/{flavor_id}: "
            f"expected {descriptor['sha256']}, got {actual_digest}"
        )
    return validate_package_shard(payload, descriptor, catalog)

def _component_closure(
    component_index: dict[str, dict[str, Any]], selected: Iterable[str]
) -> set[str]:
    resolved: set[str] = set()

    def include(component_id: str) -> None:
        if component_id in resolved:
            return
        resolved.add(component_id)
        for dependency in component_index[component_id]["depends"]:
            include(dependency)

    for component_id in selected:
        include(component_id)
    return resolved


def _kconfig_fragment(target: dict[str, Any], packages: list[str]) -> str:
    lines = [
        f"CONFIG_TARGET_{target['openwrt_target']}=y",
        f"CONFIG_TARGET_{target['openwrt_target']}_{target['openwrt_subtarget']}=y",
        (
            f"CONFIG_TARGET_{target['openwrt_target']}_{target['openwrt_subtarget']}"
            f"_DEVICE_{target['profile']}=y"
        ),
    ]
    lines.extend(f"CONFIG_PACKAGE_{package}=y" for package in packages)
    return "\n".join(lines) + "\n"


def resolve_components(
    catalog: dict[str, Any],
    target_id: str,
    flavor_id: str,
    requested_components: Iterable[str],
    *,
    include_defaults: bool = True,
) -> dict[str, Any]:
    """Resolve allow-listed bundle and official package IDs into build inputs."""
    target_index = {target["id"]: target for target in catalog["targets"]}
    component_index = {component["id"]: component for component in catalog["components"]}

    if not isinstance(target_id, str) or target_id not in target_index:
        raise RequestError(f"unknown target: {target_id!r}")
    if not isinstance(flavor_id, str) or flavor_id not in ALLOWED_FLAVORS:
        raise RequestError(f"unknown flavor: {flavor_id!r}")
    if flavor_id == "nss" and target_id != "xiaomi_ax9000":
        raise RequestError("nss flavor is supported only for xiaomi_ax9000")
    if isinstance(requested_components, (str, bytes)):
        raise RequestError("components must be supplied as a list of component IDs")
    requested = list(requested_components)
    if any(not isinstance(item, str) for item in requested):
        raise RequestError("component IDs must be strings")
    maximum = catalog["max_selected_components"]
    if len(requested) > maximum:
        raise RequestError(
            f"selection contains {len(requested)} components; maximum is {maximum}"
        )
    if len(set(requested)) != len(requested):
        raise RequestError("duplicate component selection")

    package_catalog = load_package_catalog_index(catalog)
    package_shard = load_package_shard(
        package_catalog, catalog, target_id, flavor_id
    )
    package_index = {item["id"]: item for item in package_shard["packages"]}
    overlap = sorted(set(component_index) & set(package_index))
    if overlap:
        raise CatalogError(f"bundle and package IDs overlap: {overlap}")

    known_ids = set(component_index) | set(package_index)
    unknown = sorted(set(requested) - known_ids)
    if unknown:
        raise RequestError(f"unknown component selection: {unknown}")
    requested_bundles = sorted(item for item in requested if item in component_index)
    requested_packages = sorted(item for item in requested if item in package_index)
    blocked = [package_index[item] for item in requested_packages if not package_index[item]["selectable"]]
    if blocked:
        details = [f"{item['package']}: {item['blocked_reason']}" for item in blocked]
        raise RequestError(f"package selection is blocked: {details}")

    community_packages = sorted(
        package_index[item]["package"]
        for item in requested_packages
        if package_index[item]["source"] == "kiddin9"
    )
    if community_packages and (target_id, flavor_id) != ("xiaomi_ax9000", "official"):
        raise RequestError("community packages are supported only by AX9000 official builds")

    defaults = sorted(
        component["id"]
        for component in catalog["components"]
        if include_defaults and target_id in component["default_for"]
    )
    resolved_bundles = _component_closure(
        component_index, set(requested_bundles) | set(defaults)
    )
    resolved = resolved_bundles | set(requested_packages)

    unsupported = sorted(
        component_id
        for component_id in resolved_bundles
        if target_id not in component_index[component_id]["supported_targets"]
    )
    if unsupported:
        raise RequestError(f"components are unsupported on {target_id}: {unsupported}")

    conflicts: set[tuple[str, str]] = set()
    for component_id in resolved_bundles:
        for conflict_id in component_index[component_id]["conflicts"]:
            if conflict_id in resolved_bundles:
                conflicts.add(tuple(sorted((component_id, conflict_id))))
    if conflicts:
        pairs = [f"{left}<->{right}" for left, right in sorted(conflicts)]
        raise RequestError(f"conflicting component selection: {pairs}")

    requested_ids = sorted(requested)
    resolved_ids = sorted(resolved)
    packages = sorted(
        {
            *(
                package
                for component_id in resolved_bundles
                for package in component_index[component_id]["packages"]
            ),
            *(package_index[package_id]["package"] for package_id in requested_packages),
        }
    )
    target = target_index[target_id]
    hash_payload = {
        "schema_version": REQUEST_SCHEMA_VERSION,
        "catalog_version": catalog["catalog_version"],
        "target": target_id,
        "flavor": flavor_id,
        "requested_components": requested_ids,
        "default_components": defaults,
        "resolved_components": resolved_ids,
        "packages": packages,
        "community_packages": community_packages,
    }
    canonical = json.dumps(
        hash_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    request_hash = hashlib.sha256(canonical).hexdigest()

    return {
        "schema_version": REQUEST_SCHEMA_VERSION,
        "catalog_version": catalog["catalog_version"],
        "target": {
            "id": target["id"],
            "openwrt_target": target["openwrt_target"],
            "openwrt_subtarget": target["openwrt_subtarget"],
            "profile": target["profile"],
        },
        "flavor": flavor_id,
        "requested_components": requested_ids,
        "default_components": defaults,
        "resolved_components": resolved_ids,
        "packages": packages,
        "community_packages": community_packages,
        "community_feed_required": bool(community_packages),
        "imagebuilder_packages": " ".join(packages),
        "kconfig_fragment": _kconfig_fragment(target, packages),
        "request_hash": request_hash,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Resolve allow-listed NexaWrt components into deterministic build inputs."
    )
    parser.add_argument("--target", required=True, help="Catalog target ID")
    parser.add_argument(
        "--flavor",
        required=True,
        choices=sorted(ALLOWED_FLAVORS),
        help="Build flavor; nss is valid only for xiaomi_ax9000",
    )
    parser.add_argument(
        "--component",
        action="append",
        default=[],
        metavar="ID",
        help="Allow-listed component ID; repeat for multiple selections",
    )
    parser.add_argument(
        "--no-defaults",
        action="store_true",
        help="Do not add catalog defaults for the selected target",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        result = resolve_components(
            load_catalog(),
            arguments.target,
            arguments.flavor,
            arguments.component,
            include_defaults=not arguments.no_defaults,
        )
    except (CatalogError, RequestError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False, sort_keys=True), file=sys.stderr)
        return 2
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
