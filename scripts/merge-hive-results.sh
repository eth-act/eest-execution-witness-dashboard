#!/usr/bin/env bash

set -Eeuo pipefail

_merge_hive_results_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_merge_hive_results_script_dir="$(_merge_hive_results_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_merge_hive_results_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_merge_hive_results_script_dir/env.sh"
# shellcheck source=scripts/lib/el-clients.sh
. "$_merge_hive_results_script_dir/lib/el-clients.sh"

HIVE_RESULTS_SOURCE_DIR="${HIVE_RESULTS_SOURCE_DIR:-$HIVE_CLIENT_RESULTS_DIR}"
_merge_hive_results_sources=()

_merge_hive_results_usage() {
  printf '%s\n' \
    'Usage: scripts/merge-hive-results.sh [--source DIR]...' \
    '' \
    'Validate and merge selected per-client Hive results plus optional' \
    'additional Hive-shaped result directories into HIVE_RESULTS_DIR.' \
    '' \
    'Options:' \
    '  --source DIR    Add an already-Hive-shaped source directory. May be repeated.' \
    '  --help, -h      Show this help.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EL_CLIENTS, EL_CLIENT_CONFIG, EL_CLIENT_OVERRIDES_JSON' \
    '  HIVE_CLIENT_RESULTS_DIR, HIVE_RESULTS_DIR' \
    '' \
    'Additional overrides:' \
    '  HIVE_RESULTS_SOURCE_DIR     Root containing CLIENT_ID/ or hive-results-CLIENT_ID/ directories.'
}

_merge_hive_results_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_merge_hive_results_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    _merge_hive_results_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_merge_hive_results_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        if [ "$#" -lt 2 ]; then
          _merge_hive_results_die "--source requires a directory"
        fi
        _merge_hive_results_sources+=("$2")
        shift 2
        ;;
      --help | -h)
        _merge_hive_results_usage
        exit 0
        ;;
      *)
        _merge_hive_results_usage >&2
        _merge_hive_results_die "unknown argument: $1"
        ;;
    esac
  done
}

_merge_hive_results_source_dir_for() {
  local artifact id source_root

  source_root="$1"
  id="$2"
  artifact="$(eest_el_clients_artifact_name "$id")"
  if [ -d "$source_root/$id" ]; then
    printf '%s\n' "$source_root/$id"
    return
  fi
  if [ -d "$source_root/$artifact" ]; then
    printf '%s\n' "$source_root/$artifact"
    return
  fi
  return 1
}

main() {
  local client_dir descriptor full_name id resolved source source_root
  local -a merge_args

  _merge_hive_results_parse_args "$@"
  _merge_hive_results_require_cmd jq jq
  _merge_hive_results_require_cmd python3 Python

  source_root="$HIVE_RESULTS_SOURCE_DIR"
  case "$source_root" in
    /*) ;;
    *) source_root="$ROOT_DIR/$source_root" ;;
  esac

  case "$(printf '%s' "$EL_CLIENTS" | tr '[:upper:]' '[:lower:]')" in
    none | skip | empty)
      resolved='[]'
      ;;
    *)
      if ! resolved="$(eest_el_clients_resolve_descriptors)"; then
        _merge_hive_results_die "failed to resolve EL client descriptors"
      fi
      ;;
  esac

  merge_args=(--output "$HIVE_RESULTS_DIR" --clean-output)
  while IFS= read -r descriptor; do
    id="$(eest_el_clients_descriptor_field "$descriptor" '.id')"
    full_name="$(eest_el_clients_full_client_name "$descriptor")"
    if ! client_dir="$(_merge_hive_results_source_dir_for "$source_root" "$id")"; then
      _merge_hive_results_die "missing isolated result directory for $id under $source_root"
    fi
    merge_args+=(--client-source "$id" "$full_name" "$client_dir")
  done < <(jq -c '.[]' <<< "$resolved")

  for source in "${_merge_hive_results_sources[@]}"; do
    merge_args+=("$source")
  done

  python3 "$_merge_hive_results_script_dir/merge-hive-result-dirs.py" "${merge_args[@]}"
}

main "$@"
