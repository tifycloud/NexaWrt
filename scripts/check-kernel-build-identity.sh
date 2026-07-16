#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-}"
SOURCE_COMMIT="${2:-}"
DESCRIPTION="${3:-kernel config}"

fail() {
  echo "kernel build identity: $*" >&2
  exit 1
}

[[ -n "$CONFIG_FILE" && -n "$SOURCE_COMMIT" ]] || {
  echo "Usage: $0 CONFIG_FILE SOURCE_COMMIT [DESCRIPTION]" >&2
  exit 2
}
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] ||
  fail "$DESCRIPTION is missing or is not a regular file"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  fail "source lock commit is not a full lowercase 40-character SHA-1"

assert_exact_string() {
  local symbol="$1"
  local expected_value="$2"

  awk -v symbol="$symbol" -v expected_line="$symbol=\"$expected_value\"" '
    $0 == "# " symbol " is not set" || index($0, symbol "=") == 1 {
      seen++
      if ($0 == expected_line) exact++
    }
    END { exit !(seen == 1 && exact == 1) }
  ' "$CONFIG_FILE" ||
    fail "$DESCRIPTION must contain exactly $symbol=\"$expected_value\""
}

assert_exact_bool() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    $0 == "# " symbol " is not set" || index($0, symbol "=") == 1 {
      seen++
      if ($0 == symbol "=y") exact++
    }
    END { exit !(seen == 1 && exact == 1) }
  ' "$CONFIG_FILE" ||
    fail "$DESCRIPTION must contain exactly $symbol=y"
}

assert_exact_disabled_bool() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    $0 == "# " symbol " is not set" || index($0, symbol "=") == 1 {
      seen++
      if ($0 == "# " symbol " is not set") exact++
    }
    END { exit !(seen == 1 && exact == 1) }
  ' "$CONFIG_FILE" ||
    fail "$DESCRIPTION must contain exactly # $symbol is not set"
}

assert_exact_string CONFIG_KERNEL_BUILD_USER nexawrt
assert_exact_string CONFIG_KERNEL_BUILD_DOMAIN builder
assert_exact_bool CONFIG_IMAGEOPT
assert_exact_bool CONFIG_VERSIONOPT
assert_exact_string CONFIG_VERSION_CODE "nexawrt-r0-${SOURCE_COMMIT:0:8}"
assert_exact_disabled_bool CONFIG_VERSION_FILENAMES
assert_exact_disabled_bool CONFIG_VERSION_CODE_FILENAMES
