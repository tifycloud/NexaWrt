#!/usr/bin/env python3
"""Exercise the real Pages catalog validator with malicious catalog fixtures."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts" / "validate-component-catalogs.py"
SOURCE_COMPONENTS = ROOT / "components"


def canonical(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


class ComponentCatalogStagingTests(unittest.TestCase):
    baseline_directory: tempfile.TemporaryDirectory[str]
    baseline_components: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.baseline_directory = tempfile.TemporaryDirectory()
        cls.baseline_components = Path(cls.baseline_directory.name) / "components"
        packages_root = cls.baseline_components / "packages"
        packages_root.mkdir(parents=True)

        shutil.copyfile(SOURCE_COMPONENTS / "catalog.json", cls.baseline_components / "catalog.json")
        resolver_path = ROOT / "scripts" / "resolve-components.py"
        spec = importlib.util.spec_from_file_location("staging_test_resolver", resolver_path)
        if spec is None or spec.loader is None:
            raise RuntimeError("unable to load resolver contract for staging tests")
        resolver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(resolver)
        requires_arch = "arch" in resolver.PACKAGE_RECORD_KEYS

        index = load_json(SOURCE_COMPONENTS / "package-catalog.json")
        for descriptor in index["shards"]:
            source = ROOT / descriptor["path"]
            shard = load_json(source)
            if descriptor["target"] == "x86_64" and descriptor["flavor"] == "official":
                selected = next(
                    record for record in shard["packages"] if record["package"] == "base-files"
                )
            else:
                selected = shard["packages"][0]
            selected = copy.deepcopy(selected)
            if requires_arch and "arch" not in selected:
                selected["arch"] = (
                    "noarch"
                    if descriptor["flavor"] == "nss"
                    else "x86_64"
                    if descriptor["target"] == "x86_64"
                    else "aarch64_cortex-a53"
                )
            minimal = {
                "schema_version": shard["schema_version"],
                "catalog_version": shard["catalog_version"],
                "target": shard["target"],
                "flavor": shard["flavor"],
                "packages": [selected],
            }
            raw = canonical(minimal)
            name = Path(descriptor["path"]).name
            (packages_root / name).write_bytes(raw)
            descriptor["sha256"] = hashlib.sha256(raw).hexdigest()
            descriptor["package_count"] = 1
            descriptor["selectable_count"] = int(selected["selectable"])
        (cls.baseline_components / "package-catalog.json").write_bytes(canonical(index))

    @classmethod
    def tearDownClass(cls) -> None:
        cls.baseline_directory.cleanup()

    def fixture(self) -> tuple[tempfile.TemporaryDirectory[str], Path, Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        components = root / "components"
        shutil.copytree(self.baseline_components, components)
        site = root / "site"
        site.mkdir()
        return temporary, components, site

    def run_validator(self, components: Path, site: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(VALIDATOR),
                "--repo-root",
                str(ROOT),
                "--components-root",
                str(components),
                "--site-root",
                str(site / "components"),
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def mutate_shard(
        self,
        components: Path,
        pair: tuple[str, str],
        mutation: Callable[[dict[str, Any]], None],
    ) -> None:
        index_path = components / "package-catalog.json"
        index = load_json(index_path)
        descriptor = next(
            item for item in index["shards"] if (item["target"], item["flavor"]) == pair
        )
        shard_path = components / "packages" / Path(descriptor["path"]).name
        shard = load_json(shard_path)
        mutation(shard)
        raw = canonical(shard)
        shard_path.write_bytes(raw)
        descriptor["sha256"] = hashlib.sha256(raw).hexdigest()
        descriptor["package_count"] = len(shard["packages"])
        descriptor["selectable_count"] = sum(
            record.get("selectable") is True for record in shard["packages"]
        )
        index_path.write_bytes(canonical(index))

    def assert_rejected(
        self,
        name: str,
        mutation: Callable[[Path], None],
    ) -> None:
        temporary, components, site = self.fixture()
        try:
            mutation(components)
            result = self.run_validator(components, site)
            self.assertNotEqual(
                result.returncode,
                0,
                f"{name} was accepted\nstdout={result.stdout}\nstderr={result.stderr}",
            )
            self.assertIn("rejected", result.stderr, name)
        finally:
            temporary.cleanup()

    def test_valid_fixture_is_staged_one_shard_at_a_time(self) -> None:
        temporary, components, site = self.fixture()
        try:
            result = self.run_validator(components, site)
            self.assertEqual(result.returncode, 0, result.stderr)
            staged = site / "components"
            self.assertEqual(
                sorted(path.name for path in (staged / "packages").glob("*.json")),
                [
                    "x86_64-official.json",
                    "xiaomi_ax9000-nss.json",
                    "xiaomi_ax9000-official.json",
                ],
            )
            self.assertEqual(
                (staged / "package-catalog.json").read_bytes(),
                (components / "package-catalog.json").read_bytes(),
            )
        finally:
            temporary.cleanup()

    def test_rejects_extra_root_key(self) -> None:
        def mutation(components: Path) -> None:
            path = components / "package-catalog.json"
            payload = load_json(path)
            payload["unexpected"] = True
            path.write_bytes(canonical(payload))

        self.assert_rejected("extra root key", mutation)

    def test_rejects_duplicate_json_key(self) -> None:
        def mutation(components: Path) -> None:
            path = components / "package-catalog.json"
            raw = path.read_text(encoding="utf-8")
            needle = '"schema_version":1'
            self.assertIn(needle, raw)
            path.write_text(raw.replace(needle, f"{needle},{needle}", 1), encoding="utf-8")

        self.assert_rejected("duplicate JSON key", mutation)

    def test_rejects_package_index_catalog_version_mismatch(self) -> None:
        def mutation(components: Path) -> None:
            path = components / "package-catalog.json"
            payload = load_json(path)
            payload["catalog_version"] = "2026.07.21.999"
            path.write_bytes(canonical(payload))

        self.assert_rejected("package index catalog version mismatch", mutation)

    def test_rejects_shard_target_mismatch(self) -> None:
        self.assert_rejected(
            "target mismatch",
            lambda components: self.mutate_shard(
                components,
                ("x86_64", "official"),
                lambda shard: shard.__setitem__("target", "xiaomi_ax9000"),
            ),
        )

    def test_rejects_shard_flavor_mismatch(self) -> None:
        self.assert_rejected(
            "flavor mismatch",
            lambda components: self.mutate_shard(
                components,
                ("x86_64", "official"),
                lambda shard: shard.__setitem__("flavor", "nss"),
            ),
        )

    def test_rejects_shard_catalog_version_mismatch(self) -> None:
        self.assert_rejected(
            "catalog version mismatch",
            lambda components: self.mutate_shard(
                components,
                ("x86_64", "official"),
                lambda shard: shard.__setitem__("catalog_version", "2026.07.21.999"),
            ),
        )

    def test_rejects_package_id_mismatch(self) -> None:
        self.assert_rejected(
            "package ID mismatch",
            lambda components: self.mutate_shard(
                components,
                ("xiaomi_ax9000", "official"),
                lambda shard: shard["packages"][0].__setitem__("id", "pkg-0000000000000000"),
            ),
        )

    def test_rejects_undeclared_feed(self) -> None:
        self.assert_rejected(
            "undeclared feed",
            lambda components: self.mutate_shard(
                components,
                ("xiaomi_ax9000", "official"),
                lambda shard: shard["packages"][0].__setitem__("feed", "untrusted"),
            ),
        )

    def test_rejects_feed_category_mismatch(self) -> None:
        self.assert_rejected(
            "feed/category mismatch",
            lambda components: self.mutate_shard(
                components,
                ("xiaomi_ax9000", "official"),
                lambda shard: shard["packages"][0].__setitem__("category", "official-video"),
            ),
        )

    def test_rejects_forged_risk(self) -> None:
        self.assert_rejected(
            "forged risk",
            lambda components: self.mutate_shard(
                components,
                ("xiaomi_ax9000", "official"),
                lambda shard: shard["packages"][0].__setitem__("risk", "system"),
            ),
        )

    def test_rejects_base_files_reclassified_as_selectable(self) -> None:
        def reclassify(shard: dict[str, Any]) -> None:
            record = shard["packages"][0]
            self.assertEqual(record["package"], "base-files")
            record["selectable"] = True
            record["blocked_reason"] = ""

        self.assert_rejected(
            "base-files selectable",
            lambda components: self.mutate_shard(
                components, ("x86_64", "official"), reclassify
            ),
        )

    def test_rejects_hardlinked_source_shard(self) -> None:
        def mutation(components: Path) -> None:
            source = components / "packages" / "x86_64-official.json"
            victim = components.parent / "hardlink-victim.json"
            source.replace(victim)
            os.link(victim, source)

        self.assert_rejected("hardlinked source shard", mutation)

    def test_rejects_non_noarch_record_in_nss(self) -> None:
        def change_arch(shard: dict[str, Any]) -> None:
            # When the backend arch field lands, this exercises its semantic
            # noarch policy. Before then, exact-schema validation rejects the
            # unexpected architecture field fail-closed.
            shard["packages"][0]["arch"] = "aarch64_cortex-a53"

        self.assert_rejected(
            "NSS non-noarch package",
            lambda components: self.mutate_shard(
                components, ("xiaomi_ax9000", "nss"), change_arch
            ),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
