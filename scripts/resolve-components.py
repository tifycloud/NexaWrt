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
import re
import stat
import sys
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "components" / "catalog.json"
REQUEST_SCHEMA_VERSION = 1
REQUIRED_TARGETS = {"x86_64", "xiaomi_ax9000"}
ALLOWED_FLAVORS = {"official", "nss"}

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
    expected_parent = (ROOT / "components").resolve(strict=True)
    if CATALOG_PATH.parent.resolve(strict=True) != expected_parent:
        raise CatalogError("catalog parent is outside the components allow-list")
    file_stat = CATALOG_PATH.lstat()
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise CatalogError("catalog must be a regular, non-symlink file")
    if file_stat.st_nlink != 1:
        raise CatalogError("catalog must not be hard-linked")
    try:
        with CATALOG_PATH.open("r", encoding="utf-8") as handle:
            payload = json.load(handle, object_pairs_hook=_reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CatalogError(f"unable to load component catalog: {error}") from error
    return validate_catalog(payload)


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
    """Resolve a component selection without accepting package or shell input."""
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
    unknown = sorted(set(requested) - set(component_index))
    if unknown:
        raise RequestError(f"unknown component selection: {unknown}")

    defaults = sorted(
        component["id"]
        for component in catalog["components"]
        if include_defaults and target_id in component["default_for"]
    )
    initial = set(requested) | set(defaults)
    resolved = _component_closure(component_index, initial)
    if len(resolved) > maximum:
        raise RequestError(
            f"selection resolves to {len(resolved)} components; maximum is {maximum}"
        )

    unsupported = sorted(
        component_id
        for component_id in resolved
        if target_id not in component_index[component_id]["supported_targets"]
    )
    if unsupported:
        raise RequestError(f"components are unsupported on {target_id}: {unsupported}")

    conflicts: set[tuple[str, str]] = set()
    for component_id in resolved:
        for conflict_id in component_index[component_id]["conflicts"]:
            if conflict_id in resolved:
                conflicts.add(tuple(sorted((component_id, conflict_id))))
    if conflicts:
        pairs = [f"{left}<->{right}" for left, right in sorted(conflicts)]
        raise RequestError(f"conflicting component selection: {pairs}")

    resolved_ids = sorted(resolved)
    packages = sorted(
        {
            package
            for component_id in resolved_ids
            for package in component_index[component_id]["packages"]
        }
    )
    target = target_index[target_id]
    hash_payload = {
        "schema_version": REQUEST_SCHEMA_VERSION,
        "catalog_version": catalog["catalog_version"],
        "target": target_id,
        "components": resolved_ids,
        "flavor": flavor_id,
        "packages": packages,
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
        "requested_components": sorted(requested),
        "default_components": defaults,
        "resolved_components": resolved_ids,
        "packages": packages,
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
