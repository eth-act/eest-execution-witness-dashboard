#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_setup_eest_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_setup_eest_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_setup_eest_script_dir/env.sh"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
export UV_CACHE_DIR

_setup_eest_usage() {
  printf '%s\n' \
    'Usage: scripts/setup-eest.sh' \
    '' \
    'Clone or update execution-specs and run uv sync.' \
    'In fill mode, checkout EEST_REPO at EEST_REF.' \
    'In release mode, checkout ethereum/execution-specs at EEST_RELEASE_TAG.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_REPO, EEST_REF, EEST_RELEASE_TAG, EEST_DIR'
}

_setup_eest_checkout_repo=""
_setup_eest_checkout_ref=""

_setup_eest_resolve_checkout() {
  eest_dashboard_validate_eest_source

  case "$(eest_dashboard_eest_source_mode)" in
    release)
      _setup_eest_checkout_repo="https://github.com/ethereum/execution-specs.git"
      _setup_eest_checkout_ref="$EEST_RELEASE_TAG"
      ;;
    fill)
      _setup_eest_checkout_repo="$EEST_REPO"
      _setup_eest_checkout_ref="$EEST_REF"
      ;;
    *)
      eest_die "unsupported EEST source mode: $(eest_dashboard_eest_source_mode)"
      ;;
  esac
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
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_setup_eest_prepare_execution_specs() {
  eest_prepare_git_checkout execution-specs \
    "$_setup_eest_checkout_repo" "$_setup_eest_checkout_ref" "$EEST_DIR"
}

_setup_eest_sync_execution_specs() {
  eest_log "Running uv sync"
  (cd "$EEST_DIR" && uv sync)
}

main() {
  _setup_eest_parse_args "$@"
  eest_require_cmd git Git
  eest_require_cmd uv uv
  _setup_eest_resolve_checkout
  _setup_eest_prepare_execution_specs
  _setup_eest_sync_execution_specs
}

main "$@"
