#!/usr/bin/env python3
"""Tests for the closed NexaWrt component catalog and resolver contract."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "resolve-components.py"
SPEC = importlib.util.spec_from_file_location("resolve_components", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("unable to load component resolver")
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)


def expect_catalog_rejected(payload: dict, label: str) -> None:
    try:
        resolver.validate_catalog(payload)
    except resolver.CatalogError:
        return
    raise AssertionError(f"invalid catalog unexpectedly accepted: {label}")


def expect_request_rejected(
    catalog: dict,
    target: str,
    components: list[str],
    label: str,
    *,
    flavor: str = "official",
    include_defaults: bool = True,
) -> None:
    try:
        resolver.resolve_components(
            catalog, target, flavor, components, include_defaults=include_defaults
        )
    except resolver.RequestError:
        return
    raise AssertionError(f"invalid request unexpectedly accepted: {label}")


catalog = resolver.load_catalog()
assert catalog["schema_version"] == 1
assert catalog["catalog_version"] == "2026.07.20"
assert catalog["max_selected_components"] == 8
assert {target["id"] for target in catalog["targets"]} >= {
    "x86_64",
    "xiaomi_ax9000",
}
assert all(component["category"] for component in catalog["components"])
assert all(component["packages"] for component in catalog["components"])
assert all("depends" in component and "conflicts" in component for component in catalog["components"])
assert all(component["supported_targets"] for component in catalog["components"])
assert any(component["default_for"] for component in catalog["components"])

x86 = resolver.resolve_components(catalog, "x86_64", "official", ["wireguard"])
assert x86["flavor"] == "official"
assert x86["requested_components"] == ["wireguard"]
assert x86["default_components"] == ["diagnostic-tools", "web-ui"]
assert x86["resolved_components"] == ["diagnostic-tools", "web-ui", "wireguard"]
assert x86["target"] == {
    "id": "x86_64",
    "openwrt_target": "x86",
    "openwrt_subtarget": "64",
    "profile": "generic",
}
assert x86["imagebuilder_packages"] == " ".join(x86["packages"])
assert "CONFIG_TARGET_x86_64_DEVICE_generic=y\n" in x86["kconfig_fragment"]
assert "CONFIG_PACKAGE_kmod-wireguard=y\n" in x86["kconfig_fragment"]
assert len(x86["request_hash"]) == 64
assert set(x86["request_hash"]) <= set("0123456789abcdef")
assert x86["request_hash"] == "2aeca1c0914e74fa52c7e7748a5e3870e510a91883b1f647312addf678f966cf"
assert json.loads(json.dumps(x86, ensure_ascii=False, sort_keys=True)) == x86

ax9000 = resolver.resolve_components(catalog, "xiaomi_ax9000", "official", [])
assert ax9000["default_components"] == ["web-ui"]
assert ax9000["resolved_components"] == ["web-ui"]
assert ax9000["target"] == {
    "id": "xiaomi_ax9000",
    "openwrt_target": "qualcommax",
    "openwrt_subtarget": "ipq807x",
    "profile": "xiaomi_ax9000",
}
assert "CONFIG_TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax9000=y\n" in ax9000[
    "kconfig_fragment"
]

without_defaults = resolver.resolve_components(
    catalog, "x86_64", "official", ["ksmbd"], include_defaults=False
)
assert without_defaults["default_components"] == []
assert without_defaults["resolved_components"] == ["ksmbd", "usb-storage", "web-ui"]

first = resolver.resolve_components(catalog, "x86_64", "official", ["wireguard", "adblock"])
second = resolver.resolve_components(catalog, "x86_64", "official", ["adblock", "wireguard"])
assert first["request_hash"] == second["request_hash"]
assert first["resolved_components"] == second["resolved_components"]
assert first["packages"] == second["packages"]
nss = resolver.resolve_components(catalog, "xiaomi_ax9000", "nss", ["wireguard"])
official = resolver.resolve_components(catalog, "xiaomi_ax9000", "official", ["wireguard"])
assert nss["request_hash"] != official["request_hash"]
assert nss["flavor"] == "nss"

expect_request_rejected(catalog, "unknown", [], "unknown-target")
expect_request_rejected(catalog, "x86_64", [], "unknown-flavor", flavor="preview")
expect_request_rejected(catalog, "x86_64", [], "nss-x86", flavor="nss")
expect_request_rejected(catalog, "x86_64", ["not-in-catalog"], "unknown-component")
expect_request_rejected(catalog, "x86_64", ["wireguard", "wireguard"], "duplicate")
expect_request_rejected(catalog, "x86_64", ["sqm", "qosify"], "conflict")
expect_request_rejected(catalog, "xiaomi_ax9000", ["pppoe-server"], "unsupported-target")
expect_request_rejected(
    catalog,
    "x86_64",
    [
        "web-ui",
        "diagnostic-tools",
        "wireguard",
        "sqm",
        "adblock",
        "usb-storage",
        "ksmbd",
        "pppoe-server",
        "usb-printer",
    ],
    "too-many-explicit-selections",
)
expect_request_rejected(
    catalog,
    "x86_64",
    [
        "wireguard",
        "sqm",
        "adblock",
        "usb-storage",
        "ksmbd",
        "pppoe-server",
        "usb-printer",
    ],
    "too-many-after-defaults-and-dependencies",
)
expect_request_rejected(catalog, "x86_64", ["curl;touch-/tmp/pwned"], "shell-like-input")
try:
    resolver.resolve_components(catalog, "x86_64", "official", "wireguard")
except resolver.RequestError:
    pass
else:
    raise AssertionError("string component container unexpectedly accepted")

mutations: dict[str, dict] = {}
extra = copy.deepcopy(catalog)
extra["unexpected"] = True
mutations["extra-top-level-key"] = extra

bad_package = copy.deepcopy(catalog)
bad_package["components"][0]["packages"][0] = "curl;id"
mutations["shell-package"] = bad_package

unknown_dependency = copy.deepcopy(catalog)
unknown_dependency["components"][0]["depends"] = ["missing"]
mutations["unknown-dependency"] = unknown_dependency

asymmetric = copy.deepcopy(catalog)
for component in asymmetric["components"]:
    if component["id"] == "qosify":
        component["conflicts"] = []
mutations["asymmetric-conflict"] = asymmetric

cycle = copy.deepcopy(catalog)
for component in cycle["components"]:
    if component["id"] == "web-ui":
        component["depends"] = ["wireguard"]
mutations["dependency-cycle"] = cycle

unsupported_default = copy.deepcopy(catalog)
for component in unsupported_default["components"]:
    if component["id"] == "pppoe-server":
        component["default_for"] = ["xiaomi_ax9000"]
mutations["unsupported-default"] = unsupported_default

missing_target = copy.deepcopy(catalog)
missing_target["targets"] = [
    target for target in missing_target["targets"] if target["id"] != "xiaomi_ax9000"
]
mutations["missing-required-target"] = missing_target

duplicate_component = copy.deepcopy(catalog)
duplicate_component["components"].append(copy.deepcopy(duplicate_component["components"][0]))
mutations["duplicate-component-id"] = duplicate_component

for mutation_label, mutation in mutations.items():
    expect_catalog_rejected(mutation, mutation_label)

try:
    json.loads('{"schema_version":1,"schema_version":1}', object_pairs_hook=resolver._reject_duplicate_keys)
except resolver.CatalogError:
    pass
else:
    raise AssertionError("duplicate JSON key unexpectedly accepted")

allowed_cli_destinations = {
    action.dest for action in resolver._parser()._actions if action.dest != "help"
}
assert allowed_cli_destinations == {"target", "flavor", "component", "no_defaults"}

completed = subprocess.run(
    [
        sys.executable,
        str(MODULE_PATH),
        "--target",
        "xiaomi_ax9000",
        "--flavor",
        "nss",
        "--component",
        "wireguard",
    ],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
)
cli_payload = json.loads(completed.stdout)
assert cli_payload == resolver.resolve_components(catalog, "xiaomi_ax9000", "nss", ["wireguard"])

for forbidden_arguments in (
    ["--package", "curl"],
    ["--catalog", "/tmp/catalog.json"],
    ["--script", "echo owned"],
):
    rejected = subprocess.run(
        [sys.executable, str(MODULE_PATH), "--target", "x86_64", "--flavor", "official", *forbidden_arguments],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert rejected.returncode == 2

print("Component catalog policy: strict allow-list, deterministic resolver, and safe outputs OK")
