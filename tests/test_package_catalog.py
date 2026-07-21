#!/usr/bin/env python3
"""Tests for the locked, sharded OpenWrt package catalog."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOLVER_PATH = ROOT / "scripts" / "resolve-components.py"
GENERATOR_PATH = ROOT / "scripts" / "generate-package-catalog.py"
POLICY_PATH = ROOT / "scripts" / "component_package_policy.py"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


resolver = load_module("package_catalog_resolver", RESOLVER_PATH)
generator = load_module("package_catalog_generator", GENERATOR_PATH)
policy = load_module("component_package_policy_test", POLICY_PATH)
catalog = resolver.load_catalog()
index = resolver.load_package_catalog_index(catalog)

assert set(index) == {"schema_version", "catalog_version", "openwrt_version", "shards"}
assert index["schema_version"] == 1
assert index["catalog_version"] == "2026.07.21"
assert index["openwrt_version"] == "25.12.5"
assert [(item["target"], item["flavor"]) for item in index["shards"]] == [
    ("x86_64", "official"),
    ("xiaomi_ax9000", "official"),
    ("xiaomi_ax9000", "nss"),
]
assert [item["path"] for item in index["shards"]] == [
    "components/packages/x86_64-official.json",
    "components/packages/xiaomi_ax9000-official.json",
    "components/packages/xiaomi_ax9000-nss.json",
]

ROOT_KEYS = {"schema_version", "catalog_version", "openwrt_version", "shards"}
DESCRIPTOR_KEYS = {
    "target", "flavor", "path", "sha256", "package_count", "selectable_count", "sources"
}
SOURCE_KEYS = {"feed", "url", "sha256"}
SHARD_KEYS = {"schema_version", "catalog_version", "target", "flavor", "packages"}
RECORD_KEYS = {
    "id", "package", "version", "description", "feed", "installed_size", "category",
    "arch", "risk", "selectable", "blocked_reason"
}
TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
assert set(json.loads((ROOT / "components/package-catalog.json").read_text())) == ROOT_KEYS

shards = {}
for descriptor in index["shards"]:
    assert set(descriptor) == DESCRIPTOR_KEYS
    assert SHA_RE.fullmatch(descriptor["sha256"])
    assert descriptor["path"].startswith("components/packages/")
    assert ".." not in descriptor["path"]
    assert descriptor["sources"]
    assert len({source["feed"] for source in descriptor["sources"]}) == len(descriptor["sources"])
    for source in descriptor["sources"]:
        assert set(source) == SOURCE_KEYS
        assert source["url"].startswith("https://downloads.openwrt.org/releases/25.12.5/")
        assert source["url"].endswith("/packages.adb")
        assert SHA_RE.fullmatch(source["sha256"])

    path = ROOT / descriptor["path"]
    raw = path.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == descriptor["sha256"]
    payload = json.loads(raw)
    assert set(payload) == SHARD_KEYS
    assert raw == generator._canonical_json(payload)
    shard = resolver.load_package_shard(
        index, catalog, descriptor["target"], descriptor["flavor"]
    )
    assert shard == payload
    assert shard["schema_version"] == 1
    assert shard["catalog_version"] == catalog["catalog_version"]
    assert shard["target"] == descriptor["target"]
    assert shard["flavor"] == descriptor["flavor"]
    assert len(shard["packages"]) == descriptor["package_count"]
    assert sum(item["selectable"] for item in shard["packages"]) == descriptor["selectable_count"]
    assert shard["packages"] == sorted(
        shard["packages"], key=lambda item: (item["package"], item["version"], item["id"])
    )

    ids = set()
    package_names = set()
    for record in shard["packages"]:
        assert set(record) == RECORD_KEYS
        assert TOKEN_RE.fullmatch(record["package"])
        assert not record["package"].startswith(("-", "+"))
        assert record["id"] == "pkg-" + hashlib.sha256(
            record["package"].encode("utf-8")
        ).hexdigest()[:16]
        assert record["id"] not in ids
        assert record["package"] not in package_names
        ids.add(record["id"])
        package_names.add(record["package"])
        assert record["arch"] in policy.allowed_architectures_for(
            descriptor["target"], descriptor["flavor"]
        )
        assert record["risk"] == policy.risk_for(record["package"], record["feed"])
        assert record["blocked_reason"] == policy.blocked_reason_for(record["package"])
        assert record["selectable"] is (not record["blocked_reason"])
        assert type(record["installed_size"]) is int and record["installed_size"] >= 0
        assert record["description"]
        if record["selectable"]:
            assert record["blocked_reason"] == ""
        else:
            assert record["blocked_reason"]
        if record["package"].startswith("kmod-"):
            assert descriptor["flavor"] == "official"
            assert record["risk"] == "advanced"
    shards[(descriptor["target"], descriptor["flavor"])] = shard

x86 = shards[("x86_64", "official")]
ax_official = shards[("xiaomi_ax9000", "official")]
ax_nss = shards[("xiaomi_ax9000", "nss")]
assert len(x86["packages"]) > 10000
assert len(ax_official["packages"]) > 10000
assert len(ax_nss["packages"]) > 3000
assert not any(item["feed"] in {"target", "kmods"} for item in ax_nss["packages"])
assert not any(item["package"].startswith("kmod-") for item in ax_nss["packages"])
assert {item["arch"] for item in ax_nss["packages"]} == {"noarch"}
assert {item["arch"] for item in x86["packages"]} <= {"x86_64", "noarch"}
assert {item["arch"] for item in ax_official["packages"]} <= {
    "aarch64_cortex-a53", "noarch"
}

x86_by_name = {item["package"]: item for item in x86["packages"]}
ax_official_by_name = {item["package"]: item for item in ax_official["packages"]}
ax_nss_by_name = {item["package"]: item for item in ax_nss["packages"]}
assert x86_by_name["base-files"]["selectable"] is False
assert x86_by_name["base-files"]["blocked_reason"]
assert x86_by_name["kmod-3c59x"]["risk"] == "advanced"
assert "kmod-3c59x" in ax_official_by_name
assert "kmod-3c59x" not in ax_nss_by_name



def expect_shard_rejected(payload, descriptor, label: str) -> None:
    try:
        resolver.validate_package_shard(payload, descriptor, catalog)
    except resolver.CatalogError:
        return
    raise AssertionError(f"malicious shard unexpectedly accepted: {label}")


# The resolver independently re-runs policy; synchronized metadata forgery is rejected.
base_forgery = copy.deepcopy(x86)
base_record = next(item for item in base_forgery["packages"] if item["package"] == "base-files")
base_record["selectable"] = True
base_record["blocked_reason"] = ""
base_descriptor = copy.deepcopy(index["shards"][0])
base_descriptor["selectable_count"] += 1
expect_shard_rejected(base_forgery, base_descriptor, "base-files made selectable")

for prefix in ("uboot-",):
    candidate = next(item for item in x86["packages"] if item["package"].startswith(prefix))
    forged = copy.deepcopy(x86)
    record = next(item for item in forged["packages"] if item["package"] == candidate["package"])
    record["selectable"] = True
    record["blocked_reason"] = ""
    descriptor = copy.deepcopy(index["shards"][0])
    descriptor["selectable_count"] += 1
    expect_shard_rejected(forged, descriptor, f"{candidate['package']} made selectable")

firmware_candidate = next(
    item for item in ax_official["packages"] if "firmware" in item["package"].lower()
)
firmware_forgery = copy.deepcopy(ax_official)
firmware_record = next(
    item for item in firmware_forgery["packages"]
    if item["package"] == firmware_candidate["package"]
)
firmware_record["selectable"] = True
firmware_record["blocked_reason"] = ""
firmware_descriptor = copy.deepcopy(index["shards"][1])
firmware_descriptor["selectable_count"] += 1
expect_shard_rejected(firmware_forgery, firmware_descriptor, "firmware made selectable")

risk_forgery = copy.deepcopy(x86)
next(item for item in risk_forgery["packages"] if item["package"] == "curl")["risk"] = "system"
expect_shard_rejected(risk_forgery, index["shards"][0], "curl risk forged")

x86_arch_forgery = copy.deepcopy(x86)
next(item for item in x86_arch_forgery["packages"] if item["package"] == "curl")["arch"] = "aarch64_cortex-a53"
expect_shard_rejected(x86_arch_forgery, index["shards"][0], "AX architecture in x86 shard")

ax_arch_forgery = copy.deepcopy(ax_official)
next(item for item in ax_arch_forgery["packages"] if item["package"] == "curl")["arch"] = "x86_64"
expect_shard_rejected(ax_arch_forgery, index["shards"][1], "x86 architecture in AX shard")

nss_arch_forgery = copy.deepcopy(ax_nss)
nss_arch_forgery["packages"][0]["arch"] = "aarch64_cortex-a53"
expect_shard_rejected(nss_arch_forgery, index["shards"][2], "non-noarch package in NSS shard")


# The resolver accepts package IDs but never arbitrary package names.
curl = x86_by_name["curl"]
curl_request = resolver.resolve_components(catalog, "x86_64", "official", [curl["id"]])
assert curl_request["requested_components"] == [curl["id"]]
assert curl["id"] in curl_request["resolved_components"]
assert "curl" in curl_request["packages"]
try:
    resolver.resolve_components(catalog, "x86_64", "official", ["curl"])
except resolver.RequestError:
    pass
else:
    raise AssertionError("raw package name unexpectedly accepted")

# Blocked packages are visible in the catalog but rejected as build inputs.
blocked_id = x86_by_name["base-files"]["id"]
try:
    resolver.resolve_components(catalog, "x86_64", "official", [blocked_id])
except resolver.RequestError as error:
    assert "blocked" in str(error) and "base-files" in str(error)
else:
    raise AssertionError("blocked package unexpectedly accepted")

# A package ID outside the selected target/flavor shard is unknown.
kmod_id = ax_official_by_name["kmod-3c59x"]["id"]
try:
    resolver.resolve_components(catalog, "xiaomi_ax9000", "nss", [kmod_id])
except resolver.RequestError as error:
    assert "unknown component" in str(error)
else:
    raise AssertionError("official kmod unexpectedly accepted by NSS shard")

try:
    resolver.resolve_components(catalog, "x86_64", "official", ["pkg-0000000000000000"])
except resolver.RequestError:
    pass
else:
    raise AssertionError("unknown package ID unexpectedly accepted")

# The root index hash is authoritative, and paths cannot escape the repository allow-list.
tampered_hash = copy.deepcopy(index)
tampered_hash["shards"][0]["sha256"] = "0" * 64
try:
    resolver.load_package_shard(tampered_hash, catalog, "x86_64", "official")
except resolver.CatalogError as error:
    assert "SHA256 mismatch" in str(error)
else:
    raise AssertionError("tampered shard hash unexpectedly accepted")

escaped_path = copy.deepcopy(index)
escaped_path["shards"][0]["path"] = "components/packages/../catalog.json"
try:
    resolver.validate_package_catalog_index(escaped_path, catalog)
except resolver.CatalogError:
    pass
else:
    raise AssertionError("escaping shard path unexpectedly accepted")

extra_record_key = copy.deepcopy(x86)
extra_record_key["packages"][0]["unexpected"] = True
try:
    resolver.validate_package_shard(extra_record_key, index["shards"][0], catalog)
except resolver.CatalogError:
    pass
else:
    raise AssertionError("non-exact package record unexpectedly accepted")

# Generator helpers are deterministic and reject non-allow-listed URLs/tokens.
synthetic = [
    (
        "base",
        [
            {"name": "zeta", "version": "1", "description": "Z", "installed-size": 2, "arch": "noarch"},
            {"name": "alpha", "version": "1", "description": "A", "installed-size": 1, "arch": "noarch"},
        ],
    )
]
forward = generator._merge_packages(synthetic, target="x86_64", flavor="official")
reverse = generator._merge_packages(
    [("base", list(reversed(synthetic[0][1])))],
    target="x86_64",
    flavor="official",
)
assert forward == reverse
assert [item["package"] for item in forward] == ["alpha", "zeta"]
assert generator._record(
    {"name": "+unsafe", "version": "1", "description": "x", "arch": "noarch"}, "base"
) is None
for unsafe_url in (
    "http://downloads.openwrt.org/releases/25.12.5/packages/x86_64/base/packages.adb",
    "https://example.com/releases/25.12.5/packages/x86_64/base/packages.adb",
    "https://downloads.openwrt.org/releases/25.12.5/../snapshot/packages.adb",
):
    try:
        generator._safe_url(unsafe_url, suffixes=("packages.adb",))
    except generator.GenerationError:
        pass
    else:
        raise AssertionError(f"unsafe source URL unexpectedly accepted: {unsafe_url}")


class FakeDownloadResponse:
    def __init__(self, url: str, body: bytes, content_length: str | None):
        self._url = url
        self._body = body
        self._read = False
        self.headers = {} if content_length is None else {"Content-Length": content_length}

    def __enter__(self):
        return self

    def __exit__(self, _type, _value, _traceback):
        return False

    def geturl(self) -> str:
        return self._url

    def read(self, _size: int) -> bytes:
        if self._read:
            return b""
        self._read = True
        return self._body


def expect_download_rejected(body: bytes, content_length: str | None, label: str) -> None:
    safe_url = generator.PROFILE_URL
    original_limit = generator.MAX_PROFILE_BYTES
    original_urlopen = generator.urllib.request.urlopen
    generator.MAX_PROFILE_BYTES = 4
    generator.urllib.request.urlopen = lambda _request, timeout: FakeDownloadResponse(
        safe_url, body, content_length
    )
    try:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "profiles.json"
            try:
                generator._download(safe_url, destination)
            except generator.GenerationError:
                pass
            else:
                raise AssertionError(f"oversized download unexpectedly accepted: {label}")
            assert not destination.exists()
    finally:
        generator.MAX_PROFILE_BYTES = original_limit
        generator.urllib.request.urlopen = original_urlopen


expect_download_rejected(b"", "5", "declared Content-Length")
expect_download_rejected(b"12345", None, "streamed body")

# Safe output refuses target links, parent links, hard links, and non-regular files.
def expect_generation_rejected(operation, label: str) -> None:
    try:
        operation()
    except generator.GenerationError:
        return
    raise AssertionError(f"unsafe generator output unexpectedly accepted: {label}")


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "components").mkdir()
    victim = root / "victim.json"
    victim.write_text("do-not-overwrite", encoding="utf-8")
    (root / "components/package-catalog.json").symlink_to(victim)
    expect_generation_rejected(lambda: generator._write_catalog(root, []), "target symlink")
    assert victim.read_text(encoding="utf-8") == "do-not-overwrite"

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "components").mkdir()
    victim = root / "victim.json"
    victim.write_text("do-not-replace", encoding="utf-8")
    os.link(victim, root / "components/package-catalog.json")
    expect_generation_rejected(lambda: generator._write_catalog(root, []), "target hard link")
    assert victim.read_text(encoding="utf-8") == "do-not-replace"

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    outside = root / "outside"
    outside.mkdir()
    (root / "components").symlink_to(outside, target_is_directory=True)
    expect_generation_rejected(
        lambda: generator._safe_write_output(
            root, "components/packages/test.json", b"{}\n"
        ),
        "parent symlink",
    )
    assert not (outside / "packages/test.json").exists()

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "components/package-catalog.json").mkdir(parents=True)
    expect_generation_rejected(lambda: generator._write_catalog(root, []), "directory target")

# Archive member validation permits only directories and ordinary files.
assert generator._validate_archive_members(
    ["imagebuilder/", "imagebuilder/apk"],
    ["drwxr-xr-x root/root 0 2026-01-01 00:00 imagebuilder/", "-rwxr-xr-x root/root 1 2026-01-01 00:00 imagebuilder/apk"],
) == ["imagebuilder"]
for member_type in ("l", "h", "p", "c", "b"):
    expect_generation_rejected(
        lambda member_type=member_type: generator._validate_archive_members(
            ["imagebuilder/link"],
            [f"{member_type}rwxr-xr-x root/root 0 2026-01-01 00:00 imagebuilder/link"],
        ),
        f"archive member type {member_type}",
    )

# Repository reads are bounded and reject links through no-follow, same-fd reads.
def expect_repository_read_rejected(path: Path, parent: Path, label: str) -> None:
    try:
        resolver._load_repository_json(
            path, parent, label, resolver.MAX_PACKAGE_CATALOG_BYTES
        )
    except resolver.CatalogError:
        return
    raise AssertionError(f"unsafe repository JSON unexpectedly accepted: {label}")


with tempfile.TemporaryDirectory() as temporary:
    parent = Path(temporary)
    oversized = parent / "oversized.json"
    oversized.write_bytes(b" " * (resolver.MAX_PACKAGE_CATALOG_BYTES + 1))
    try:
        resolver._load_repository_json(
            oversized,
            parent,
            "oversized package catalog",
            resolver.MAX_PACKAGE_CATALOG_BYTES,
        )
    except resolver.CatalogError as error:
        assert "limit" in str(error)
    else:
        raise AssertionError("oversized repository JSON unexpectedly accepted")

with tempfile.TemporaryDirectory() as temporary:
    parent = Path(temporary)
    source = parent / "source.json"
    source.write_text("{}\n", encoding="utf-8")
    linked = parent / "linked.json"
    linked.symlink_to(source)
    expect_repository_read_rejected(linked, parent, "repository symlink")

with tempfile.TemporaryDirectory() as temporary:
    parent = Path(temporary)
    source = parent / "source.json"
    source.write_text("{}\n", encoding="utf-8")
    linked = parent / "linked.json"
    os.link(source, linked)
    expect_repository_read_rejected(linked, parent, "repository hard link")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    real_parent = root / "real"
    real_parent.mkdir()
    (real_parent / "catalog.json").write_text("{}\n", encoding="utf-8")
    linked_parent = root / "linked"
    linked_parent.symlink_to(real_parent, target_is_directory=True)
    expect_repository_read_rejected(
        linked_parent / "catalog.json", linked_parent, "repository parent symlink"
    )

completed = subprocess.run(
    [sys.executable, str(GENERATOR_PATH), "--help"],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
)
assert "--output-root" in completed.stdout
assert "--apk" not in completed.stdout

print("Package catalog policy: signed shards, shared safety policy, architecture isolation, safe I/O, and deterministic data OK")
