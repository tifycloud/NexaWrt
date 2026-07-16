#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EVIDENCE_RAW="${1:-}"
DIST_DIR="${2:-}"
COMPARE_SCRIPT="$ROOT_DIR/scripts/compare-reproducible-builds.sh"
fail() { echo "hardware session creation failed: $*" >&2; exit 1; }
[[ -n "$EVIDENCE_RAW" && -d "$DIST_DIR" ]] || fail "usage: $0 EVIDENCE_DIRECTORY VERIFIED_DIST_DIRECTORY"
command -v python3 >/dev/null || fail "python3 is required"
command -v sha256sum >/dev/null || fail "sha256sum is required"
[[ -f "$COMPARE_SCRIPT" && ! -L "$COMPARE_SCRIPT" ]] || fail "reproducibility verifier is missing or unsafe"
candidate_metadata="$(bash "$COMPARE_SCRIPT" --verify-verified-dist "$DIST_DIR")" ||
  fail "candidate is not a repository-locked compare-generated verified-dist"
[[ -n "$candidate_metadata" ]] || fail "verified candidate metadata is empty"

EVIDENCE_DIR="$(python3 - "$ROOT_DIR" "$EVIDENCE_RAW" <<'PY'
import os, pathlib, sys
root=pathlib.Path(sys.argv[1]).resolve(strict=True)
allowed=root / "hardware-evidence"
if os.path.lexists(allowed) and (allowed.is_symlink() or not allowed.is_dir()): raise SystemExit(1)
raw=pathlib.Path(os.path.abspath(sys.argv[2]))
try: relative=raw.relative_to(allowed)
except ValueError: raise SystemExit(1)
if not relative.parts: raise SystemExit(1)
current=allowed
for part in relative.parts:
    current /= part
    if os.path.lexists(current) and current.is_symlink(): raise SystemExit(1)
resolved=raw.resolve(strict=False)
if not resolved.is_dir(): raise SystemExit(1)
print(resolved)
PY
)" || fail "evidence must be an existing non-symlink directory below $ROOT_DIR/hardware-evidence"

session_id="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
image_sha="$(awk -F= '$1 == "firmware_sha256" { print $2 }' <<<"$candidate_metadata")"
image_size="$(awk -F= '$1 == "firmware_size" { print $2 }' <<<"$candidate_metadata")"
comparison_receipt_sha="$(awk -F= '$1 == "comparison_receipt_sha256" { print $2 }' <<<"$candidate_metadata")"
[[ "$image_sha" =~ ^[0-9a-f]{64}$ && "$image_size" =~ ^[1-9][0-9]*$ && "$comparison_receipt_sha" =~ ^[0-9a-f]{64}$ ]] ||
  fail "validated candidate metadata could not be parsed"
image_size_hex="$(printf '%x' "$image_size")"
python3 - "$EVIDENCE_DIR" "$session_id" "$candidate_metadata" <<'PY' || fail "evidence directory is not empty or session metadata already exists"
import os, pathlib, sys
root=pathlib.Path(sys.argv[1])
session_id=sys.argv[2]
candidate=sys.argv[3]
if any(os.scandir(root)):
    raise SystemExit(1)
created=[]
def exclusive_write(name, content):
    path=root/name
    flags=os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor=os.open(path, flags, 0o600)
    created.append(path)
    try:
        data=content.encode("utf-8")
        while data:
            written=os.write(descriptor, data)
            if written <= 0:
                raise OSError("short write")
            data=data[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
try:
    exclusive_write("CANDIDATE.txt", candidate.rstrip("\n") + "\n")
    exclusive_write("SESSION.txt", f"session_id={session_id}\n")
    if {entry.name for entry in os.scandir(root)} != {"CANDIDATE.txt", "SESSION.txt"}:
        raise OSError("evidence directory changed during initialization")
    directory_fd=os.open(root, os.O_RDONLY)
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
cat <<EOF_COMMANDS
Hardware session created: $EVIDENCE_DIR/SESSION.txt
Expected image SHA-256: $image_sha
Expected image bytes: $image_size (U-Boot hexadecimal filesize: $image_size_hex)
Comparison receipt SHA-256: $comparison_receipt_sha
Candidate binding: $EVIDENCE_DIR/CANDIDATE.txt

After TFTP has loaded the image at \${loadaddr}, run these VOLATILE U-Boot commands exactly; never run saveenv:
  setenv nexawrt_session_id $session_id
  setenv nexawrt_original_bootargs "\${bootargs}"
  setenv bootargs "\${bootargs} nexawrt.session=$session_id"
  if hash sha256 \${loadaddr} \${filesize} nexawrt_image_sha256; then echo NEXAWRT_HASH_EXECUTION=success; else echo NEXAWRT_HASH_EXECUTION=failure; fi
  setenv nexawrt_image_size_hex \${filesize}
  printenv nexawrt_image_sha256 nexawrt_image_size_hex nexawrt_session_id ethaddr
  bootm \${loadaddr}

The UART log must preserve the complete, unwrapped U-Boot prompt line for the conditional hash command and exactly one standalone NEXAWRT_HASH_EXECUTION=success output line, with no failure line. The final verifier also requires the four printenv values exactly once.
EOF_COMMANDS
