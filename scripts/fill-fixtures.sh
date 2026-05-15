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

_fill_fixtures_format=blockchain_test_engine

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

_fill_fixtures_prepare_execution_specs() {
  _fill_fixtures_log "Preparing execution-specs checkout at $EEST_DIR"

  if [ -d "$EEST_DIR" ]; then
    if ! git -C "$EEST_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _fill_fixtures_die "EEST_DIR exists but is not a git checkout: $EEST_DIR"
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

_fill_fixtures_sync_execution_specs() {
  _fill_fixtures_log "Running uv sync"
  (cd "$EEST_DIR" && uv sync)
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

_fill_fixtures_validate() {
  local engine_dir first_fixture index_path

  index_path="$FIXTURES_DIR/.meta/index.json"
  engine_dir="$FIXTURES_DIR/blockchain_tests_engine"

  _fill_fixtures_log "Validating fixture index"

  if [ ! -f "$index_path" ]; then
    _fill_fixtures_die "fixture index was not created: $index_path"
  fi

  if ! jq -e --arg format "$_fill_fixtures_format" '
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
    _fill_fixtures_die "fixture index does not include $_fill_fixtures_format"
  fi

  if [ ! -d "$engine_dir" ]; then
    _fill_fixtures_die "engine fixture directory was not created: $engine_dir"
  fi

  first_fixture="$(find "$engine_dir" -type f -print -quit)"
  if [ -z "$first_fixture" ]; then
    _fill_fixtures_die "engine fixture directory is empty: $engine_dir"
  fi

  _fill_fixtures_log "Fixture validation passed"
}

main() {
  _fill_fixtures_parse_args "$@"
  _fill_fixtures_require_cmd git Git
  _fill_fixtures_require_cmd uv uv
  _fill_fixtures_require_cmd jq jq

  _fill_fixtures_prepare_execution_specs
  _fill_fixtures_sync_execution_specs
  _fill_fixtures_generate
  _fill_fixtures_validate
}

main "$@"
