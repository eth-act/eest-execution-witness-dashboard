#!/usr/bin/env bash

set -Eeuo pipefail

_merge_hive_results_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_merge_hive_results_script_dir="$(_merge_hive_results_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_merge_hive_results_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_merge_hive_results_script_dir/env.sh"
# shellcheck source=scripts/lib/el-clients.sh
. "$_merge_hive_results_script_dir/lib/el-clients.sh"

HIVE_RESULTS_SOURCE_DIR="${HIVE_RESULTS_SOURCE_DIR:-$HIVE_CLIENT_RESULTS_DIR}"

_merge_hive_results_usage() {
  printf '%s\n' \
    'Usage: scripts/merge-hive-results.sh' \
    '' \
    'Merge isolated per-client Hive result directories into HIVE_RESULTS_DIR.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EL_CLIENTS, EL_CLIENT_CONFIG, EL_CLIENT_OVERRIDES_JSON' \
    '  HIVE_CLIENT_RESULTS_DIR, HIVE_RESULTS_DIR' \
    '' \
    'Additional overrides:' \
    '  HIVE_RESULTS_SOURCE_DIR     Root containing CLIENT_ID/ or hive-results-CLIENT_ID/ directories.'
}

_merge_hive_results_log() {
  printf '==> %s\n' "$*"
}

_merge_hive_results_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_merge_hive_results_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _merge_hive_results_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_merge_hive_results_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _merge_hive_results_usage
        exit 0
        ;;
      *)
        _merge_hive_results_usage >&2
        _merge_hive_results_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_merge_hive_results_normalize_path() {
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
          _merge_hive_results_die "path escapes filesystem root: $1"
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

_merge_hive_results_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$HIVE_UI_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$SITE_DIR" | "$HIVE_CLIENT_RESULTS_DIR")
      _merge_hive_results_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _merge_hive_results_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_merge_hive_results_source_dir_for() {
  local artifact id source_root

  source_root="$1"
  id="$2"
  artifact="$(eest_el_clients_artifact_name "$id")"

  if [ -d "$source_root/$id" ]; then
    printf '%s\n' "$source_root/$id"
    return
  fi

  if [ -d "$source_root/$artifact" ]; then
    printf '%s\n' "$source_root/$artifact"
    return
  fi

  return 1
}

_merge_hive_results_first_suite_json() {
  find "$1" -maxdepth 1 -type f -name '*.json' \
    ! -name 'hive.json' \
    ! -name 'errorReport.json' \
    ! -name 'containerErrorReport.json' \
    ! -name '.*' \
    -print -quit
}

_merge_hive_results_all_results_pruned() {
  local summary_file

  summary_file="$1/.eest-prune-skipped-summary"
  [ -f "$summary_file" ] || return 1

  jq -e '
    (.suite_files_seen | type == "number")
    and (.suite_files_seen > 0)
    and (.suite_files_removed | type == "number")
    and (.suite_files_removed > 0)
    and (.test_cases_pruned | type == "number")
    and (.test_cases_pruned > 0)
  ' "$summary_file" >/dev/null
}

_merge_hive_results_validate_client_dir() {
  local client_dir first_json full_name invalid_json

  client_dir="$1"
  full_name="$2"

  first_json="$(_merge_hive_results_first_suite_json "$client_dir")"
  if [ -z "$first_json" ]; then
    if _merge_hive_results_all_results_pruned "$client_dir"; then
      return 2
    fi
    _merge_hive_results_die "client $full_name did not produce any top-level Hive result JSON in $client_dir"
  fi

  invalid_json="$(
    find "$client_dir" -maxdepth 1 -type f -name '*.json' \
      ! -name 'hive.json' \
      ! -name 'errorReport.json' \
      ! -name 'containerErrorReport.json' \
      ! -name '.*' \
      -print0 |
      while IFS= read -r -d '' result_json; do
        if ! jq -e --arg client "$full_name" '
          ((.clients // (.clientVersions | keys_unsorted) // [])) as $clients
          | ($clients | type == "array")
          and ($clients | length == 1)
          and ($clients[0] == $client)
        ' "$result_json" >/dev/null; then
          printf '%s\n' "$result_json"
        fi
      done |
      sed -n '1p'
  )"

  if [ -n "$invalid_json" ]; then
    _merge_hive_results_die "result JSON is not a single-client $full_name run: $invalid_json"
  fi
}

_merge_hive_results_copy_tree() {
  local client_dir rel result_file target_file

  client_dir="$1"

  while IFS= read -r -d '' result_file; do
    rel="${result_file#$client_dir/}"
    target_file="$HIVE_RESULTS_DIR/$rel"

    if [ -e "$target_file" ]; then
      if cmp -s "$result_file" "$target_file"; then
        continue
      fi
      _merge_hive_results_die "refusing to overwrite conflicting result path: $target_file"
    fi

    mkdir -p "$(dirname "$target_file")"
    cp -p "$result_file" "$target_file"
  done < <(find "$client_dir" -type f -print0)
}

_merge_hive_results_validate_final_dir() {
  local invalid_json

  invalid_json="$(
    find "$HIVE_RESULTS_DIR" -maxdepth 1 -type f -name '*.json' \
      ! -name 'hive.json' \
      ! -name 'errorReport.json' \
      ! -name 'containerErrorReport.json' \
      ! -name '.*' \
      -print0 |
      while IFS= read -r -d '' result_json; do
        if ! jq -e '
          ((.clients // (.clientVersions | keys_unsorted) // [])) as $clients
          | ($clients | type == "array")
          and ($clients | length == 1)
        ' "$result_json" >/dev/null; then
          printf '%s\n' "$result_json"
        fi
      done |
      sed -n '1p'
  )"

  if [ -n "$invalid_json" ]; then
    _merge_hive_results_die "merged result JSON is not a single-client run: $invalid_json"
  fi
}

main() {
  local client_dir descriptor full_name id resolved source_root validate_status

  _merge_hive_results_parse_args "$@"
  _merge_hive_results_require_cmd jq jq

  HIVE_RESULTS_SOURCE_DIR="$(_merge_hive_results_normalize_path "$HIVE_RESULTS_SOURCE_DIR")"
  HIVE_RESULTS_DIR="$(_merge_hive_results_normalize_path "$HIVE_RESULTS_DIR")"
  source_root="$HIVE_RESULTS_SOURCE_DIR"

  if [ ! -d "$source_root" ]; then
    _merge_hive_results_die "HIVE_RESULTS_SOURCE_DIR does not exist: $source_root"
  fi

  if [ "$source_root" = "$HIVE_RESULTS_DIR" ]; then
    _merge_hive_results_die "HIVE_RESULTS_SOURCE_DIR and HIVE_RESULTS_DIR must be different"
  fi

  if ! resolved="$(eest_el_clients_resolve_descriptors)"; then
    _merge_hive_results_die "failed to resolve EL client descriptors"
  fi

  _merge_hive_results_guard_clean_dir HIVE_RESULTS_DIR "$HIVE_RESULTS_DIR"
  _merge_hive_results_log "Resetting merged Hive results directory at $HIVE_RESULTS_DIR"
  rm -rf "$HIVE_RESULTS_DIR"
  mkdir -p "$HIVE_RESULTS_DIR"

  while IFS= read -r descriptor; do
    id="$(eest_el_clients_descriptor_field "$descriptor" '.id')"
    full_name="$(eest_el_clients_full_client_name "$descriptor")"

    if ! client_dir="$(_merge_hive_results_source_dir_for "$source_root" "$id")"; then
      _merge_hive_results_die "missing isolated result directory for $id under $source_root"
    fi

    _merge_hive_results_log "Merging results for $full_name from $client_dir"
    validate_status=0
    _merge_hive_results_validate_client_dir "$client_dir" "$full_name" || validate_status=$?
    if [ "$validate_status" -eq 2 ]; then
      _merge_hive_results_log "Skipping $full_name because only skipped Hive cases were produced"
      continue
    fi
    if [ "$validate_status" -ne 0 ]; then
      exit "$validate_status"
    fi
    _merge_hive_results_copy_tree "$client_dir"
  done < <(jq -c '.[]' <<< "$resolved")

  _merge_hive_results_validate_final_dir
  _merge_hive_results_log "Merged per-client Hive results into $HIVE_RESULTS_DIR"
}

main "$@"
