#!/usr/bin/env bash

set -Eeuo pipefail

_setup_zkevm_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_setup_zkevm_script_dir="$(_setup_zkevm_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_setup_zkevm_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_setup_zkevm_script_dir/env.sh"

_setup_zkevm_usage() {
  printf '%s\n' \
    'Usage: scripts/setup-zkevm-benchmark-workload.sh' \
    '' \
    'Clone or update zkevm-benchmark-workload and check out the configured ref.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  ZKEVM_BENCHMARK_WORKLOAD_REPO, ZKEVM_BENCHMARK_WORKLOAD_REF, ZKEVM_BENCHMARK_WORKLOAD_DIR'
}

_setup_zkevm_log() {
  printf '==> %s\n' "$*"
}

_setup_zkevm_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_setup_zkevm_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _setup_zkevm_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_setup_zkevm_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _setup_zkevm_usage
        exit 0
        ;;
      *)
        _setup_zkevm_usage >&2
        _setup_zkevm_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_setup_zkevm_validate() {
  if [ -z "$ZKEVM_BENCHMARK_WORKLOAD_REPO" ]; then
    _setup_zkevm_die "ZKEVM_BENCHMARK_WORKLOAD_REPO must be set"
  fi
  if [ -z "$ZKEVM_BENCHMARK_WORKLOAD_REF" ]; then
    _setup_zkevm_die "ZKEVM_BENCHMARK_WORKLOAD_REF must be set"
  fi
}

_setup_zkevm_prepare_checkout() {
  _setup_zkevm_log "Preparing zkevm-benchmark-workload checkout at $ZKEVM_BENCHMARK_WORKLOAD_DIR"
  _setup_zkevm_log "Using $ZKEVM_BENCHMARK_WORKLOAD_REPO at $ZKEVM_BENCHMARK_WORKLOAD_REF"

  if [ -d "$ZKEVM_BENCHMARK_WORKLOAD_DIR" ]; then
    if ! git -C "$ZKEVM_BENCHMARK_WORKLOAD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _setup_zkevm_die "ZKEVM_BENCHMARK_WORKLOAD_DIR exists but is not a git checkout: $ZKEVM_BENCHMARK_WORKLOAD_DIR"
    fi

    if git -C "$ZKEVM_BENCHMARK_WORKLOAD_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$ZKEVM_BENCHMARK_WORKLOAD_DIR" remote set-url origin "$ZKEVM_BENCHMARK_WORKLOAD_REPO"
    else
      git -C "$ZKEVM_BENCHMARK_WORKLOAD_DIR" remote add origin "$ZKEVM_BENCHMARK_WORKLOAD_REPO"
    fi
  else
    mkdir -p "$(dirname "$ZKEVM_BENCHMARK_WORKLOAD_DIR")"
    git clone "$ZKEVM_BENCHMARK_WORKLOAD_REPO" "$ZKEVM_BENCHMARK_WORKLOAD_DIR"
  fi

  git -C "$ZKEVM_BENCHMARK_WORKLOAD_DIR" fetch --prune origin "$ZKEVM_BENCHMARK_WORKLOAD_REF"
  git -C "$ZKEVM_BENCHMARK_WORKLOAD_DIR" checkout --detach FETCH_HEAD
}

main() {
  _setup_zkevm_parse_args "$@"
  _setup_zkevm_require_cmd git Git
  _setup_zkevm_validate
  _setup_zkevm_prepare_checkout
}

main "$@"
