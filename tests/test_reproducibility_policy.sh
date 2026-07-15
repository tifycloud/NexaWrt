#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/compare-reproducible-builds.sh"
mkdir -p "$ROOT_DIR/.work"
TMP="$(mktemp -d "$ROOT_DIR/.work/test-reproducibility-policy.XXXXXX")"
OUT_ROOT="$ROOT_DIR/release-staging/test-reproducibility-policy.$$"
mkdir -p "$OUT_ROOT"
trap 'rm -rf "$TMP" "$OUT_ROOT"' EXIT
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
MANIFEST='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
SBOM='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'
fail() { echo "test_reproducibility_policy: $*" >&2; exit 1; }
hash_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi; }

write_checksums() {
  local directory="$1"
  (
    cd "$directory"
    while IFS= read -r file; do hash_file "$file"; done < <(find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort)
  ) > "$directory/SHA256SUMS"
}

make_replica() {
  local directory="$1" serial="$2" timestamp="$3" flavor="${4:-official}"
  rm -rf "$directory"
  mkdir -p "$directory/EVIDENCE"
  printf firmware > "$directory/$IMAGE"
  printf 'base-files - 1\n' > "$directory/$MANIFEST"
  printf '{"bomFormat":"CycloneDX","serialNumber":"%s","metadata":{"timestamp":"%s"},"components":[{"type":"library","name":"base-files","version":"1"}]}\n' "$serial" "$timestamp" > "$directory/$SBOM"
  for file in config.buildinfo feeds.buildinfo profiles.json version.buildinfo BUILD-MANIFEST.txt DO-NOT-FLASH.txt; do
    printf '%s\n' "$file" > "$directory/$file"
  done
  printf 'inputs\n' > "$directory/EVIDENCE/INPUTS.sha256"
  printf 'config\n' > "$directory/EVIDENCE/resolved.config"
  printf 'source state\n' > "$directory/EVIDENCE/SOURCE-STATE.txt"
  printf '%s\n' "$serial" > "$directory/EVIDENCE/BUILD-ENVIRONMENT.txt"
  printf 'build log\n' > "$directory/EVIDENCE/build.log"
  printf 'evidence sums\n' > "$directory/EVIDENCE/EVIDENCE.sha256"
  if [[ "$flavor" == nss ]]; then
    mkdir -p "$directory/LICENSES/nss-firmware"
    printf 'third party\n' > "$directory/THIRD_PARTY_NOTICES.md"
    printf 'license\n' > "$directory/LICENSES/nss-firmware/LICENSE.md"
  fi
  write_checksums "$directory"
}

expect_rejected() {
  local label="$1"; shift
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    fail "$label unexpectedly passed"
  fi
}

make_replica "$TMP/a" urn:uuid:a 2026-01-01T00:00:00Z
make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
"$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/success/verified-dist" >/dev/null
[[ -f "$OUT_ROOT/success/verified-dist/REPRODUCIBILITY.json" ]] || fail "verified output metadata missing"
grep -Fq '"reproducible":true' "$OUT_ROOT/success/verified-dist/REPRODUCIBILITY.json"

printf changed >> "$TMP/b/$IMAGE"; write_checksums "$TMP/b"
expect_rejected "firmware mismatch" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/fail/verified-dist"
make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
python3 - "$TMP/b/$SBOM" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    document = json.load(stream)
document["components"][0]["version"] = "2"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(document, stream)
PY
write_checksums "$TMP/b"
expect_rejected "SBOM mismatch" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/fail2/verified-dist"

make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
sed -i.bak '\|  ./config.buildinfo$|d' "$TMP/b/SHA256SUMS"; rm -f "$TMP/b/SHA256SUMS.bak"
expect_rejected "missing checksum entry" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/missing/verified-dist"
make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
head -n 1 "$TMP/b/SHA256SUMS" >> "$TMP/b/SHA256SUMS"
expect_rejected "duplicate checksum entry" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/duplicate/verified-dist"
make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
python3 - "$TMP/b/SHA256SUMS" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
hash_value = lines[0].split()[0]
lines[0] = f"{hash_value}  ./../escape"
path.write_text("\n".join(lines) + "\n")
PY
expect_rejected "unsafe checksum path" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/unsafe-sum/verified-dist"
make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
printf extra > "$TMP/b/unexpected.txt"; write_checksums "$TMP/b"
expect_rejected "unexpected replica file" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/extra/verified-dist"
make_replica "$TMP/b" urn:uuid:b 2026-01-02T00:00:00Z
rm "$TMP/b/config.buildinfo"; ln -s feeds.buildinfo "$TMP/b/config.buildinfo"
expect_rejected "replica symlink" "$SCRIPT" official "$TMP/a" "$TMP/b" "$OUT_ROOT/symlink-input/verified-dist"

outside="$(mktemp -d)/verified-dist"
trap 'rm -rf "$TMP" "$OUT_ROOT" "$(dirname "$outside")"' EXIT
expect_rejected "workspace-external output" "$SCRIPT" official "$TMP/a" "$TMP/a" "$outside"
mkdir -p "$OUT_ROOT/output-target" "$OUT_ROOT/symlink-output"
ln -s "$OUT_ROOT/output-target" "$OUT_ROOT/symlink-output/verified-dist"
expect_rejected "symlink output" "$SCRIPT" official "$TMP/a" "$TMP/a" "$OUT_ROOT/symlink-output/verified-dist"

make_replica "$TMP/nss-a" urn:uuid:a 2026-01-01T00:00:00Z nss
make_replica "$TMP/nss-b" urn:uuid:b 2026-01-02T00:00:00Z nss
"$SCRIPT" nss "$TMP/nss-a" "$TMP/nss-b" "$OUT_ROOT/nss/verified-dist" >/dev/null

echo 'reproducibility checksum exact-set, safe-path, symlink, and fail-closed comparison policy: OK'
