#!/usr/bin/env python3
"""Policy tests for the fixed AX9000 device metadata contract."""

from __future__ import annotations

import copy
import importlib.util
import json
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts/device_metadata.py"
SPEC = importlib.util.spec_from_file_location("device_metadata", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("unable to load device metadata module")
device_metadata = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(device_metadata)


def expect_rejected(payload: dict, root: Path, label: str) -> None:
    path = root / f"{label}.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    try:
        device_metadata.load_device_metadata(path, project_root=root)
    except ValueError:
        return
    raise AssertionError(f"invalid metadata unexpectedly accepted: {label}")


canonical = device_metadata.load_device_metadata()
assert canonical["id"] == "xiaomi-ax9000"
assert canonical["hardware_status"] == "unverified"
assert canonical["production_ready"] is False
assert canonical["image_capabilities"] == {"ram_boot": True, "factory": False, "sysupgrade": False}
for flavor in ("official", "nss"):
    device_metadata.validate_request(canonical, device="xiaomi-ax9000", flavor=flavor, channel="ram-test")
for kwargs in (
    {"device": "other", "flavor": "official", "channel": "ram-test"},
    {"device": "xiaomi-ax9000", "flavor": "unknown", "channel": "ram-test"},
    {"device": "xiaomi-ax9000", "flavor": "official", "channel": "stable"},
):
    try:
        device_metadata.validate_request(canonical, **kwargs)
    except ValueError:
        pass
    else:
        raise AssertionError(f"invalid request unexpectedly accepted: {kwargs}")

public = device_metadata.public_device(canonical)
assert set(public) == {
    "schema", "id", "display_name", "vendor", "model", "target", "subtarget", "profile",
    "hardware_status", "production_ready", "website_visible", "image_capabilities", "flavors",
    "channels", "browser_build_workflow_url", "recovery_url", "testing_url",
}
assert public["recovery_url"] == "https://github.com/tifycloud/NexaWrt/blob/main/docs/RECOVERY.md"
assert public["testing_url"] == "https://github.com/tifycloud/NexaWrt/blob/main/docs/TESTING.md"

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "docs").mkdir()
    (root / "docs/RECOVERY.md").write_text("recovery\n", encoding="utf-8")
    (root / "docs/TESTING.md").write_text("testing\n", encoding="utf-8")
    valid_path = root / "valid.json"
    valid_path.write_text(json.dumps(canonical), encoding="utf-8")
    assert device_metadata.load_device_metadata(valid_path, project_root=root) == canonical

    mutations = {
        "production-ready": ("production_ready", True),
        "hardware-verified": ("hardware_status", "verified"),
        "factory-enabled": ("image_capabilities.factory", True),
        "sysupgrade-enabled": ("image_capabilities.sysupgrade", True),
        "wrong-workflow": ("browser_build_workflow_url", "https://attacker.invalid/build.yml"),
        "stable-channel": ("channels", ["ram-test", "stable"]),
        "extra-key": ("extra", "unexpected"),
        "hidden": ("website_visible", False),
        "wrong-model": ("model", "AX9001"),
        "wrong-profile": ("profile", "other_profile"),
        "different-doc": ("docs.recovery", "docs/OTHER.md"),
        "unsafe-doc": ("docs.recovery", "docs/../README.md"),
    }
    for label, (field, value) in mutations.items():
        payload = copy.deepcopy(canonical)
        target = payload
        parts = field.split(".")
        for part in parts[:-1]:
            target = target[part]
        target[parts[-1]] = value
        expect_rejected(payload, root, label)

    duplicate = root / "duplicate.json"
    duplicate.write_text('{"schema":1,"schema":1}', encoding="utf-8")
    try:
        device_metadata.load_device_metadata(duplicate, project_root=root)
    except ValueError:
        pass
    else:
        raise AssertionError("duplicate JSON key unexpectedly accepted")

    symlink = root / "metadata-link.json"
    symlink.symlink_to(valid_path)
    try:
        device_metadata.load_device_metadata(symlink, project_root=root)
    except ValueError:
        pass
    else:
        raise AssertionError("symlink metadata unexpectedly accepted")

    hardlink = root / "metadata-hardlink.json"
    os.link(valid_path, hardlink)
    try:
        device_metadata.load_device_metadata(hardlink, project_root=root)
    except ValueError:
        pass
    else:
        raise AssertionError("hard-linked metadata unexpectedly accepted")

print("Device metadata policy: fixed AX9000 RAM-only non-production catalog OK")
