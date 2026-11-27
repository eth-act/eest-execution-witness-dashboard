#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_validate_fixtures_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_validate_fixtures_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_validate_fixtures_script_dir/env.sh"

_validate_fixtures_formats=(blockchain_test_engine)

_validate_fixtures_usage() {
  printf '%s\n' \
    'Usage: scripts/validate-fixtures.sh' \
    '' \
    'Validate that FIXTURES_DIR contains blockchain_test_engine fixtures.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  FIXTURES_DIR'
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
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_validate_fixtures_dir_for_format() {
  case "$1" in
    blockchain_test_engine)
      printf '%s\n' "$FIXTURES_DIR/blockchain_tests_engine"
      ;;
    *)
      eest_die "unsupported fixture format validation: $1"
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
    eest_die "fixture index does not include $format"
  fi

  if [ ! -d "$fixture_dir" ]; then
    eest_die "$format fixture directory does not exist: $fixture_dir"
  fi

  first_fixture="$(find "$fixture_dir" -type f -print -quit)"
  if [ -z "$first_fixture" ]; then
    eest_die "$format fixture directory is empty: $fixture_dir"
  fi
}

_validate_fixtures_validate() {
  local format index_path

  index_path="$FIXTURES_DIR/.meta/index.json"

  eest_log "Validating fixture index"

  if [ ! -f "$index_path" ]; then
    eest_die "fixture index does not exist: $index_path"
  fi

  for format in "${_validate_fixtures_formats[@]}"; do
    _validate_fixtures_validate_format "$index_path" "$format"
  done

  eest_log "Fixture validation passed"
}

main() {
  _validate_fixtures_parse_args "$@"
  eest_require_cmd jq jq
  _validate_fixtures_validate
}

main "$@"
