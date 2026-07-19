#!/usr/bin/env python3
"""Unit policy checks for the Pages Release attestation gate."""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import io
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify-pages-releases.py"
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("verify_pages_releases", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def archive_bytes(*, extra: tuple[str, bytes] | None = None) -> bytes:
    firmware = b"firmware-subject\n"
    sbom = b'{"bomFormat":"CycloneDX"}\n'
    checksums = (
        f"{hashlib.sha256(firmware).hexdigest()}  ./{module.FIRMWARE}\n"
        f"{hashlib.sha256(sbom).hexdigest()}  ./{module.SBOM}\n"
    ).encode("ascii")
    members = [
        (f"verified-dist/{module.FIRMWARE}", firmware),
        (f"verified-dist/{module.SBOM}", sbom),
        (f"verified-dist/{module.INTERNAL_CHECKSUMS}", checksums),
    ]
    if extra is not None:
        members.insert(0, extra)
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, payload in members:
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mtime = 1
            archive.addfile(info, io.BytesIO(payload))
    return output.getvalue()


def tar_header(name: str, size: int, typeflag: bytes = b"0", *, size_field: bytes | None = None) -> bytes:
    header = bytearray(module.TAR_BLOCK_BYTES)
    encoded_name = name.encode("ascii")
    assert len(encoded_name) <= 100
    header[:len(encoded_name)] = encoded_name
    header[100:108] = b"0000644\0"
    header[108:116] = b"0000000\0"
    header[116:124] = b"0000000\0"
    header[124:136] = size_field if size_field is not None else f"{size:011o}\0".encode("ascii")
    header[136:148] = b"00000000001\0"
    header[148:156] = b"        "
    header[156:157] = typeflag
    header[257:263] = b"ustar\0"
    header[263:265] = b"00"
    checksum = sum(header)
    header[148:156] = f"{checksum:06o}\0 ".encode("ascii")
    return bytes(header)


def padded(payload: bytes) -> bytes:
    padding = (-len(payload)) % module.TAR_BLOCK_BYTES
    return payload + bytes(padding)


def gzip_raw(raw: bytes) -> bytes:
    return gzip.compress(raw, compresslevel=9, mtime=0)


def extension_archive(typeflag: bytes, payload: bytes = b"metadata\n") -> bytes:
    raw = tar_header("PaxHeaders/extension", len(payload), typeflag) + padded(payload)
    return gzip_raw(raw + bytes(module.TAR_BLOCK_BYTES * 2))


def tarfile_extension_archive(kind: str) -> bytes:
    output = io.BytesIO()
    if kind == "pax-local":
        with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
            info = tarfile.TarInfo("verified-dist/pax-local")
            info.size = 1
            info.pax_headers = {"comment": "forbidden local PAX metadata"}
            archive.addfile(info, io.BytesIO(b"x"))
    elif kind == "pax-global":
        with tarfile.open(
            fileobj=output, mode="w:gz", format=tarfile.PAX_FORMAT,
            pax_headers={"comment": "forbidden global PAX metadata"},
        ) as archive:
            info = tarfile.TarInfo("verified-dist/pax-global")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
    elif kind == "gnu-longname":
        with tarfile.open(fileobj=output, mode="w:gz", format=tarfile.GNU_FORMAT) as archive:
            info = tarfile.TarInfo(f"verified-dist/{'x' * 120}")
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
    else:
        raise AssertionError(f"unknown extension fixture: {kind}")
    return output.getvalue()


def reject_archive_payload(payload: bytes, message: str) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        archive = work / "invalid.tar.gz"
        subjects = work / "subjects"
        subjects.mkdir()
        archive.write_bytes(payload)
        expect_verification_error(lambda: module.extract_subjects(archive, subjects), message)


def raw_release(metadata: dict, release_id: int, flavor: str, version: str, published_at: str,
                sizes: dict[str, int] | None = None) -> dict:
    prefix = "ram-test-" if flavor == "official" else f"ram-test-{flavor}-"
    names = module.expected_names(metadata, flavor, version)
    assets = [
        {
            "id": release_id * 10 + index,
            "name": name,
            "state": "uploaded",
            "size": sizes[name] if sizes is not None else 1,
        }
        for index, name in enumerate(names.values(), 1)
    ]
    return {
        "id": release_id,
        "tag_name": f"{prefix}{version}",
        "draft": False,
        "prerelease": True,
        "immutable": True,
        "published_at": published_at,
        "assets": assets,
    }


def release_fixture(payloads: dict[str, bytes]) -> tuple[dict, tuple]:
    metadata = module.load_device_metadata()
    version = "v1.10.0-rc.1"
    raw = raw_release(
        metadata,
        77,
        "official",
        version,
        "2026-07-18T01:00:00Z",
        {name: len(payload) for name, payload in payloads.items()},
    )
    candidate = module.candidate_assets(raw, metadata)
    assert candidate is not None
    return metadata, candidate


def expect_verification_error(callable_value, message: str) -> None:
    try:
        callable_value()
    except module.VerificationError:
        return
    raise AssertionError(message)


def vm_evidence_payloads(version: str = "v0.1.0-rc.1", *,
                         missing_label: str | None = None,
                         missing_smoke: str | None = None,
                         label_updates: dict[str, str] | None = None,
                         smoke_updates: dict[str, str] | None = None) -> dict[str, bytes]:
    names = module.vm_expected_names(version)
    image = b"exact x86_64 VM image\n"
    labels = {
        "ARTIFACT_CLASS": "VM_DISTRIBUTION_IMAGE",
        "OPENWRT_VERSION": "24.10.2",
        "TARGET": "x86-64",
        "MODE": "release",
        "VM_ONLY": "true",
        "NOT_AX9000_FIRMWARE": "true",
        "HARDWARE_VALIDATION": "false",
        "NSS_VALIDATION": "false",
        "VALIDATION_SCOPE": "QEMU_BOOT_AND_USERSPACE_ONLY",
        "IMAGEBUILDER_URL": "https://downloads.openwrt.org/releases/24.10.2/targets/x86/64/imagebuilder.tar.zst",
        "IMAGEBUILDER_SHA256": "1" * 64,
        "RELEASE_TAG": f"vm-x86_64-{version}",
        "RELEASE_VERSION": version,
        "SSH_DEFAULT": "disabled",
        "SSH_AUTHORIZED_KEYS": "absent",
    }
    smoke = {
        "status": "PASS",
        "target": "x86-64",
        "image": names["image"],
        "vm_only": "true",
        "not_ax9000_firmware": "true",
        "hardware_validation": "false",
        "nss_validation": "false",
        "exact_release_image": "true",
        "qemu_boot": "PASS",
        "serial_labels": "PASS",
        "http": "PASS",
        "ssh_runtime_evidence": "PASS",
        "ssh_port_probe": "PASS",
        "ssh": "DISABLED_BY_DEFAULT",
        "authorized_keys": "ABSENT",
        "dropbear_enabled": "NO",
        "dropbear_running": "NO",
        "http_status": "200",
        "auth_challenge": "false",
        "http_host_port": "18080",
        "ssh_host_port": "18022",
        "serial_log": "/home/runner/work/NexaWrt/NexaWrt/vm-release-results/x86-64/serial.log",
        "ssh_probe_log": "/home/runner/work/NexaWrt/NexaWrt/vm-release-results/x86-64/ssh-port-probe.txt",
    }
    labels.update(label_updates or {})
    smoke.update(smoke_updates or {})
    if missing_label is not None:
        labels.pop(missing_label)
    if missing_smoke is not None:
        smoke.pop(missing_smoke)
    payloads = {
        names["image"]: image,
        names["image_checksum"]: f"{hashlib.sha256(image).hexdigest()}  {names['image']}\n".encode("ascii"),
        names["manifest"]: b"base-files - 1\n",
        names["artifact_labels"]: "".join(f'{key}="{value}"\n' for key, value in labels.items()).encode(),
        names["readme"]: b"NexaWrt x86_64 VM only\n",
        names["smoke_report"]: "".join(f"{key}={value}\n" for key, value in smoke.items()).encode(),
        names["provenance_image"]: b"image bundle",
        names["provenance_checksums"]: b"checksums bundle",
    }
    checksum_names = ["image", "image_checksum", "manifest", "artifact_labels", "readme", "smoke_report"]
    payloads[names["checksums"]] = "".join(
        f"{hashlib.sha256(payloads[names[key]]).hexdigest()}  {names[key]}\n" for key in checksum_names
    ).encode("ascii")
    return payloads


def verify_vm_fixture(payloads: dict[str, bytes], version: str = "v0.1.0-rc.1") -> tuple[str, dict]:
    names = module.vm_expected_names(version)
    release_id = 88
    raw = {
        "id": release_id,
        "tag_name": f"vm-x86_64-{version}",
        "draft": False,
        "prerelease": True,
        "immutable": True,
        "published_at": "2026-07-18T02:00:00Z",
        "assets": [
            {"id": release_id * 100 + index, "name": name, "state": "uploaded", "size": len(payloads[name])}
            for index, name in enumerate(names.values(), 1)
        ],
    }
    candidate = module.vm_candidate_assets(raw)
    assert candidate is not None
    source_digest = "c" * 40
    originals = (module.resolve_tag_commit, module.require_main_ancestor, module.download_asset, module.verify_vm_attestation)
    try:
        module.resolve_tag_commit = lambda gh, tag: source_digest
        module.require_main_ancestor = lambda commit, trusted: None
        def fake_download(gh: Path, asset: dict, destination: Path, budget: module.DownloadBudget) -> None:
            budget.reserve(asset["size"])
            destination.write_bytes(payloads[asset["name"]])
        module.download_asset = fake_download
        module.verify_vm_attestation = lambda gh, subject, bundle, tag, digest: None
        return module.verify_vm_candidate(Path("/trusted/gh"), candidate, "d" * 40, module.DownloadBudget())
    finally:
        module.resolve_tag_commit, module.require_main_ancestor, module.download_asset, module.verify_vm_attestation = originals


def main() -> None:
    archive = archive_bytes()
    archive_name = "NexaWrt-AX9000-official-v1.10.0-rc.1-verified-dist.tar.gz"
    checksum_name = f"{archive_name}.sha256"
    checksum = f"{hashlib.sha256(archive).hexdigest()}  {archive_name}\n".encode("ascii")
    payloads = {
        archive_name: archive,
        checksum_name: checksum,
        "archive.provenance.bundle.json": b"archive bundle",
        "checksums.provenance.bundle.json": b"checksums bundle",
        "firmware.provenance.bundle.json": b"firmware bundle",
        "sbom.provenance.bundle.json": b"sbom bundle",
    }
    metadata, candidate = release_fixture(payloads)
    source_digest = "a" * 40
    events: list[tuple[str, str, str] | tuple[str, str]] = []

    original_resolve = module.resolve_tag_commit
    original_ancestor = module.require_main_ancestor
    original_download = module.download_asset
    original_attestation = module.verify_attestation
    try:
        module.resolve_tag_commit = lambda gh, tag: source_digest
        module.require_main_ancestor = lambda commit, trusted: (
            None if (commit, trusted) == (source_digest, "b" * 40) else (_ for _ in ()).throw(AssertionError())
        )

        def fake_download(gh: Path, asset: dict, destination: Path, budget: module.DownloadBudget) -> None:
            budget.reserve(asset["size"])
            events.append(("download", asset["name"]))
            destination.write_bytes(payloads[asset["name"]])
            assert destination.stat().st_size == asset["size"]

        def fake_attestation(gh: Path, subject: Path, bundle: Path, tag: str, digest: str) -> None:
            events.append(("attest", subject.name, bundle.name))

        module.download_asset = fake_download
        module.verify_attestation = fake_attestation
        tag, proof = module.verify_candidate(
            Path("/trusted/gh"), candidate, metadata, "b" * 40, module.DownloadBudget()
        )
    finally:
        module.resolve_tag_commit = original_resolve
        module.require_main_ancestor = original_ancestor
        module.download_asset = original_download
        module.verify_attestation = original_attestation

    assert tag == "ram-test-v1.10.0-rc.1"
    assert proof["release_id"] == 77
    assert proof["source_digest"] == source_digest
    assert proof["archive_sha256"] == hashlib.sha256(archive).hexdigest()
    assert proof["checksum_sha256"] == hashlib.sha256(checksum).hexdigest()
    assert proof["verified_subjects"] == ["archive", "checksums", "firmware", "sbom"]
    assert events[:3] == [
        ("download", archive_name),
        ("download", "archive.provenance.bundle.json"),
        ("attest", archive_name, "archive.provenance.bundle.json"),
    ]
    assert [event for event in events if event[0] == "attest"] == [
        ("attest", archive_name, "archive.provenance.bundle.json"),
        ("attest", module.INTERNAL_CHECKSUMS, "checksums.provenance.bundle.json"),
        ("attest", module.FIRMWARE, "firmware.provenance.bundle.json"),
        ("attest", module.SBOM, "sbom.provenance.bundle.json"),
    ]

    command = module.attestation_command(
        Path("/trusted/gh"), Path(archive_name), Path("archive.provenance.bundle.json"), tag, source_digest
    )
    for pair in (
        ["--repo", "tifycloud/NexaWrt"],
        ["--signer-workflow", "tifycloud/NexaWrt/.github/workflows/release.yml"],
        ["--source-ref", f"refs/tags/{tag}"],
        ["--source-digest", source_digest],
        ["--predicate-type", "https://slsa.dev/provenance/v1"],
        ["--cert-oidc-issuer", "https://token.actions.githubusercontent.com"],
    ):
        index = command.index(pair[0])
        assert command[index:index + 2] == pair
    assert "--deny-self-hosted-runners" in command

    expected = module.expected_names(metadata, "official", "v1.10.0-rc.1")
    bounded_raw = raw_release(metadata, 88, "official", "v1.10.0-rc.1", "2026-07-18T01:00:00Z")
    next(asset for asset in bounded_raw["assets"] if asset["name"] == expected["checksum"])["size"] = module.MAX_CHECKSUM_BYTES + 1
    assert module.candidate_assets(bounded_raw, metadata) is None
    next(asset for asset in bounded_raw["assets"] if asset["name"] == expected["checksum"])["size"] = 1
    next(asset for asset in bounded_raw["assets"] if asset["name"] == expected["provenance_archive"])["size"] = module.MAX_PROVENANCE_BYTES + 1
    assert module.candidate_assets(bounded_raw, metadata) is None

    candidates = [
        raw_release(metadata, 100 + rc, "official", f"v2.0.0-rc.{rc}", "2026-07-18T02:00:00Z")
        for rc in range(1, module.MAX_CANDIDATES_PER_FLAVOR + 3)
    ]
    selected = module.select_candidates(candidates, metadata)
    assert len(selected) == module.MAX_CANDIDATES_PER_FLAVOR
    assert selected[0][3] == f"v2.0.0-rc.{module.MAX_CANDIDATES_PER_FLAVOR + 2}"
    assert selected[-1][3] == "v2.0.0-rc.3"

    tiny_budget = module.DownloadBudget(limit=3)
    tiny_budget.reserve(2)
    try:
        tiny_budget.reserve(2)
    except ValueError:
        pass
    else:
        raise AssertionError("global release download budget did not fail closed")

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        subjects = work / "subjects"
        subjects.mkdir()
        bad_archive = work / "bad.tar.gz"
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as tar:
            info = tarfile.TarInfo("verified-dist/../escape")
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))
        bad_archive.write_bytes(output.getvalue())
        expect_verification_error(
            lambda: module.extract_subjects(bad_archive, subjects),
            "unsafe archive path was accepted",
        )

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        subjects = work / "subjects"
        subjects.mkdir()
        oversized_total = work / "oversized-total.tar.gz"
        oversized_total.write_bytes(archive_bytes(extra=("verified-dist/filler", b"x" * 32)))
        original_total_limit = module.MAX_TOTAL_MEMBER_BYTES
        try:
            module.MAX_TOTAL_MEMBER_BYTES = 31
            expect_verification_error(
                lambda: module.extract_subjects(oversized_total, subjects),
                "archive uncompressed member total was not bounded",
            )
        finally:
            module.MAX_TOTAL_MEMBER_BYTES = original_total_limit

    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        subjects = work / "subjects"
        subjects.mkdir()
        checksum_heavy = work / "checksum-heavy.tar.gz"
        checksum_heavy.write_bytes(archive)
        original_checksum_limit = module.MAX_INTERNAL_CHECKSUM_BYTES
        try:
            module.MAX_INTERNAL_CHECKSUM_BYTES = 8
            expect_verification_error(
                lambda: module.extract_subjects(checksum_heavy, subjects),
                "internal checksum subject size was not bounded",
            )
        finally:
            module.MAX_INTERNAL_CHECKSUM_BYTES = original_checksum_limit

    for kind in ("pax-local", "pax-global", "gnu-longname"):
        reject_archive_payload(
            tarfile_extension_archive(kind),
            f"{kind} extension header was accepted before tarfile parsing",
        )
    for typeflag in (b"K", b"S"):
        reject_archive_payload(
            extension_archive(typeflag),
            f"GNU {typeflag.decode('ascii')} extension header was accepted",
        )

    raw_archive = gzip.decompress(archive)
    original_stream_limit = module.MAX_TAR_STREAM_BYTES
    try:
        module.MAX_TAR_STREAM_BYTES = len(raw_archive) - 1
        reject_archive_payload(archive, "complete decompressed tar stream was not bounded")
    finally:
        module.MAX_TAR_STREAM_BYTES = original_stream_limit

    damaged_header = bytearray(raw_archive)
    damaged_header[0] ^= 1
    reject_archive_payload(gzip_raw(bytes(damaged_header)), "damaged tar header checksum was accepted")

    base256 = bytes([0x80]) + bytes(11)
    reject_archive_payload(
        gzip_raw(tar_header("verified-dist/base256", 0, size_field=base256) + bytes(1024)),
        "base-256 tar size was accepted",
    )
    invalid_octal = b"00000000008\0"
    reject_archive_payload(
        gzip_raw(tar_header("verified-dist/bad-octal", 0, size_field=invalid_octal) + bytes(1024)),
        "non-octal tar size was accepted",
    )
    reject_archive_payload(
        gzip_raw(tar_header("verified-dist/symlink", 0, typeflag=b"2") + bytes(1024)),
        "unknown or non-regular tar member type was accepted",
    )
    reject_archive_payload(
        gzip_raw(tar_header("verified-dist/truncated", 1024) + bytes(512)),
        "truncated tar member data was accepted",
    )
    reject_archive_payload(
        gzip_raw(tar_header("verified-dist/no-end", 0)),
        "tar stream without legal end blocks was accepted",
    )
    reject_archive_payload(
        gzip_raw(tar_header("verified-dist/one-end", 0) + bytes(512)),
        "tar stream with one end block was accepted",
    )
    nonzero_tail = bytearray(raw_archive)
    nonzero_tail[-1] = 1
    reject_archive_payload(gzip_raw(bytes(nonzero_tail)), "non-zero tar trailing bytes were accepted")

    original_header_limit = module.MAX_ARCHIVE_MEMBERS
    try:
        module.MAX_ARCHIVE_MEMBERS = 2
        reject_archive_payload(archive, "physical tar header count was not bounded")
    finally:
        module.MAX_ARCHIVE_MEMBERS = original_header_limit

    vm_tag, vm_proof = verify_vm_fixture(vm_evidence_payloads())
    assert vm_tag == "vm-x86_64-v0.1.0-rc.1"
    assert set(vm_proof) == {"release_id", "source_digest", "assets", "verified_subjects"}
    assert set(vm_proof["assets"]) == set(module.vm_expected_names("v0.1.0-rc.1"))
    assert all(set(asset) == {"id", "name", "size", "sha256"} for asset in vm_proof["assets"].values())
    assert len({asset["id"] for asset in vm_proof["assets"].values()}) == 9

    critical_labels = {
        "SSH_AUTHORIZED_KEYS", "TARGET", "MODE", "RELEASE_TAG", "RELEASE_VERSION", "VALIDATION_SCOPE",
    }
    critical_smoke = {
        "qemu_boot", "ssh_runtime_evidence", "ssh_port_probe", "ssh", "authorized_keys",
        "dropbear_enabled", "dropbear_running", "http_host_port", "ssh_host_port",
        "serial_log", "ssh_probe_log",
    }
    for key in critical_labels:
        expect_verification_error(
            lambda key=key: verify_vm_fixture(vm_evidence_payloads(missing_label=key)),
            f"VM artifact labels accepted missing critical key: {key}",
        )
    for key in critical_smoke:
        expect_verification_error(
            lambda key=key: verify_vm_fixture(vm_evidence_payloads(missing_smoke=key)),
            f"VM smoke report accepted missing critical key: {key}",
        )
    expect_verification_error(
        lambda: verify_vm_fixture(vm_evidence_payloads(smoke_updates={"dropbear_running": "YES"})),
        "VM smoke report accepted a running Dropbear service",
    )
    expect_verification_error(
        lambda: verify_vm_fixture(vm_evidence_payloads(label_updates={"RELEASE_VERSION": "v9.9.9-rc.9"})),
        "VM artifact labels accepted a mismatched release version",
    )
    for field in ("qemu_boot", "ssh_runtime_evidence", "ssh_port_probe"):
        expect_verification_error(
            lambda field=field: verify_vm_fixture(vm_evidence_payloads(smoke_updates={field: "FAIL"})),
            f"VM smoke report accepted failed runtime evidence: {field}",
        )
    for field, value in (
        ("http_host_port", "80"),
        ("ssh_host_port", "22"),
        ("http_host_port", "65536"),
        ("ssh_host_port", "018022"),
    ):
        expect_verification_error(
            lambda field=field, value=value: verify_vm_fixture(vm_evidence_payloads(smoke_updates={field: value})),
            f"VM smoke report accepted invalid non-privileged port: {field}={value}",
        )
    expect_verification_error(
        lambda: verify_vm_fixture(vm_evidence_payloads(smoke_updates={"ssh_host_port": "18080"})),
        "VM smoke report accepted identical HTTP and SSH host ports",
    )
    for field, value in (
        ("serial_log", "/tmp/replay/vm-release-results/x86-64/serial.log"),
        ("serial_log", "/home/runner/work/NexaWrt/NexaWrt/vm-release-results/x86-64/../serial.log"),
        ("ssh_probe_log", "/home/runner/work/NexaWrt/NexaWrt/vm-release-results/x86-64/serial.log"),
        ("ssh_probe_log", "ssh-port-probe.txt"),
    ):
        expect_verification_error(
            lambda field=field, value=value: verify_vm_fixture(vm_evidence_payloads(smoke_updates={field: value})),
            f"VM smoke report accepted unsafe or replayable log path: {field}",
        )

    print(
        "Pages provenance policy: strict AX archive trust plus exact VM evidence and per-asset proof identity OK"
    )


if __name__ == "__main__":
    main()
