#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sanitize-git-environment.sh
source "$ROOT_DIR/scripts/sanitize-git-environment.sh"
nexawrt_sanitize_git_environment
# shellcheck source=lock-file-policy.sh
source "$ROOT_DIR/scripts/lock-file-policy.sh"
# shellcheck source=git-metadata-policy.sh
source "$ROOT_DIR/scripts/git-metadata-policy.sh"
# shellcheck source=../manifests/upstream.lock
nexawrt_validate_lock_file "$ROOT_DIR/manifests/upstream.lock" upstream
source "$ROOT_DIR/manifests/upstream.lock"
# shellcheck source=../manifests/package-repository.lock
nexawrt_validate_lock_file "$ROOT_DIR/manifests/package-repository.lock" package-repository
source "$ROOT_DIR/manifests/package-repository.lock"
NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
WITH_FEEDS=1
CLEAN=0
PACKAGES_IPERF3_RPATH_PATCH="$ROOT_DIR/patches/packages/001-iperf3-avoid-libtool-absolute-rpath.patch"
NSS_PACKAGES_SOURCE_PATCH="$ROOT_DIR/patches/nss/001-pin-codelinaro-source-archives.patch"
COMPLETE_GIT_WORKTREE_DIFF="$ROOT_DIR/scripts/complete-git-worktree-diff.sh"
APK_REPRO_SOURCE_PATCH="package/system/apk/patches/0011-genhelp-reproducible-gzip.patch"
APK_REPRO_UPSTREAM_SHA256="a338662ccbef6b916b7cb2e32c91ef981b9f8e69fe056ad0513fd384ee152d1c"

# Do not inherit an unreviewed user/global Git proxy. A caller that needs one
# must provide it explicitly through NEXAWRT_GIT_HTTP_PROXY or HTTPS_PROXY.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=http.proxy
export GIT_CONFIG_VALUE_0="${NEXAWRT_GIT_HTTP_PROXY:-${HTTPS_PROXY:-${https_proxy:-}}}"

case "$NEXAWRT_FLAVOR" in
  official)
    SOURCE_REPO="${OPENWRT_REPO_OVERRIDE:-$OPENWRT_REPO}"
    SOURCE_COMMIT="$OPENWRT_COMMIT"
    SOURCE_LABEL="$OPENWRT_TAG"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi.config"
    DEFAULT_WORK_DIR="$ROOT_DIR/.work/openwrt"
    ;;
  nss)
    # Keep the stable official path independent from the experimental NSS lock.
    # shellcheck source=../manifests/nss.lock
    nexawrt_validate_lock_file "$ROOT_DIR/manifests/nss.lock" nss
    source "$ROOT_DIR/manifests/nss.lock"
    SOURCE_REPO="${OPENWRT_REPO_OVERRIDE:-$NSS_OPENWRT_REPO}"
    SOURCE_COMMIT="$NSS_OPENWRT_COMMIT"
    SOURCE_LABEL="$NSS_OPENWRT_BRANCH"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi-nss.config"
    DEFAULT_WORK_DIR="$ROOT_DIR/.work/openwrt-nss"
    ;;
  *)
    echo "Unsupported NEXAWRT_FLAVOR: $NEXAWRT_FLAVOR (expected official or nss)" >&2
    exit 2
    ;;
esac
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
# Keep the source checkout path stable after this script changes directory into
# it. Relative WORK_DIR values are common in GitHub Actions; without converting
# them once at entry, later `git -C "$WORK_DIR"` checks would resolve the path a
# second time from inside the checkout and reject the otherwise canonical
# origin.
if [[ "$WORK_DIR" != /* ]]; then
  WORK_DIR="$(pwd -P)/$WORK_DIR"
fi

usage() {
  cat <<USAGE
Usage: $0 [--clean] [--no-feeds]

Prepare the NEXAWRT_FLAVOR=official|nss source at its pinned commit, apply the
single-large-UBI RAM-only patches, copy the matching seed config/files, rewrite
all feeds to exact commit pins, and optionally install the feeds.
USAGE
}

while (($#)); do
  case "$1" in
    --clean) CLEAN=1 ;;
    --no-feeds) WITH_FEEDS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

COMPONENT_KCONFIG_FRAGMENT=""
if [[ -n "${NEXAWRT_COMPONENTS:-}" || -n "${NEXAWRT_COMPONENT_TARGET:-}" ]]; then
  [[ "${NEXAWRT_COMPONENT_TARGET:-}" == xiaomi_ax9000 ]] || {
    echo "NEXAWRT_COMPONENT_TARGET must be xiaomi_ax9000 when components are enabled" >&2
    exit 2
  }
  [[ "${NEXAWRT_COMPONENT_FLAVOR:-}" == official || "${NEXAWRT_COMPONENT_FLAVOR:-}" == nss ]] || {
    echo "NEXAWRT_COMPONENT_FLAVOR must be official or nss when components are enabled" >&2
    exit 2
  }
  [[ "${NEXAWRT_COMPONENT_CATALOG_VERSION:-}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || {
    echo "NEXAWRT_COMPONENT_CATALOG_VERSION must be a valid catalog version" >&2
    exit 2
  }
  [[ "${NEXAWRT_COMPONENT_REQUEST_HASH:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "NEXAWRT_COMPONENT_REQUEST_HASH must be a full lowercase SHA256 value" >&2
    exit 2
  }
  [[ ${#NEXAWRT_COMPONENTS} -le 1024 ]] || {
    echo "NEXAWRT_COMPONENTS exceeds the bounded component ID list length" >&2
    exit 2
  }
  if [[ -n "$NEXAWRT_COMPONENTS" ]]; then
    [[ "$NEXAWRT_COMPONENTS" =~ ^[a-z0-9][a-z0-9_-]{0,63}(,[a-z0-9][a-z0-9_-]{0,63})*$ ]] || {
      echo "Non-empty NEXAWRT_COMPONENTS accepts only comma-separated catalog component IDs" >&2
      exit 2
    }
  fi
  component_resolver_args=(--target xiaomi_ax9000 --flavor "$NEXAWRT_COMPONENT_FLAVOR")
  if [[ -n "$NEXAWRT_COMPONENTS" ]]; then
    IFS=',' read -r -a component_ids <<< "$NEXAWRT_COMPONENTS"
    for component_id in "${component_ids[@]}"; do
      component_resolver_args+=(--component "$component_id")
    done
  fi
  COMPONENT_KCONFIG_FRAGMENT="$(
    python3 "$ROOT_DIR/scripts/resolve-components.py" "${component_resolver_args[@]}" |
      EXPECTED_FLAVOR="$NEXAWRT_COMPONENT_FLAVOR" \
      EXPECTED_CATALOG_VERSION="$NEXAWRT_COMPONENT_CATALOG_VERSION" \
      EXPECTED_REQUEST_HASH="$NEXAWRT_COMPONENT_REQUEST_HASH" \
      python3 -c '
import json, os, sys
request = json.load(sys.stdin)
if request.get("flavor") != os.environ["EXPECTED_FLAVOR"]:
    raise SystemExit("component flavor mismatch")
if request.get("catalog_version") != os.environ["EXPECTED_CATALOG_VERSION"]:
    raise SystemExit("component catalog version mismatch")
if request.get("request_hash") != os.environ["EXPECTED_REQUEST_HASH"]:
    raise SystemExit("component request hash mismatch")
sys.stdout.write(request["kconfig_fragment"])
'
  )" || {
    echo "Component selection was rejected by the repository catalog" >&2
    exit 2
  }
fi

apply_component_kconfig() {
  [[ -n "$COMPONENT_KCONFIG_FRAGMENT" ]] || return 0
  {
    printf '\n# NexaWrt allow-listed component selection\n'
    printf '%s\n' "$COMPONENT_KCONFIG_FRAGMENT"
  } >> .config
}

if [[ "$(uname -s)" == Darwin && "$WITH_FEEDS" == 1 && "${ALLOW_UNSUPPORTED_HOST:-0}" != 1 ]]; then
  cat >&2 <<'MSG'
On macOS, use --no-feeds for patch/static validation and use the GitHub Actions
Linux workflow for a full preparation/build. OpenWrt requires newer GNU tools
and a case-sensitive filesystem. Set ALLOW_UNSUPPORTED_HOST=1 only after you
have provided those requirements yourself.
MSG
  exit 1
fi

pin_feed() {
  local feed="$1"
  local expected_repo="$2"
  local revision="$3"
  local input="$WORK_DIR/feeds.conf.default"
  local output="$WORK_DIR/feeds.conf.default.tmp"

  awk -v feed="$feed" -v revision="$revision" -v expected_repo="$expected_repo" '
    $1 ~ /^src-git(-full)?$/ && $2 == feed {
      print $1 " " $2 " " expected_repo "^" revision
      found++
      next
    }
    { print }
    END { if (found != 1) exit 42 }
  ' "$input" > "$output" || {
    rm -f "$output"
    echo "Feed $feed is missing or duplicated in feeds.conf.default" >&2
    exit 1
  }
  mv "$output" "$input"
}

expected_feed_names() {
  awk 'NF >= 2 && $1 !~ /^#/ { print $1 }' "$ROOT_DIR/manifests/feeds.lock"
  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    printf '%s\n%s\n' "$NSS_PACKAGES_FEED" "$NSS_SQM_FEED"
  fi
}

config_feed_set_matches_locks() {
  local expected expected_unique actual actual_unique

  awk '
    $1 ~ /^src-/ && $1 !~ /^src-git(-full)?$/ { exit 1 }
  ' "$WORK_DIR/feeds.conf.default" || return 1
  expected="$(expected_feed_names | LC_ALL=C sort)"
  expected_unique="$(printf '%s\n' "$expected" | LC_ALL=C sort -u)"
  [[ "$expected" == "$expected_unique" ]] || return 1
  actual="$(awk '$1 ~ /^src-git(-full)?$/ { print $2 }' \
    "$WORK_DIR/feeds.conf.default" | LC_ALL=C sort)"
  actual_unique="$(printf '%s\n' "$actual" | LC_ALL=C sort -u)"
  [[ "$actual" == "$actual_unique" && "$actual" == "$expected" ]]
}

top_level_names() {
  local directory="$1"
  find "$directory" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort
}


git_history_overrides_absent() {
  nexawrt_git_metadata_is_safe "$1" "$2"
}

canonical_origin_matches() {
  local checkout="$1"
  local expected_repo="$2"
  local fetch_urls push_status

  # Inspect the raw config rather than `remote get-url`: get-url does not expose
  # pushurl entries and may apply insteadOf rewriting. Exactly one canonical
  # fetch URL is allowed, and any push-only destination is fail-closed.
  fetch_urls="$(git -C "$checkout" config --get-all remote.origin.url 2>/dev/null)" || return 1
  [[ "$fetch_urls" == "$expected_repo" ]] || return 1

  if git -C "$checkout" config --get-all remote.origin.pushurl >/dev/null 2>&1; then
    return 1
  else
    push_status=$?
  fi
  [[ "$push_status" == 1 ]]
}

feed_top_level_matches_locks() {
  local expected actual feed entry base_link resolved

  [[ -d "$WORK_DIR/feeds" ]] || return 1
  expected="$(expected_feed_names | LC_ALL=C sort)"
  actual="$(find "$WORK_DIR/feeds" -mindepth 1 -maxdepth 1 ! -name base -exec basename {} \; | LC_ALL=C sort)"
  [[ "$actual" == "$expected" ]] || return 1

  base_link="$WORK_DIR/feeds/base"
  if [[ -e "$base_link" || -L "$base_link" ]]; then
    [[ -L "$base_link" && "$(readlink "$base_link")" == ../package ]] || return 1
    resolved="$(cd -P "$base_link" 2>/dev/null && pwd -P)" || return 1
    [[ "$resolved" == "$(cd -P "$WORK_DIR/package" && pwd -P)" ]] || return 1
  fi

  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    entry="$WORK_DIR/feeds/$feed"
    [[ -d "$entry" && ! -L "$entry" ]] || return 1
  done <<< "$expected"
}

package_feed_links_match_locks() {
  local expected actual feed directory entry feed_root resolved

  [[ -d "$WORK_DIR/package/feeds" ]] || return 1
  expected="$(expected_feed_names | LC_ALL=C sort)"
  actual="$(top_level_names "$WORK_DIR/package/feeds")"
  [[ "$actual" == "$expected" ]] || return 1

  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    directory="$WORK_DIR/package/feeds/$feed"
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    feed_root="$(cd -P "$WORK_DIR/feeds/$feed" && pwd -P)" || return 1
    while IFS= read -r -d '' entry; do
      [[ -L "$entry" && -d "$entry" ]] || return 1
      resolved="$(cd -P "$entry" 2>/dev/null && pwd -P)" || return 1
      case "$resolved" in
        "$feed_root"/*) ;;
        *) return 1 ;;
      esac
    done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
  done <<< "$expected"
}

feed_checkout_is_clean() {
  local feed="$1"
  local checkout="$WORK_DIR/feeds/$feed"
  local git_dir sparse_checkout sparse_index sparse_entries index_tags untracked ignored

  git_dir="$(git -C "$checkout" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  sparse_checkout="$(git -C "$checkout" config --get core.sparseCheckout 2>/dev/null || true)"
  sparse_index="$(git -C "$checkout" config --get index.sparse 2>/dev/null || true)"
  sparse_entries="$(git -C "$checkout" ls-files --sparse --stage 2>/dev/null)" || return 1
  case "$sparse_checkout" in
    ""|false|no|off|0) ;;
    *) echo "feed checkout $feed uses sparse checkout or a sparse index" >&2; return 1 ;;
  esac
  case "$sparse_index" in
    ""|false|no|off|0) ;;
    *) echo "feed checkout $feed uses sparse checkout or a sparse index" >&2; return 1 ;;
  esac
  if [[ -e "$git_dir/info/sparse-checkout" ]] ||
      grep -Eq '^040000 ' <<<"$sparse_entries"; then
    echo "feed checkout $feed uses sparse checkout or a sparse index" >&2
    return 1
  fi

  index_tags="$(git -C "$checkout" ls-files -v)" || return 1
  if grep -Eq '^[a-z] ' <<<"$index_tags"; then
    echo "feed checkout $feed has assume-unchanged index entries" >&2
    return 1
  fi
  if grep -Eq '^[Ss] ' <<<"$index_tags"; then
    echo "feed checkout $feed has skip-worktree index entries" >&2
    return 1
  fi

  git -C "$checkout" diff-index --quiet --cached HEAD -- || {
    echo "feed checkout $feed has staged changes" >&2
    return 1
  }
  local expected_patch="" patch_description=""
  if [[ "$feed" == packages ]]; then
    expected_patch="$PACKAGES_IPERF3_RPATH_PATCH"
    patch_description="iperf3 link-stage RPATH patch"
  elif [[ "$NEXAWRT_FLAVOR" == nss && "$feed" == "$NSS_PACKAGES_FEED" ]]; then
    expected_patch="$NSS_PACKAGES_SOURCE_PATCH"
    patch_description="source archive patch"
  fi

  if [[ -n "$expected_patch" ]]; then
    [[ -f "$expected_patch" && -x "$COMPLETE_GIT_WORKTREE_DIFF" ]] || {
      echo "required $patch_description or complete-diff helper is missing" >&2
      return 1
    }
    [[ "$("$COMPLETE_GIT_WORKTREE_DIFF" "$checkout")" == "$(cat "$expected_patch")" ]] || {
      echo "feed checkout $feed does not contain the exact NexaWrt $patch_description" >&2
      return 1
    }
  else
    git -C "$checkout" diff-files --quiet --ignore-submodules -- || {
      echo "feed checkout $feed is not clean" >&2
      return 1
    }
    untracked="$(git -C "$checkout" ls-files --others --exclude-standard)" || return 1
    if [[ -n "$untracked" ]]; then
      echo "feed checkout $feed is not clean" >&2
      return 1
    fi
  fi
  ignored="$(git -C "$checkout" ls-files --others --ignored --exclude-standard)" || return 1
  if [[ -n "$ignored" ]]; then
    echo "feed checkout $feed contains ignored files" >&2
    return 1
  fi
}

feed_checkout_matches_lock() {
  local feed="$1"
  local revision="$2"
  local expected_repo="$3"
  local checkout="$WORK_DIR/feeds/$feed"

  [[ -d "$checkout/.git" && ! -L "$checkout/.git" ]] || return 1
  git_history_overrides_absent "$checkout" "feed checkout $feed" || return 1
  [[ "$(git -C "$checkout" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" == "$revision" ]] || return 1
  canonical_origin_matches "$checkout" "$expected_repo" || return 1
  checkout_commit_is_complete_locally "$checkout" "$revision" || return 1
  feed_checkout_is_clean "$feed"
}

feed_checkouts_match_locks() {
  local feed expected_repo revision

  config_feed_set_matches_locks || return 1
  while read -r feed expected_repo revision; do
    [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
    feed_checkout_matches_lock "$feed" "$revision" "$expected_repo" || return 1
  done < "$ROOT_DIR/manifests/feeds.lock"

  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    feed_checkout_matches_lock \
      "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_COMMIT" "$NSS_PACKAGES_REPO" || return 1
    feed_checkout_matches_lock \
      "$NSS_SQM_FEED" "$NSS_SQM_COMMIT" "$NSS_SQM_REPO" || return 1
  fi
}

remove_generated_feed_metadata() {
  local feed index targetindex temporary

  if [[ -L "$WORK_DIR/feeds/base" && "$(readlink "$WORK_DIR/feeds/base")" == ../package ]]; then
    rm "$WORK_DIR/feeds/base"
  fi
  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    index="$WORK_DIR/feeds/$feed.index"
    targetindex="$WORK_DIR/feeds/$feed.targetindex"
    temporary="$WORK_DIR/feeds/$feed.tmp"
    if [[ -L "$index" && "$(readlink "$index")" == "$feed.tmp/.packageinfo" ]]; then
      rm "$index"
    fi
    if [[ -L "$targetindex" && "$(readlink "$targetindex")" == "$feed.tmp/.targetinfo" ]]; then
      rm "$targetindex"
    fi
    [[ ! -d "$temporary" || -L "$temporary" ]] || rm -rf "$temporary"
  done < <(expected_feed_names)
}

assert_existing_feed_checkouts_have_no_history_overrides() {
  local entry

  [[ -d "$WORK_DIR/feeds" ]] || return 0
  while IFS= read -r -d '' entry; do
    if [[ -e "$entry/.git" || -L "$entry/.git" ]]; then
      git_history_overrides_absent "$entry" "feed checkout $(basename "$entry")" || return 1
    fi
  done < <(find "$WORK_DIR/feeds" -mindepth 1 -maxdepth 1 -print0)
}

reset_feed_checkouts() {
  assert_existing_feed_checkouts_have_no_history_overrides || return 1
  rm -rf "$WORK_DIR/feeds" "$WORK_DIR/package/feeds" "$WORK_DIR/.nexawrt-feeds-state"
}

reset_one_feed_checkout() {
  local feed="$1"
  local checkout="$WORK_DIR/feeds/$feed"

  if [[ -e "$checkout/.git" || -L "$checkout/.git" ]]; then
    git_history_overrides_absent "$checkout" "feed checkout $feed" || return 1
  fi
  rm -rf \
    "$WORK_DIR/feeds/$feed" \
    "$WORK_DIR/feeds/$feed.tmp" \
    "$WORK_DIR/feeds/$feed.index" \
    "$WORK_DIR/feeds/$feed.targetindex" \
    "$WORK_DIR/package/feeds/$feed"
}

feed_lock_values() {
  local wanted="$1"
  local feed expected_repo revision

  while IFS=$' \t' read -r feed expected_repo revision; do
    [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
    if [[ "$feed" == "$wanted" ]]; then
      printf '%s\t%s\n' "$expected_repo" "$revision"
      return 0
    fi
  done < "$ROOT_DIR/manifests/feeds.lock"

  if [[ "$NEXAWRT_FLAVOR" == nss && "$wanted" == "$NSS_PACKAGES_FEED" ]]; then
    printf '%s\t%s\n' "$NSS_PACKAGES_REPO" "$NSS_PACKAGES_COMMIT"
    return 0
  fi
  if [[ "$NEXAWRT_FLAVOR" == nss && "$wanted" == "$NSS_SQM_FEED" ]]; then
    printf '%s\t%s\n' "$NSS_SQM_REPO" "$NSS_SQM_COMMIT"
    return 0
  fi
  return 1
}

update_one_pinned_feed() {
  local feed="$1"
  local expected_repo revision checkout fetched_head attempt

  IFS=$'\t' read -r expected_repo revision < <(feed_lock_values "$feed") || {
    echo "No lock entry for feed $feed" >&2
    return 1
  }
  checkout="$WORK_DIR/feeds/$feed"

  for attempt in 1 2 3 4 5; do
    reset_one_feed_checkout "$feed" || return 1
    if GIT_TERMINAL_PROMPT=0 ./scripts/feeds update "$feed"; then
      git_history_overrides_absent "$checkout" "feed checkout $feed" || return 1
      fetched_head="$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null || true)"
      if [[ "$fetched_head" == "$revision" ]] &&
          canonical_origin_matches "$checkout" "$expected_repo"; then
        return 0
      fi
      echo "Feed $feed checkout did not match its exact lock after update" >&2
    fi

    # The feeds helper performs a regular clone before checking out the pinned
    # revision. On unreliable links that can fail after transferring unrelated
    # history. Fall back to fetching only the reviewed commit, then regenerate
    # the feed index locally. The canonical origin URL and exact HEAD are still
    # checked below, so this changes transport volume rather than trust policy.
    reset_one_feed_checkout "$feed" || return 1
    if git init -q "$checkout" &&
      git -C "$checkout" remote add origin "$expected_repo" &&
      GIT_TERMINAL_PROMPT=0 git -C "$checkout" -c protocol.version=2 \
        fetch --no-tags --depth=1 origin "$revision" &&
      git -C "$checkout" checkout -q --detach "$revision" &&
      ./scripts/feeds update -i "$feed"; then
      git_history_overrides_absent "$checkout" "feed checkout $feed" || return 1
      fetched_head="$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null || true)"
      if [[ "$fetched_head" == "$revision" ]] &&
          canonical_origin_matches "$checkout" "$expected_repo"; then
        return 0
      fi
      echo "Feed $feed shallow fallback did not match its exact lock" >&2
    fi
    echo "Feed $feed update attempt $attempt failed; retrying only that feed..." >&2
    sleep $((attempt * 3))
  done

  echo "Unable to update pinned feed $feed" >&2
  return 1
}

write_feed_state() {
  local state="$1"
  local marker="$WORK_DIR/.nexawrt-feeds-state"
  local temporary="$marker.tmp"

  printf 'version=1\nflavor=%s\nstate=%s\n' "$NEXAWRT_FLAVOR" "$state" > "$temporary"
  mv "$temporary" "$marker"
}

write_openwrt_revision() {
  local expected="r0-${SOURCE_COMMIT:0:8}"
  local target="$WORK_DIR/version"
  local temporary="$WORK_DIR/.nexawrt-version.tmp"

  # OpenWrt's scripts/getver.sh gives this root file precedence over Git's
  # object-set-dependent short hash. Replace every prior form, including an
  # ignored stale file, directory, or symlink left by another flavor/cache.
  rm -rf -- "$target" "$temporary"
  (umask 022; printf '%s\n' "$expected" > "$temporary")
  [[ -f "$temporary" && ! -L "$temporary" ]] || {
    echo "Unable to create deterministic OpenWrt revision seed" >&2
    exit 1
  }
  chmod 0644 "$temporary"
  mv -f -- "$temporary" "$target"
  [[ -f "$target" && ! -L "$target" ]] &&
    cmp -s -- "$target" <(printf '%s\n' "$expected") || {
    echo "Deterministic OpenWrt revision seed verification failed" >&2
    exit 1
  }
}

checkout_commit_is_complete_locally() {
  local checkout="$1"
  local commit="$2"
  local object_type

  object_type="$(GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
    git -C "$checkout" cat-file -t "$commit" 2>/dev/null || true)"
  [[ "$object_type" == commit ]] || return 1

  # A partial/promisor checkout can have the commit object while omitting trees
  # or blobs. Check the complete checkout closure without allowing lazy fetches;
  # gitlink targets are intentionally excluded because checkout does not need the
  # referenced submodule commits.
  GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
    git -C "$checkout" ls-tree -r -t "$commit" 2>/dev/null | \
    awk '$2 != "commit" { print $3 }' | \
    GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
      git -C "$checkout" cat-file --batch-check='%(objecttype)' | \
    awk '$NF == "missing" { missing = 1 } END { exit missing }'
}

source_commit_is_complete_locally() {
  checkout_commit_is_complete_locally "$WORK_DIR" "$1"
}

installed_feed_state_is_reusable() {
  feed_checkouts_match_locks &&
    feed_top_level_matches_locks &&
    package_feed_links_match_locks
}

if [[ -e "$WORK_DIR/.git" || -L "$WORK_DIR/.git" ]]; then
  git_history_overrides_absent "$WORK_DIR" "$NEXAWRT_FLAVOR source checkout" || exit 1
fi

if ((CLEAN)); then
  rm -rf "$WORK_DIR"
fi

if [[ ! -d "$WORK_DIR/.git" ]]; then
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  git -c init.templateDir= -C "$WORK_DIR" init -q
  git -C "$WORK_DIR" remote add origin "$SOURCE_REPO"
fi

git_history_overrides_absent "$WORK_DIR" "$NEXAWRT_FLAVOR source checkout" || exit 1
cd "$WORK_DIR"
if ! canonical_origin_matches "$WORK_DIR" "$SOURCE_REPO"; then
  origin_urls="$(git config --get-all remote.origin.url 2>/dev/null || true)"
  origin_pushurls="$(git config --get-all remote.origin.pushurl 2>/dev/null || true)"
  echo "Refusing unexpected OpenWrt remote: fetch=[$origin_urls] push=[$origin_pushurls]" >&2
  exit 1
fi

if source_commit_is_complete_locally "$SOURCE_COMMIT"; then
  printf 'Reusing complete local %s source commit %s\n' \
    "$NEXAWRT_FLAVOR" "$SOURCE_COMMIT"
else
  fetched=0
  for attempt in 1 2 3; do
    if GIT_TERMINAL_PROMPT=0 git -c http.version=HTTP/1.1 fetch --depth 1 origin "$SOURCE_COMMIT"; then
      fetched_commit="$(git rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null || true)"
      if [[ "$fetched_commit" != "$SOURCE_COMMIT" ]]; then
        echo "Fetched commit mismatch: expected $SOURCE_COMMIT, got $fetched_commit" >&2
        exit 1
      fi
      source_commit_is_complete_locally "$SOURCE_COMMIT" || {
        echo "Fetched source commit is incomplete: $SOURCE_COMMIT" >&2
        exit 1
      }
      fetched=1
      break
    fi
    echo "$NEXAWRT_FLAVOR source fetch attempt $attempt failed; retrying..." >&2
    sleep $((attempt * 3))
  done
  ((fetched == 1)) || { echo "Unable to fetch pinned $NEXAWRT_FLAVOR source" >&2; exit 1; }
fi

rm -f -- "$WORK_DIR/.git/index"
GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
  git -c core.hooksPath=/dev/null checkout --detach --force "$SOURCE_COMMIT"
GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
  git -c core.hooksPath=/dev/null reset --hard "$SOURCE_COMMIT"
git -c core.hooksPath=/dev/null clean -ffdx -e /feeds/ -e /package/feeds/ -e /.nexawrt-feeds-state
git_history_overrides_absent "$WORK_DIR" "$NEXAWRT_FLAVOR source checkout after reset" || exit 1

if ! canonical_origin_matches "$WORK_DIR" "$SOURCE_REPO"; then
  origin_urls="$(git config --get-all remote.origin.url 2>/dev/null || true)"
  origin_pushurls="$(git config --get-all remote.origin.pushurl 2>/dev/null || true)"
  echo "Refusing unexpected OpenWrt remote after source reset: fetch=[$origin_urls] push=[$origin_pushurls]" >&2
  exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
  echo "$NEXAWRT_FLAVOR source commit verification failed" >&2
  exit 1
fi
git diff-index --quiet --cached HEAD -- || { echo "$NEXAWRT_FLAVOR source index differs from pinned commit" >&2; exit 1; }
git diff-files --quiet --no-ext-diff --ignore-submodules -- || { echo "$NEXAWRT_FLAVOR source worktree differs from pinned commit" >&2; exit 1; }
python3 - "$WORK_DIR" <<'PY_UNTRACKED' || { echo "$NEXAWRT_FLAVOR source has non-whitelisted untracked files after reset" >&2; exit 1; }
import os
import pathlib
import subprocess
import sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
raw = subprocess.check_output(["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"])
for encoded in raw.split(b"\0"):
    if not encoded:
        continue
    path = os.fsdecode(encoded)
    if path == ".nexawrt-feeds-state":
        continue
    raise SystemExit(f"unexpected untracked source path: {path}")
PY_UNTRACKED
python3 - "$WORK_DIR" <<'PY_IGNORED' || { echo "$NEXAWRT_FLAVOR source has non-whitelisted ignored files after reset" >&2; exit 1; }
import os
import pathlib
import subprocess
import sys
root = pathlib.Path(sys.argv[1]).resolve(strict=True)
raw = subprocess.check_output(["git", "-C", str(root), "ls-files", "--others", "--ignored", "--exclude-standard", "-z"])
allowed_roots = ("feeds/", "package/feeds/")
for encoded in raw.split(b"\0"):
    if not encoded:
        continue
    path = os.fsdecode(encoded)
    if path == ".nexawrt-feeds-state" or path.startswith(allowed_roots):
        continue
    raise SystemExit(f"unexpected ignored source path: {path}")
PY_IGNORED
write_openwrt_revision

# The official lock already contains the reviewed apk gzip fix while the NSS
# lock does not. Normalize only that exact known file so root patch 004 can add
# one canonical package-local source patch on both source lines.
if [[ -e "$APK_REPRO_SOURCE_PATCH" || -L "$APK_REPRO_SOURCE_PATCH" ]]; then
  [[ -f "$APK_REPRO_SOURCE_PATCH" && ! -L "$APK_REPRO_SOURCE_PATCH" ]] || {
    echo "Existing apk reproducibility patch is unsafe" >&2
    exit 1
  }
  apk_repro_hash="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$APK_REPRO_SOURCE_PATCH"; else shasum -a 256 -- "$APK_REPRO_SOURCE_PATCH"; fi | awk '{print $1}')"
  [[ "$apk_repro_hash" == "$APK_REPRO_UPSTREAM_SHA256" ]] || {
    echo "Existing apk reproducibility patch differs from the reviewed upstream copy" >&2
    exit 1
  }
  rm -- "$APK_REPRO_SOURCE_PATCH"
fi

for patch in "$ROOT_DIR"/patches/[0-9][0-9][0-9]-*.patch; do
  git apply --check "$patch"
  git apply "$patch"
done

while read -r feed expected_repo revision; do
  [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
  pin_feed "$feed" "$expected_repo" "$revision"
done < "$ROOT_DIR/manifests/feeds.lock"

if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
  pin_feed "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_REPO" "$NSS_PACKAGES_COMMIT"
  pin_feed "$NSS_SQM_FEED" "$NSS_SQM_REPO" "$NSS_SQM_COMMIT"
fi
config_feed_set_matches_locks || {
  echo "Enabled feeds do not exactly match the $NEXAWRT_FLAVOR lock set" >&2
  exit 1
}

rm -rf files
mkdir -p files
rsync -a "$ROOT_DIR/files/" files/
if [[ "$NEXAWRT_FLAVOR" == nss && -d "$ROOT_DIR/files-nss" ]]; then
  rsync -a "$ROOT_DIR/files-nss/" files/
fi

repository_public_key="$ROOT_DIR/manifests/package-repository-public.pem"
repository_package_set="$ROOT_DIR/manifests/package-repository-packages.txt"
repository_package_source="$ROOT_DIR/packages/nexawrt-repository"
for required in "$repository_public_key" "$repository_package_set" "$repository_package_source/Makefile"; do
  [[ -f "$required" && ! -L "$required" ]] || {
    echo "NexaWrt package repository input is missing or unsafe: $required" >&2
    exit 1
  }
done
if find "$repository_package_source" \( -type l -o -type f -links +1 \) -print -quit | grep -q .; then
  echo "NexaWrt package repository source must not contain symbolic or hard links" >&2
  exit 1
fi
repository_package_set_sha="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$repository_package_set"; else shasum -a 256 -- "$repository_package_set"; fi | awk '{print $1}')"
[[ "$repository_package_set_sha" == "$NEXAWRT_REPOSITORY_PACKAGE_SET_SHA256" ]] || {
  echo "NexaWrt package repository package set differs from its lock" >&2
  exit 1
}
repository_public_sha="$(openssl pkey -pubin -in "$repository_public_key" -outform DER 2>/dev/null |   { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')"
[[ "$repository_public_sha" == "$NEXAWRT_REPOSITORY_PUBLIC_SHA256" ]] || {
  echo "NexaWrt package repository public key differs from its lock" >&2
  exit 1
}
mkdir -p files/etc/apk/keys files/etc/apk/repositories.d package/nexawrt-repository
install -m 0644 "$repository_public_key" files/etc/apk/keys/nexawrt-repository.pem
printf '%s\n' "$NEXAWRT_REPOSITORY_INDEX_URL" > files/etc/apk/repositories.d/nexawrt.list
rsync -a --delete "$repository_package_source/" package/nexawrt-repository/
cp "$SEED_CONFIG" .config

assert_existing_feed_checkouts_have_no_history_overrides || exit 1

reuse_installed_feeds=0
if ((WITH_FEEDS)) && installed_feed_state_is_reusable; then
  reuse_installed_feeds=1
  printf 'Reusing fully verified installed %s feed state\n' "$NEXAWRT_FLAVOR"
else
  # An incomplete or unverifiable feed state is never repaired in place. Keep
  # only the shared download cache, then rebuild from the exact feed locks.
  reset_feed_checkouts || exit 1
fi

if ((WITH_FEEDS)); then
  if ((reuse_installed_feeds == 0)); then
    # Update one exact-pinned feed at a time. A transient TLS failure must not
    # discard already verified feeds and restart the entire network operation.
    while IFS= read -r feed; do
      [[ -n "$feed" ]] || continue
      update_one_pinned_feed "$feed"
    done < <(awk '$1 ~ /^src-git(-full)?$/ { print $2 }' feeds.conf.default)

    git -C feeds/packages apply --check "$PACKAGES_IPERF3_RPATH_PATCH"
    git -C feeds/packages apply "$PACKAGES_IPERF3_RPATH_PATCH"
    if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
      git -C "feeds/$NSS_PACKAGES_FEED" apply --check "$NSS_PACKAGES_SOURCE_PATCH"
      git -C "feeds/$NSS_PACKAGES_FEED" apply "$NSS_PACKAGES_SOURCE_PATCH"
    fi
    feed_checkouts_match_locks || {
      echo "A pinned feed changed before installation" >&2
      exit 1
    }
    ./scripts/feeds install -a
  fi

  # Feed installation and a reused verified state both resolve from the locked
  # seed. make defconfig may regenerate feed indexes, which are removed before
  # the complete checkout/link policy is verified again.
  cp "$SEED_CONFIG" .config
  apply_component_kconfig
  make defconfig
  remove_generated_feed_metadata
  feed_checkouts_match_locks && feed_top_level_matches_locks && \
    package_feed_links_match_locks || {
    echo "Pinned feeds or installed package links changed during installation or defconfig" >&2
    exit 1
  }
  write_feed_state feeds-installed
else
  write_feed_state no-feeds
fi

NEXAWRT_FLAVOR="$NEXAWRT_FLAVOR" OPENWRT_REPO_OVERRIDE="$SOURCE_REPO" \
  "$ROOT_DIR/scripts/validate.sh" --source "$WORK_DIR"
printf 'Prepared %s source %s (%s) at %s\n' \
  "$NEXAWRT_FLAVOR" "$SOURCE_COMMIT" "$SOURCE_LABEL" "$WORK_DIR"
