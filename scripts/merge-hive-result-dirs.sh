#!/usr/bin/env bash

set -Eeuo pipefail

_merge_hive_result_dirs_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_merge_hive_result_dirs_script_dir="$(_merge_hive_result_dirs_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_merge_hive_result_dirs_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_merge_hive_result_dirs_script_dir/env.sh"

exec python3 "$_merge_hive_result_dirs_script_dir/merge-hive-result-dirs.py" "$@"
