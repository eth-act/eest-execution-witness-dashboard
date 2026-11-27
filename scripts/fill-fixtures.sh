#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_fill_fixtures_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_fill_fixtures_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_fill_fixtures_script_dir/env.sh"

FILL_TEST_NAME="${FILL_TEST_NAME-auto}"
UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
export UV_CACHE_DIR

_fill_fixtures_format='blockchain_test_engine'

_fill_fixtures_usage() {
  printf '%s\n' \
    'Usage: scripts/fill-fixtures.sh' \
    '' \
    'Clone or update execution-specs, install Python dependencies with uv,' \
    'generate execution witness fixtures into FIXTURES_DIR, and validate' \
    'that the fixture index includes blockchain_test_engine.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_REPO, EEST_REF, EEST_DIR, FILLER_PATH, FORK, FIXTURES_DIR' \
    '' \
    'Additional overrides:' \
    '  FILL_TEST_NAME             Optional pytest-xdist worker value. Default: auto' \
    '  UV_CACHE_DIR               uv cache directory. Default: /tmp/uv-cache'
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
        eest_die "unknown argument: $1"
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

  eest_log "Generating fixtures in $FIXTURES_DIR"
  (cd "$EEST_DIR" && uv "${fill_args[@]}")
}

_fill_fixtures_validate_source() {
  eest_dashboard_validate_eest_source

  if [ "$(eest_dashboard_eest_source_mode)" != fill ]; then
    eest_die 'EEST_RELEASE_TAG is set; use scripts/prepare-fixtures.sh for release-mode fixture downloads'
  fi
}

main() {
  _fill_fixtures_parse_args "$@"
  eest_require_cmd uv uv
  eest_require_cmd jq jq
  _fill_fixtures_validate_source

  "$_fill_fixtures_script_dir/setup-eest.sh"
  _fill_fixtures_generate
  "$_fill_fixtures_script_dir/validate-fixtures.sh"
}

main "$@"
