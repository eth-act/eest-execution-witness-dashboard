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

_validate_fixtures_formats=(blockchain_test blockchain_test_engine)

_validate_fixtures_usage() {
  printf '%s\n' \
    'Usage: scripts/validate-fixtures.sh' \
    '' \
    'Validate that FIXTURES_DIR contains blockchain_test and blockchain_test_engine fixtures.' \
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

_validate_fixtures_dir_for_format() {
  case "$1" in
    blockchain_test)
      printf '%s\n' "$FIXTURES_DIR/blockchain_tests"
      ;;
    blockchain_test_engine)
      printf '%s\n' "$FIXTURES_DIR/blockchain_tests_engine"
      ;;
    *)
      _validate_fixtures_die "unsupported fixture format validation: $1"
      ;;
  esac
}

_validate_fixtures_index_has_format() {
  local format index_path

  index_path="$1"
  format="$2"

  jq -e --arg format "$format" '
    .fixture_formats as $formats
    | if ($formats | type) == "array" then
        any($formats[]; . == $format)
      elif ($formats | type) == "object" then
        ($formats | has($format))
      else
        false
      end
  ' "$index_path" >/dev/null
}

_validate_fixtures_validate_format() {
  local first_fixture fixture_dir format index_path

  index_path="$1"
  format="$2"
  fixture_dir="$(_validate_fixtures_dir_for_format "$format")"

  if ! _validate_fixtures_index_has_format "$index_path" "$format"; then
    printf 'fixture_formats in %s:\n' "$index_path" >&2
    jq '.fixture_formats' "$index_path" >&2 || true
    _validate_fixtures_die "fixture index does not include $format"
  fi

  if [ ! -d "$fixture_dir" ]; then
    _validate_fixtures_die "$format fixture directory does not exist: $fixture_dir"
  fi

  first_fixture="$(find "$fixture_dir" -type f -print -quit)"
  if [ -z "$first_fixture" ]; then
    _validate_fixtures_die "$format fixture directory is empty: $fixture_dir"
  fi
}

_validate_fixtures_validate() {
  local format index_path

  index_path="$FIXTURES_DIR/.meta/index.json"

  _validate_fixtures_log "Validating fixture index"

  if [ ! -f "$index_path" ]; then
    _validate_fixtures_die "fixture index does not exist: $index_path"
  fi

  for format in "${_validate_fixtures_formats[@]}"; do
    _validate_fixtures_validate_format "$index_path" "$format"
  done

  _validate_fixtures_log "Fixture validation passed"
}

main() {
  _validate_fixtures_parse_args "$@"
  _validate_fixtures_require_cmd jq jq
  _validate_fixtures_validate
}

main "$@"
