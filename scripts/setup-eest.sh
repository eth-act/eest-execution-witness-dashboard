#!/usr/bin/env bash

set -Eeuo pipefail

_setup_eest_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_setup_eest_script_dir="$(_setup_eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_setup_eest_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_setup_eest_script_dir/env.sh"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
export UV_CACHE_DIR

_setup_eest_usage() {
  printf '%s\n' \
    'Usage: scripts/setup-eest.sh' \
    '' \
    'Clone or update execution-specs at EEST_REF and run uv sync.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_REPO, EEST_REF, EEST_DIR'
}

_setup_eest_log() {
  printf '==> %s\n' "$*"
}

_setup_eest_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_setup_eest_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _setup_eest_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_setup_eest_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _setup_eest_usage
        exit 0
        ;;
      *)
        _setup_eest_usage >&2
        _setup_eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_setup_eest_prepare_execution_specs() {
  _setup_eest_log "Preparing execution-specs checkout at $EEST_DIR"

  if [ -d "$EEST_DIR" ]; then
    if ! git -C "$EEST_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _setup_eest_die "EEST_DIR exists but is not a git checkout: $EEST_DIR"
    fi

    if git -C "$EEST_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$EEST_DIR" remote set-url origin "$EEST_REPO"
    else
      git -C "$EEST_DIR" remote add origin "$EEST_REPO"
    fi
  else
    mkdir -p "$(dirname "$EEST_DIR")"
    git clone "$EEST_REPO" "$EEST_DIR"
  fi

  git -C "$EEST_DIR" fetch --prune origin "$EEST_REF"
  git -C "$EEST_DIR" checkout --detach FETCH_HEAD
}

_setup_eest_sync_execution_specs() {
  _setup_eest_log "Running uv sync"
  (cd "$EEST_DIR" && uv sync)
}

main() {
  _setup_eest_parse_args "$@"
  _setup_eest_require_cmd git Git
  _setup_eest_require_cmd uv uv
  _setup_eest_prepare_execution_specs
  _setup_eest_sync_execution_specs
}

main "$@"
