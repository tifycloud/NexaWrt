#!/usr/bin/env bash
set -euo pipefail

nexawrt_git_metadata_is_safe() {
  local checkout="$1"
  local description="$2"
  local system_path trusted_git trusted_python
  local git_dir common_dir metadata_root metadata_path packed_refs replace_refs grep_status
  local -a metadata_roots

  system_path="$(builtin command -p getconf PATH 2>/dev/null)" || {
    echo "$description could not determine the system default command path" >&2
    return 1
  }
  [[ -n "$system_path" ]] || {
    echo "$description system default command path is empty" >&2
    return 1
  }
  trusted_git="$(hash -r; PATH="$system_path" builtin command -p -v git 2>/dev/null)" || {
    echo "$description could not resolve Git from the system default command path" >&2
    return 1
  }
  [[ "$trusted_git" == /* && -f "$trusted_git" && -x "$trusted_git" ]] || {
    echo "$description system-default Git is not an absolute executable file: $trusted_git" >&2
    return 1
  }
  trusted_python="$(hash -r; PATH="$system_path" builtin command -p -v python3 2>/dev/null)" || {
    echo "$description could not resolve Python from the system default command path" >&2
    return 1
  }
  [[ "$trusted_python" == /* && -f "$trusted_python" && -x "$trusted_python" ]] || {
    echo "$description system-default Python is not an absolute executable file: $trusted_python" >&2
    return 1
  }

  [[ -d "$checkout/.git" && ! -L "$checkout/.git" ]] || {
    echo "$description Git metadata root is missing, unsafe, or a symlink: $checkout/.git" >&2
    return 1
  }
  git_dir="$("$trusted_git" -C "$checkout" rev-parse --absolute-git-dir 2>/dev/null)" || {
    echo "$description has unreadable Git metadata" >&2
    return 1
  }
  common_dir="$("$trusted_git" -C "$checkout" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "$description has unreadable Git common metadata" >&2
    return 1
  }
  metadata_roots=("$git_dir")
  [[ "$common_dir" == "$git_dir" ]] || metadata_roots+=("$common_dir")

  for metadata_root in "${metadata_roots[@]}"; do
    [[ -d "$metadata_root" && ! -L "$metadata_root" ]] || {
      echo "$description Git metadata root is missing, unsafe, or a symlink: $metadata_root" >&2
      return 1
    }
    [[ -f "$metadata_root/config" && ! -L "$metadata_root/config" ]] || {
      echo "$description Git local config is missing, unsafe, or a symlink" >&2
      return 1
    }
    for metadata_path in \
      "$metadata_root/config.worktree" \
      "$metadata_root/commondir" \
      "$metadata_root/worktrees" \
      "$metadata_root/modules" \
      "$metadata_root/info/attributes" \
      "$metadata_root/info/grafts" \
      "$metadata_root/objects/info/alternates" \
      "$metadata_root/refs/replace"; do
      if [[ -e "$metadata_path" || -L "$metadata_path" ]]; then
        case "$metadata_path" in
          */info/grafts|*/refs/replace)
            echo "$description has forbidden Git replace/grafts metadata: $metadata_path" >&2
            ;;
          *)
            echo "$description has forbidden Git metadata: $metadata_path" >&2
            ;;
        esac
        return 1
      fi
    done
    for metadata_path in "$metadata_root/refs" "$metadata_root/info" "$metadata_root/objects" "$metadata_root/hooks"; do
      if [[ -L "$metadata_path" ]]; then
        echo "$description has a symbolic Git metadata path: $metadata_path" >&2
        return 1
      fi
    done
    if [[ -d "$metadata_root/hooks" ]]; then
      while IFS= read -r -d '' metadata_path; do
        case "$(basename "$metadata_path")" in
          *.sample)
            [[ -f "$metadata_path" && ! -L "$metadata_path" ]] || {
              echo "$description has unsafe Git hook metadata: $metadata_path" >&2
              return 1
            }
            ;;
          *)
            echo "$description has an active or unexpected Git hook: $metadata_path" >&2
            return 1
            ;;
        esac
      done < <(find "$metadata_root/hooks" -mindepth 1 -maxdepth 1 -print0)
    fi

    "$trusted_python" -I - "$trusted_git" "$checkout" "$description" <<'PY' || return 1
import subprocess
import sys

trusted_git, checkout, description = sys.argv[1:]
proc = subprocess.run(
    [trusted_git, "-C", checkout, "config", "--local", "--null", "--list", "--no-includes"],
    check=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
entries = []
for record in proc.stdout.split(b"\0"):
    if not record:
        continue
    try:
        key, value = record.decode("utf-8", "strict").split("\n", 1)
    except (UnicodeDecodeError, ValueError):
        raise SystemExit(f"{description} has malformed Git local config")
    entries.append((key.lower(), value))

allowed_single = {
    "core.repositoryformatversion": {"0"},
    "core.filemode": {"true", "false"},
    "core.bare": {"false"},
    "core.logallrefupdates": {"true", "false"},
    "core.ignorecase": {"true", "false"},
    "core.precomposeunicode": {"true", "false"},
}
required = {"core.repositoryformatversion", "core.bare", "remote.origin.url", "remote.origin.fetch"}
counts = {}
for key, value in entries:
    counts[key] = counts.get(key, 0) + 1
    if key in {"remote.origin.url", "remote.origin.pushurl", "user.name", "user.email"}:
        if not value or any(ch in value for ch in "\r\n\0"):
            raise SystemExit(f"{description} has malformed Git local config: {key}")
        continue
    if key == "remote.origin.fetch":
        wildcard = "+refs/heads/*:refs/remotes/origin/*"
        single = __import__("re").fullmatch(
            r"\+(refs/heads/([^:]+)):(refs/remotes/origin/([^:]+))", value
        )
        if value != wildcard:
            if single is None:
                raise SystemExit(f"{description} has forbidden Git local config: {key}")
            source_ref, source_branch, target_ref, target_branch = single.groups()
            ref_validity = [
                subprocess.run(
                    [trusted_git, "check-ref-format", refname],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ).returncode == 0
                for refname in (source_ref, target_ref)
            ]
            if source_branch != target_branch or not all(ref_validity):
                raise SystemExit(f"{description} has forbidden Git local config: {key}")
        continue
    branch_match = __import__("re").fullmatch(r"branch\.[a-z0-9._/-]+\.(remote|merge)", key)
    if branch_match:
        if branch_match.group(1) == "remote" and value not in {"origin", "."}:
            raise SystemExit(f"{description} has forbidden Git branch remote")
        if branch_match.group(1) == "merge" and not __import__("re").fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", value):
            raise SystemExit(f"{description} has forbidden Git branch merge ref")
        continue
    if key not in allowed_single or value.lower() not in allowed_single[key]:
        raise SystemExit(f"{description} has forbidden Git local config: {key}")
for key in allowed_single:
    if counts.get(key, 0) > 1:
        raise SystemExit(f"{description} has duplicate Git local config: {key}")
if counts.get("remote.origin.fetch", 0) != 1 or counts.get("remote.origin.url", 0) < 1:
    raise SystemExit(f"{description} Git local config is incomplete")
if not required.issubset(counts):
    raise SystemExit(f"{description} Git local config is incomplete")
PY

    packed_refs="$metadata_root/packed-refs"
    if [[ -e "$packed_refs" || -L "$packed_refs" ]]; then
      [[ -f "$packed_refs" && ! -L "$packed_refs" && -r "$packed_refs" ]] || {
        echo "$description packed-refs is unreadable, unsafe, or a symlink: $packed_refs" >&2
        return 1
      }
      if grep -Eq '^[0-9a-fA-F]+[[:space:]]+refs/replace(/|$)' "$packed_refs"; then
        echo "$description has forbidden packed Git replace refs" >&2
        return 1
      else
        grep_status=$?
      fi
      [[ "$grep_status" == 1 ]] || {
        echo "$description packed-refs could not be inspected safely" >&2
        return 1
      }
    fi
  done

  replace_refs="$("$trusted_git" -C "$checkout" for-each-ref --format='%(refname)' refs/replace 2>/dev/null)" || {
    echo "$description replace refs could not be enumerated safely" >&2
    return 1
  }
  [[ -z "$replace_refs" ]] || {
    echo "$description has forbidden Git replace refs: $replace_refs" >&2
    return 1
  }
}
