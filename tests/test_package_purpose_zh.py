#!/usr/bin/env python3
"""Tests for the deterministic Chinese OpenWrt package-purpose catalog."""

from __future__ import annotations

import copy
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import package_purpose_zh as generator

CHINESE_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")


def current_catalog_facts() -> tuple[str, set[str]]:
    versions: set[str] = set()
    keys: set[str] = set()
    for shard_name in sorted(glob.glob(str(ROOT / "components" / "packages" / "*.json"))):
        payload = json.loads(Path(shard_name).read_text(encoding="utf-8"))
        versions.add(payload["catalog_version"])
        keys.update(f"{record['source']}/{record['package']}" for record in payload["packages"])
    if len(versions) != 1:
        raise AssertionError(f"test fixtures have inconsistent catalog versions: {versions}")
    return next(iter(versions)), keys


class PackagePurposeZhTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog_version, cls.expected_keys = current_catalog_facts()
        cls.records_by_shard, loaded_version = generator.load_package_shards(
            ROOT / "components"
        )
        if loaded_version != cls.catalog_version:
            raise AssertionError("loader returned an unexpected catalog version")
        cls.payload = generator.build_purpose_catalog(
            cls.records_by_shard, cls.catalog_version
        )

    def test_fixed_schema_and_all_unique_packages_are_covered(self) -> None:
        payload = self.payload
        self.assertEqual(
            list(payload),
            [
                "schema_version",
                "catalog_version",
                "package_count",
                "quality_counts",
                "purposes",
            ],
        )
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["catalog_version"], self.catalog_version)
        self.assertEqual(
            set(payload["quality_counts"]), {"exact", "family", "category"}
        )
        self.assertEqual(payload["package_count"], len(self.expected_keys))
        self.assertEqual(set(payload["purposes"]), self.expected_keys)
        self.assertEqual(list(payload["purposes"]), sorted(self.expected_keys))
        self.assertGreaterEqual(payload["quality_counts"]["exact"], generator.MIN_EXACT_PURPOSES)
        self.assertLessEqual(
            payload["quality_counts"]["category"] / payload["package_count"],
            generator.MAX_CATEGORY_SHARE,
        )
        generator.validate_purpose_catalog(
            payload, self.catalog_version, self.expected_keys
        )

    def test_every_purpose_is_nonempty_chinese_and_control_free(self) -> None:
        for key, entry in self.payload["purposes"].items():
            with self.subTest(package=key):
                self.assertEqual(set(entry), {"purpose", "quality"})
                self.assertTrue(entry["purpose"].strip())
                self.assertRegex(entry["purpose"], CHINESE_RE)
                self.assertFalse(
                    any(
                        unicodedata.category(character) in {"Cc", "Cf"}
                        for character in entry["purpose"]
                    )
                )
                self.assertIn(entry["quality"], {"exact", "family", "category"})

    def test_common_packages_have_reviewed_exact_meanings(self) -> None:
        expectations = {
            "official/base-files": ("基础文件系统", "OpenWrt"),
            "official/luci-app-firewall": ("防火墙", "LuCI"),
            "official/wireguard-tools": ("WireGuard", "VPN"),
            "official/adguardhome": ("DNS", "广告"),
            "official/samba4-server": ("SMB", "文件共享"),
            "official/dockerd": ("Docker", "容器引擎"),
            "official/collectd": ("指标", "监控"),
        }
        for key, words in expectations.items():
            with self.subTest(package=key):
                entry = self.payload["purposes"][key]
                self.assertEqual(entry["quality"], "exact")
                for word in words:
                    self.assertIn(word, entry["purpose"])

    def test_named_families_use_family_quality(self) -> None:
        examples = {
            "official/luci-i18n-base-zh-cn": "翻译",
            "official/luci-app-acme": "LuCI",
            "official/luci-proto-autoip": "接口类型",
            "official/kmod-bluetooth": "内核模块",
            "official/libarchive": "共享库",
            "official/python3-asyncio": "Python 3",
            "official/perl-cgi": "Perl",
            "official/ruby-json": "Ruby",
            "official/php8-mod-curl": "PHP",
            "official/collectd-mod-cpu": "collectd",
        }
        for key, expected_text in examples.items():
            with self.subTest(package=key):
                self.assertIn(key, self.payload["purposes"])
                entry = self.payload["purposes"][key]
                self.assertEqual(entry["quality"], "family")
                self.assertIn(expected_text, entry["purpose"])
        translation = self.payload["purposes"]["official/luci-i18n-base-zh-cn"]["purpose"]
        self.assertIn("base", translation)
        self.assertIn("zh-cn", translation)
        self.assertNotIn("base-zh", translation)

    def test_canonical_json_is_stable_and_utf8(self) -> None:
        first = generator.canonical_json(self.payload)
        reordered = {
            "purposes": self.payload["purposes"],
            "quality_counts": {
                "category": self.payload["quality_counts"]["category"],
                "family": self.payload["quality_counts"]["family"],
                "exact": self.payload["quality_counts"]["exact"],
            },
            "package_count": self.payload["package_count"],
            "catalog_version": self.payload["catalog_version"],
            "schema_version": self.payload["schema_version"],
        }
        self.assertEqual(first, generator.canonical_json(reordered))
        self.assertIn("基础文件系统".encode("utf-8"), first)
        self.assertTrue(first.endswith(b"\n"))

    def test_build_is_independent_of_shard_and_record_order(self) -> None:
        reversed_shards = {
            shard: list(reversed(self.records_by_shard[shard]))
            for shard in reversed(list(self.records_by_shard))
        }
        rebuilt = generator.build_purpose_catalog(
            reversed_shards, self.catalog_version
        )
        self.assertEqual(
            generator.canonical_json(self.payload),
            generator.canonical_json(rebuilt),
        )

    def test_generation_is_byte_for_byte_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            command = [
                sys.executable,
                str(SCRIPTS / "package_purpose_zh.py"),
                "--components-root",
                str(ROOT / "components"),
            ]
            subprocess.run(command + ["--output", str(first)], check=True)
            subprocess.run(command + ["--output", str(second)], check=True)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(
                first.read_bytes(),
                (ROOT / "components" / "package-purpose-zh.json").read_bytes(),
                "committed purpose catalog differs from the current deterministic generator",
            )
            generated = json.loads(first.read_text(encoding="utf-8"))
            generator.validate_purpose_catalog(
                generated, self.catalog_version, self.expected_keys
            )

    def test_browser_text_boundaries_and_index_update_contract(self) -> None:
        sample_key = next(iter(self.payload["purposes"]))
        for length in (generator.MAX_PURPOSE_LENGTH - 1, generator.MAX_PURPOSE_LENGTH):
            payload = copy.deepcopy(self.payload)
            payload["purposes"][sample_key]["purpose"] = "中" * length
            generator.validate_purpose_catalog(payload, self.catalog_version, self.expected_keys)

        compatibility = copy.deepcopy(self.payload)
        compatibility["purposes"][sample_key]["purpose"] = "兼容汉字：豈"
        generator.validate_purpose_catalog(compatibility, self.catalog_version, self.expected_keys)

        with tempfile.TemporaryDirectory() as directory:
            index_path = Path(directory) / "package-catalog.json"
            index = json.loads((ROOT / "components" / "package-catalog.json").read_text(encoding="utf-8"))
            index["purpose_catalog"]["sha256"] = "0" * 64
            index["purpose_catalog"]["package_count"] = 1
            index_path.write_text(
                json.dumps(index, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            purpose_bytes = generator.canonical_json(self.payload)
            generator.update_package_index_descriptor(index_path, self.payload, purpose_bytes)
            updated = json.loads(index_path.read_text(encoding="utf-8"))
            self.assertEqual(updated["purpose_catalog"]["package_count"], self.payload["package_count"])
            self.assertEqual(
                updated["purpose_catalog"]["sha256"], hashlib.sha256(purpose_bytes).hexdigest()
            )

    def test_update_index_cli_validates_before_writing_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            components = Path(directory) / "components"
            packages = components / "packages"
            packages.mkdir(parents=True)
            for shard in sorted((ROOT / "components" / "packages").glob("*.json")):
                (packages / shard.name).write_bytes(shard.read_bytes())
            output = components / "package-purpose-zh.json"
            original_sidecar = b"sentinel-sidecar\n"
            output.write_bytes(original_sidecar)
            (components / "package-catalog.json").write_text(
                '{"schema_version":2}\n', encoding="utf-8"
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPTS / "package_purpose_zh.py"),
                    "--components-root",
                    str(components),
                    "--output",
                    str(output),
                    "--update-index",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("exact schema_version 3 contract", result.stderr)
            self.assertEqual(output.read_bytes(), original_sidecar)

            valid_index = (ROOT / "components" / "package-catalog.json").read_bytes()
            real_index = components / "real-package-catalog.json"
            real_index.write_bytes(valid_index)
            index_path = components / "package-catalog.json"
            index_path.unlink()
            index_path.symlink_to(real_index.name)
            output.write_bytes(original_sidecar)
            symlink_result = subprocess.run(
                result.args, capture_output=True, text=True, check=False
            )
            self.assertEqual(symlink_result.returncode, 2)
            self.assertIn("refusing unsafe output target", symlink_result.stderr)
            self.assertEqual(output.read_bytes(), original_sidecar)

            index_path.unlink()
            hardlink_peer = components / "hardlink-package-catalog.json"
            hardlink_peer.write_bytes(valid_index)
            os.link(hardlink_peer, index_path)
            output.write_bytes(original_sidecar)
            hardlink_result = subprocess.run(
                result.args, capture_output=True, text=True, check=False
            )
            self.assertEqual(hardlink_result.returncode, 2)
            self.assertIn("refusing unsafe output target", hardlink_result.stderr)
            self.assertEqual(output.read_bytes(), original_sidecar)

    def test_validator_rejects_schema_count_key_and_text_corruption(self) -> None:
        mutations = []

        extra_top_key = copy.deepcopy(self.payload)
        extra_top_key["unexpected"] = True
        mutations.append(("extra top-level key", extra_top_key))

        wrong_schema = copy.deepcopy(self.payload)
        wrong_schema["schema_version"] = 2
        mutations.append(("wrong schema version", wrong_schema))

        wrong_quality_keys = copy.deepcopy(self.payload)
        wrong_quality_keys["quality_counts"]["other"] = 0
        mutations.append(("extra quality key", wrong_quality_keys))

        wrong_count = copy.deepcopy(self.payload)
        wrong_count["package_count"] += 1
        mutations.append(("wrong package count", wrong_count))

        sample_key = next(iter(self.payload["purposes"]))
        missing_inner_key = copy.deepcopy(self.payload)
        del missing_inner_key["purposes"][sample_key]["quality"]
        mutations.append(("missing purpose entry key", missing_inner_key))

        non_chinese = copy.deepcopy(self.payload)
        non_chinese["purposes"][sample_key]["purpose"] = "generic package"
        mutations.append(("non-Chinese purpose", non_chinese))

        too_long = copy.deepcopy(self.payload)
        too_long["purposes"][sample_key]["purpose"] = "中" * (generator.MAX_PURPOSE_LENGTH + 1)
        mutations.append(("purpose longer than browser contract", too_long))

        control_character = copy.deepcopy(self.payload)
        control_character["purposes"][sample_key]["purpose"] += "\n破坏"
        mutations.append(("control character", control_character))

        bad_quality = copy.deepcopy(self.payload)
        bad_quality["purposes"][sample_key]["quality"] = "guessed"
        mutations.append(("unknown quality", bad_quality))

        for label, payload in mutations:
            with self.subTest(label=label):
                with self.assertRaises(generator.PurposeCatalogError):
                    generator.validate_purpose_catalog(
                        payload, self.catalog_version, self.expected_keys
                    )

        with self.assertRaises(generator.PurposeCatalogError):
            generator.validate_purpose_catalog(
                self.payload,
                self.catalog_version,
                self.expected_keys | {"official/not-present"},
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
