#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TARGET="${1:-}"
DIST_DIR_RAW="${2:-}"
FLAVOR="${3:-}"
OUTPUT_RAW="${4:-}"
IMAGE='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
REMOTE_DIR=/tmp/nexawrt-runtime-evidence

fail() { echo "runtime evidence collection failed: $*" >&2; exit 1; }
[[ -n "$TARGET" && -n "$DIST_DIR_RAW" && -n "$FLAVOR" && -n "$OUTPUT_RAW" ]] ||
  fail "usage: $0 SSH_TARGET VERIFIED_DIST official|nss OUTPUT_DIRECTORY"
[[ "$TARGET" =~ ^[A-Za-z0-9._%+@:-]+$ && "$TARGET" != -* ]] || fail "unsafe SSH target"
case "$FLAVOR" in official|nss) ;; *) fail "flavor must be official or nss" ;; esac
command -v ssh >/dev/null || fail "ssh is required"
command -v python3 >/dev/null || fail "python3 is required"

DIST_DIR="$(python3 - "$DIST_DIR_RAW" <<'PY'
import os, pathlib, sys
raw = pathlib.Path(os.path.abspath(sys.argv[1]))
if raw.is_symlink(): raise SystemExit(1)
resolved = raw.resolve(strict=True)
if not resolved.is_dir(): raise SystemExit(1)
print(resolved)
PY
)" || fail "unsafe or missing verified distribution directory"

OUTPUT_DIR="$(python3 - "$ROOT_DIR" "$OUTPUT_RAW" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
allowed = root / "hardware-evidence"
if os.path.lexists(allowed) and (allowed.is_symlink() or not allowed.is_dir()): raise SystemExit(1)
raw = pathlib.Path(os.path.abspath(sys.argv[2]))
try: relative = raw.relative_to(allowed)
except ValueError: raise SystemExit("outside hardware-evidence")
if not relative.parts: raise SystemExit("output may not be hardware-evidence root")
current = allowed
for part in relative.parts:
    current /= part
    if os.path.lexists(current) and current.is_symlink(): raise SystemExit("symlink component")
print(raw.resolve(strict=False))
PY
)" || fail "output must be a non-symlink path below $ROOT_DIR/hardware-evidence"

[[ -f "$DIST_DIR/$IMAGE" && -f "$DIST_DIR/BUILD-MANIFEST.txt" && -f "$DIST_DIR/SHA256SUMS" ]] ||
  fail "verified distribution is incomplete"
(cd "$DIST_DIR" && sha256sum -c SHA256SUMS >/dev/null) || fail "verified distribution checksums failed"
grep -Eq "^[0-9a-fA-F]{64}  (\./)?${IMAGE//./\.}$" "$DIST_DIR/SHA256SUMS" ||
  fail "firmware is not checksum-bound"
grep -Eq '^[0-9a-fA-F]{64}  (\./)?BUILD-MANIFEST\.txt$' "$DIST_DIR/SHA256SUMS" ||
  fail "build manifest is not checksum-bound"
manifest_flavor="$(awk -F= '$1 == "flavor" { count++; value=$2 } END { if (count != 1) exit 1; print value }' "$DIST_DIR/BUILD-MANIFEST.txt")" ||
  fail "verified distribution flavor is missing or duplicated"
[[ "$manifest_flavor" == "$FLAVOR" ]] || fail "requested flavor does not match verified distribution"
image_sha="$(sha256sum "$DIST_DIR/$IMAGE" | awk '{print $1}')"
probe_sha="$(sha256sum "$ROOT_DIR/scripts/ax9000-runtime-probe.sh" | awk '{print $1}')"

[[ -d "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] ||
  fail "output must already exist; create it and run create-hardware-session.sh first"
session_file="$OUTPUT_DIR/SESSION.txt"
[[ -s "$session_file" && ! -L "$session_file" ]] || fail "safe SESSION.txt is required"
session_id="$(python3 - "$session_file" <<'PY'
import pathlib, re, sys
lines=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict").splitlines()
if len(lines) != 1: raise SystemExit(1)
match=re.fullmatch(r"session_id=([0-9a-f]{64})", lines[0])
if not match: raise SystemExit(1)
print(match.group(1))
PY
)" || fail "SESSION.txt schema is invalid"
runtime_files=(device.txt runtime-gate.txt ram-boot.log)
for file in "${runtime_files[@]}"; do
  [[ ! -e "$OUTPUT_DIR/$file" && ! -L "$OUTPUT_DIR/$file" ]] ||
    fail "runtime evidence already exists and cannot be overwritten: $file"
done
tmp_archive="$(mktemp "$ROOT_DIR/hardware-evidence/.runtime-evidence.XXXXXX.tar")"
cleanup() {
  rm -f -- "$tmp_archive"
  ssh "$TARGET" "rm -rf -- '$REMOTE_DIR'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh "$TARGET" "rm -rf -- '$REMOTE_DIR'; mkdir -m 0700 -- '$REMOTE_DIR'; sh -s -- '$image_sha' '$FLAVOR' '$REMOTE_DIR' '$probe_sha' '$session_id'" \
  < "$ROOT_DIR/scripts/ax9000-runtime-probe.sh"
ssh "$TARGET" "tar -C '$REMOTE_DIR' -cf - device.txt runtime-gate.txt ram-boot.log" > "$tmp_archive"

python3 - "$tmp_archive" "$OUTPUT_DIR" <<'PY'
import os, pathlib, tarfile, sys
archive = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
expected = {"device.txt", "runtime-gate.txt", "ram-boot.log"}
payloads = {}
with tarfile.open(archive, "r:") as stream:
    members = stream.getmembers()
    names = {member.name for member in members}
    if names != expected or len(members) != len(expected):
        raise SystemExit(f"unexpected runtime evidence set: {sorted(names)}")
    for member in members:
        if not member.isfile() or pathlib.PurePosixPath(member.name).parts != (member.name,):
            raise SystemExit(f"unsafe runtime evidence entry: {member.name}")
        if member.size <= 0 or member.size > 1024 * 1024:
            raise SystemExit(f"invalid runtime evidence size: {member.name}")
        source = stream.extractfile(member)
        if source is None:
            raise SystemExit(f"cannot read runtime evidence entry: {member.name}")
        data = source.read(1024 * 1024 + 1)
        if len(data) != member.size or len(data) > 1024 * 1024:
            raise SystemExit(f"runtime evidence size mismatch: {member.name}")
        data.decode("utf-8", errors="strict")
        payloads[member.name] = data

created = []
try:
    for name in sorted(expected):
        path = out / name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, 0o600)
        created.append(path)
        try:
            view = memoryview(payloads[name])
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OSError("short write")
                view = view[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    directory_fd = os.open(out, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except BaseException:
    for path in reversed(created):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    raise
PY
printf 'Runtime evidence collected in %s\n' "$OUTPUT_DIR"
printf 'Firmware SHA-256: %s\n' "$image_sha"
printf 'Remaining manual gates: UART/recovery, post-reboot comparison, 24h stress, independent signature.\n'
