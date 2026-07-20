#!/usr/bin/env python3
"""Strictly validate committed ESXi acceptance evidence against an exact VM RC."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import urllib.parse
import uuid
from pathlib import Path, PurePosixPath
from typing import Any

RC_RE = re.compile(
    r"^vm-x86_64-(v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*))$"
)
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CHECKSUM_LINE_RE = re.compile(r"^([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)$")
LABEL_RE = re.compile(r'^([A-Z][A-Z0-9_]*)="([^"\r\n]*)"$')


class EvidenceError(ValueError):
    pass


class DuplicateKeyError(EvidenceError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, DuplicateKeyError) as exc:
        raise EvidenceError(f"cannot read strict JSON {path}: {exc}") from exc


def json_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    raise EvidenceError(f"schema uses unsupported type {expected!r}")


def resolve_ref(root_schema: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise EvidenceError(f"only local schema references are allowed: {ref}")
    current: Any = root_schema
    for raw_part in ref[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or part not in current:
            raise EvidenceError(f"unresolvable schema reference: {ref}")
        current = current[part]
    if not isinstance(current, dict):
        raise EvidenceError(f"schema reference does not resolve to an object: {ref}")
    return current


def validate_format(value: str, fmt: str, path: str) -> None:
    try:
        if fmt == "date-time":
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("timezone is missing")
        elif fmt == "ipv4":
            if not isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address):
                raise ValueError("not IPv4")
        elif fmt == "uuid":
            parsed_uuid = uuid.UUID(value)
            if str(parsed_uuid) != value.lower():
                raise ValueError("UUID is not canonical")
        elif fmt == "uri":
            parsed_uri = urllib.parse.urlsplit(value)
            if not parsed_uri.scheme or not parsed_uri.netloc:
                raise ValueError("absolute URI required")
        else:
            raise EvidenceError(f"schema uses unsupported format {fmt!r}")
    except (ValueError, ipaddress.AddressValueError) as exc:
        raise EvidenceError(f"{path}: invalid {fmt}: {value!r}") from exc


def validate_schema(instance: Any, schema: dict[str, Any], root: dict[str, Any], path: str = "$") -> None:
    if "$ref" in schema:
        if set(schema) != {"$ref"}:
            raise EvidenceError(f"schema combines unsupported siblings with $ref at {path}")
        validate_schema(instance, resolve_ref(root, schema["$ref"]), root, path)
        return

    if "type" in schema and not json_type_matches(instance, schema["type"]):
        raise EvidenceError(f"{path}: expected {schema['type']}, got {type(instance).__name__}")
    if "const" in schema and instance != schema["const"]:
        raise EvidenceError(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise EvidenceError(f"{path}: value is not in the allowed enum")

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            raise EvidenceError(f"{path}: string is shorter than minLength")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            raise EvidenceError(f"{path}: string is longer than maxLength")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            raise EvidenceError(f"{path}: string does not match required pattern")
        if "format" in schema:
            validate_format(instance, schema["format"], path)

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise EvidenceError(f"{path}: value is below minimum")
        if "maximum" in schema and instance > schema["maximum"]:
            raise EvidenceError(f"{path}: value is above maximum")

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            raise EvidenceError(f"{path}: array has too few items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise EvidenceError(f"{path}: array has too many items")
        if schema.get("uniqueItems"):
            canonical = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
            if len(canonical) != len(set(canonical)):
                raise EvidenceError(f"{path}: array items must be unique")
        item_schema = schema.get("items")
        if item_schema is not None:
            for index, item in enumerate(instance):
                validate_schema(item, item_schema, root, f"{path}[{index}]")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        missing = sorted(set(required) - set(instance))
        if missing:
            raise EvidenceError(f"{path}: missing required fields: {', '.join(missing)}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            unknown = sorted(set(instance) - set(properties))
            if unknown:
                raise EvidenceError(f"{path}: unknown fields: {', '.join(unknown)}")
        for key, child in instance.items():
            if key in properties:
                validate_schema(child, properties[key], root, f"{path}.{key}")


def expected_assets(version: str) -> list[str]:
    prefix = f"NexaWrt-x86_64-{version}"
    raw = f"{prefix}-generic-ext4-combined.img.gz"
    iso_bios = f"{prefix}-generic-image.iso"
    iso_efi = f"{prefix}-generic-image-efi.iso"
    vmdk_bios = f"{prefix}-generic-ext4-combined.vmdk"
    vmdk_efi = f"{prefix}-generic-ext4-combined-efi.vmdk"
    manifest = f"{prefix}-generic.manifest"
    return [
        raw,
        f"{raw}.sha256",
        iso_bios,
        f"{iso_bios}.sha256",
        iso_efi,
        f"{iso_efi}.sha256",
        vmdk_bios,
        f"{vmdk_bios}.sha256",
        vmdk_efi,
        f"{vmdk_efi}.sha256",
        manifest,
        "artifact-labels.env",
        "README-VM.txt",
        "smoke-report.txt",
        "SHA256SUMS",
        "raw-bios.provenance.bundle.json",
        "iso-bios.provenance.bundle.json",
        "iso-efi.provenance.bundle.json",
        "vmdk-bios.provenance.bundle.json",
        "vmdk-efi.provenance.bundle.json",
        "checksums.provenance.bundle.json",
    ]


def expected_checksum_entries(version: str) -> list[str]:
    return expected_assets(version)[:15 - 1]  # first 14 assets; SHA256SUMS cannot hash itself


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_safe_repo_evidence(repo_root: Path, raw_path: str) -> Path:
    if not raw_path or "\\" in raw_path or "\x00" in raw_path:
        raise EvidenceError("evidence path must be a non-empty POSIX path")
    pure = PurePosixPath(raw_path)
    if pure.is_absolute() or pure.as_posix() != raw_path:
        raise EvidenceError("evidence path must be a normalized repository-relative POSIX path")
    if any(part in ("", ".", "..") for part in pure.parts):
        raise EvidenceError("evidence path contains an unsafe component")
    if len(pure.parts) < 3 or pure.parts[:2] != ("evidence", "vm-esxi") or pure.suffix != ".json":
        raise EvidenceError("evidence must be a JSON file below evidence/vm-esxi/")

    root = repo_root.resolve(strict=True)
    current = root
    for part in pure.parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as exc:
            raise EvidenceError(f"evidence path does not exist: {raw_path}") from exc
        if stat.S_ISLNK(mode):
            raise EvidenceError(f"evidence path may not contain symlinks: {raw_path}")
    candidate = current.resolve(strict=True)
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise EvidenceError("evidence path escapes the repository") from exc
    if not candidate.is_file():
        raise EvidenceError("evidence path is not a regular file")

    commands = [
        ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", raw_path],
        ["git", "-C", str(root), "diff", "--quiet", "HEAD", "--", raw_path],
        ["git", "-C", str(root), "diff", "--cached", "--quiet", "--", raw_path],
        ["git", "-C", str(root), "cat-file", "-e", f"HEAD:{raw_path}"],
    ]
    for command in commands:
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if result.returncode != 0:
            raise EvidenceError("evidence must be tracked, committed in HEAD, and unmodified")
    return candidate


def require_exact_release_dir(release_dir: Path, expected: list[str]) -> dict[str, Path]:
    directory = release_dir.resolve(strict=True)
    if not directory.is_dir():
        raise EvidenceError("release-dir is not a directory")
    actual: dict[str, Path] = {}
    for entry in directory.iterdir():
        mode = entry.lstat().st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
            raise EvidenceError(f"release directory contains a non-regular asset: {entry.name}")
        if entry.name in actual:
            raise EvidenceError(f"duplicate release asset: {entry.name}")
        actual[entry.name] = entry
    if set(actual) != set(expected):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        raise EvidenceError(f"release assets do not match contract; missing={missing}, extra={extra}")
    for name, path in actual.items():
        if path.stat().st_size <= 0:
            raise EvidenceError(f"release asset is empty: {name}")
    return actual


def parse_checksum_file(path: Path, expected_names: list[str]) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise EvidenceError(f"cannot read checksum file {path.name}: {exc}") from exc
    if len(lines) != len(expected_names):
        raise EvidenceError(f"{path.name}: expected {len(expected_names)} checksum lines, got {len(lines)}")
    parsed: dict[str, str] = {}
    for line in lines:
        match = CHECKSUM_LINE_RE.fullmatch(line)
        if not match:
            raise EvidenceError(f"{path.name}: malformed checksum line")
        digest, name = match.groups()
        if name in parsed:
            raise EvidenceError(f"{path.name}: duplicate checksum entry {name}")
        parsed[name] = digest
    if list(parsed) != expected_names:
        raise EvidenceError(f"{path.name}: checksum entries must exactly match the ordered release contract")
    return parsed


def parse_labels(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise EvidenceError(f"cannot read artifact-labels.env: {exc}") from exc
    labels: dict[str, str] = {}
    for line in lines:
        match = LABEL_RE.fullmatch(line)
        if not match:
            raise EvidenceError("artifact-labels.env contains a malformed or unsafe line")
        key, value = match.groups()
        if key in labels:
            raise EvidenceError(f"artifact-labels.env has duplicate key {key}")
        labels[key] = value
    return labels


def parse_utc(value: str, label: str) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise EvidenceError(f"{label} is not a valid timestamp") from exc
    if parsed.tzinfo is None:
        raise EvidenceError(f"{label} must include a timezone")
    return parsed.astimezone(dt.timezone.utc)


def validate_uri_scheme(value: str, scheme: str, label: str) -> urllib.parse.SplitResult:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme.lower() != scheme or not parsed.hostname:
        raise EvidenceError(f"{label} must be an absolute {scheme.upper()} URL")
    if parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise EvidenceError(f"{label} may not contain credentials or a fragment")
    return parsed


def semantic_validation(
    evidence: dict[str, Any],
    rc_tag: str,
    rc_commit: str,
    rc_published_at: str,
    release_files: dict[str, Path],
    expected_names: list[str],
    version: str,
) -> None:
    expected_bindings = {
        "rc_tag": rc_tag,
        "rc_commit": rc_commit,
        "release_version": version,
        "release_contract": "vm-x86_64/v2",
    }
    for field, expected in expected_bindings.items():
        if evidence[field] != expected:
            raise EvidenceError(f"evidence {field} does not bind the requested RC")

    tested_at = parse_utc(evidence["tested_at"], "tested_at")
    published_at = parse_utc(rc_published_at, "rc-published-at")
    if tested_at < published_at:
        raise EvidenceError("tested_at predates publication of the RC")
    if tested_at > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
        raise EvidenceError("tested_at is implausibly in the future")

    evidence_assets = evidence["assets"]
    evidence_names = [asset["name"] for asset in evidence_assets]
    if evidence_names != expected_names:
        raise EvidenceError("evidence assets must exactly match the ordered 21-asset RC contract")
    for asset in evidence_assets:
        path = release_files[asset["name"]]
        if asset["size"] != path.stat().st_size:
            raise EvidenceError(f"evidence size mismatch for {asset['name']}")
        if asset["sha256"] != sha256_file(path):
            raise EvidenceError(f"evidence SHA256 mismatch for {asset['name']}")

    checksum_names = expected_checksum_entries(version)
    checksums = parse_checksum_file(release_files["SHA256SUMS"], checksum_names)
    for name, expected_digest in checksums.items():
        if sha256_file(release_files[name]) != expected_digest:
            raise EvidenceError(f"RC SHA256SUMS verification failed for {name}")

    image_names = [name for name in expected_names if not name.endswith(".sha256") and name.endswith((".img.gz", ".iso", ".vmdk"))]
    for image_name in image_names:
        sidecar_name = f"{image_name}.sha256"
        sidecar = parse_checksum_file(release_files[sidecar_name], [image_name])
        if sidecar[image_name] != sha256_file(release_files[image_name]):
            raise EvidenceError(f"adjacent checksum verification failed for {image_name}")

    labels = parse_labels(release_files["artifact-labels.env"])
    required_labels = {
        "RELEASE_CONTRACT": "vm-x86_64/v2",
        "RELEASE_TAG": rc_tag,
        "RELEASE_VERSION": version,
        "PROJECT_COMMIT": rc_commit,
    }
    for key, expected in required_labels.items():
        if labels.get(key) != expected:
            raise EvidenceError(f"artifact-labels.env {key} does not bind the requested RC")

    checks = evidence["checks"]
    nics = checks["two_nics"]
    if nics["lan_interface"] == nics["wan_interface"]:
        raise EvidenceError("LAN and WAN interfaces must differ")
    if nics["lan_port_group"] == nics["wan_port_group"]:
        raise EvidenceError("LAN and WAN port groups must differ")
    if checks["wan_dhcp"]["interface"] != nics["wan_interface"]:
        raise EvidenceError("WAN DHCP evidence is not bound to the WAN interface")
    if checks["lan_dhcp"]["interface"] != nics["lan_interface"]:
        raise EvidenceError("LAN DHCP evidence is not bound to the LAN interface")
    if checks["nat"]["client_address"] != checks["lan_dhcp"]["client_address"]:
        raise EvidenceError("NAT evidence is not bound to the DHCP client")
    if checks["dns"]["client_address"] != checks["lan_dhcp"]["client_address"]:
        raise EvidenceError("DNS evidence is not bound to the DHCP client")

    imported = checks["vmdk_import"]["asset_name"]
    bios_vmdk = f"NexaWrt-x86_64-{version}-generic-ext4-combined.vmdk"
    efi_vmdk = f"NexaWrt-x86_64-{version}-generic-ext4-combined-efi.vmdk"
    expected_vmdk = bios_vmdk if evidence["esxi"]["firmware"] == "bios" else efi_vmdk
    if imported != expected_vmdk:
        raise EvidenceError("imported VMDK does not match the recorded ESXi firmware mode")

    https = validate_uri_scheme(checks["https"]["url"], "https", "HTTPS check URL")
    http = validate_uri_scheme(checks["http_redirect"]["url"], "http", "HTTP redirect source")
    redirect = validate_uri_scheme(checks["http_redirect"]["location"], "https", "HTTP redirect location")
    lan_address = checks["persistence"]["lan_address_after"]
    if https.hostname != lan_address or http.hostname != lan_address or redirect.hostname != lan_address:
        raise EvidenceError("HTTP/HTTPS evidence must target the persisted LAN address")

    persistence = checks["persistence"]
    equal_pairs = [
        ("installation_id_before", "installation_id_after"),
        ("configuration_sha256_before", "configuration_sha256_after"),
        ("hostname_before", "hostname_after"),
        ("lan_address_before", "lan_address_after"),
    ]
    for before, after in equal_pairs:
        if persistence[before] != persistence[after]:
            raise EvidenceError(f"persistence check failed: {before} != {after}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--evidence", required=True, help="repository-relative evidence JSON path")
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--release-dir", required=True)
    parser.add_argument("--rc-tag", required=True)
    parser.add_argument("--rc-commit", required=True)
    parser.add_argument("--rc-published-at", required=True)
    args = parser.parse_args()

    try:
        match = RC_RE.fullmatch(args.rc_tag)
        if not match:
            raise EvidenceError("rc-tag is not a valid NexaWrt VM RC tag")
        version = match.group(1)
        if not SHA1_RE.fullmatch(args.rc_commit):
            raise EvidenceError("rc-commit must be a full lowercase 40-character commit SHA")

        repo_root = Path(args.repo_root).resolve(strict=True)
        schema_path = Path(args.schema)
        if not schema_path.is_absolute():
            schema_path = repo_root / schema_path
        schema_path = schema_path.resolve(strict=True)
        try:
            schema_path.relative_to(repo_root)
        except ValueError as exc:
            raise EvidenceError("schema path escapes the repository") from exc
        schema = load_json(schema_path)
        if not isinstance(schema, dict) or schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            raise EvidenceError("unexpected or unsupported evidence schema")

        evidence_path = require_safe_repo_evidence(repo_root, args.evidence)
        evidence = load_json(evidence_path)
        validate_schema(evidence, schema, schema)

        names = expected_assets(version)
        release_files = require_exact_release_dir(Path(args.release_dir), names)
        semantic_validation(
            evidence,
            args.rc_tag,
            args.rc_commit,
            args.rc_published_at,
            release_files,
            names,
            version,
        )
    except EvidenceError as exc:
        print(f"ESXi evidence verification failed: {exc}", file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"ESXi evidence verification failed: {exc}", file=sys.stderr)
        return 1

    print(json.dumps({
        "status": "PASS",
        "evidence": args.evidence,
        "rc_tag": args.rc_tag,
        "rc_commit": args.rc_commit,
        "asset_count": 21,
        "release_contract": "vm-x86_64/v2",
    }, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
