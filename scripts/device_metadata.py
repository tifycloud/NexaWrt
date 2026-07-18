#!/usr/bin/env python3
"""Validate the fixed NexaWrt device catalog and requested build identity."""

from __future__ import annotations

import argparse
import json
import re
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote

REPOSITORY = "tifycloud/NexaWrt"
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEVICE_METADATA_PATH = PROJECT_ROOT / "devices/xiaomi-ax9000/device.json"
MAX_METADATA_BYTES = 64 * 1024
EXPECTED_DEVICE = {
    "id": "xiaomi-ax9000",
    "display_name": "Xiaomi AX9000",
    "vendor": "Xiaomi",
    "model": "AX9000",
    "target": "qualcommax",
    "subtarget": "ipq807x",
    "profile": "xiaomi_ax9000",
}
EXPECTED_WORKFLOW_URL = f"https://github.com/{REPOSITORY}/actions/workflows/build.yml"
EXPECTED_DOCS = {"recovery": "docs/RECOVERY.md", "testing": "docs/TESTING.md"}
EXPECTED_KEYS = {
    "schema",
    "id",
    "display_name",
    "vendor",
    "model",
    "target",
    "subtarget",
    "profile",
    "hardware_status",
    "production_ready",
    "website_visible",
    "image_capabilities",
    "flavors",
    "channels",
    "browser_build_workflow_url",
    "docs",
}
IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9]+(?:[-_][a-z0-9]+)*$")
DISPLAY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,63}$")
MODEL_PATTERN = re.compile(r"^[A-Z0-9][A-Z0-9._+-]{0,31}$")
DOC_PATTERN = re.compile(r"^docs/[A-Za-z0-9][A-Za-z0-9._/-]*\.md$")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate metadata key: {key}")
        result[key] = value
    return result


def _plain_file(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise ValueError(f"{label} is missing: {path}") from exc
    if path.is_symlink() or not stat.S_ISREG(info.st_mode):
        raise ValueError(f"{label} must be a regular file, not a symlink: {path}")
    if info.st_nlink != 1:
        raise ValueError(f"{label} must not be a hard link: {path}")


def _read_json(path: Path) -> Any:
    _plain_file(path, "device metadata")
    if path.stat().st_size > MAX_METADATA_BYTES:
        raise ValueError("device metadata exceeds the size limit")
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)
    except UnicodeDecodeError as exc:
        raise ValueError("device metadata must be UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"device metadata is invalid JSON: {exc.msg}") from exc


def _require_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{label} must contain exactly: {', '.join(sorted(expected))}")
    return value


def _require_string(value: Any, label: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise ValueError(f"{label} is invalid")
    return value


def _relative_document(root: Path, value: Any, label: str, verify_documents: bool) -> str:
    if not isinstance(value, str) or not DOC_PATTERN.fullmatch(value) or "\\" in value:
        raise ValueError(f"{label} must be a repository-relative docs/*.md path")
    pure = PurePosixPath(value)
    if pure.is_absolute() or ".." in pure.parts or "." in pure.parts:
        raise ValueError(f"{label} must not traverse outside docs/")
    document = root.joinpath(*pure.parts)
    if verify_documents:
        _plain_file(document, label)
    return value


def load_device_metadata(
    path: Path = DEVICE_METADATA_PATH,
    *,
    project_root: Path = PROJECT_ROOT,
    verify_documents: bool = True,
) -> dict[str, Any]:
    """Load and strictly validate the only currently supported device metadata."""

    raw = _require_exact_keys(_read_json(path), EXPECTED_KEYS, "device metadata")
    if type(raw["schema"]) is not int or raw["schema"] != 1:
        raise ValueError("device metadata schema must be integer 1")
    _require_string(raw["display_name"], "display_name", DISPLAY_PATTERN)
    _require_string(raw["vendor"], "vendor", DISPLAY_PATTERN)
    _require_string(raw["model"], "model", MODEL_PATTERN)
    for field in ("id", "target", "subtarget", "profile"):
        _require_string(raw[field], field, IDENTIFIER_PATTERN)
    for field, expected in EXPECTED_DEVICE.items():
        if raw[field] != expected:
            raise ValueError(f"{field} must be {expected}")
    if raw["hardware_status"] != "unverified":
        raise ValueError("hardware_status must remain unverified before hardware approval")
    if raw["production_ready"] is not False:
        raise ValueError("production_ready must remain false before hardware approval")
    if raw["website_visible"] is not True:
        raise ValueError("website_visible must remain true for the supported device")

    capabilities = _require_exact_keys(
        raw["image_capabilities"], {"ram_boot", "factory", "sysupgrade"}, "image_capabilities"
    )
    if capabilities != {"ram_boot": True, "factory": False, "sysupgrade": False}:
        raise ValueError("image capabilities must remain RAM-only with factory/sysupgrade disabled")

    flavors = _require_exact_keys(raw["flavors"], {"official", "nss"}, "flavors")
    for flavor, expected_experimental in (("official", False), ("nss", True)):
        settings = _require_exact_keys(flavors[flavor], {"experimental"}, f"flavors.{flavor}")
        if settings["experimental"] is not expected_experimental:
            raise ValueError(f"flavors.{flavor}.experimental is invalid")

    channels = raw["channels"]
    if channels != ["ram-test"]:
        raise ValueError("channels must contain only ram-test")
    if raw["browser_build_workflow_url"] != EXPECTED_WORKFLOW_URL:
        raise ValueError("browser_build_workflow_url is not the fixed repository workflow URL")

    docs = _require_exact_keys(raw["docs"], {"recovery", "testing"}, "docs")
    if docs != EXPECTED_DOCS:
        raise ValueError("docs must reference the fixed recovery and testing documents")
    _relative_document(project_root, docs["recovery"], "docs.recovery", verify_documents)
    _relative_document(project_root, docs["testing"], "docs.testing", verify_documents)
    return raw


def validate_request(metadata: dict[str, Any], *, device: str, flavor: str, channel: str) -> None:
    if device != metadata["id"]:
        raise ValueError(f"unsupported device: {device}")
    if flavor not in metadata["flavors"]:
        raise ValueError(f"unsupported flavor for {device}: {flavor}")
    if channel not in metadata["channels"]:
        raise ValueError(f"unsupported channel for {device}: {channel}")
    if metadata["hardware_status"] != "unverified" or metadata["production_ready"] is not False:
        raise ValueError("device production/hardware gate is inconsistent")
    if metadata["image_capabilities"] != {"ram_boot": True, "factory": False, "sysupgrade": False}:
        raise ValueError("device is not constrained to RAM-only images")


def repository_document_url(relative_path: str) -> str:
    encoded = "/".join(quote(part, safe="") for part in PurePosixPath(relative_path).parts)
    return f"https://github.com/{REPOSITORY}/blob/main/{encoded}"


def public_device(metadata: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": metadata["schema"],
        "id": metadata["id"],
        "display_name": metadata["display_name"],
        "vendor": metadata["vendor"],
        "model": metadata["model"],
        "target": metadata["target"],
        "subtarget": metadata["subtarget"],
        "profile": metadata["profile"],
        "hardware_status": metadata["hardware_status"],
        "production_ready": metadata["production_ready"],
        "website_visible": metadata["website_visible"],
        "image_capabilities": metadata["image_capabilities"],
        "flavors": metadata["flavors"],
        "channels": metadata["channels"],
        "browser_build_workflow_url": metadata["browser_build_workflow_url"],
        "recovery_url": repository_document_url(metadata["docs"]["recovery"]),
        "testing_url": repository_document_url(metadata["docs"]["testing"]),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--flavor", required=True)
    parser.add_argument("--channel", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        metadata = load_device_metadata()
        validate_request(metadata, device=args.device, flavor=args.flavor, channel=args.channel)
    except (OSError, ValueError) as exc:
        print(f"device-metadata: {exc}", file=sys.stderr)
        return 1
    print(
        f"validated device={args.device} flavor={args.flavor} channel={args.channel} "
        "hardware_status=unverified production_ready=false ram_only=true"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
