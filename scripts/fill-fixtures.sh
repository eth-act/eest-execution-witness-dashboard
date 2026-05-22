#!/usr/bin/env bash

set -Eeuo pipefail

_fill_fixtures_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_fill_fixtures_script_dir="$(_fill_fixtures_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_fill_fixtures_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_fill_fixtures_script_dir/env.sh"

FILL_TEST_NAME="${FILL_TEST_NAME-auto}"
UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
export UV_CACHE_DIR

_fill_fixtures_format='blockchain_test or blockchain_test_engine'

_fill_fixtures_usage() {
  printf '%s\n' \
    'Usage: scripts/fill-fixtures.sh' \
    '' \
    'Clone or update execution-specs, install Python dependencies with uv,' \
    'generate execution witness fixtures into FIXTURES_DIR, and validate' \
    'that the fixture index includes blockchain_test and blockchain_test_engine.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_REPO, EEST_REF, EEST_DIR, FILLER_PATH, FORK, FIXTURES_DIR' \
    '' \
    'Additional overrides:' \
    '  FILL_TEST_NAME             Optional pytest-xdist worker value. Default: auto' \
    '  UV_CACHE_DIR               uv cache directory. Default: /tmp/uv-cache'
}

_fill_fixtures_log() {
  printf '==> %s\n' "$*"
}

_fill_fixtures_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_fill_fixtures_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _fill_fixtures_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_fill_fixtures_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _fill_fixtures_usage
        exit 0
        ;;
      *)
        _fill_fixtures_usage >&2
        _fill_fixtures_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_fill_fixtures_generate() {
  local -a fill_args

  fill_args=(run fill --clean --output "$FIXTURES_DIR" --fork "$FORK")
  fill_args+=(-m "$_fill_fixtures_format" "$FILLER_PATH")

  if [ -n "$FILL_TEST_NAME" ]; then
    fill_args+=(-n "$FILL_TEST_NAME")
  fi

  _fill_fixtures_log "Generating fixtures in $FIXTURES_DIR"
  (cd "$EEST_DIR" && uv "${fill_args[@]}")
}

_fill_fixtures_validate_source() {
  eest_dashboard_validate_eest_source

  if [ "$(eest_dashboard_eest_source_mode)" != fill ]; then
    _fill_fixtures_die 'EEST_RELEASE_TAG is set; use scripts/prepare-fixtures.sh for release-mode fixture downloads'
  fi
}

main() {
  _fill_fixtures_parse_args "$@"
  _fill_fixtures_require_cmd uv uv
  _fill_fixtures_require_cmd jq jq
  _fill_fixtures_validate_source

  "$_fill_fixtures_script_dir/setup-eest.sh"
  _fill_fixtures_generate
  "$_fill_fixtures_script_dir/validate-fixtures.sh"
}

main "$@"
