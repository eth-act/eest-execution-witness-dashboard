#!/usr/bin/env bash

set -Eeuo pipefail

_build_site_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_build_site_script_dir="$(_build_site_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_build_site_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_build_site_script_dir/env.sh"

HIVEVIEW_LIST_LIMIT="${HIVEVIEW_LIST_LIMIT:-200}"

_build_site_usage() {
  printf '%s\n' \
    'Usage: scripts/build-site.sh' \
    '' \
    'Build a static Hiveview site from HIVE_RESULTS_DIR.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  HIVE_DIR, HIVE_RESULTS_DIR, SITE_DIR, SITE_MAX_SIZE_MB' \
    '' \
    'Additional overrides:' \
    '  HIVEVIEW_LIST_LIMIT        Number of test runs in listing.jsonl. Default: 200'
}

_build_site_log() {
  printf '==> %s\n' "$*"
}

_build_site_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_build_site_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _build_site_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_build_site_require_positive_int() {
  local name value

  name="$1"
  value="$2"

  case "$value" in
    '' | *[!0-9]*)
      _build_site_die "$name must be a positive integer: $value"
      ;;
    0)
      _build_site_die "$name must be greater than zero"
      ;;
  esac
}

_build_site_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _build_site_usage
        exit 0
        ;;
      *)
        _build_site_usage >&2
        _build_site_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_build_site_normalize_path() {
  local IFS part path result
  local -a parts stack

  path="$1"
  case "$path" in
    /*) ;;
    *) path="$ROOT_DIR/$path" ;;
  esac

  IFS='/'
  read -r -a parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    case "$part" in
      '' | .)
        ;;
      ..)
        if [ "${#stack[@]}" -eq 0 ]; then
          _build_site_die "path escapes filesystem root: $1"
        fi
        stack=("${stack[@]:0:$((${#stack[@]} - 1))}")
        ;;
      *)
        stack+=("$part")
        ;;
    esac
  done

  if [ "${#stack[@]}" -eq 0 ]; then
    printf '%s\n' /
    return
  fi

  result="/${stack[0]}"
  for part in "${stack[@]:1}"; do
    result="$result/$part"
  done
  printf '%s\n' "$result"
}

_build_site_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$EEST_DIR" | "$GETH_SRC_DIR" | "$FIXTURES_DIR" | "$HIVE_RESULTS_DIR")
      _build_site_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _build_site_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_build_site_validate_inputs() {
  local first_result

  _build_site_require_positive_int HIVEVIEW_LIST_LIMIT "$HIVEVIEW_LIST_LIMIT"
  _build_site_require_positive_int SITE_MAX_SIZE_MB "$SITE_MAX_SIZE_MB"

  ROOT_DIR="$(_build_site_normalize_path "$ROOT_DIR")"
  HIVE_DIR="$(_build_site_normalize_path "$HIVE_DIR")"
  EEST_DIR="$(_build_site_normalize_path "$EEST_DIR")"
  GETH_SRC_DIR="$(_build_site_normalize_path "$GETH_SRC_DIR")"
  FIXTURES_DIR="$(_build_site_normalize_path "$FIXTURES_DIR")"
  HIVE_RESULTS_DIR="$(_build_site_normalize_path "$HIVE_RESULTS_DIR")"
  SITE_DIR="$(_build_site_normalize_path "$SITE_DIR")"

  if [ ! -d "$HIVE_DIR/cmd/hiveview" ]; then
    _build_site_die "Hiveview command does not exist; run scripts/setup-hive.sh first: $HIVE_DIR/cmd/hiveview"
  fi

  if [ ! -d "$HIVE_RESULTS_DIR" ]; then
    _build_site_die "Hive results directory does not exist; run scripts/run-hive-consume.sh first: $HIVE_RESULTS_DIR"
  fi

  first_result="$(find "$HIVE_RESULTS_DIR" -type f -print -quit)"
  if [ -z "$first_result" ]; then
    _build_site_die "Hive results directory is empty: $HIVE_RESULTS_DIR"
  fi
}

_build_site_reset_site_dir() {
  _build_site_guard_clean_dir SITE_DIR "$SITE_DIR"
  _build_site_log "Resetting static site directory at $SITE_DIR"
  rm -rf "$SITE_DIR"
  mkdir -p "$SITE_DIR"
}

_build_site_run_hiveview_deploy() {
  _build_site_log "Generating Hiveview static assets"
  (
    cd "$HIVE_DIR"
    go run ./cmd/hiveview -deploy -logdir "$HIVE_RESULTS_DIR" "$SITE_DIR"
  )
}

_build_site_generate_listing() {
  _build_site_log "Generating listing.jsonl"
  (
    cd "$HIVE_DIR"
    go run ./cmd/hiveview -listing -limit "$HIVEVIEW_LIST_LIMIT" -logdir "$HIVE_RESULTS_DIR"
  ) > "$SITE_DIR/listing.jsonl"
}

_build_site_copy_results() {
  _build_site_log "Copying Hive results into static site"
  mkdir -p "$SITE_DIR/results"
  rsync -a --delete "$HIVE_RESULTS_DIR"/ "$SITE_DIR/results"/
}

_build_site_validate_output() {
  local first_copied_result first_listing_result max_size_kb site_size_kb site_size_mb

  if [ ! -s "$SITE_DIR/listing.jsonl" ]; then
    _build_site_die "listing.jsonl was not created or is empty: $SITE_DIR/listing.jsonl"
  fi

  if ! jq -e . "$SITE_DIR/listing.jsonl" >/dev/null; then
    _build_site_die "listing.jsonl is not valid JSON lines: $SITE_DIR/listing.jsonl"
  fi

  first_listing_result="$(jq -r 'select(.fileName != null) | .fileName' "$SITE_DIR/listing.jsonl" | sed -n '1p')"
  if [ -n "$first_listing_result" ] && [ ! -f "$SITE_DIR/results/$first_listing_result" ]; then
    _build_site_die "listing.jsonl references a result file that was not copied: results/$first_listing_result"
  fi

  first_copied_result="$(find "$SITE_DIR/results" -type f -print -quit)"
  if [ -z "$first_copied_result" ]; then
    _build_site_die "results directory was not populated: $SITE_DIR/results"
  fi

  site_size_kb="$(du -sk "$SITE_DIR" | awk '{print $1}')"
  max_size_kb=$((SITE_MAX_SIZE_MB * 1024))
  if [ "$site_size_kb" -gt "$max_size_kb" ]; then
    site_size_mb=$(((site_size_kb + 1023) / 1024))
    _build_site_die "generated site is ${site_size_mb}MB, above SITE_MAX_SIZE_MB=$SITE_MAX_SIZE_MB"
  fi

  _build_site_log "Static site build complete at $SITE_DIR"
}

main() {
  _build_site_parse_args "$@"
  _build_site_require_cmd go Go
  _build_site_require_cmd jq jq
  _build_site_require_cmd rsync rsync
  _build_site_validate_inputs
  _build_site_reset_site_dir
  _build_site_run_hiveview_deploy
  _build_site_generate_listing
  _build_site_copy_results
  _build_site_validate_output
}

main "$@"
