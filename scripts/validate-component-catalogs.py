#!/usr/bin/env python3
"""Validate repository component catalogs and stage a safe GitHub Pages copy.

The catalog contract is owned by scripts/resolve-components.py.  This command
loads that module and calls its validators directly so Pages cannot silently
publish a weaker schema than the build backend accepts.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import inspect
import json
import os
import re
import stat
import sys
from pathlib import Path
from types import ModuleType
from typing import Any, Callable

MAX_SHARDS = 3
MAX_CURATED_CATALOG_BYTES = 2 * 1024 * 1024
MAX_PACKAGE_INDEX_BYTES = 2 * 1024 * 1024
MAX_PACKAGE_SHARD_BYTES = 16 * 1024 * 1024
MAX_PACKAGE_PURPOSE_BYTES = 8 * 1024 * 1024
READ_CHUNK_BYTES = 1024 * 1024
SAFE_SHARD_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}\.json$")


class StagingError(RuntimeError):
    """Catalog validation or safe staging failed."""


def _load_module(path: Path, name: str) -> ModuleType:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise StagingError(f"unable to locate {name}: {error}") from error
    spec = importlib.util.spec_from_file_location(name, resolved)
    if spec is None or spec.loader is None:
        raise StagingError(f"unable to load {name} from {resolved}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _require_real_directory(path: Path, context: str) -> Path:
    try:
        info = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise StagingError(f"unable to inspect {context}: {error}") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise StagingError(f"{context} must be a real directory: {path}")
    return resolved


def _read_regular_file(path: Path, expected_parent: Path, limit: int, context: str) -> bytes:
    allowed_parent = _require_real_directory(expected_parent, f"{context} parent")
    try:
        if path.parent.resolve(strict=True) != allowed_parent:
            raise StagingError(f"{context} is outside its allowed directory: {path}")
        before = path.lstat()
    except OSError as error:
        raise StagingError(f"unable to inspect {context}: {error}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise StagingError(f"{context} must be a regular, non-symlink file: {path}")
    if before.st_nlink != 1:
        raise StagingError(f"{context} must not be hard-linked: {path}")
    if before.st_size > limit:
        raise StagingError(f"{context} exceeds the {limit}-byte limit: {path}")

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise StagingError(f"unable to open {context}: {error}") from error
    try:
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            raise StagingError(f"{context} changed type or link count while opening: {path}")
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise StagingError(f"{context} changed while opening: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            remaining = limit + 1 - total
            chunk = os.read(descriptor, min(READ_CHUNK_BYTES, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                raise StagingError(f"{context} exceeds the {limit}-byte limit: {path}")
        after = os.fstat(descriptor)
        if (
            (current.st_dev, current.st_ino, current.st_size)
            != (after.st_dev, after.st_ino, after.st_size)
        ):
            raise StagingError(f"{context} changed while reading: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _parse_json(raw: bytes, path: Path, resolver: ModuleType) -> Any:
    duplicate_hook = getattr(resolver, "_reject_duplicate_keys", None)
    if not callable(duplicate_hook):
        raise StagingError("resolver does not expose duplicate-key rejection")
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=duplicate_hook)
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise StagingError(f"invalid strict JSON in {path}: {error}") from error


def _call_resolver(function: Callable[..., Any], context: str, *args: Any) -> Any:
    try:
        return function(*args)
    except Exception as error:
        raise StagingError(f"{context} failed backend validation: {error}") from error


def _policy_functions(
    repo_root: Path, resolver: ModuleType
) -> tuple[Callable[[str], str], Callable[..., str], Callable[[str, str], Any] | None]:
    """Use shared resolver policy when available; fall back to the generator policy.

    The fallback keeps this staging validator aligned with today's generator while
    allowing a concurrent backend change to move policy into the resolver or a
    shared module without duplicating package-name rules here.
    """

    blocked_names = ("blocked_reason_for_record", "blocked_reason_for", "blocked_reason_for_package", "package_blocked_reason", "_blocked_reason")
    risk_names = ("risk_for", "risk_for_package", "package_risk", "_risk")
    arch_names = ("allowed_architectures_for", "package_architectures_for")

    def find(module: ModuleType, names: tuple[str, ...]) -> Callable[..., Any] | None:
        for name in names:
            candidate = getattr(module, name, None)
            if callable(candidate):
                return candidate
        return None

    blocked = find(resolver, blocked_names)
    risk = find(resolver, risk_names)
    architectures = find(resolver, arch_names)
    if blocked is not None and risk is not None and architectures is not None:
        return blocked, risk, architectures

    shared_path = repo_root / "scripts" / "component_package_policy.py"
    if shared_path.is_file():
        shared = _load_module(shared_path, "nexawrt_component_package_policy")
        blocked = blocked or find(shared, blocked_names)
        risk = risk or find(shared, risk_names)
        architectures = architectures or find(shared, arch_names)

    if blocked is None or risk is None:
        generator = _load_module(
            repo_root / "scripts" / "generate-package-catalog.py",
            "nexawrt_package_catalog_generator",
        )
        blocked = blocked or find(generator, blocked_names)
        risk = risk or find(generator, risk_names)
        architectures = architectures or find(generator, arch_names)

    if blocked is None or risk is None:
        raise StagingError("unable to locate the shared package selectable/risk policy")
    return blocked, risk, architectures


def _validate_policy(
    shard: dict[str, Any],
    descriptor: dict[str, Any],
    resolver: ModuleType,
    blocked_reason: Callable[[str], str],
    package_risk: Callable[..., str],
    allowed_architectures: Callable[[str, str], Any] | None,
) -> None:
    record_keys = getattr(resolver, "PACKAGE_RECORD_KEYS", set())
    has_arch_contract = "arch" in record_keys
    risk_parameter_count = len(inspect.signature(package_risk).parameters)
    if risk_parameter_count not in {2, 3}:
        raise StagingError("shared package risk policy has an unsupported signature")
    official_packages = {record["package"] for record in shard["packages"] if record.get("source") == "official"}
    blocked_parameter_count = len(inspect.signature(blocked_reason).parameters)
    if blocked_parameter_count not in {1, 3}:
        raise StagingError("shared package blocked policy has an unsupported signature")
    for position, record in enumerate(shard["packages"]):
        context = f"{descriptor['path']} packages[{position}]"
        package = record["package"]
        expected_reason = (
            blocked_reason(package)
            if blocked_parameter_count == 1
            else blocked_reason(package, record["source"], duplicates_official=package in official_packages)
        )
        if not isinstance(expected_reason, str):
            raise StagingError(f"package policy returned an invalid blocked reason for {package}")
        expected_selectable = not expected_reason
        if risk_parameter_count == 2:
            expected_risk = package_risk(package, record["feed"])
        else:
            expected_risk = package_risk(package, record["feed"], expected_selectable)
        if record["selectable"] is not expected_selectable:
            raise StagingError(f"{context}.selectable differs from the shared package policy")
        if record["blocked_reason"] != expected_reason:
            raise StagingError(f"{context}.blocked_reason differs from the shared package policy")
        if record["risk"] != expected_risk:
            raise StagingError(f"{context}.risk differs from the shared package policy")
        if has_arch_contract:
            arch = record.get("arch")
            if not isinstance(arch, str) or not arch:
                raise StagingError(f"{context}.arch is missing or invalid")
            if allowed_architectures is None:
                raise StagingError("package arch schema exists without a shared architecture policy")
            allowed = allowed_architectures(descriptor["target"], descriptor["flavor"])
            if arch not in allowed:
                raise StagingError(f"{context}.arch violates the target/flavor architecture policy")


def _prepare_destination(site_root: Path) -> tuple[Path, Path]:
    site_parent = site_root.parent
    _require_real_directory(site_parent, "Pages site directory")
    if site_root.exists() or site_root.is_symlink():
        _require_real_directory(site_root, "Pages component directory")
    else:
        try:
            site_root.mkdir(mode=0o755)
        except OSError as error:
            raise StagingError(f"unable to create Pages component directory: {error}") from error
    package_root = site_root / "packages"
    if package_root.exists() or package_root.is_symlink():
        raise StagingError(f"refusing pre-existing Pages package directory: {package_root}")
    try:
        package_root.mkdir(mode=0o755)
    except OSError as error:
        raise StagingError(f"unable to create Pages package directory: {error}") from error
    _require_real_directory(site_root, "Pages component directory")
    _require_real_directory(package_root, "Pages package directory")
    return site_root, package_root


def _write_validated_file(destination: Path, expected_parent: Path, raw: bytes) -> None:
    allowed_parent = _require_real_directory(expected_parent, "Pages destination parent")
    try:
        if destination.parent.resolve(strict=True) != allowed_parent:
            raise StagingError(f"Pages destination is outside its allowed directory: {destination}")
        if destination.exists() or destination.is_symlink():
            info = destination.lstat()
            if (
                stat.S_ISLNK(info.st_mode)
                or not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
            ):
                raise StagingError(f"refusing unsafe Pages destination: {destination}")
            destination.unlink()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(destination, flags, 0o644)
    except (OSError, StagingError) as error:
        if isinstance(error, StagingError):
            raise
        raise StagingError(f"unable to create Pages destination {destination}: {error}") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise StagingError(f"Pages destination is not a single-link regular file: {destination}")
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise StagingError(f"short write while staging {destination}")
            view = view[written:]
        os.fsync(descriptor)
        final = os.fstat(descriptor)
        if not stat.S_ISREG(final.st_mode) or final.st_nlink != 1 or final.st_size != len(raw):
            raise StagingError(f"Pages destination changed while staging: {destination}")
    finally:
        os.close(descriptor)


def _discover_shards(package_root: Path) -> set[str]:
    _require_real_directory(package_root, "package shard source directory")
    discovered: set[str] = set()
    try:
        with os.scandir(package_root) as entries:
            for entry in entries:
                path = package_root / entry.name
                info = entry.stat(follow_symlinks=False)
                if entry.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise StagingError(f"package shard directory contains an unsafe entry: {path}")
                if not SAFE_SHARD_NAME_RE.fullmatch(entry.name):
                    raise StagingError(f"package shard directory contains an unsafe filename: {path}")
                discovered.add(entry.name)
                if len(discovered) > MAX_SHARDS:
                    raise StagingError(
                        f"package shard directory exceeds MAX_SHARDS={MAX_SHARDS}"
                    )
    except OSError as error:
        raise StagingError(f"unable to scan package shard directory: {error}") from error
    return discovered



def _backend_byte_limit(resolver: ModuleType, name: str, local_limit: int) -> int:
    backend_limit = getattr(resolver, name, local_limit)
    if type(backend_limit) is not int or backend_limit <= 0:
        raise StagingError(f"backend exposes an invalid {name}")
    return min(local_limit, backend_limit)

def validate_and_stage(repo_root: Path, components_root: Path, site_root: Path) -> None:
    repo_root = _require_real_directory(repo_root, "repository root")
    components_root = components_root if components_root.is_absolute() else repo_root / components_root
    site_root = site_root if site_root.is_absolute() else repo_root / site_root
    components_root = Path(components_root)
    site_root = Path(site_root)
    package_root = components_root / "packages"
    _require_real_directory(components_root, "component catalog directory")
    _require_real_directory(package_root, "package shard source directory")

    resolver = _load_module(repo_root / "scripts" / "resolve-components.py", "nexawrt_component_resolver")
    purpose_module = _load_module(repo_root / "scripts" / "package_purpose_zh.py", "nexawrt_package_purpose_zh")
    validate_purposes = getattr(purpose_module, "validate_purpose_catalog", None)
    if not callable(validate_purposes):
        raise StagingError("package purpose module does not expose validate_purpose_catalog")
    expected_shards = getattr(resolver, "EXPECTED_PACKAGE_SHARDS", None)
    if not isinstance(expected_shards, dict) or len(expected_shards) != MAX_SHARDS:
        raise StagingError(f"backend must define exactly MAX_SHARDS={MAX_SHARDS} package shards")
    curated_limit = _backend_byte_limit(
        resolver, "MAX_COMPONENT_CATALOG_BYTES", MAX_CURATED_CATALOG_BYTES
    )
    index_limit = _backend_byte_limit(
        resolver, "MAX_PACKAGE_CATALOG_BYTES", MAX_PACKAGE_INDEX_BYTES
    )
    shard_limit = _backend_byte_limit(
        resolver, "MAX_PACKAGE_SHARD_BYTES", MAX_PACKAGE_SHARD_BYTES
    )

    curated_path = components_root / "catalog.json"
    index_path = components_root / "package-catalog.json"
    curated_raw = _read_regular_file(
        curated_path, components_root, curated_limit, "curated component catalog"
    )
    curated_payload = _parse_json(curated_raw, curated_path, resolver)
    catalog = _call_resolver(resolver.validate_catalog, "curated component catalog", curated_payload)

    index_raw = _read_regular_file(
        index_path, components_root, index_limit, "package catalog index"
    )
    index_payload = _parse_json(index_raw, index_path, resolver)
    index = _call_resolver(
        resolver.validate_package_catalog_index, "package catalog index", index_payload, catalog
    )
    if len(index["shards"]) != MAX_SHARDS:
        raise StagingError(f"package catalog must contain exactly MAX_SHARDS={MAX_SHARDS} shards")

    referenced_names = {
        descriptor["path"].removeprefix("components/packages/") for descriptor in index["shards"]
    }
    if len(referenced_names) != MAX_SHARDS or _discover_shards(package_root) != referenced_names:
        raise StagingError("package shard files do not exactly match the three backend descriptors")

    staged_root, staged_packages = _prepare_destination(site_root)
    _write_validated_file(staged_root / "catalog.json", staged_root, curated_raw)
    _write_validated_file(staged_root / "package-catalog.json", staged_root, index_raw)

    blocked_reason, package_risk, allowed_architectures = _policy_functions(repo_root, resolver)
    expected_purpose_keys: set[str] = set()
    for descriptor in index["shards"]:
        relative_name = descriptor["path"].removeprefix("components/packages/")
        if not SAFE_SHARD_NAME_RE.fullmatch(relative_name):
            raise StagingError(f"unsafe backend shard filename: {relative_name}")
        source = package_root / relative_name
        shard_raw = _read_regular_file(
            source, package_root, shard_limit, f"package shard {relative_name}"
        )
        actual_sha256 = hashlib.sha256(shard_raw).hexdigest()
        if actual_sha256 != descriptor["sha256"]:
            raise StagingError(f"SHA-256 mismatch for {descriptor['path']}")
        shard_payload = _parse_json(shard_raw, source, resolver)
        shard = _call_resolver(
            resolver.validate_package_shard,
            f"package shard {descriptor['path']}",
            shard_payload,
            descriptor,
            catalog,
        )
        _validate_policy(
            shard, descriptor, resolver, blocked_reason, package_risk, allowed_architectures
        )
        expected_purpose_keys.update(
            f"{record['source']}/{record['package']}" for record in shard["packages"]
        )
        _write_validated_file(staged_packages / relative_name, staged_packages, shard_raw)
        del shard_payload, shard, shard_raw

    purpose_descriptor = index["purpose_catalog"]
    purpose_path = components_root / Path(purpose_descriptor["path"]).name
    purpose_raw = _read_regular_file(
        purpose_path, components_root, MAX_PACKAGE_PURPOSE_BYTES, "Chinese package purpose catalog"
    )
    if hashlib.sha256(purpose_raw).hexdigest() != purpose_descriptor["sha256"]:
        raise StagingError("SHA-256 mismatch for the Chinese package purpose catalog")
    purpose_payload = _parse_json(purpose_raw, purpose_path, resolver)
    try:
        validate_purposes(purpose_payload, catalog["catalog_version"], expected_purpose_keys)
    except Exception as error:
        raise StagingError(f"Chinese package purpose catalog failed validation: {error}") from error
    if purpose_payload["package_count"] != purpose_descriptor["package_count"]:
        raise StagingError("Chinese package purpose count differs from its descriptor")
    _write_validated_file(staged_root / purpose_path.name, staged_root, purpose_raw)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--components-root", type=Path, default=Path("components"))
    parser.add_argument("--site-root", type=Path, default=Path("site/components"))
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        validate_and_stage(args.repo_root, args.components_root, args.site_root)
    except StagingError as error:
        print(f"component catalog staging rejected: {error}", file=sys.stderr)
        return 1
    print(f"validated and staged exactly {MAX_SHARDS} component package shards plus the Chinese purpose catalog")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
