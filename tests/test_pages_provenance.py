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
                         contract_version: int = module.VM_CONTRACT_V1,
                         missing_label: str | None = None,
                         missing_smoke: str | None = None,
                         label_updates: dict[str, str] | None = None,
                         smoke_updates: dict[str, str] | None = None) -> dict[str, bytes]:
    names = module.vm_expected_names(version, contract_version)
    labels = {
        "ARTIFACT_CLASS": "VM_DISTRIBUTION_IMAGE" if contract_version == 1 else "VM_DISTRIBUTION_SET",
        "OPENWRT_VERSION": "24.10.2",
        "TARGET": "x86-64",
        "MODE": "release",
        "VM_ONLY": "true",
        "NOT_AX9000_FIRMWARE": "true",
        "HARDWARE_VALIDATION": "false",
        "NSS_VALIDATION": "false",
        "VALIDATION_SCOPE": "QEMU_BOOT_AND_USERSPACE_ONLY" if contract_version == 1 else "QEMU_RUNTIME_ALL_VARIANTS",
        "IMAGEBUILDER_URL": "https://downloads.openwrt.org/releases/24.10.2/targets/x86/64/imagebuilder.tar.zst",
        "IMAGEBUILDER_SHA256": "1" * 64,
        "RELEASE_TAG": f"vm-x86_64-{version}",
        "RELEASE_VERSION": version,
        "SSH_DEFAULT": "disabled",
        "SSH_AUTHORIZED_KEYS": "absent",
    }
    result_dir = module.VM_RESULT_ROOT if contract_version == module.VM_CONTRACT_V1 else module.VM_RESULT_ROOT / "raw_bios"
    smoke = {
        "status": "PASS",
        "target": "x86-64",
        "vm_only": "true",
        "not_ax9000_firmware": "true",
        "hardware_validation": "false",
        "nss_validation": "false",
        "exact_release_image": "true",
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
        "serial_log": str(result_dir / "serial.log"),
        "ssh_probe_log": str(result_dir / "ssh-port-probe.txt"),
    }
    if contract_version == module.VM_CONTRACT_V1:
        smoke.update({"image": names["image"], "qemu_boot": "PASS"})
        image_keys = ["image"]
    else:
        labels.update({
            "RELEASE_CONTRACT": "vm-x86_64/v2",
            "PUBLISHED_VARIANTS": module.VM_PUBLISHED_VARIANTS,
            "ESXI_VALIDATION": "not-tested",
        })
        smoke.update({
            "release_contract": "vm-x86_64/v2",
            "esxi_validation": "not-tested",
            **{f"{variant}_file": names[variant] for variant in module.VM_VARIANTS},
            **{f"{variant}_qemu": "runtime-pass" for variant in module.VM_VARIANTS},
        })
        image_keys = list(module.VM_VARIANTS)
    labels.update(label_updates or {})
    smoke.update(smoke_updates or {})
    if missing_label is not None:
        labels.pop(missing_label)
    if missing_smoke is not None:
        smoke.pop(missing_smoke)

    payloads: dict[str, bytes] = {}
    for key in image_keys:
        image = f"exact x86_64 VM image: {key}\n".encode()
        payloads[names[key]] = image
        payloads[names[f"{key}_checksum"]] = (
            f"{hashlib.sha256(image).hexdigest()}  {names[key]}\n".encode("ascii")
        )
    payloads.update({
        names["manifest"]: b"base-files - 1\n",
        names["artifact_labels"]: "".join(f'{key}="{value}"\n' for key, value in labels.items()).encode(),
        names["readme"]: b"NexaWrt x86_64 VM only\n",
        names["smoke_report"]: "".join(f"{key}={value}\n" for key, value in smoke.items()).encode(),
    })
    provenance_keys = module.VM_V1_PROVENANCE_ASSETS if contract_version == 1 else module.VM_V2_PROVENANCE_ASSETS
    for key, name in provenance_keys.items():
        payloads[name] = f"{key} bundle".encode()
    checksum_keys = [key for image_key in image_keys for key in (image_key, f"{image_key}_checksum")]
    checksum_keys += ["manifest", "artifact_labels", "readme", "smoke_report"]
    payloads[names["checksums"]] = "".join(
        f"{hashlib.sha256(payloads[names[key]]).hexdigest()}  {names[key]}\n" for key in checksum_keys
    ).encode("ascii")
    return payloads


def verify_vm_fixture(payloads: dict[str, bytes], version: str = "v0.1.0-rc.1", *,
                      contract_version: int = module.VM_CONTRACT_V1,
                      attested_subjects: list[tuple[str, str]] | None = None) -> tuple[str, dict]:
    names = module.vm_expected_names(version, contract_version)
    release_id = 88 if contract_version == 1 else 89
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
    assert candidate is not None and candidate[4] == contract_version
    source_digest = "c" * 40
    originals = (module.resolve_tag_commit, module.require_main_ancestor, module.download_asset, module.verify_vm_attestation)
    try:
        module.resolve_tag_commit = lambda gh, tag: source_digest
        module.require_main_ancestor = lambda commit, trusted: None
        def fake_download(gh: Path, asset: dict, destination: Path, budget: module.DownloadBudget) -> None:
            budget.reserve(asset["size"])
            destination.write_bytes(payloads[asset["name"]])
        module.download_asset = fake_download
        def fake_attest(gh: Path, subject: Path, bundle: Path, tag: str, digest: str) -> None:
            if attested_subjects is not None:
                attested_subjects.append((subject.name, bundle.name))
        module.verify_vm_attestation = fake_attest
        return module.verify_vm_candidate(Path("/trusted/gh"), candidate, "d" * 40, module.DownloadBudget())
    finally:
        module.resolve_tag_commit, module.require_main_ancestor, module.download_asset, module.verify_vm_attestation = originals


def verify_vm_stable_fixture(payloads: dict[str, bytes], source_proof: dict,
                             *, mutate_body: str | None = None) -> tuple[str, dict]:
    source_version = "v0.1.0-rc.1"
    stable_version = "v0.1.0"
    source_tag = f"vm-x86_64-{source_version}"
    stable_tag = f"vm-x86_64-{stable_version}"
    digest = "c" * 40
    names = module.vm_expected_names(source_version, module.VM_CONTRACT_V2)
    source_raw = {
        "id": source_proof["release_id"], "tag_name": source_tag, "draft": False,
        "prerelease": True, "immutable": True, "published_at": "2026-07-18T02:00:00Z",
        "assets": [{"id": asset["id"], "name": asset["name"], "state": "uploaded", "size": asset["size"]}
                   for asset in source_proof["assets"].values()],
    }
    body = "\n".join([
        f"# NexaWrt x86_64 VM {stable_version}", "",
        f"This stable release is an **in-place promotion of {source_tag}** after user-performed VMware ESXi acceptance.", "",
        "## Byte and source identity",
        f"- Stable tag: `{stable_tag}`",
        f"- Source RC tag: `{source_tag}`",
        f"- Source commit: `{digest}` (both tags point to this exact commit)",
        f"- Evidence path: `evidence/vm-esxi/{source_tag}.json` at repository commit `{'d' * 40}`",
    ])
    if mutate_body is not None:
        body = mutate_body
    stable_raw = {
        "id": 190, "tag_name": stable_tag, "target_commitish": digest,
        "name": f"NexaWrt x86_64 VM {stable_version}", "body": body,
        "draft": False, "prerelease": False, "immutable": True, "published_at": "2026-07-19T02:00:00Z",
        "assets": [
            {"id": 19000 + index, "name": name, "state": "uploaded", "size": len(payloads[name]),
             "digest": f"sha256:{hashlib.sha256(payloads[name]).hexdigest()}"}
            for index, name in enumerate(names.values(), 1)
        ],
    }
    source_candidate = module.vm_candidate_assets(source_raw)
    stable_candidate = module.vm_candidate_assets(stable_raw)
    assert source_candidate is not None and stable_candidate is not None
    originals = (module.resolve_tag_commit, module.require_main_ancestor, module.download_asset, module.verify_vm_stable_evidence)
    try:
        module.resolve_tag_commit = lambda gh, tag: digest
        module.require_main_ancestor = lambda commit, trusted: None
        module.download_asset = lambda gh, asset, destination, budget: (budget.reserve(asset["size"]), destination.write_bytes(payloads[asset["name"]]))
        module.verify_vm_stable_evidence = lambda promotion, trusted, release_dir, published_at: None
        return module.verify_vm_stable_candidate(Path("/trusted/gh"), stable_candidate, source_candidate,
                                                 source_proof, "d" * 40, module.DownloadBudget())
    finally:
        module.resolve_tag_commit, module.require_main_ancestor, module.download_asset, module.verify_vm_stable_evidence = originals

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
    assert set(vm_proof) == {
        "release_id", "source_digest", "contract_version", "assets", "verified_subjects", "validation",
    }
    assert vm_proof["contract_version"] == module.VM_CONTRACT_V1
    assert vm_proof["validation"] == {"qemu": {"raw_bios": "runtime-pass"}, "esxi": "not-tested"}
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
    for status, challenge in (("200", "true"), ("403", "false")):
        expect_verification_error(
            lambda status=status, challenge=challenge: verify_vm_fixture(
                vm_evidence_payloads(smoke_updates={"http_status": status, "auth_challenge": challenge})
            ),
            f"VM smoke report accepted inconsistent HTTP/auth pair: {status}/{challenge}",
        )

    v2_attested: list[tuple[str, str]] = []
    v2_payloads = vm_evidence_payloads(contract_version=module.VM_CONTRACT_V2)
    v2_tag, v2_proof = verify_vm_fixture(
        v2_payloads, contract_version=module.VM_CONTRACT_V2, attested_subjects=v2_attested,
    )
    assert v2_tag == "vm-x86_64-v0.1.0-rc.1"
    assert v2_proof["contract_version"] == module.VM_CONTRACT_V2
    assert len(v2_proof["assets"]) == 21
    assert v2_proof["verified_subjects"] == [*module.VM_VARIANTS, "checksums"]
    assert v2_proof["validation"] == {
        "qemu": {variant: "runtime-pass" for variant in module.VM_VARIANTS},
        "esxi": "not-tested",
    }
    v2_names = module.vm_expected_names("v0.1.0-rc.1", module.VM_CONTRACT_V2)
    assert v2_attested == [
        (v2_names[variant], v2_names[f"provenance_{variant}"]) for variant in module.VM_VARIANTS
    ] + [(v2_names["checksums"], v2_names["provenance_checksums"])]
    stable_tag, stable_proof = verify_vm_stable_fixture(v2_payloads, v2_proof)
    assert stable_tag == "vm-x86_64-v0.1.0"
    assert stable_proof["source_rc_tag"] == v2_tag
    assert stable_proof["source_rc_release_id"] == v2_proof["release_id"]
    assert stable_proof["source_digest"] == v2_proof["source_digest"]
    assert stable_proof["validation"] == {
        "qemu": {variant: "runtime-pass" for variant in module.VM_VARIANTS},
        "esxi": "validated",
    }
    assert all(
        stable_proof["assets"][key][field] == v2_proof["assets"][key][field]
        for key in stable_proof["assets"] for field in ("name", "size", "sha256")
    )
    assert all(stable_proof["assets"][key]["id"] != v2_proof["assets"][key]["id"] for key in stable_proof["assets"])
    invalid_stable = {
        "id": 191, "tag_name": "vm-x86_64-v0.1.0", "target_commitish": "c" * 40,
        "name": "NexaWrt x86_64 VM v0.1.0", "body": "missing promotion bindings",
        "draft": False, "prerelease": False, "immutable": True, "published_at": "2026-07-19T02:00:00Z", "assets": [],
    }
    assert module.vm_candidate_assets(invalid_stable) is None
    for key in ("RELEASE_CONTRACT", "PUBLISHED_VARIANTS", "ESXI_VALIDATION"):
        expect_verification_error(
            lambda key=key: verify_vm_fixture(
                vm_evidence_payloads(contract_version=2, missing_label=key), contract_version=2,
            ),
            f"v2 artifact labels accepted missing contract key: {key}",
        )
    for key in ("release_contract", "raw_bios_file", "iso_bios_qemu", "vmdk_efi_file", "esxi_validation"):
        expect_verification_error(
            lambda key=key: verify_vm_fixture(
                vm_evidence_payloads(contract_version=2, missing_smoke=key), contract_version=2,
            ),
            f"v2 smoke report accepted missing exact key: {key}",
        )
    expect_verification_error(
        lambda: verify_vm_fixture(
            vm_evidence_payloads(contract_version=2, smoke_updates={"iso_efi_qemu": "boot-pass"}),
            contract_version=2,
        ),
        "v2 smoke report accepted less than a runtime pass",
    )
    expect_verification_error(
        lambda: verify_vm_fixture(
            vm_evidence_payloads(contract_version=2, smoke_updates={"vmdk_bios_file": "other.vmdk"}),
            contract_version=2,
        ),
        "v2 smoke report accepted a filename not bound to the release asset",
    )
    expect_verification_error(
        lambda: verify_vm_fixture(
            vm_evidence_payloads(contract_version=2, label_updates={"ESXI_VALIDATION": "passed"}),
            contract_version=2,
        ),
        "v2 labels claimed ESXi validation",
    )
    expect_verification_error(
        lambda: verify_vm_fixture(
            vm_evidence_payloads(
                contract_version=2,
                smoke_updates={"serial_log": str(module.VM_RESULT_ROOT / "serial.log")},
            ),
            contract_version=2,
        ),
        "v2 smoke report accepted the legacy v1 root-level serial path",
    )
    expect_verification_error(
        lambda: verify_vm_fixture(
            vm_evidence_payloads(
                contract_version=2,
                smoke_updates={"ssh_probe_log": str(module.VM_RESULT_ROOT / "iso_bios" / "ssh-port-probe.txt")},
            ),
            contract_version=2,
        ),
        "v2 smoke report accepted a non-raw_bios variant log path",
    )

    bad_sidecar = vm_evidence_payloads(contract_version=2)
    bad_sidecar[v2_names["iso_bios"]] += b"tampered"
    expect_verification_error(
        lambda: verify_vm_fixture(bad_sidecar, contract_version=2),
        "v2 image was not bound to its independent checksum sidecar",
    )
    bad_sums = vm_evidence_payloads(contract_version=2)
    bad_sums[v2_names["checksums"]] = bad_sums[v2_names["checksums"]].replace(b"a", b"b", 1)
    expect_verification_error(
        lambda: verify_vm_fixture(bad_sums, contract_version=2),
        "v2 SHA256SUMS tampering was accepted",
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
