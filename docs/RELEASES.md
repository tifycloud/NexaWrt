# Versioned RAM-test prereleases

The RAM-test release workflow publishes reproducible **prereleases** for the NexaWrt AX9000. These artifacts are initramfs RAM-boot candidates only; they are not approved for flashing. Hardware, UART, recovery, and stress-test approval remain separate mandatory gates.

## Accepted tags

GitHub Actions keeps broad tag globs so both release families trigger the workflow, but preflight rejects every tag except these complete forms:

- Official: `ram-test-vMAJOR.MINOR.PATCH-rc.N`
- NSS: `ram-test-nss-vMAJOR.MINOR.PATCH-rc.N`

`MAJOR`, `MINOR`, `PATCH`, and `N` are decimal integers. Each is either `0` or begins with `1`-`9`; leading zeroes are forbidden. Examples:

- Accepted: `ram-test-v1.4.0-rc.1`
- Accepted: `ram-test-nss-v1.4.0-rc.2`
- Rejected: `ram-test-v1.4.0`
- Rejected: `ram-test-v01.4.0-rc.1`
- Rejected: `ram-test-nss-v1.4.0-rc.01`

The workflow derives `release_version` by removing only the flavor prefix. For example, both `ram-test-v1.4.0-rc.1` and `ram-test-nss-v1.4.0-rc.1` derive `v1.4.0-rc.1`.

Tags must be **lightweight tags** that point directly to a commit. Annotated and signed tag objects are rejected. The tagged commit must be an ancestor of `origin/main`, the workflow definition must come from that same tagged commit, and no GitHub release may already exist for the tag.

GitHub **Immutable Releases** is a hard release gate. Before either build replica starts, preflight calls the official `repos/{owner}/{repo}/immutable-releases` API with `X-GitHub-Api-Version: 2026-03-10` and fails closed unless `enabled` is exactly `true`. The endpoint requires repository Administration read access, which the normal workflow `GITHUB_TOKEN` does not request; configure `IMMUTABLE_RELEASES_READ_TOKEN` as a repository Actions secret containing a short-lived fine-grained token restricted to this repository with **Administration: read**. Do not reuse a broadly scoped personal token, do not grant write administration, and do not bypass this gate.

## Release procedure

1. Update local `main` from the canonical repository and choose the exact commit to release. Do not release an unmerged side-branch commit.
2. Create or rotate the short-lived fine-grained read token, save it as the repository Actions secret `IMMUTABLE_RELEASES_READ_TOKEN`, and confirm immutable releases are enabled using that token:

   ```sh
   gh api \
     -H 'Accept: application/vnd.github+json' \
     -H 'X-GitHub-Api-Version: 2026-03-10' \
     repos/tifycloud/NexaWrt/immutable-releases --jq '.enabled'
   ```

   The command must print exactly `true`. Authentication, authorization, missing-secret, network, malformed-response, and disabled-state results all block release. The secret is used only for this read-only preflight request; the workflow returns to its normal `GITHUB_TOKEN` for other GitHub API operations.

3. Run the repository release-policy tests before tagging:

   ```sh
   tests/test_workflow_policy.sh
   tests/test_static.sh
   ```

4. Choose the next release-candidate version and construct exactly one accepted tag. For example:

   ```sh
   tag=ram-test-v1.4.0-rc.1
   # NSS alternative:
   # tag=ram-test-nss-v1.4.0-rc.1
   ```

5. Confirm that the tag does not already exist locally or remotely and that no release exists:

   ```sh
   ! git show-ref --verify --quiet "refs/tags/$tag"
   ! git ls-remote --exit-code --tags origin "refs/tags/$tag"
   ! gh release view "$tag"
   ```

   The final command should fail specifically because the release is absent. Authentication, network, rate-limit, and other API failures are not evidence that a release is absent.

6. Create a lightweight tag at the intended commit. Do not use `git tag -a` or `git tag -s`:

   ```sh
   commit=$(git rev-parse origin/main)
   git merge-base --is-ancestor "$commit" origin/main
   git tag "$tag" "$commit"
   test "$(git cat-file -t "refs/tags/$tag")" = commit
   ```

7. Push only the selected tag:

   ```sh
   git push origin "refs/tags/$tag"
   ```

8. Monitor the `NexaWrt AX9000 reproducible RAM-test release` workflow. The workflow builds two independent replicas, enforces exact reproducibility, verifies the immutable `verified-dist`, creates a deterministic archive and checksum, attests the release subjects, uploads the exact publish directory, and checks the exact remote asset-name set before publishing.
9. After completion, verify the release is published as a prerelease, is not a draft, uses the triggering tag, has a publication timestamp, is not marked latest, and reports `immutable=true`. The workflow also requires exactly six remote assets: the versioned archive, its checksum, and four provenance bundles. Any extra, missing, duplicate, non-`uploaded`, zero-sized, negative-sized, or otherwise malformed asset fails final verification.

The GitHub Pages job performs a full checkout of `refs/heads/main` with `fetch-depth: 0` and treats that checkout as its trust root. For every candidate, `scripts/verify-pages-releases.py` requires an immutable prerelease whose release tag is a lightweight tag pointing directly to a commit that is an ancestor of the trusted `main`. It downloads by Release asset ID and validates exactly six assets: the version-qualified verified-dist archive, its external `.sha256`, and the `archive`, `checksums`, `firmware`, and `sbom` provenance bundles. Extra, missing, duplicate, non-`uploaded`, zero-sized, negative-sized, or otherwise malformed assets exclude the release.

The verifier downloads only the archive and `archive.provenance.bundle.json` first and authenticates that largest untrusted input before fetching the remaining four assets. It considers at most the 12 newest candidates per flavor, enforces a 768 MiB run-wide download budget, and the Pages build job has a 30-minute timeout. The external checksum must bind the downloaded archive exactly. Before Python `tarfile` sees any member, the verifier decompresses the complete gzip payload into a temporary tar under a strict 320 MiB cap covering every physical header, extension record, data block, padding byte, end marker, and trailing byte. It then scans every 512-byte physical header itself, validates the unsigned header checksum and strict octal size, rejects base-256 sizes, PAX `x`/`g`, GNU `L`/`K`/`S`, and every unknown or non-regular-file/non-directory type, requires two zero end blocks, and permits only zero-filled trailing blocks. Only that prevalidated raw tar is passed to `tarfile`; the existing safe-path, duplicate-name, member-count, individual-size, total-uncompressed-member-byte, and checksum/firmware/SBOM subject-size limits still apply. Release archives are generated deterministically with POSIX ustar (`tar --format=ustar`) so the trusted publisher never needs PAX or GNU extension headers. Its internal `SHA256SUMS` must bind both the AX9000 initramfs firmware and the CycloneDX SBOM extracted from that archive. The four provenance bundles are verified against the archive, internal `SHA256SUMS`, firmware, and SBOM subjects respectively. Every verification constrains the repository to `tifycloud/NexaWrt`, the signer workflow to `tifycloud/NexaWrt/.github/workflows/release.yml`, the source ref to the candidate `refs/tags/<tag>`, and the source digest to the lightweight tag's trusted `main`-ancestor commit; self-hosted runners are denied, so the accepted provenance must come from a GitHub-hosted runner.

Only after all of those checks pass does `scripts/verify-pages-releases.py` emit the strict proof manifest consumed by `scripts/generate-pages-data.py`. The page generator requires a matching proof and Release ID before it can expose a download. A manually created immutable/prerelease lookalike—even one with plausible names and an exact six-asset shape—is therefore excluded when it lacks the trusted signer, source, subject digests, or proof manifest entry. The index refreshes on `main` updates, after a successful release workflow, on manual dispatch, and every six hours. This periodic revalidation is defense in depth: a release that no longer satisfies the contract disappears from the generated download index instead of remaining labeled verified.

Pages schema version 2 also embeds the strictly validated device catalog from `devices/xiaomi-ax9000/device.json`. At the current hardware stage the only supported target is Xiaomi AX9000, and the only accepted state is `hardware_status=unverified`, `production_ready=false`, channel `ram-test`, and capabilities `{ram_boot: true, factory: false, sysupgrade: false}`. These are RAM-only candidates: they are not hardware-validated, production-ready, or flashable firmware. The build and release preflights validate the same record before doing work. The browser fails closed if the device record, repository URLs, release-to-device binding, history ordering, unique tags, `latest` entry, or RAM-only boundary is inconsistent. Production or stable channels must not be added merely because cloud builds and immutable prereleases succeed; they require the signed AX9000 hardware evidence defined in `docs/PRODUCTION-READINESS.md`.

## Published names

For `release_version=v1.4.0-rc.1`, the archive and checksum names are:

- Official archive: `NexaWrt-AX9000-official-v1.4.0-rc.1-verified-dist.tar.gz`
- Official checksum: `NexaWrt-AX9000-official-v1.4.0-rc.1-verified-dist.tar.gz.sha256`
- NSS archive: `NexaWrt-AX9000-nss-v1.4.0-rc.1-verified-dist.tar.gz`
- NSS checksum: `NexaWrt-AX9000-nss-v1.4.0-rc.1-verified-dist.tar.gz.sha256`

The archive provenance attestation subject is the exact version-qualified archive path. Release titles are human-readable and include the flavor where needed, for example `NexaWrt AX9000 v1.4.0-rc.1 RAM-test prerelease` or `NexaWrt AX9000 NSS v1.4.0-rc.1 RAM-test prerelease`.

## Draft recovery

The publish job intentionally creates a draft first, uploads every asset, compares the complete remote asset-name set with the local publish directory, and only then publishes it. A failed publish job can therefore leave a partial draft.

Draft creation is immediately resolved with `gh release view` to a positive numeric `databaseId`. All draft asset inspection and publication then use the fixed REST `releases/{release_id}` identity. GitHub's REST `releases/tags/{tag}` endpoint does not expose draft releases and can return `404` until publication; the workflow uses that endpoint only after publication, when it verifies that the by-tag result has the same Release ID and immutable final state.

Do **not** manually publish a partial draft and do not upload replacement assets by hand. Once published, an immutable release cannot be repaired in place; use a new release-candidate tag for corrections. First inspect the release and the failed workflow logs:

```sh
tag=ram-test-v1.4.0-rc.1
gh release view "$tag" --json isDraft,isPrerelease,tagName,publishedAt,url
gh release view "$tag" --json assets --jq '.assets[].name'
```

If and only if the release is still a draft for the exact triggering tag:

1. Preserve the failed workflow logs and note the failure cause.
2. Delete the draft without deleting the Git tag:

   ```sh
   gh release delete "$tag" --yes
   test "$(git ls-remote --tags origin "refs/tags/$tag" | wc -l | tr -d ' ')" = 1
   ```

3. Correct external conditions if needed, then use GitHub Actions to rerun the failed publish job. Its retained verified artifact will be downloaded and reverified before a new draft is created. If the artifacts have expired or the rerun cannot reuse them, delete the draft as above and rerun the complete workflow for the unchanged tag.

If the workflow implementation itself must change, the failed tag still identifies the old workflow commit and must remain immutable evidence. Do not move or recreate the failed tag. Merge the fix to `main`, delete only the draft release, and create the next release-candidate tag (for example, `rc.2`) from the corrected `main` commit.

If the release is already published (`isDraft=false` or `publishedAt` is set), stop. Do not delete or overwrite it as routine draft recovery. Investigate the final-state verification failure and treat any correction as an explicit release-management incident; normally a new release-candidate tag is required.

## x86_64 VM candidate releases

The x86_64 virtual-machine release channel is independent from AX9000 RAM-test releases. A VM candidate tag must match exactly:

```text
vm-x86_64-vMAJOR.MINOR.PATCH-rc.N
```

It is a prerelease for QEMU/UTM/PVE-style virtual machines only. It is not AX9000 firmware and does not assert hardware, NSS, Wi-Fi, NAND/UBI, recovery, or flash validation.

### Browser release procedure

1. Merge all VM release changes to trusted `main` and ensure repository policy checks pass.
2. Open **Actions → NexaWrt x86_64 VM release → Run workflow**.
3. Select the `main` branch and enter the complete tag, for example `vm-x86_64-v0.1.0-rc.1`.
4. The preflight reads the current remote `main` commit SHA from GitHub, requires the browser dispatch `GITHUB_SHA` to equal that exact SHA, rejects an existing tag or release, and creates the lightweight tag at that SHA. Build, attestation, draft creation, and final publication continue to check out and reverify the same pinned SHA and remote tag. A historical `main` ancestor is not sufficient for a new browser-triggered release.
5. The workflow builds the exact no-key release image and boots that same compressed image in QEMU. It requires QEMU to remain alive, LuCI HTTP to return an accepted result, the serial VM-only labels to appear, runtime evidence that Dropbear is disabled and not running and `authorized_keys` is absent, and a separate probe showing that the host port forwarded to guest port 22 exposes no SSH service.
6. Only after those checks pass does the workflow attest the image and `SHA256SUMS`, create and recheck the exact draft assets, recheck the pinned source/tag and repository Immutable Releases setting immediately before publication, and publish the result as an immutable prerelease.

A successful VM release contains exactly these nine assets:

```text
NexaWrt-x86_64-vX.Y.Z-rc.N-generic-ext4-combined.img.gz
NexaWrt-x86_64-vX.Y.Z-rc.N-generic-ext4-combined.img.gz.sha256
NexaWrt-x86_64-vX.Y.Z-rc.N-generic-ext4-combined.manifest
artifact-labels.env
README-VM.txt
smoke-report.txt
SHA256SUMS
image.provenance.bundle.json
checksums.provenance.bundle.json
```

The Pages verifier accepts a VM release only when all of the following hold:

- it is an immutable, non-draft prerelease whose lightweight tag resolves to a commit in the trusted `main` history;
- its uploaded asset set is exactly the nine names above, with no additions, omissions, duplicates, invalid sizes, or AX9000-labelled names;
- the external image checksum and `SHA256SUMS` match the downloaded assets exactly;
- `artifact-labels.env` has the exact 15-key release safety contract;
- `smoke-report.txt` has exactly these 23 keys: `status`, `target`, `image`, `vm_only`, `not_ax9000_firmware`, `hardware_validation`, `nss_validation`, `exact_release_image`, `qemu_boot`, `serial_labels`, `http`, `ssh_runtime_evidence`, `ssh_port_probe`, `ssh`, `authorized_keys`, `dropbear_enabled`, `dropbear_running`, `http_status`, `auth_challenge`, `http_host_port`, `ssh_host_port`, `serial_log`, and `ssh_probe_log`;
- those 23 fields bind the exact published image and report PASS/expected values for QEMU boot, LuCI HTTP, VM-only serial labels, Dropbear disabled and not running, absent `authorized_keys`, and no SSH service on the host port forwarded to guest port 22;
- the image and `SHA256SUMS` provenance bundles verify against `tifycloud/NexaWrt/.github/workflows/vm-release.yml`, the release source digest, and a GitHub-hosted runner;
- the generated proof binds every one of the nine assets by asset ID, name, size, and downloaded SHA-256; the Pages generator then requires those identities to match the same GitHub Release API response (and its trusted `digest` when provided).

If any VM condition fails, the site hides that VM candidate. This VM fail-closed path is isolated from a separately valid AX9000 catalog, and the reverse is also true. A VM PASS is evidence only for the exact x86_64 virtual-machine image and release pipeline; it is not permission to flash AX9000 and is not an AX9000 production-readiness claim.

Do not move a VM release tag, replace assets, or manually repair a published immutable release. Merge the correction and use the next RC tag. See [`docs/VM-X86_64.md`](VM-X86_64.md) for download and QEMU instructions.
