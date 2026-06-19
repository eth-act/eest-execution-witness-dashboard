#!/usr/bin/env bash

set -Eeuo pipefail

_list_zkevm_metrics_roots_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_list_zkevm_metrics_roots_script_dir="$(_list_zkevm_metrics_roots_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_list_zkevm_metrics_roots_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_list_zkevm_metrics_roots_script_dir/env.sh"

_list_zkevm_metrics_roots_default_input="${ZKEVM_METRICS_ARTIFACTS_DIR:-}"
_list_zkevm_metrics_roots_input=""
_list_zkevm_metrics_roots_null=0

_list_zkevm_metrics_roots_usage() {
  printf '%s\n' \
    'Usage: scripts/list-zkevm-metrics-roots.sh [--null] [METRICS_ARTIFACTS_DIR]' \
    '' \
    'Discover downloaded zkevm-benchmark-workload metrics roots.' \
    '' \
    'The script supports both artifact-wrapper and flattened download layouts:' \
    '  METRICS_ARTIFACTS_DIR/<artifact>/<execution-client>/<zkvm>/*.json' \
    '  METRICS_ARTIFACTS_DIR/<execution-client>/<zkvm>/*.json' \
    '' \
    'Options:' \
    '  --null       Emit NUL-delimited paths for safe shell consumption.' \
    '  --help, -h   Show this help.'
}

_list_zkevm_metrics_roots_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_list_zkevm_metrics_roots_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --null)
        _list_zkevm_metrics_roots_null=1
        shift
        ;;
      --help | -h)
        _list_zkevm_metrics_roots_usage
        exit 0
        ;;
      -*)
        _list_zkevm_metrics_roots_usage >&2
        _list_zkevm_metrics_roots_die "unknown argument: $1"
        ;;
      *)
        if [ -n "$_list_zkevm_metrics_roots_input" ]; then
          _list_zkevm_metrics_roots_usage >&2
          _list_zkevm_metrics_roots_die "expected at most one METRICS_ARTIFACTS_DIR"
        fi
        _list_zkevm_metrics_roots_input="$1"
        shift
        ;;
    esac
  done

  if [ -z "$_list_zkevm_metrics_roots_input" ]; then
    _list_zkevm_metrics_roots_input="$_list_zkevm_metrics_roots_default_input"
  fi

  if [ -z "$_list_zkevm_metrics_roots_input" ]; then
    _list_zkevm_metrics_roots_usage >&2
    _list_zkevm_metrics_roots_die "METRICS_ARTIFACTS_DIR is required"
  fi
}

_list_zkevm_metrics_roots_has_metrics_root() {
  local candidate first_metric

  candidate="$1"
  first_metric="$(
    find "$candidate" \
      -mindepth 3 \
      -maxdepth 3 \
      -type f \
      -name '*.json' \
      ! -name hardware.json \
      -print \
      -quit
  )"

  [ -n "$first_metric" ]
}

_list_zkevm_metrics_roots_emit() {
  if [ "$_list_zkevm_metrics_roots_null" -eq 1 ]; then
    printf '%s\0' "$1"
  else
    printf '%s\n' "$1"
  fi
}

_list_zkevm_metrics_roots_main() {
  local candidate input

  _list_zkevm_metrics_roots_parse_args "$@"
  input="$(_list_zkevm_metrics_roots_abs_dir "$_list_zkevm_metrics_roots_input")"
  if [ -z "$input" ]; then
    _list_zkevm_metrics_roots_die "metrics artifacts directory does not exist: $_list_zkevm_metrics_roots_input"
  fi

  if _list_zkevm_metrics_roots_has_metrics_root "$input"; then
    _list_zkevm_metrics_roots_emit "$input"
    return
  fi

  while IFS= read -r -d '' candidate; do
    if _list_zkevm_metrics_roots_has_metrics_root "$candidate"; then
      _list_zkevm_metrics_roots_emit "$candidate"
    fi
  done < <(find "$input" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

_list_zkevm_metrics_roots_main "$@"
