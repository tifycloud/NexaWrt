#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/stage-package-repository.py"


class PackageRepositoryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.input_dir = self.root / "input"
        self.input_dir.mkdir()
        (self.input_dir / "hello-1.0-r0.apk").write_bytes(b"first apk\n")
        (self.input_dir / "luci-app-demo-2.0-r1.apk").write_bytes(b"second apk\n")

        self.private_key = self.root / "private.pem"
        self.public_key = self.root / "public.pem"
        subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.private_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.private_key.chmod(0o600)
        subprocess.run(
            ["openssl", "ec", "-in", str(self.private_key), "-pubout", "-out", str(self.public_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        public_der = subprocess.check_output(
            ["openssl", "pkey", "-pubin", "-in", str(self.public_key), "-outform", "DER"],
            stderr=subprocess.DEVNULL,
        )
        self.public_sha256 = hashlib.sha256(public_der).hexdigest()
        self.private_material = self.private_key.read_text(encoding="ascii").strip()

        self.fake_apk_log = self.root / "fake-apk.log"
        self.fake_apk = self.root / "fake-apk"
        self.fake_apk.write_text(
            """#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['FAKE_APK_LOG'], 'a', encoding='utf-8') as stream:
    stream.write(json.dumps(args) + '\\n')
if args and args[0] == 'mkndx':
    assert args[0:3] == ['mkndx', '--allow-untrusted', '--sign']
    assert args[4:6] == ['--output', 'packages.adb']
    packages = args[6:]
    payload = ''.join(f'{name} {hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()}\\n' for name in packages)
    public_data = pathlib.Path(os.environ['FAKE_APK_PUBLIC_KEY']).read_bytes()
    if os.environ.get('FAKE_APK_UNSIGNED') == '1':
        pathlib.Path('packages.adb').write_text(payload, encoding='ascii')
    else:
        signature = hashlib.sha256(public_data).hexdigest()
        pathlib.Path('packages.adb').write_text(f'SIGNED {signature}\\n{payload}', encoding='ascii')
    raise SystemExit(0)
if len(args) == 4 and args[0] == '--keys-dir' and args[2:] == ['verify', 'packages.adb']:
    assert '--allow-untrusted' not in args
    keys = list(pathlib.Path(args[1]).iterdir())
    assert len(keys) == 1 and keys[0].is_file()
    signature = hashlib.sha256(keys[0].read_bytes()).hexdigest()
    index = pathlib.Path('packages.adb').read_text(encoding='ascii')
    if os.environ.get('FAKE_APK_VERIFY_FAIL') == '1' or not index.startswith(f'SIGNED {signature}\\n'):
        raise SystemExit(17)
    raise SystemExit(0)
raise SystemExit(99)
""",
            encoding="utf-8",
        )
        self.fake_apk.chmod(0o755)
        self.lock = self.root / "package-repository.lock"
        self.asset_name = "nexawrt-apk-repository-25.12.5-r1.tar.gz"
        self.directory = "25.12/testing/aarch64_cortex-a53"
        self.write_lock()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_lock(self, architecture: str = "aarch64_cortex-a53") -> None:
        self.lock.write_text(
            "# strict, non-shell package repository lock\n"
            'NEXAWRT_REPOSITORY_SCHEMA="1"\n'
            'NEXAWRT_REPOSITORY_CHANNEL="testing"\n'
            'NEXAWRT_REPOSITORY_SERIES="25.12"\n'
            'NEXAWRT_REPOSITORY_RELEASE="25.12.5-r1"\n'
            f'NEXAWRT_REPOSITORY_ARCH="{architecture}"\n'
            f'NEXAWRT_REPOSITORY_BASE_URL="https://tifycloud.github.io/NexaWrt/packages/25.12/testing/{architecture}"\n'
            f'NEXAWRT_REPOSITORY_INDEX_URL="https://tifycloud.github.io/NexaWrt/packages/25.12/testing/{architecture}/packages.adb"\n'
            'NEXAWRT_REPOSITORY_RELEASE_TAG="package-repository-v25.12.5-r1"\n'
            f'NEXAWRT_REPOSITORY_ASSET="{self.asset_name}"\n'
            f'NEXAWRT_REPOSITORY_PUBLIC_SHA256="{self.public_sha256}"\n'
            f'NEXAWRT_REPOSITORY_PACKAGE_SET_SHA256="{"2" * 64}"\n'
            'NEXAWRT_REPOSITORY_MAX_ARCHIVE_BYTES="10485760"\n'
            'NEXAWRT_REPOSITORY_MAX_MEMBER_BYTES="1048576"\n'
            'NEXAWRT_REPOSITORY_MAX_TOTAL_BYTES="10485760"\n'
            'NEXAWRT_REPOSITORY_MAX_MEMBERS="100"\n',
            encoding="ascii",
        )

    def run_script(
        self,
        *arguments: object,
        expected: int = 0,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(SCRIPT), "--lock", str(self.lock), *(str(item) for item in arguments)]
        environment = os.environ.copy()
        environment.update(
            {
                "FAKE_APK_LOG": str(self.fake_apk_log),
                "FAKE_APK_PUBLIC_KEY": str(self.public_key),
            }
        )
        if extra_env:
            environment.update(extra_env)
        result = subprocess.run(command, text=True, capture_output=True, check=False, env=environment)
        self.assertEqual(
            result.returncode,
            expected,
            msg=f"command: {command!r}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertNotIn(self.private_material, result.stdout)
        self.assertNotIn(self.private_material, result.stderr)
        return result

    def build(
        self,
        *,
        public_key: Path | None = None,
        expected: int = 0,
        extra_env: dict[str, str] | None = None,
    ) -> tuple[Path, Path, subprocess.CompletedProcess[str]]:
        output = self.root / "repository"
        archive = self.root / self.asset_name
        result = self.run_script(
            "build",
            "--input-dir",
            self.input_dir,
            "--output-dir",
            output,
            "--archive",
            archive,
            "--private-key",
            self.private_key,
            "--public-key",
            public_key or self.public_key,
            "--apk-executable",
            self.fake_apk,
            expected=expected,
            extra_env=extra_env,
        )
        return output, archive, result

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def fake_apk_calls(self) -> list[list[str]]:
        if not self.fake_apk_log.exists():
            return []
        return [json.loads(line) for line in self.fake_apk_log.read_text(encoding="utf-8").splitlines()]

    def write_asset_json(self, archive: Path, digest: str | None = None) -> Path:
        asset_json = self.root / "asset.json"
        asset_json.write_text(
            json.dumps({"assets": [{"name": archive.name, "digest": "sha256:" + (digest or self.digest(archive))}]}),
            encoding="utf-8",
        )
        return asset_json

    def stage(
        self,
        archive: Path,
        *,
        sha256: str | None = None,
        asset_digest: str | None = None,
        expected: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        site = self.root / "site"
        site.mkdir(exist_ok=True)
        return self.run_script(
            "stage-pages",
            "--archive",
            archive,
            "--archive-sha256",
            sha256 or self.digest(archive),
            "--github-asset-json",
            self.write_asset_json(archive, asset_digest),
            "--site-dir",
            site,
            expected=expected,
        )

    def repack(self, archive: Path, transform) -> None:
        extracted = self.root / "repack"
        extracted.mkdir()
        with tarfile.open(archive, "r:*") as source:
            for member in source.getmembers():
                target = extracted.joinpath(*Path(member.name).parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = source.extractfile(member)
                assert stream is not None
                target.write_bytes(stream.read())
        transform(extracted / self.directory)
        archive.unlink()
        with tarfile.open(archive, "w:gz") as output:
            for path in sorted(item for item in extracted.rglob("*") if item.is_file()):
                output.add(path, arcname=path.relative_to(extracted).as_posix(), recursive=False)

    def write_malicious_archive(self, member: tarfile.TarInfo, payload: bytes = b"x") -> Path:
        archive = self.root / self.asset_name
        with tarfile.open(archive, "w") as output:
            if member.isfile():
                member.size = len(payload)
                output.addfile(member, io.BytesIO(payload))
            else:
                output.addfile(member)
        return archive

    def test_successful_build_verifies_signature_and_pages_stage(self) -> None:
        output, archive, _ = self.build()
        descriptor = json.loads((output / "repository.json").read_text(encoding="ascii"))
        self.assertIs(descriptor["index"]["signature_verified"], True)
        self.assertEqual(descriptor["index"]["sha256"], self.digest(output / "packages.adb"))
        self.assertEqual(descriptor["public_sha256"], self.public_sha256)
        calls = self.fake_apk_calls()
        self.assertEqual(calls[0][0:3], ["mkndx", "--allow-untrusted", "--sign"])
        self.assertEqual(calls[1][2:], ["verify", "packages.adb"])
        self.assertNotIn("--allow-untrusted", calls[1])
        self.assertFalse(Path(calls[1][1]).exists(), "verification keys directory was not removed")
        with tarfile.open(archive, "r:*") as source:
            names = source.getnames()
            self.assertFalse(any(name.endswith(".pem") or "nexawrt-apk-verify" in name for name in names))
            self.assertFalse(any(self.private_material.encode("ascii") in source.extractfile(member).read() for member in source.getmembers() if member.isfile()))
        self.stage(archive)
        staged = self.root / "site/packages" / self.directory
        self.assertTrue((staged / "packages.adb").is_file())

    def test_build_rejects_wrong_locked_public_key(self) -> None:
        wrong_private = self.root / "wrong-private.pem"
        wrong_public = self.root / "wrong-public.pem"
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(wrong_private)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "ec", "-in", str(wrong_private), "-pubout", "-out", str(wrong_public)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        output, archive, result = self.build(public_key=wrong_public, expected=1)
        self.assertIn("locked public key", result.stderr.lower())
        self.assertFalse(output.exists())
        self.assertFalse(archive.exists())

    def test_build_fails_when_apk_verify_rejects_index(self) -> None:
        output, archive, result = self.build(expected=1, extra_env={"FAKE_APK_VERIFY_FAIL": "1"})
        self.assertIn("apk verify refused or failed", result.stderr.lower())
        self.assertEqual(self.fake_apk_calls()[-1][2:], ["verify", "packages.adb"])
        self.assertFalse(output.exists())
        self.assertFalse(archive.exists())

    def test_build_fails_for_unsigned_index(self) -> None:
        output, archive, result = self.build(expected=1, extra_env={"FAKE_APK_UNSIGNED": "1"})
        self.assertIn("apk verify refused or failed", result.stderr.lower())
        self.assertFalse(output.exists())
        self.assertFalse(archive.exists())

    def test_pages_rejects_tampered_signature_receipt(self) -> None:
        _, archive, _ = self.build()

        def alter(repository: Path) -> None:
            descriptor_path = repository / "repository.json"
            descriptor = json.loads(descriptor_path.read_text(encoding="ascii"))
            descriptor["index"]["signature_verified"] = False
            descriptor_path.write_text(json.dumps(descriptor), encoding="ascii")

        self.repack(archive, alter)
        result = self.stage(archive, expected=1)
        self.assertIn("signature verification receipt", result.stderr.lower())

    def test_rejects_path_traversal(self) -> None:
        archive = self.write_malicious_archive(tarfile.TarInfo("../../escaped.apk"))
        self.stage(archive, expected=1)
        self.assertFalse((self.root / "escaped.apk").exists())

    def test_rejects_symbolic_and_hard_links(self) -> None:
        for link_type in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            with self.subTest(link_type=link_type):
                archive = self.root / self.asset_name
                if archive.exists():
                    archive.unlink()
                member = tarfile.TarInfo(f"{self.directory}/packages.adb")
                member.type = link_type
                member.linkname = "/etc/passwd" if link_type == tarfile.SYMTYPE else f"{self.directory}/payload.apk"
                self.write_malicious_archive(member)
                self.assertIn("link", self.stage(archive, expected=1).stderr.lower())

    def test_rejects_archive_and_api_digest_tampering(self) -> None:
        _, archive, _ = self.build()
        actual = self.digest(archive)
        wrong = "0" * 64 if actual != "0" * 64 else "1" * 64
        self.assertIn("sha-256 mismatch", self.stage(archive, sha256=wrong, expected=1).stderr.lower())
        self.assertIn("github api asset digest", self.stage(archive, asset_digest=wrong, expected=1).stderr.lower())

    def test_rejects_wrong_repository_architecture(self) -> None:
        _, archive, _ = self.build()

        def alter(repository: Path) -> None:
            descriptor_path = repository / "repository.json"
            descriptor = json.loads(descriptor_path.read_text())
            descriptor["architecture"] = "x86_64"
            descriptor_path.write_text(json.dumps(descriptor), encoding="utf-8")

        self.repack(archive, alter)
        self.assertIn("wrong architecture", self.stage(archive, expected=1).stderr.lower())

    def test_build_rejects_symlinked_apk(self) -> None:
        target = self.root / "outside.apk"
        target.write_bytes(b"outside")
        (self.input_dir / "linked.apk").symlink_to(target)
        output, _, result = self.build(expected=1)
        self.assertIn("regular, single-link", result.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
