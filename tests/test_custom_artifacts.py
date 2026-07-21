#!/usr/bin/env python3
"""Small regression fixtures for custom artifact finalization and auditing."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "custom-artifacts.py"
CUSTOM_BUILD = ROOT / "scripts" / "custom-build.sh"
COMMIT = "1" * 40
REQUEST_HASH = "a" * 64


class CustomArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="nexawrt-custom-artifacts-")
        self.root = pathlib.Path(self.temporary.name)
        self.artifact_dir = self.root / "artifacts"
        self.artifact_dir.mkdir()
        (self.artifact_dir / "firmware.img.gz").write_bytes(b"fixture firmware\n")
        (self.artifact_dir / "build.log").write_text("fixture build\n", encoding="utf-8")
        (self.artifact_dir / "custom-imagebuilder-packages.json").write_text(
            json.dumps(["base-files", "luci"]) + "\n",
            encoding="utf-8",
        )
        self.request_path = self.root / "request.json"
        self.request_path.write_text(
            json.dumps(
                {
                    "catalog_version": "2026.07.20",
                    "flavor": "official",
                    "packages": ["base-files", "luci"],
                    "request_hash": REQUEST_HASH,
                    "resolved_components": ["web-ui"],
                    "target": {"id": "x86_64"},
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def command(self, operation: str, **overrides: str) -> list[str]:
        values = {
            "artifact_dir": str(self.artifact_dir),
            "expected_commit": COMMIT,
            "expected_target": "x86_64",
            "expected_flavor": "official",
            "expected_request_hash": REQUEST_HASH,
        }
        values.update(overrides)
        command = ["python3", str(TOOL), operation]
        for key, value in values.items():
            command.extend([f"--{key.replace('_', '-')}", value])
        if operation == "finalize":
            command.extend(["--request-file", str(self.request_path)])
        else:
            command.extend(["--manifest", str(self.artifact_dir / "custom-build-manifest.json")])
        return command

    def finalize(self) -> None:
        subprocess.run(self.command("finalize"), check=True, capture_output=True, text=True)

    def assert_audit_rejected(self, **overrides: str) -> None:
        result = subprocess.run(self.command("audit", **overrides), check=False, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_finalize_and_audit_small_fixture(self) -> None:
        self.finalize()
        manifest_path = self.artifact_dir / "custom-build-manifest.json"
        checksums_path = self.artifact_dir / "SHA256SUMS"
        self.assertTrue(manifest_path.is_file() and not manifest_path.is_symlink() and manifest_path.stat().st_size > 0)
        self.assertTrue(checksums_path.is_file() and not checksums_path.is_symlink() and checksums_path.stat().st_size > 0)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["request_hash"], REQUEST_HASH)
        self.assertEqual(manifest["target"], "x86_64")
        self.assertEqual(manifest["flavor"], "official")
        self.assertEqual(manifest["commit"], COMMIT)
        self.assertIn("custom-build-manifest.json", checksums_path.read_text(encoding="utf-8"))
        subprocess.run(self.command("audit"), check=True, capture_output=True, text=True)
        subprocess.run(
            ["sha256sum", "--check", "--strict", "SHA256SUMS"],
            cwd=self.artifact_dir,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_missing_or_symlinked_manifest_is_rejected(self) -> None:
        self.finalize()
        manifest_path = self.artifact_dir / "custom-build-manifest.json"
        manifest_path.unlink()
        self.assert_audit_rejected()
        outside = self.root / "outside-manifest.json"
        outside.write_text("{}\n", encoding="utf-8")
        manifest_path.symlink_to(outside)
        self.assert_audit_rejected()

    def test_checksum_traversal_and_missing_manifest_entry_are_rejected(self) -> None:
        self.finalize()
        checksums_path = self.artifact_dir / "SHA256SUMS"
        lines = checksums_path.read_text(encoding="utf-8").splitlines()
        checksums_path.write_text(
            "\n".join(line for line in lines if not line.endswith("  custom-build-manifest.json")) + "\n",
            encoding="utf-8",
        )
        self.assert_audit_rejected()
        outside = self.root / "outside.bin"
        outside.write_bytes(b"outside\n")
        outside_hash = hashlib.sha256(outside.read_bytes()).hexdigest()
        checksums_path.write_text(f"{outside_hash}  ../outside.bin\n", encoding="utf-8")
        self.assert_audit_rejected()

    def test_corruption_and_identity_mismatch_are_rejected(self) -> None:
        self.finalize()
        self.assert_audit_rejected(expected_request_hash="b" * 64)
        self.assert_audit_rejected(expected_commit="2" * 40)
        with (self.artifact_dir / "firmware.img.gz").open("ab") as stream:
            stream.write(b"corruption\n")
        self.assert_audit_rejected()

    def test_generator_failure_is_not_hidden_by_heredoc_control_flow(self) -> None:
        source = CUSTOM_BUILD.read_text(encoding="utf-8")
        self.assertIsNone(
            re.search(r"<<\s*['\"]?[A-Za-z0-9_]+['\"]?\s*\|\|\s*\n\s*fail\b", source),
            "a fail handler after a heredoc operator is consumed as heredoc input",
        )
        self.assertIn('if ! python3 "$CUSTOM_ARTIFACTS" finalize', source)
        self.request_path.write_text("{not-json\n", encoding="utf-8")
        result = subprocess.run(self.command("finalize"), check=False, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.artifact_dir / "custom-build-manifest.json").exists())
        self.assertFalse((self.artifact_dir / "SHA256SUMS").exists())

    def test_manifest_argument_cannot_escape_artifact_directory(self) -> None:
        self.finalize()
        outside = self.root / "outside-manifest.json"
        shutil.copyfile(self.artifact_dir / "custom-build-manifest.json", outside)
        result = subprocess.run(
            self.command("audit")[:-2] + ["--manifest", str(outside)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
