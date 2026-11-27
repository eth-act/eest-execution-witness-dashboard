#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_list_el_clients_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_list_el_clients_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_list_el_clients_script_dir/env.sh"
# shellcheck source=scripts/lib/el-clients.sh
. "$_list_el_clients_script_dir/lib/el-clients.sh"

_list_el_clients_usage() {
  printf '%s\n' \
    'Usage: scripts/list-el-clients.sh [--json | --github-matrix | --ids]' \
    '' \
    'Resolve the selected EL client descriptors from EL_CLIENTS and' \
    'EL_CLIENT_OVERRIDES_JSON without preparing Hive.' \
    'Set EL_CLIENTS to none, skip, or empty to select no Hive clients.'
}

main() {
  local mode resolved

  mode=table
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        mode=json
        ;;
      --github-matrix)
        mode=github-matrix
        ;;
      --ids)
        mode=ids
        ;;
      --help | -h)
        _list_el_clients_usage
        exit 0
        ;;
      *)
        _list_el_clients_usage >&2
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done

  eest_require_cmd jq jq

  if eest_el_clients_selects_none; then
    case "$mode" in
      json) printf '%s\n' '[]' ;;
      github-matrix) printf '%s\n' '{"include":[]}' ;;
      ids | table) ;;
    esac
    return 0
  fi

  case "$mode" in
    json)
      eest_el_clients_resolve_descriptors
      ;;
    github-matrix)
      eest_el_clients_matrix_json
      ;;
    ids)
      eest_el_clients_selected_ids
      ;;
    table)
      resolved="$(eest_el_clients_resolve_descriptors)"
      jq -r '.[] | [.id, (.hive_client + (if (.nametag // "") != "" then "_" + .nametag else "" end)), .ref] | @tsv' <<< "$resolved"
      ;;
  esac
}

main "$@"
