#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-vm-image.sh"

fail_test() {
  printf 'VM manifest selection test failed: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../scripts/build-vm-image.sh
source "$BUILD_SCRIPT"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

version="25.12.5"
image_basename="openwrt-${version}-x86-64-generic-ext4-combined.img.gz"
manifest_basename="openwrt-${version}-x86-64.manifest"
image_derived_manifest="${image_basename%.img.gz}.manifest"
release_manifest_basename="NexaWrt-x86_64-v0.1.0-rc.1-generic-ext4-combined.manifest"

positive_dir="$tmp_dir/positive/bin/targets/x86/64"
mkdir -p "$positive_dir"
printf 'fake image bytes\n' > "$positive_dir/$image_basename"
printf 'base-files - 1\nluci - 1\n' > "$positive_dir/$manifest_basename"
selected="$(select_x86_64_release_manifest "$positive_dir" "$version" "$image_basename")"
[[ "$selected" == "$positive_dir/$manifest_basename" ]] ||
  fail_test "selector did not return the target-level manifest"
[[ "${selected##*/}" != "$image_derived_manifest" ]] ||
  fail_test "selector accepted an image-specific manifest name"
cp "$selected" "$tmp_dir/$release_manifest_basename"
cmp -s "$positive_dir/$manifest_basename" "$tmp_dir/$release_manifest_basename" ||
  fail_test "selected target manifest was not copied under the NexaWrt release name"

zero_dir="$tmp_dir/zero/bin/targets/x86/64"
mkdir -p "$zero_dir"
printf 'fake image bytes\n' > "$zero_dir/$image_basename"
if (select_x86_64_release_manifest "$zero_dir" "$version" "$image_basename" >/dev/null 2>&1); then
  fail_test "selector accepted a target directory with zero manifests"
fi

multiple_dir="$tmp_dir/multiple/bin/targets/x86/64"
mkdir -p "$multiple_dir"
printf 'fake image bytes\n' > "$multiple_dir/$image_basename"
printf 'expected\n' > "$multiple_dir/$manifest_basename"
printf 'unexpected\n' > "$multiple_dir/openwrt-${version}-x86-64-extra.manifest"
if (select_x86_64_release_manifest "$multiple_dir" "$version" "$image_basename" >/dev/null 2>&1); then
  fail_test "selector accepted multiple target manifests"
fi

manifest_plus_symlink_dir="$tmp_dir/manifest-plus-symlink/bin/targets/x86/64"
mkdir -p "$manifest_plus_symlink_dir"
printf 'expected\n' > "$manifest_plus_symlink_dir/$manifest_basename"
ln -s "$manifest_basename" \
  "$manifest_plus_symlink_dir/openwrt-${version}-x86-64-shadow.manifest"
if (select_x86_64_release_manifest "$manifest_plus_symlink_dir" "$version" "$image_basename" >/dev/null 2>&1); then
  fail_test "selector ignored an additional symlink manifest directory entry"
fi

unique_symlink_dir="$tmp_dir/unique-symlink/bin/targets/x86/64"
mkdir -p "$unique_symlink_dir"
printf 'symlink target\n' > "$tmp_dir/manifest-target"
ln -s "$tmp_dir/manifest-target" "$unique_symlink_dir/$manifest_basename"
if (select_x86_64_release_manifest "$unique_symlink_dir" "$version" "$image_basename" >/dev/null 2>&1); then
  fail_test "selector accepted a unique symlink manifest"
fi

abnormal_dir="$tmp_dir/abnormal/bin/targets/x86/64"
mkdir -p "$abnormal_dir"
printf 'fake image bytes\n' > "$abnormal_dir/$image_basename"
printf 'image-specific\n' > "$abnormal_dir/$image_derived_manifest"
if (select_x86_64_release_manifest "$abnormal_dir" "$version" "$image_basename" >/dev/null 2>&1); then
  fail_test "selector accepted an image-specific manifest instead of the official target manifest"
fi

printf 'VM manifest selection tests passed.\n'
