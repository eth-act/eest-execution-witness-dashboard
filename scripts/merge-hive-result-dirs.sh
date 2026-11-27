#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_merge_hive_result_dirs_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_merge_hive_result_dirs_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_merge_hive_result_dirs_script_dir/env.sh"

exec python3 "$_merge_hive_result_dirs_script_dir/merge-hive-result-dirs.py" "$@"
