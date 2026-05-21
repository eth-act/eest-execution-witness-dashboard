#!/usr/bin/env bash

set -Eeuo pipefail

_validate_fixtures_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_validate_fixtures_script_dir="$(_validate_fixtures_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_validate_fixtures_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_validate_fixtures_script_dir/env.sh"

_validate_fixtures_format=blockchain_test_engine

_validate_fixtures_usage() {
  printf '%s\n' \
    'Usage: scripts/validate-fixtures.sh' \
    '' \
    'Validate that FIXTURES_DIR contains blockchain_test_engine fixtures.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  FIXTURES_DIR'
}

_validate_fixtures_log() {
  printf '==> %s\n' "$*"
}

_validate_fixtures_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_validate_fixtures_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _validate_fixtures_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_validate_fixtures_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _validate_fixtures_usage
        exit 0
        ;;
      *)
        _validate_fixtures_usage >&2
        _validate_fixtures_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_validate_fixtures_validate() {
  local engine_dir first_fixture index_path

  index_path="$FIXTURES_DIR/.meta/index.json"
  engine_dir="$FIXTURES_DIR/blockchain_tests_engine"

  _validate_fixtures_log "Validating fixture index"

  if [ ! -f "$index_path" ]; then
    _validate_fixtures_die "fixture index does not exist: $index_path"
  fi

  if ! jq -e --arg format "$_validate_fixtures_format" '
    .fixture_formats as $formats
    | if ($formats | type) == "array" then
        any($formats[]; . == $format)
      elif ($formats | type) == "object" then
        ($formats | has($format))
      else
        false
      end
  ' "$index_path" >/dev/null; then
    printf 'fixture_formats in %s:\n' "$index_path" >&2
    jq '.fixture_formats' "$index_path" >&2 || true
    _validate_fixtures_die "fixture index does not include $_validate_fixtures_format"
  fi

  if [ ! -d "$engine_dir" ]; then
    _validate_fixtures_die "engine fixture directory does not exist: $engine_dir"
  fi

  first_fixture="$(find "$engine_dir" -type f -print -quit)"
  if [ -z "$first_fixture" ]; then
    _validate_fixtures_die "engine fixture directory is empty: $engine_dir"
  fi

  _validate_fixtures_log "Fixture validation passed"
}

main() {
  _validate_fixtures_parse_args "$@"
  _validate_fixtures_require_cmd jq jq
  _validate_fixtures_validate
}

main "$@"
