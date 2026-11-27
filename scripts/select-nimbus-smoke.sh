#!/usr/bin/env bash

set -Eeuo pipefail

# Reads the paths a pull request changes, one per line, and prints true if one
# matches a pattern in config/nimbus-smoke-paths.txt, false otherwise:
#
#   git diff --name-only HEAD^1 HEAD | scripts/select-nimbus-smoke.sh

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_select_nimbus_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_select_nimbus_script_dir" ] || eest_die "unable to resolve scripts directory"
_select_nimbus_paths_file="$_select_nimbus_script_dir/../config/nimbus-smoke-paths.txt"

main() {
  local line path pattern nimbus
  local -a patterns=()

  while IFS= read -r line; do
    case "$line" in
      '' | '#'*) ;;
      *) patterns+=("$line") ;;
    esac
  done < "$_select_nimbus_paths_file"
  [ "${#patterns[@]}" -gt 0 ] || eest_die "no patterns in $_select_nimbus_paths_file"

  nimbus=false
  while IFS= read -r path; do
    for pattern in "${patterns[@]}"; do
      # The pattern is unquoted so that case matches it as a glob.
      case "$path" in
        $pattern)
          eest_log "Nimbus runs because $path changed" >&2
          nimbus=true
          break
          ;;
      esac
    done
  done
  printf '%s\n' "$nimbus"
}

main "$@"
