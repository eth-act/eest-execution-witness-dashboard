#!/usr/bin/env bash

set -Eeuo pipefail

_list_el_clients_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_list_el_clients_script_dir="$(_list_el_clients_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_list_el_clients_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

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

_list_el_clients_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_list_el_clients_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _list_el_clients_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

main() {
  local mode normalized resolved

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
        _list_el_clients_die "unknown argument: $1"
        ;;
    esac
    shift
  done

  _list_el_clients_require_cmd jq jq

  normalized="$(printf '%s' "$EL_CLIENTS" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$normalized" in
    none | skip | empty)
      case "$mode" in
        json) printf '%s\n' '[]' ;;
        github-matrix) printf '%s\n' '{"include":[]}' ;;
        ids | table) ;;
      esac
      return 0
      ;;
  esac

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
