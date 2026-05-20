#!/usr/bin/env bash

set -Eeuo pipefail

_merge_hive_result_dirs_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_merge_hive_result_dirs_script_dir="$(_merge_hive_result_dirs_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_merge_hive_result_dirs_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_merge_hive_result_dirs_script_dir/env.sh"

_merge_hive_result_dirs_output="$HIVE_RESULTS_DIR"
_merge_hive_result_dirs_clean=0
_merge_hive_result_dirs_require_single_client=1
_merge_hive_result_dirs_sources=()

_merge_hive_result_dirs_usage() {
  printf '%s\n' \
    'Usage: scripts/merge-hive-result-dirs.sh [options] SOURCE_DIR...' \
    '' \
    'Merge already-Hive-shaped result directories into one output directory.' \
    '' \
    'Each SOURCE_DIR must contain at least one top-level Hive suite JSON and may' \
    'contain referenced logs, details/, and client log subdirectories.' \
    '' \
    'Options:' \
    '  --output DIR            Output directory. Default: HIVE_RESULTS_DIR from scripts/env.sh.' \
    '  --clean-output          Delete and recreate the output directory before merging.' \
    '  --allow-multi-client    Do not enforce one client per top-level result JSON.' \
    '  --help, -h              Show this help.' \
    '' \
    'The merge refuses to overwrite conflicting files. Identical duplicate files' \
    'are accepted.'
}

_merge_hive_result_dirs_log() {
  printf '==> %s\n' "$*"
}

_merge_hive_result_dirs_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_merge_hive_result_dirs_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _merge_hive_result_dirs_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_merge_hive_result_dirs_normalize_path() {
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
          _merge_hive_result_dirs_die "path escapes filesystem root: $1"
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

_merge_hive_result_dirs_path_contains() {
  local child parent

  parent="${1%/}"
  child="${2%/}"

  case "$child" in
    "$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_merge_hive_result_dirs_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$HIVE_UI_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$SITE_DIR")
      _merge_hive_result_dirs_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _merge_hive_result_dirs_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_merge_hive_result_dirs_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output)
        if [ "$#" -lt 2 ]; then
          _merge_hive_result_dirs_die "--output requires a directory"
        fi
        _merge_hive_result_dirs_output="$2"
        shift 2
        ;;
      --clean-output)
        _merge_hive_result_dirs_clean=1
        shift
        ;;
      --allow-multi-client)
        _merge_hive_result_dirs_require_single_client=0
        shift
        ;;
      --help | -h)
        _merge_hive_result_dirs_usage
        exit 0
        ;;
      -*)
        _merge_hive_result_dirs_usage >&2
        _merge_hive_result_dirs_die "unknown argument: $1"
        ;;
      *)
        _merge_hive_result_dirs_sources+=("$1")
        shift
        ;;
    esac
  done

  if [ "${#_merge_hive_result_dirs_sources[@]}" -eq 0 ]; then
    _merge_hive_result_dirs_usage >&2
    _merge_hive_result_dirs_die "at least one SOURCE_DIR is required"
  fi
}

_merge_hive_result_dirs_first_suite_json() {
  find "$1" -maxdepth 1 -type f -name '*.json' \
    ! -name 'hive.json' \
    ! -name 'errorReport.json' \
    ! -name 'containerErrorReport.json' \
    ! -name '.*' \
    -print -quit
}

_merge_hive_result_dirs_validate_source() {
  local invalid_json source source_json

  source="$1"
  if [ ! -d "$source" ]; then
    _merge_hive_result_dirs_die "source directory does not exist: $source"
  fi

  if [ -z "$(_merge_hive_result_dirs_first_suite_json "$source")" ]; then
    _merge_hive_result_dirs_die "source has no top-level Hive suite JSON: $source"
  fi

  invalid_json="$(
    find "$source" -maxdepth 1 -type f -name '*.json' \
      ! -name 'hive.json' \
      ! -name 'errorReport.json' \
      ! -name 'containerErrorReport.json' \
      ! -name '.*' \
      -print0 |
      while IFS= read -r -d '' source_json; do
        if ! jq -e '(.name | type == "string" and length > 0) and (.testCases | type == "object")' "$source_json" >/dev/null; then
          printf '%s\n' "$source_json"
          break
        fi
        if [ "$_merge_hive_result_dirs_require_single_client" -eq 1 ]; then
          if ! jq -e '
            ((.clients // (.clientVersions | keys_unsorted) // [])) as $clients
            | ($clients | type == "array")
            and ($clients | length == 1)
          ' "$source_json" >/dev/null; then
            printf '%s\n' "$source_json"
            break
          fi
        fi
      done |
      sed -n '1p'
  )"

  if [ -n "$invalid_json" ]; then
    if [ "$_merge_hive_result_dirs_require_single_client" -eq 1 ]; then
      _merge_hive_result_dirs_die "source contains an invalid or multi-client result JSON: $invalid_json"
    fi
    _merge_hive_result_dirs_die "source contains an invalid result JSON: $invalid_json"
  fi
}

_merge_hive_result_dirs_prepare_output() {
  local output

  output="$1"
  _merge_hive_result_dirs_guard_clean_dir output "$output"

  if [ "$_merge_hive_result_dirs_clean" -eq 1 ]; then
    _merge_hive_result_dirs_log "Resetting merged Hive result directory at $output"
    rm -rf "$output"
    mkdir -p "$output"
    return
  fi

  if [ -e "$output" ] && [ ! -d "$output" ]; then
    _merge_hive_result_dirs_die "output path exists but is not a directory: $output"
  fi

  mkdir -p "$output"
  if [ -n "$(find "$output" -mindepth 1 -print -quit)" ]; then
    _merge_hive_result_dirs_die "output directory is not empty; pass --clean-output to recreate it: $output"
  fi
}

_merge_hive_result_dirs_copy_tree() {
  local rel source source_file target_file

  source="$1"

  while IFS= read -r -d '' source_file; do
    rel="${source_file#$source/}"
    target_file="$_merge_hive_result_dirs_output/$rel"

    if [ -e "$target_file" ]; then
      if cmp -s "$source_file" "$target_file"; then
        continue
      fi
      _merge_hive_result_dirs_die "refusing to overwrite conflicting result path: $target_file"
    fi

    mkdir -p "$(dirname "$target_file")"
    cp -p "$source_file" "$target_file"
  done < <(find "$source" -type f -print0)
}

main() {
  local normalized_source source
  local -a normalized_sources

  _merge_hive_result_dirs_parse_args "$@"
  _merge_hive_result_dirs_require_cmd jq jq

  _merge_hive_result_dirs_output="$(_merge_hive_result_dirs_normalize_path "$_merge_hive_result_dirs_output")"
  normalized_sources=()

  for source in "${_merge_hive_result_dirs_sources[@]}"; do
    normalized_source="$(_merge_hive_result_dirs_normalize_path "$source")"
    if [ "$normalized_source" = "$_merge_hive_result_dirs_output" ]; then
      _merge_hive_result_dirs_die "source and output must differ: $normalized_source"
    fi
    if _merge_hive_result_dirs_path_contains "$normalized_source" "$_merge_hive_result_dirs_output"; then
      _merge_hive_result_dirs_die "output must not be inside source: $_merge_hive_result_dirs_output"
    fi
    if _merge_hive_result_dirs_path_contains "$_merge_hive_result_dirs_output" "$normalized_source"; then
      _merge_hive_result_dirs_die "source must not be inside output: $normalized_source"
    fi
    _merge_hive_result_dirs_validate_source "$normalized_source"
    normalized_sources+=("$normalized_source")
  done

  _merge_hive_result_dirs_prepare_output "$_merge_hive_result_dirs_output"

  for source in "${normalized_sources[@]}"; do
    _merge_hive_result_dirs_log "Merging Hive results from $source"
    _merge_hive_result_dirs_copy_tree "$source"
  done

  _merge_hive_result_dirs_log "Merged ${#normalized_sources[@]} Hive result directories into $_merge_hive_result_dirs_output"
}

main "$@"
