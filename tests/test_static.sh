#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/validate.sh" "$@"
"$ROOT_DIR/tests/test_backup_guards.sh"
"$ROOT_DIR/tests/test_release_policy.sh"
