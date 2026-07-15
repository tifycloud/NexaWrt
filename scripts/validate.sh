#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../manifests/upstream.lock
source "$ROOT_DIR/manifests/upstream.lock"
NEXAWRT_FLAVOR="${NEXAWRT_FLAVOR:-official}"
SOURCE_DIR=""
CHECK_ARTIFACTS=0
FEED_POLICY_ONLY=0
NSS_PACKAGES_SOURCE_PATCH="$ROOT_DIR/patches/nss/001-pin-codelinaro-source-archives.patch"

case "$NEXAWRT_FLAVOR" in
  official)
    EXPECTED_SOURCE_REPO="${OPENWRT_REPO_OVERRIDE:-$OPENWRT_REPO}"
    EXPECTED_SOURCE_COMMIT="$OPENWRT_COMMIT"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi.config"
    ;;
  nss)
    # Keep official validation independent from the experimental NSS lock.
    # shellcheck source=../manifests/nss.lock
    source "$ROOT_DIR/manifests/nss.lock"
    EXPECTED_SOURCE_REPO="${OPENWRT_REPO_OVERRIDE:-$NSS_OPENWRT_REPO}"
    EXPECTED_SOURCE_COMMIT="$NSS_OPENWRT_COMMIT"
    SEED_CONFIG="$ROOT_DIR/configs/ax9000-single-ubi-nss.config"
    ;;
  *)
    echo "validation: unsupported NEXAWRT_FLAVOR: $NEXAWRT_FLAVOR (expected official or nss)" >&2
    exit 2
    ;;
esac

usage() {
  echo "Usage: NEXAWRT_FLAVOR=official|nss $0 [--source PATH] [--artifacts] [--feed-policy-only]" >&2
}

while (($#)); do
  case "$1" in
    --source) SOURCE_DIR="${2:?missing source path}"; shift ;;
    --artifacts) CHECK_ARTIFACTS=1 ;;
    --feed-policy-only) FEED_POLICY_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

fail() { echo "validation: $*" >&2; exit 1; }

patch_added_lines() {
  sed -n -e '/^+++ /d' -e 's/^+//p' "$1"
}

assert_patch_has_context() {
  local patch="$1"
  awk '
    /^@@ / {
      if (seen_hunk && !has_context) bad = 1
      seen_hunk = 1
      has_context = 0
      next
    }
    seen_hunk && /^ / { has_context = 1 }
    END {
      if (!seen_hunk || !has_context) bad = 1
      exit bad
    }
  ' "$patch" || fail "patch has a zero-context or malformed hunk: $(basename "$patch")"
}

extract_shell_function() {
  local function_name="$1"
  local file="$2"
  awk -v signature="${function_name}() {" '
    $0 == signature { in_function = 1 }
    in_function { print }
    in_function && $0 == "}" { exit }
  ' "$file"
}

extract_board_branch() {
  local board="$1"
  awk -v board="$board" '
    $0 ~ "^[[:space:]]*" board "\\)" { in_branch = 1 }
    in_branch { print }
    in_branch && /^[[:space:]]*;;[[:space:]]*$/ { exit }
  '
}

assert_ax9000_upgrade_blocked() {
  local platform="$1"
  local function_name function_body branch

  function_body="$(extract_shell_function ax9000_persistent_upgrade_blocked "$platform")"
  grep -Fq 'return 74' <<<"$function_body" ||
    fail "AX9000 persistent-upgrade helper remains forceable"

  for function_name in platform_check_image platform_pre_upgrade platform_do_upgrade; do
    function_body="$(extract_shell_function "$function_name" "$platform")"
    [[ -n "$function_body" ]] || fail "$function_name is missing"
    branch="$(printf '%s\n' "$function_body" | extract_board_branch 'xiaomi,ax9000')"
    [[ -n "$branch" ]] || fail "$function_name has no dedicated xiaomi,ax9000 branch"
    grep -Fq 'ax9000_persistent_upgrade_blocked' <<<"$branch" ||
      fail "$function_name does not fail closed for xiaomi,ax9000"
  done

  function_body="$(extract_shell_function platform_do_upgrade "$platform")"
  branch="$(printf '%s\n' "$function_body" | extract_board_branch 'xiaomi,ax9000')"
  grep -Fq 'return 1' <<<"$branch" ||
    fail "platform_do_upgrade does not explicitly return failure for xiaomi,ax9000"
  if grep -Eq '(^|[^[:alnum:]_])(nand_do_upgrade|fw_setenv|ubiformat)([^[:alnum:]_]|$)' <<<"$branch"; then
    fail "platform_do_upgrade uses a dangerous persistent-upgrade tool for xiaomi,ax9000"
  fi
}

assert_sha() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] || fail "invalid $name commit lock"
}

feed_pin_matches_lock() {
  local config="$1"
  local feed="$2"
  local expected_repo="$3"
  local revision="$4"

  awk -v feed="$feed" -v revision="$revision" -v expected_repo="$expected_repo" '
    $1 ~ /^src-git(-full)?$/ && $2 == feed {
      seen++
      if ($3 == expected_repo "^" revision) valid++
    }
    END { exit !(seen == 1 && valid == 1) }
  ' "$config"
}

expected_feed_names() {
  awk 'NF >= 2 && $1 !~ /^#/ { print $1 }' "$ROOT_DIR/manifests/feeds.lock"
  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    printf '%s\n%s\n' "$NSS_PACKAGES_FEED" "$NSS_SQM_FEED"
  fi
}

assert_config_feed_set() {
  local config="$1"
  local expected expected_unique actual actual_unique

  awk '
    $1 ~ /^src-/ && $1 !~ /^src-git(-full)?$/ { exit 1 }
  ' "$config" || fail "feeds.conf.default contains an unsupported enabled feed type"
  expected="$(expected_feed_names | LC_ALL=C sort)"
  expected_unique="$(printf '%s\n' "$expected" | LC_ALL=C sort -u)"
  [[ "$expected" == "$expected_unique" ]] || fail "locked feed set contains duplicate names"
  actual="$(awk '$1 ~ /^src-git(-full)?$/ { print $2 }' "$config" | LC_ALL=C sort)"
  actual_unique="$(printf '%s\n' "$actual" | LC_ALL=C sort -u)"
  [[ "$actual" == "$actual_unique" ]] || fail "feeds.conf.default contains duplicate enabled feeds"
  [[ "$actual" == "$expected" ]] ||
    fail "feeds.conf.default enabled feed set does not exactly match the $NEXAWRT_FLAVOR lock set"
}

top_level_names() {
  local directory="$1"
  find "$directory" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort
}

assert_top_level_feed_set() {
  local directory="$1"
  local description="$2"
  local expected actual feed entry

  [[ -d "$directory" ]] || fail "$description directory is missing"
  expected="$(expected_feed_names | LC_ALL=C sort)"
  actual="$(top_level_names "$directory")"
  [[ "$actual" == "$expected" ]] ||
    fail "$description top-level set does not exactly match the locked feed set"
  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    entry="$directory/$feed"
    [[ -d "$entry" && ! -L "$entry" ]] ||
      fail "$description entry is not a real directory: $feed"
  done <<< "$expected"
}

assert_feed_checkout_set() {
  local source="$1"
  local directory="$source/feeds"
  local expected actual feed entry base_link resolved

  [[ -d "$directory" ]] || fail "feeds directory is missing"
  expected="$(expected_feed_names | LC_ALL=C sort)"
  actual="$(find "$directory" -mindepth 1 -maxdepth 1 ! -name base -exec basename {} \; | LC_ALL=C sort)"
  [[ "$actual" == "$expected" ]] ||
    fail "feeds top-level set does not exactly match the locked feed set"

  base_link="$directory/base"
  if [[ -e "$base_link" || -L "$base_link" ]]; then
    [[ -L "$base_link" ]] || fail "feeds/base must be the OpenWrt package symlink"
    [[ "$(readlink "$base_link")" == ../package ]] ||
      fail "feeds/base has an unexpected symlink target"
    resolved="$(cd -P "$base_link" 2>/dev/null && pwd -P)" ||
      fail "feeds/base does not resolve"
    [[ "$resolved" == "$(cd -P "$source/package" && pwd -P)" ]] ||
      fail "feeds/base does not resolve to the source package directory"
  fi

  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    entry="$directory/$feed"
    [[ -d "$entry" && ! -L "$entry" ]] ||
      fail "feeds entry is not a real directory: $feed"
  done <<< "$expected"
}

assert_package_feed_links() {
  local source="$1"
  local expected feed directory entry feed_root resolved

  assert_top_level_feed_set "$source/package/feeds" "package/feeds"
  expected="$(expected_feed_names | LC_ALL=C sort)"
  while IFS= read -r feed; do
    [[ -n "$feed" ]] || continue
    directory="$source/package/feeds/$feed"
    feed_root="$(cd -P "$source/feeds/$feed" && pwd -P)" ||
      fail "cannot resolve feed checkout root: $feed"
    while IFS= read -r -d '' entry; do
      [[ -L "$entry" ]] ||
        fail "package/feeds/$feed contains a non-symlink entry: $(basename "$entry")"
      [[ -d "$entry" ]] ||
        fail "package/feeds/$feed symlink does not resolve to a package directory: $(basename "$entry")"
      resolved="$(cd -P "$entry" 2>/dev/null && pwd -P)" ||
        fail "cannot resolve package feed symlink: $entry"
      case "$resolved" in
        "$feed_root"/*) ;;
        *) fail "package/feeds/$feed symlink resolves outside its feed checkout: $(basename "$entry")" ;;
      esac
    done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)
  done <<< "$expected"
}

assert_feed_pin() {
  local config="$1"
  local feed="$2"
  local expected_repo="$3"
  local revision="$4"

  feed_pin_matches_lock "$config" "$feed" "$expected_repo" "$revision" ||
    fail "feed $feed is not uniquely pinned to $revision at the expected repository"
}

assert_feed_checkout_clean() {
  local feed="$1"
  local checkout="$2"
  local git_dir sparse_checkout sparse_index sparse_entries index_tags untracked ignored

  git_dir="$(git -C "$checkout" rev-parse --absolute-git-dir 2>/dev/null)" ||
    fail "unable to inspect feed checkout $feed"
  sparse_checkout="$(git -C "$checkout" config --get core.sparseCheckout 2>/dev/null || true)"
  sparse_index="$(git -C "$checkout" config --get index.sparse 2>/dev/null || true)"
  sparse_entries="$(git -C "$checkout" ls-files --sparse --stage 2>/dev/null)" ||
    fail "unable to inspect feed checkout $feed"
  case "$sparse_checkout" in
    ""|false|no|off|0) ;;
    *) fail "feed checkout $feed uses sparse checkout or a sparse index" ;;
  esac
  case "$sparse_index" in
    ""|false|no|off|0) ;;
    *) fail "feed checkout $feed uses sparse checkout or a sparse index" ;;
  esac
  if [[ -e "$git_dir/info/sparse-checkout" ]] ||
      grep -Eq '^040000 ' <<<"$sparse_entries"; then
    fail "feed checkout $feed uses sparse checkout or a sparse index"
  fi

  index_tags="$(git -C "$checkout" ls-files -v)" ||
    fail "unable to inspect feed checkout $feed"
  grep -Eq '^[a-z] ' <<<"$index_tags" &&
    fail "feed checkout $feed has assume-unchanged index entries"
  grep -Eq '^[Ss] ' <<<"$index_tags" &&
    fail "feed checkout $feed has skip-worktree index entries"

  git -C "$checkout" diff-index --quiet --cached HEAD -- ||
    fail "feed checkout $feed has staged changes"
  if [[ "$NEXAWRT_FLAVOR" == nss && "$feed" == "$NSS_PACKAGES_FEED" ]]; then
    [[ -f "$NSS_PACKAGES_SOURCE_PATCH" ]] || fail "NSS source archive patch is missing"
    [[ "$(git -C "$checkout" diff --binary --no-ext-diff HEAD --)" ==       "$(cat "$NSS_PACKAGES_SOURCE_PATCH")" ]] ||
      fail "feed checkout $feed does not contain the exact NexaWrt source archive patch"
  else
    git -C "$checkout" diff-files --quiet --ignore-submodules -- ||
      fail "feed checkout $feed is not clean"
  fi
  untracked="$(git -C "$checkout" ls-files --others --exclude-standard)" ||
    fail "unable to inspect untracked files in feed checkout $feed"
  [[ -z "$untracked" ]] || fail "feed checkout $feed is not clean"
  ignored="$(git -C "$checkout" ls-files --others --ignored --exclude-standard | LC_ALL=C sort)" ||
    fail "unable to inspect ignored files in feed checkout $feed"
  if [[ -n "$ignored" ]]; then
    if ((CHECK_ARTIFACTS == 0)); then
      fail "feed checkout $feed contains ignored files"
    fi
    # A pinned LuCI build creates these ignored host tools in its checkout.
    # Post-build validation permits only this exact, regular-file set; the
    # pre-build validation performed by prepare.sh still requires no ignored
    # files at all.
    if [[ "$feed" != luci ]]; then
      fail "feed checkout $feed contains unexpected post-build ignored files"
    fi
    local expected_ignored
    expected_ignored="$(printf '%s\n' \
      modules/luci-base/src/contrib/lemon \
      modules/luci-base/src/jsmin \
      modules/luci-base/src/jsmin.o \
      modules/luci-base/src/lib/lmo.o \
      modules/luci-base/src/lib/plural_formula.c \
      modules/luci-base/src/lib/plural_formula.h \
      modules/luci-base/src/lib/plural_formula.o \
      modules/luci-base/src/po2lmo \
      modules/luci-base/src/po2lmo.o | LC_ALL=C sort)"
    [[ "$ignored" == "$expected_ignored" ]] ||
      fail "feed checkout $feed contains unexpected post-build ignored files"
    while IFS= read -r ignored_path; do
      [[ -f "$checkout/$ignored_path" && ! -L "$checkout/$ignored_path" ]] ||
        fail "feed checkout $feed post-build ignored path is not a regular file: $ignored_path"
    done <<< "$ignored"
  fi
}

assert_feed_checkout() {
  local source="$1"
  local feed="$2"
  local revision="$3"
  local expected_repo="$4"
  local checkout="$source/feeds/$feed"
  local remote_urls

  [[ -d "$checkout/.git" ]] || fail "feed checkout missing Git metadata: $feed"
  [[ "$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null)" == "$revision" ]] ||
    fail "feed checkout $feed is not at $revision"
  remote_urls="$(git -C "$checkout" remote get-url --all origin 2>/dev/null)" ||
    fail "feed checkout $feed has no origin remote"
  [[ "$remote_urls" == "$expected_repo" ]] ||
    fail "feed checkout $feed uses an unexpected origin"
  assert_feed_checkout_clean "$feed" "$checkout"
}

feed_state_field() {
  local marker="$1"
  local key="$2"

  awk -F= -v key="$key" '
    $1 == key { count++; value = substr($0, length(key) + 2) }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$marker"
}

directory_has_content() {
  local directory="$1"
  [[ -d "$directory" && -n "$(find "$directory" -mindepth 1 -maxdepth 1 -print -quit)" ]]
}

assert_feed_state() {
  local source="$1"
  local marker="$source/.nexawrt-feeds-state"
  local version marker_flavor state

  [[ -f "$marker" ]] || fail "feed state marker is missing"
  [[ "$(awk 'END { print NR }' "$marker")" == 3 ]] ||
    fail "feed state marker is malformed"
  version="$(feed_state_field "$marker" version)" || fail "feed state marker lacks one version"
  marker_flavor="$(feed_state_field "$marker" flavor)" || fail "feed state marker lacks one flavor"
  state="$(feed_state_field "$marker" state)" || fail "feed state marker lacks one state"
  [[ "$version" == 1 ]] || fail "unsupported feed state marker version"
  [[ "$marker_flavor" == "$NEXAWRT_FLAVOR" ]] || fail "feed state marker flavor mismatch"

  case "$state" in
    no-feeds)
      ! directory_has_content "$source/feeds" ||
        fail "no-feeds source unexpectedly contains feed checkout data"
      ! directory_has_content "$source/package/feeds" ||
        fail "no-feeds source unexpectedly contains installed feed packages"
      ;;
    feeds-installed)
      [[ -d "$source/feeds" ]] || fail "feeds-installed source lacks feeds directory"
      [[ -d "$source/package/feeds" ]] ||
        fail "feeds-installed source lacks package/feeds directory"
      ;;
    *) fail "unknown feed state marker value: $state" ;;
  esac

  printf '%s\n' "$state"
}

validate_feed_policy() {
  local source="$1"
  local config="$source/feeds.conf.default"
  local state feed expected_repo revision

  [[ -f "$config" ]] || fail "feeds.conf.default is missing"
  assert_config_feed_set "$config"
  while read -r feed expected_repo revision; do
    [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
    assert_feed_pin "$config" "$feed" "$expected_repo" "$revision"
  done < "$ROOT_DIR/manifests/feeds.lock"

  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    assert_feed_pin "$config" \
      "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_REPO" "$NSS_PACKAGES_COMMIT"
    assert_feed_pin "$config" \
      "$NSS_SQM_FEED" "$NSS_SQM_REPO" "$NSS_SQM_COMMIT"
  elif grep -Eq '^[[:space:]]*src-git(-full)?[[:space:]]+(nss_packages|sqm_scripts_nss)[[:space:]]' \
    "$config"; then
    fail "official flavor contains an NSS feed"
  fi

  state="$(assert_feed_state "$source")"
  [[ "$state" == feeds-installed ]] || return 0

  assert_feed_checkout_set "$source"
  while read -r feed expected_repo revision; do
    [[ -n "$feed" && "${feed:0:1}" != '#' ]] || continue
    assert_feed_checkout "$source" "$feed" "$revision" "$expected_repo"
  done < "$ROOT_DIR/manifests/feeds.lock"

  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    assert_feed_checkout "$source" \
      "$NSS_PACKAGES_FEED" "$NSS_PACKAGES_COMMIT" "$NSS_PACKAGES_REPO"
    assert_feed_checkout "$source" \
      "$NSS_SQM_FEED" "$NSS_SQM_COMMIT" "$NSS_SQM_REPO"
    assert_nss_feed_symbols "$source/feeds/$NSS_PACKAGES_FEED"
  fi
  assert_package_feed_links "$source"
}

assert_nss_feed_symbols() {
  local feed_dir="$1"
  local drv_makefile="$feed_dir/qca-nss-drv/Makefile"
  local ecm_makefile="$feed_dir/qca-nss-ecm/Makefile"
  local firmware_makefile="$feed_dir/firmware/nss-firmware/Makefile"

  [[ -f "$drv_makefile" ]] || fail "pinned nss-packages feed lacks qca-nss-drv"
  [[ -f "$ecm_makefile" ]] || fail "pinned nss-packages feed lacks qca-nss-ecm"
  [[ -f "$firmware_makefile" ]] || fail "pinned nss-packages feed lacks nss-firmware"
  grep -Fq 'define KernelPackage/qca-nss-drv' "$drv_makefile" ||
    fail "pinned feed does not define CONFIG_PACKAGE_kmod-qca-nss-drv"
  grep -Fq 'define KernelPackage/qca-nss-ecm' "$ecm_makefile" ||
    fail "pinned feed does not define CONFIG_PACKAGE_kmod-qca-nss-ecm"
  grep -Fq 'define Package/nss-firmware-ipq807x' "$firmware_makefile" ||
    fail "pinned feed does not define CONFIG_PACKAGE_nss-firmware-ipq807x"
  grep -Eq '^[[:space:]]*config NSS_FIRMWARE_VERSION_12_5$' "$firmware_makefile" ||
    fail "pinned feed does not define CONFIG_NSS_FIRMWARE_VERSION_12_5"
}

contains_forbidden_official_nss() {
  # Official qualcommax intentionally selects the upstream kmod-qca-nss-dp
  # data-plane dependency. Do not broaden this matcher to generic qca-nss-*;
  # only the third-party NSS acceleration stack is forbidden in this flavor.
  grep -Eq '^CONFIG_(ATH11K_NSS_.*|NSS_FIRMWARE_VERSION_.*|PACKAGE_(kmod-qca-nss-(drv|ecm|cfi|crypto|macsec)(-[^=]+)?|nss-firmware(-[^=]+)?|nss-ifb|nss-userspace-oss))=y$'
}

assert_official_nss_matcher() {
  if printf '%s\n' 'CONFIG_PACKAGE_kmod-qca-nss-dp=y' |
    contains_forbidden_official_nss; then
    fail "official NSS matcher rejects allowed kmod-qca-nss-dp"
  fi
  printf '%s\n' \
    'CONFIG_PACKAGE_kmod-qca-nss-drv=y' \
    'CONFIG_PACKAGE_kmod-qca-nss-ecm=y' \
    'CONFIG_PACKAGE_nss-firmware-ipq807x=y' \
    'CONFIG_PACKAGE_kmod-qca-nss-drv-bridge-mgr=y' |
    contains_forbidden_official_nss ||
    fail "official NSS matcher does not reject the third-party NSS stack"
}

assert_common_config() {
  local config="$1"
  local description="$2"
  local selected_targets=()
  local package

  while IFS= read -r target; do
    selected_targets+=("$target")
  done < <(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' "$config" || true)
  ((${#selected_targets[@]} == 1)) || fail "$description must select exactly one device"
  [[ "${selected_targets[0]}" == \
    'CONFIG_TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax9000_single_ubi=y' ]] ||
    fail "$description selects the wrong device"

  grep -Fq 'CONFIG_TARGET_ROOTFS_INITRAMFS=y' "$config" ||
    fail "$description does not enable initramfs"
  grep -Fq 'CONFIG_TARGET_ROOTFS_SQUASHFS=y' "$config" ||
    fail "$description lost the squashfs target rootfs"
  grep -Fq 'CONFIG_JSON_CYCLONEDX_SBOM=y' "$config" ||
    fail "$description does not enable the CycloneDX image SBOM"
  grep -Fq 'CONFIG_LUCI_LANG_zh_Hans=y' "$config" ||
    fail "$description lost Simplified Chinese LuCI language"
  for package in luci luci-ssl ca-bundle curl ethtool htop iperf3 nano tcpdump-mini; do
    grep -Fq "CONFIG_PACKAGE_${package}=y" "$config" ||
      fail "$description lost required package: $package"
  done

  if grep -Eq '^CONFIG_PACKAGE_(mtd|uboot-envtools|ubi-utils)=[ym]$' "$config"; then
    fail "$description enabled a persistent flash/environment tool"
  fi
  for command in sysupgrade firstboot jffs2reset jffs2mark factoryreset mount_root; do
    guard="$ROOT_DIR/files/sbin/$command"
    [[ -x "$guard" ]] || fail "RAM-only runtime guard is missing or not executable: $command"
    grep -Fq "$command is disabled" "$guard" || fail "RAM-only runtime guard is malformed: $command"
    grep -Fq 'exit 74' "$guard" || fail "RAM-only runtime guard is forceable: $command"
  done
}

assert_flavor_config() {
  local config="$1"
  local description="$2"
  local symbol

  assert_common_config "$config" "$description"
  if [[ "$NEXAWRT_FLAVOR" == official ]]; then
    if contains_forbidden_official_nss < "$config"; then
      fail "$description enabled the third-party NSS stack in the official flavor"
    fi
  else
    for symbol in \
      PACKAGE_kmod-qca-nss-drv \
      PACKAGE_kmod-qca-nss-ecm \
      PACKAGE_nss-firmware-ipq807x \
      NSS_FIRMWARE_VERSION_12_5; do
      grep -Fq "CONFIG_${symbol}=y" "$config" ||
        fail "$description lost required NSS selection: $symbol"
    done
    awk '
      /^CONFIG_NSS_FIRMWARE_VERSION_[[:alnum:]_]+=y$/ {
        selected++
        if ($0 != "CONFIG_NSS_FIRMWARE_VERSION_12_5=y") unexpected = 1
      }
      END { exit !(selected == 1 && !unexpected) }
    ' "$config" || fail "$description must select only NSS firmware version 12.5"
    if grep -Eq '^CONFIG_ATH11K_NSS_[[:alnum:]_]+=y$' "$config"; then
      fail "$description enabled an ATH11K NSS feature in the first NSS flavor"
    fi
    if grep -Eiq '^CONFIG_PACKAGE_(kmod-qca-nss-drv-wifi-meshmgr|sqm-scripts(-nss)?|luci-app-sqm)=y$' "$config"; then
      fail "$description enabled NSS mesh or SQM in the first NSS flavor"
    fi
  fi

  if grep -Eiq '^CONFIG_.*(OPENCLASH|PASSWALL|DOCKER|PODMAN|SAMBA|ADGUARD|LUCKY).*=y$' "$config"; then
    fail "$description enabled a forbidden first-stage package"
  fi
}

if [[ "$NEXAWRT_FLAVOR" == official ]]; then
  assert_official_nss_matcher
  assert_sha OPENWRT "$OPENWRT_COMMIT"
else
  assert_sha NSS_OPENWRT "$NSS_OPENWRT_COMMIT"
  assert_sha NSS_PACKAGES "$NSS_PACKAGES_COMMIT"
  assert_sha NSS_SQM "$NSS_SQM_COMMIT"
  [[ "$NSS_OPENWRT_REPO" == 'https://github.com/qosmio/openwrt-ipq.git' ]] ||
    fail "unexpected NSS OpenWrt repository lock"
  [[ "$NSS_OPENWRT_BRANCH" == '25.12-nss' ]] || fail "unexpected NSS source branch lock"
  [[ "$NSS_OPENWRT_COMMIT" == 'd6848fa2ea00193b5b7d3973e3990da7f608027c' ]] ||
    fail "unexpected NSS OpenWrt commit lock"
  [[ "$NSS_PACKAGES_REPO" == 'https://github.com/qosmio/nss-packages.git' ]] ||
    fail "unexpected nss-packages repository lock"
  [[ "$NSS_PACKAGES_COMMIT" == '0d970dbf0185e3f53709bd803e8a466598023c57' ]] ||
    fail "unexpected nss-packages commit lock"
  [[ "$NSS_SQM_REPO" == 'https://github.com/qosmio/sqm-scripts-nss.git' ]] ||
    fail "unexpected sqm-scripts-nss repository lock"
  [[ "$NSS_SQM_COMMIT" == '4b4ed8639229be5e70cf94b73cdf7dbc09e66d5d' ]] ||
    fail "unexpected sqm-scripts-nss commit lock"
fi
[[ "$ROOTFS_MTD_OFFSET_HEX" == 0x01180000 ]] || fail "unexpected rootfs offset lock"
[[ "$ROOTFS_MTD_SIZE_HEX" == 0x0e800000 ]] || fail "unexpected rootfs size lock"

if ((FEED_POLICY_ONLY)); then
  [[ -n "$SOURCE_DIR" ]] || fail "--feed-policy-only requires --source"
  validate_feed_policy "$SOURCE_DIR"
  echo "feed policy validation ($NEXAWRT_FLAVOR): OK"
  exit 0
fi

patch_001="$ROOT_DIR/patches/001-ax9000-single-large-ubi-layout.patch"
patch_002="$ROOT_DIR/patches/002-ax9000-block-persistent-upgrade.patch"

assert_patch_has_context "$patch_001"
assert_patch_has_context "$patch_002"
if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
  [[ -f "$NSS_PACKAGES_SOURCE_PATCH" ]] || fail "NSS source archive patch is missing"
  assert_patch_has_context "$NSS_PACKAGES_SOURCE_PATCH"
  for required in \
    'PKG_SOURCE_VERSION:=d5ee67bd84d1ee7ed81eb6758e62a6db5a0cf4c7' \
    'PKG_HASH:=519fea60d3394684fa13bf775c5e2654ef333495c15e2b7f3911ce290536d13b' \
    'PKG_SOURCE_VERSION:=30fbfa493d700270ac6c14685290f340b6ead28c' \
    'PKG_HASH:=4e93a653fffb3da410f585e6c2a6a3292a4b80d1bd535baf1a6236c427ec6575' \
    'PKG_SOURCE_VERSION:=51be82d43ef85079f78aa163d014223b05baa6a2' \
    'PKG_HASH:=fe04eec0007deb7983a42ebb77ab60753cb5aaefe3bb2120137621fed09d42c9' \
    'PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/nss-drv-$(PKG_SOURCE_VERSION)' \
    'PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/qca-nss-ecm-$(PKG_SOURCE_VERSION)' \
    'PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/nss-clients-$(PKG_SOURCE_VERSION)'; do
    grep -Fq "+$required" "$NSS_PACKAGES_SOURCE_PATCH" ||
      fail "NSS source archive patch lost a required full commit or SHA-256 pin"
  done
  ! grep -Fq '+PKG_MIRROR_HASH:=skip' "$NSS_PACKAGES_SOURCE_PATCH" ||
    fail "NSS source archive patch disables source verification"
fi
assert_flavor_config "$SEED_CONFIG" "$NEXAWRT_FLAVOR seed config"

patch_001_added="$(patch_added_lines "$patch_001")"
grep -Fq 'bootargs-override = "root=/dev/ram0";' <<<"$patch_001_added" ||
  fail "001 patch does not force the AX9000 initramfs root"
if grep -Eq 'ubi\.mtd=|root=/dev/ubiblock' <<<"$patch_001_added"; then
  fail "001 patch adds a persistent UBI root command line"
fi
grep -Fq $'DEVICE_PACKAGES += -uboot-envtools -ubi-utils -mtd' <<<"$patch_001_added" ||
  fail "custom AX9000 profile does not remove dangerous packages"
readonly_additions="$(grep -Fxc $'				read-only;' <<<"$patch_001_added" || true)"
((readonly_additions >= 4)) ||
  fail "project patch must make appsblenv, bdata, pstore, and rootfs MTD partitions read-only"
grep -Fq 'diff --git a/package/base-files/Makefile b/package/base-files/Makefile' "$patch_001" ||
  fail "001 patch does not remove the base-files ubi-utils dependency"
grep -Fq 'diff --git a/package/system/fstools/Makefile b/package/system/fstools/Makefile' "$patch_001" ||
  fail "001 patch does not remove the fstools ubi-utils dependency"
grep -Fq $'IMAGES :=' <<<"$patch_001_added" || fail "custom AX9000 profile must clear IMAGES"
grep -Fq $'ARTIFACTS :=' <<<"$patch_001_added" || fail "custom AX9000 profile must clear ARTIFACTS"

patch_002_added="$(patch_added_lines "$patch_002")"
grep -Fq 'return 74' <<<"$patch_002_added" || fail "002 patch does not mark AX9000 upgrades non-forceable"
blocked_call_count="$(grep -Fxc $'\t\tax9000_persistent_upgrade_blocked' <<<"$patch_002_added" || true)"
((blocked_call_count == 3)) ||
  fail "002 patch must block AX9000 check, pre-upgrade, and do-upgrade paths"
if grep -Eq '(^|[^[:alnum:]_])(nand_do_upgrade|fw_setenv|ubiformat)([^[:alnum:]_]|$)' <<<"$patch_002_added"; then
  fail "002 patch adds a dangerous persistent-upgrade command"
fi

credential_scan_paths=(
  "$ROOT_DIR/.github"
  "$ROOT_DIR/configs"
  "$ROOT_DIR/docs"
  "$ROOT_DIR/files"
  "$ROOT_DIR/manifests/feeds.lock"
  "$ROOT_DIR/manifests/upstream.lock"
  "$ROOT_DIR/patches"
  "$ROOT_DIR/scripts/backup-router.sh"
  "$ROOT_DIR/scripts/build.sh"
  "$ROOT_DIR/scripts/collect-build-evidence.sh"
  "$ROOT_DIR/scripts/compare-reproducible-builds.sh"
  "$ROOT_DIR/scripts/verify-hardware-evidence.sh"
  "$ROOT_DIR/scripts/prepare.sh"
  "$ROOT_DIR/scripts/release.sh"
  "$ROOT_DIR/tests/test_backup_guards.sh"
  "$ROOT_DIR/tests/test_hardware_gate.sh"
  "$ROOT_DIR/tests/test_release_policy.sh"
  "$ROOT_DIR/tests/test_reproducibility_policy.sh"
  "$ROOT_DIR/tests/test_runtime_guards.sh"
  "$ROOT_DIR/tests/test_static.sh"
  "$ROOT_DIR/tests/test_workflow_policy.sh"
  "$ROOT_DIR"/*.md
  "$ROOT_DIR/LICENSE"
  "$ROOT_DIR/Makefile"
  "$ROOT_DIR/.gitignore"
)
if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
  credential_scan_paths+=(
    "$ROOT_DIR/scripts/nss-diagnostics.sh"
    "$ROOT_DIR/scripts/stage-nss-artifact.sh"
    "$ROOT_DIR/tests/test_feed_policy.sh"
    "$ROOT_DIR/tests/test_nss_artifact_policy.sh"
    "$ROOT_DIR/files-nss"
    "$ROOT_DIR/manifests/nss.lock"
  )
fi

if grep -RIEq --exclude='validate.sh' \
  '(password[[:space:]]*=|passwd[[:space:]]*=|token[[:space:]]*=|secret[[:space:]]*=|https?://[^/[:space:]]+:[^/@[:space:]]+@|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[[:alnum:]]{20,}|github_pat_[[:alnum:]_]{20,}|(AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}|aws_(access_key_id|secret_access_key|session_token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9/+=]{16,})' \
  "${credential_scan_paths[@]}"; then
  fail "possible embedded credential detected"
fi

for script in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/tests/*.sh; do
  [[ -e "$script" ]] || continue
  if [[ "$NEXAWRT_FLAVOR" == official ]]; then
    case "$(basename "$script")" in
      nss-diagnostics.sh|stage-nss-artifact.sh|test_feed_policy.sh|test_nss_artifact_policy.sh)
        continue
        ;;
    esac
  fi
  bash -n "$script"
done

if [[ -n "$SOURCE_DIR" ]]; then
  [[ -d "$SOURCE_DIR/.git" ]] || fail "source is not a Git checkout: $SOURCE_DIR"
  [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$EXPECTED_SOURCE_COMMIT" ]] ||
    fail "$NEXAWRT_FLAVOR source checkout is not at locked commit"
  [[ "$(git -C "$SOURCE_DIR" remote get-url origin)" == "$EXPECTED_SOURCE_REPO" ]] ||
    fail "$NEXAWRT_FLAVOR source checkout uses an unexpected origin"

  platform="$SOURCE_DIR/target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh"
  dts="$SOURCE_DIR/target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq8072-ax9000.dts"
  image_mk="$SOURCE_DIR/target/linux/qualcommax/image/ipq807x.mk"
  base_files_mk="$SOURCE_DIR/package/base-files/Makefile"
  fstools_mk="$SOURCE_DIR/package/system/fstools/Makefile"
  [[ -f "$platform" && -f "$dts" && -f "$image_mk" && -f "$base_files_mk" && -f "$fstools_mk" ]] ||
    fail "patched source files missing"

  sh -n "$platform"
  grep -Fq 'reg = <0x1180000 0xe800000>;' "$dts" || fail "single rootfs DTS layout missing"
  ! grep -A3 -F 'partition@1180000' "$dts" | grep -Fq 'label = "ubi_kernel"' ||
    fail "stock ubi_kernel partition still present"
  grep -Fq 'bootargs-override = "root=/dev/ram0";' "$dts" ||
    fail "AX9000 DTS does not force root=/dev/ram0"
  for persistent_label in '0:appsblenv' bdata pstore rootfs; do
    awk -v label="label = \"$persistent_label\";" '
      $0 ~ label { found=1; remaining=5 }
      found && /read-only;/ { ok=1; exit }
      remaining > 0 { remaining-- }
      END { exit(ok ? 0 : 1) }
    ' "$dts" || fail "AX9000 persistent MTD partition is not read-only: $persistent_label"
  done
  python3 - "$dts" <<'PY' || fail "AX9000 DTS exposes a writable MTD partition"
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
partition_start = re.compile(r"^\s*partition@[0-9a-fA-F]+\s*\{")
partitions = []
for index, line in enumerate(lines):
    if not partition_start.search(line):
        continue
    depth = 0
    block = []
    for candidate in lines[index:]:
        block.append(candidate)
        depth += candidate.count("{") - candidate.count("}")
        if depth == 0:
            break
    label = next(
        (match.group(1) for entry in block if (match := re.search(r'label\s*=\s*"([^"]+)"', entry))),
        f"partition at line {index + 1}",
    )
    partitions.append((label, any("read-only;" in entry for entry in block)))
if not partitions:
    raise SystemExit("no fixed MTD partitions found")
writable = [label for label, read_only in partitions if not read_only]
if writable:
    raise SystemExit("writable partitions: " + ", ".join(writable))
PY
  if grep -Eq 'ubi\.mtd=|root=/dev/ubiblock' "$dts"; then
    fail "AX9000 DTS still contains a persistent UBI root command line"
  fi

  image_profile="$(awk '
    /^define Device\/xiaomi_ax9000_single_ubi$/ { in_profile = 1 }
    in_profile { print }
    in_profile && /^endef$/ { exit }
  ' "$image_mk")"
  [[ -n "$image_profile" ]] || fail "custom image profile missing"
  grep -Fq 'DEVICE_PACKAGES += -uboot-envtools -ubi-utils -mtd' <<<"$image_profile" ||
    fail "custom image profile does not remove dangerous packages"
  grep -Eq '^[[:space:]]*IMAGES :=[[:space:]]*$' <<<"$image_profile" ||
    fail "custom image profile does not clear IMAGES"
  grep -Eq '^[[:space:]]*ARTIFACTS :=[[:space:]]*$' <<<"$image_profile" ||
    fail "custom image profile does not clear ARTIFACTS"
  grep -Fq 'TARGET_DEVICES += xiaomi_ax9000_single_ubi' "$image_mk" ||
    fail "custom image profile is not selected"
  ! grep -Eq '^TARGET_DEVICES \+= xiaomi_ax9000$' "$image_mk" ||
    fail "stock-looking AX9000 profile is still exposed"

  assert_ax9000_upgrade_blocked "$platform"
  if grep -Fq 'NAND_SUPPORT:ubi-utils' "$base_files_mk" "$fstools_mk"; then
    fail "RAM-only source still forces the ubi-utils package"
  fi

  validate_feed_policy "$SOURCE_DIR"

  for command in sysupgrade firstboot jffs2reset jffs2mark factoryreset mount_root; do
    prepared_guard="$SOURCE_DIR/files/sbin/$command"
    [[ -x "$prepared_guard" ]] || fail "prepared source lost RAM-only runtime guard: $command"
    cmp -s "$ROOT_DIR/files/sbin/$command" "$prepared_guard" ||
      fail "prepared source runtime guard differs from policy: $command"
  done

  nss_baseline="$SOURCE_DIR/files/etc/uci-defaults/20-nss-baseline"
  if [[ "$NEXAWRT_FLAVOR" == nss ]]; then
    [[ -f "$nss_baseline" ]] || fail "NSS runtime baseline overlay is missing"
    grep -Fq "network.globals.packet_steering='0'" "$nss_baseline" ||
      fail "NSS runtime baseline does not disable packet steering"
    grep -Fq "firewall.@defaults[0].flow_offloading='0'" "$nss_baseline" ||
      fail "NSS runtime baseline does not disable software flow offloading"
    grep -Fq "firewall.@defaults[0].flow_offloading_hw='0'" "$nss_baseline" ||
      fail "NSS runtime baseline does not disable hardware flow offloading"
  elif [[ -e "$nss_baseline" ]]; then
    fail "official flavor contains the NSS-only runtime overlay"
  fi

  if [[ -f "$SOURCE_DIR/.config" ]]; then
    assert_flavor_config "$SOURCE_DIR/.config" "$NEXAWRT_FLAVOR resolved config"
  fi
fi

if ((CHECK_ARTIFACTS)); then
  [[ -n "$SOURCE_DIR" ]] || fail "--artifacts requires --source"
  out="$SOURCE_DIR/bin/targets/qualcommax/ipq807x"
  expected_image='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi-initramfs-uImage.itb'
  expected_package_manifest='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.manifest'
  expected_sbom='openwrt-qualcommax-ipq807x-xiaomi_ax9000_single_ubi.bom.cdx.json'
  [[ -d "$out" ]] || fail "target output directory missing"
  [[ -f "$out/$expected_image" ]] || fail "exact initramfs RAM-boot image missing"
  for required in config.buildinfo feeds.buildinfo profiles.json version.buildinfo \
    "$expected_package_manifest" "$expected_sbom"; do
    [[ -f "$out/$required" ]] || fail "required build evidence is missing: $required"
  done
  python3 - "$out/$expected_sbom" <<'PY' || fail "CycloneDX SBOM is invalid"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
if document.get("bomFormat") != "CycloneDX":
    raise SystemExit("unexpected bomFormat")
components = document.get("components")
if not isinstance(components, list) or not components:
    raise SystemExit("components must be a non-empty list")
PY
  rootfs_dirs=("$SOURCE_DIR"/build_dir/target-*/root-qualcommax)
  ((${#rootfs_dirs[@]} == 1)) && [[ -d "${rootfs_dirs[0]}" ]] ||
    fail "expected exactly one final qualcommax rootfs staging directory"
  rootfs_dir="${rootfs_dirs[0]}"
  for command in sysupgrade firstboot jffs2reset jffs2mark factoryreset mount_root; do
    [[ -x "$rootfs_dir/sbin/$command" ]] || fail "final rootfs lost runtime guard: $command"
    cmp -s "$ROOT_DIR/files/sbin/$command" "$rootfs_dir/sbin/$command" ||
      fail "final rootfs runtime guard was overwritten: $command"
  done
  for command in mtd flash_erase flash_eraseall flashcp nandwrite nandtest ubiattach ubidetach ubiformat ubimkvol ubirmvol ubirsvol ubirename ubiupdatevol fw_setenv; do
    if find "$rootfs_dir" -type f -o -type l | grep -Eq "/${command//./\.}$"; then
      fail "final rootfs contains a persistent flash utility: $command"
    fi
  done
  while IFS= read -r -d '' candidate; do
    base="$(basename "$candidate")"
    lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *sysupgrade*|*factory*) fail "RAM-only output contains a persistent/installer artifact: $base" ;;
    esac
    case "$lower" in
      *.bin|*.img|*.itb|*.ubi|*.ubifs|*.squashfs|*.jffs2|*.ext4|*.trx|*.chk|*.iso|*.vmdk|*.vdi|*.qcow2|*.fit|*.uimage|*.elf|*.dtb|*.fdt|*.fw|*.firmware|*rootfs*.tar|*rootfs*.tar.gz|*rootfs*.tgz|*rootfs*.gz|*rootfs*.xz|*rootfs*.zst)
        [[ "$candidate" == "$out/$expected_image" ]] ||
          fail "RAM-only output contains a non-allowlisted image artifact: $candidate"
        ;;
    esac
  done < <(find "$out" -type f -print0)
fi

echo "validation ($NEXAWRT_FLAVOR): OK"
