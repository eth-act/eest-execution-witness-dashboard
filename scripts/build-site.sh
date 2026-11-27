#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_build_site_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_build_site_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_build_site_script_dir/env.sh"

HIVEVIEW_LIST_LIMIT="${HIVEVIEW_LIST_LIMIT:-200}"
SITE_INCLUDE_CLIENT_LOGS="${SITE_INCLUDE_CLIENT_LOGS:-0}"
# hive-ui patches from patches/, applied in order and removed in reverse.
# hive-ui-hide-logs.patch hides the log UI, since the site publishes results
# without logs.
_build_site_hive_ui_patches=(hive-ui-hide-logs.patch)
# How many of them, from the front, are applied to HIVE_UI_DIR.
_build_site_hive_ui_patches_applied=0

_build_site_usage() {
  printf '%s\n' \
    'Usage: scripts/build-site.sh' \
    '' \
    'Build a static hive-ui site from per-client Hive results in HIVE_RESULTS_DIR.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  HIVE_DIR, HIVE_RESULTS_DIR, HIVE_UI_REPO, HIVE_UI_REF, HIVE_UI_DIR' \
    '  HIVE_UI_DISCOVERY_NAME, SITE_DIR, SITE_MAX_SIZE_MB' \
    '' \
    'Additional overrides:' \
    '  HIVEVIEW_LIST_LIMIT        Number of test runs in listing.jsonl. Default: 200' \
    '  SITE_INCLUDE_CLIENT_LOGS   Include full descriptions and logs for local debugging. Default: 0'
}

_build_site_hive_ui_patch_path() {
  printf '%s/patches/%s\n' "$ROOT_DIR" "$1"
}

_build_site_cleanup() {
  local status=$?
  local index

  if [ -d "$HIVE_UI_DIR/.git" ]; then
    for ((index = _build_site_hive_ui_patches_applied - 1; index >= 0; index--)); do
      git -C "$HIVE_UI_DIR" apply --reverse \
        "$(_build_site_hive_ui_patch_path "${_build_site_hive_ui_patches[$index]}")" >/dev/null 2>&1 || true
    done
  fi

  exit "$status"
}

trap _build_site_cleanup EXIT

_build_site_validate_discovery_name() {
  case "$HIVE_UI_DISCOVERY_NAME" in
    '' | ' '* | *' ' | *[!A-Za-z0-9_.\ -]*)
      eest_die "HIVE_UI_DISCOVERY_NAME must contain only letters, numbers, spaces, dots, underscores, or hyphens, without leading or trailing spaces: $HIVE_UI_DISCOVERY_NAME"
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
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_build_site_guard_hive_ui_dir() {
  case "$HIVE_UI_DIR" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$HIVE_RESULTS_DIR" | "$SITE_DIR")
      eest_die "refusing to use unsafe HIVE_UI_DIR: $HIVE_UI_DIR"
      ;;
  esac

  case "$HIVE_UI_DIR" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      eest_die "refusing to use HIVE_UI_DIR outside ROOT_DIR or /tmp: $HIVE_UI_DIR"
      ;;
  esac
}

_build_site_path_contains() {
  local child parent

  parent="${1%/}"
  child="${2%/}"

  case "$child" in
    "$parent"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_build_site_validate_result_path() {
  local part path
  local -a parts

  path="$1"
  case "$path" in
    '' | /* | *'//'*) eest_die "invalid result path: $path" ;;
  esac

  IFS='/'
  read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      '' | . | ..)
        eest_die "invalid result path segment in: $path"
        ;;
    esac
  done
}

_build_site_first_suite_json() {
  find "$1" -maxdepth 1 -type f -name '*.json' \
    ! -name 'hive.json' \
    ! -name 'errorReport.json' \
    ! -name 'containerErrorReport.json' \
    ! -name '.*' \
    -print -quit
}

_build_site_has_listable_results() {
  local first_result

  if ! first_result="$(_build_site_first_suite_json "$1")"; then
    eest_die "unable to scan Hive results directory: $1"
  fi

  [ -n "$first_result" ]
}

# Takes leftover hive-ui patches back off and refuses any other local edit,
# then moves hive-ui to HIVE_UI_REF.
_build_site_prepare_hive_ui_checkout() {
  local index patch

  if [ -d "$HIVE_UI_DIR" ] && eest_is_git_checkout_root "$HIVE_UI_DIR"; then
    for ((index = ${#_build_site_hive_ui_patches[@]} - 1; index >= 0; index--)); do
      patch="$(_build_site_hive_ui_patch_path "${_build_site_hive_ui_patches[$index]}")"
      if git -C "$HIVE_UI_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
        eest_log "Reverting previous hive-ui patch ${_build_site_hive_ui_patches[$index]}"
        git -C "$HIVE_UI_DIR" apply --reverse "$patch"
      fi
    done

    if ! git -C "$HIVE_UI_DIR" diff --quiet -- . || ! git -C "$HIVE_UI_DIR" diff --cached --quiet -- .; then
      eest_die "hive-ui checkout has local tracked changes: $HIVE_UI_DIR"
    fi
  fi
  eest_prepare_git_checkout hive-ui "$HIVE_UI_REPO" "$HIVE_UI_REF" "$HIVE_UI_DIR"
}

_build_site_validate_inputs() {
  local patch

  eest_require_positive_int HIVEVIEW_LIST_LIMIT "$HIVEVIEW_LIST_LIMIT"
  eest_require_positive_int SITE_MAX_SIZE_MB "$SITE_MAX_SIZE_MB"
  eest_require_bool SITE_INCLUDE_CLIENT_LOGS "$SITE_INCLUDE_CLIENT_LOGS"
  if eest_is_true "$SITE_INCLUDE_CLIENT_LOGS"; then
    SITE_INCLUDE_CLIENT_LOGS=1
  else
    SITE_INCLUDE_CLIENT_LOGS=0
  fi
  _build_site_validate_discovery_name

  ROOT_DIR="$(eest_normalize_path "$ROOT_DIR")"
  HIVE_DIR="$(eest_normalize_path "$HIVE_DIR")"
  HIVE_UI_DIR="$(eest_normalize_path "$HIVE_UI_DIR")"
  EEST_DIR="$(eest_normalize_path "$EEST_DIR")"
  FIXTURES_DIR="$(eest_normalize_path "$FIXTURES_DIR")"
  HIVE_RESULTS_DIR="$(eest_normalize_path "$HIVE_RESULTS_DIR")"
  SITE_DIR="$(eest_normalize_path "$SITE_DIR")"
  _build_site_guard_hive_ui_dir

  if _build_site_path_contains "$SITE_DIR" "$HIVE_RESULTS_DIR"; then
    eest_die "HIVE_RESULTS_DIR must not be inside SITE_DIR because the site reset would delete it: $HIVE_RESULTS_DIR"
  fi

  if _build_site_path_contains "$HIVE_RESULTS_DIR" "$SITE_DIR"; then
    eest_die "SITE_DIR must not be inside HIVE_RESULTS_DIR because result copying would mix generated site files into Hive results: $SITE_DIR"
  fi

  for patch in "${_build_site_hive_ui_patches[@]}"; do
    if [ ! -f "$(_build_site_hive_ui_patch_path "$patch")" ]; then
      eest_die "hive-ui patch does not exist: $(_build_site_hive_ui_patch_path "$patch")"
    fi
  done

  if [ ! -d "$HIVE_DIR/cmd/hiveview" ]; then
    eest_die "Hiveview listing command does not exist; run scripts/setup-hive.sh first: $HIVE_DIR/cmd/hiveview"
  fi

  if [ ! -d "$HIVE_RESULTS_DIR" ]; then
    eest_die "Hive results directory does not exist; run scripts/run-hive-consume.sh first: $HIVE_RESULTS_DIR"
  fi

  if ! _build_site_has_listable_results "$HIVE_RESULTS_DIR"; then
    eest_log "Hive results directory has no non-skipped suite JSON: $HIVE_RESULTS_DIR"
  fi
}

_build_site_reset_site_dir() {
  eest_guard_clean_dir SITE_DIR "$SITE_DIR"
  eest_log "Resetting static site directory at $SITE_DIR"
  rm -rf "$SITE_DIR"
  mkdir -p "$SITE_DIR"
}

_build_site_apply_hive_ui_patches() {
  local name patch

  for name in "${_build_site_hive_ui_patches[@]}"; do
    patch="$(_build_site_hive_ui_patch_path "$name")"
    if git -C "$HIVE_UI_DIR" apply --check "$patch" >/dev/null 2>&1; then
      git -C "$HIVE_UI_DIR" apply "$patch"
    elif git -C "$HIVE_UI_DIR" apply --reverse --check "$patch" >/dev/null 2>&1; then
      eest_log "hive-ui patch $name is already applied"
    else
      eest_die "hive-ui patch $name does not apply to $HIVE_UI_REF"
    fi
    _build_site_hive_ui_patches_applied=$((_build_site_hive_ui_patches_applied + 1))
  done
}

_build_site_restore_hive_ui_patches() {
  local index

  for ((index = _build_site_hive_ui_patches_applied - 1; index >= 0; index--)); do
    git -C "$HIVE_UI_DIR" apply --reverse \
      "$(_build_site_hive_ui_patch_path "${_build_site_hive_ui_patches[$index]}")"
    _build_site_hive_ui_patches_applied=$index
  done
}

_build_site_build_hive_ui_assets() {
  eest_log "Building hive-ui static assets"
  _build_site_apply_hive_ui_patches
  (
    cd "$HIVE_UI_DIR"
    npm ci
    npm run build -- --base=./
  )
  _build_site_restore_hive_ui_patches

  if [ ! -f "$HIVE_UI_DIR/dist/index.html" ]; then
    eest_die "hive-ui build did not create dist/index.html"
  fi

  eest_log "Copying hive-ui static assets"
  # ai.md and llms.txt describe hive.ethpandaops.io, not this dashboard.
  rsync -a --delete --exclude /ai.md --exclude /llms.txt "$HIVE_UI_DIR/dist"/ "$SITE_DIR"/
}

_build_site_generate_listing() {
  local listing_source tmp

  listing_source="$HIVE_RESULTS_DIR"
  tmp="$SITE_DIR/listing.jsonl.tmp"

  eest_log "Generating listing.jsonl"
  if ! _build_site_has_listable_results "$listing_source"; then
    eest_log "No non-skipped Hive suite JSON found; writing empty listing.jsonl"
    : > "$SITE_DIR/listing.jsonl"
    return
  fi

  if ! (
    cd "$HIVE_DIR"
    go run ./cmd/hiveview -listing -limit "$HIVEVIEW_LIST_LIMIT" -logdir "$listing_source"
  ) | tee "$tmp" >/dev/null; then
    rm -f "$tmp"
    eest_die "hiveview failed to generate listing.jsonl from $listing_source"
  fi

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    eest_die "hiveview generated an empty listing.jsonl from $listing_source"
  fi

  mv "$tmp" "$SITE_DIR/listing.jsonl"
}

_build_site_listed_suite_files() {
  jq -r 'select(type == "object" and .fileName != null and .fileName != "") | .fileName' "$SITE_DIR/listing.jsonl"
}

_build_site_referenced_result_files() {
  local suite_file

  suite_file="$1"
  jq -r '[
    .simLog,
    .testDetailsLog,
    (.testCases[]? | .clientInfo? // {} | to_entries[]? | .value.logFile?)
  ] | map(select(. != null and . != "")) | .[]' "$suite_file"
}

_build_site_copy_result_file() {
  local destination relpath source

  relpath="$1"
  _build_site_validate_result_path "$relpath"

  source="$HIVE_RESULTS_DIR/$relpath"
  destination="$SITE_DIR/results/$relpath"

  if [ ! -f "$source" ]; then
    eest_die "result file referenced by listing does not exist: $relpath"
  fi

  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
}

_build_site_copy_suite_file() {
  local destination relpath source tmp

  relpath="$1"
  _build_site_validate_result_path "$relpath"

  source="$HIVE_RESULTS_DIR/$relpath"
  destination="$SITE_DIR/results/$relpath"

  if [ ! -f "$source" ]; then
    eest_die "listing.jsonl references a suite result that does not exist: $relpath"
  fi

  mkdir -p "$(dirname "$destination")"
  if [ "$SITE_INCLUDE_CLIENT_LOGS" -eq 1 ]; then
    cp "$source" "$destination"
    return
  fi

  tmp="$destination.tmp"
  jq 'del(
    .simLog,
    .testDetailsLog,
    .testCases[]?.description,
    .testCases[]?.summaryResult.details,
    .testCases[]?.summaryResult.log,
    .testCases[]?.clientInfo?[]?.logFile,
    .testCases[]?.clientInfo?[]?.logOffsets
  )' "$source" > "$tmp"
  mv "$tmp" "$destination"
}

_build_site_copy_results() {
  local asset_count asset_list relpath suite_count suite_list

  eest_log "Copying listed Hive results into static site"
  mkdir -p "$SITE_DIR/results"

  suite_list="$SITE_DIR/.listed-suite-files.tmp"
  asset_list="$SITE_DIR/.referenced-result-files.tmp"

  _build_site_listed_suite_files | sort -u > "$suite_list"
  suite_count="$(wc -l < "$suite_list" | tr -d ' ')"

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    _build_site_copy_suite_file "$relpath"
  done < "$suite_list"

  : > "$asset_list"
  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    # Only publish assets still referenced by the transformed suite JSON.
    _build_site_referenced_result_files "$SITE_DIR/results/$relpath" >> "$asset_list"
  done < "$suite_list"
  sort -u -o "$asset_list" "$asset_list"
  asset_count="$(wc -l < "$asset_list" | tr -d ' ')"

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    _build_site_copy_result_file "$relpath"
  done < "$asset_list"

  rm -f "$suite_list" "$asset_list"

  if [ "$SITE_INCLUDE_CLIENT_LOGS" -eq 1 ]; then
    eest_log "Copied $suite_count listed suite result(s) and $asset_count referenced result asset(s)"
  else
    jq -c 'del(.simLog)' "$SITE_DIR/listing.jsonl" > "$SITE_DIR/listing.jsonl.tmp"
    mv "$SITE_DIR/listing.jsonl.tmp" "$SITE_DIR/listing.jsonl"
    eest_log "Copied $suite_count listed suite result(s); omitted per-test descriptions and all result logs"
  fi
}

_build_site_write_hive_ui_notices() {
  local commit

  eest_log "Writing hive-ui source notices"
  commit="$(git -C "$HIVE_UI_DIR" rev-parse HEAD)"
  cp "$HIVE_UI_DIR/LICENSE" "$SITE_DIR/hive-ui-LICENSE"
  printf 'hive-ui source: %s\nhive-ui ref: %s\nhive-ui commit: %s\n' \
    "$HIVE_UI_REPO" \
    "$HIVE_UI_REF" \
    "$commit" > "$SITE_DIR/hive-ui-SOURCE.txt"
}

_build_site_write_discovery() {
  eest_log "Writing discovery.json"
  jq -n \
    --arg name "$HIVE_UI_DISCOVERY_NAME" \
    --arg address "." \
    '[{name: $name, address: $address}]' > "$SITE_DIR/discovery.json"
}

_build_site_validate_single_client_listing() {
  if ! jq -s -e '
    all(.[]; (.clients | type == "array" and length == 1))
  ' "$SITE_DIR/listing.jsonl" >/dev/null; then
    eest_die "listing.jsonl must contain only per-client result entries with exactly one client"
  fi
}

_build_site_validate_result_references() {
  local relpath referenced suite_path

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    _build_site_validate_result_path "$relpath"
    suite_path="$SITE_DIR/results/$relpath"

    if [ ! -f "$suite_path" ]; then
      eest_die "listing.jsonl references a result file that was not copied: results/$relpath"
    fi

    if ! jq -e . "$suite_path" >/dev/null; then
      eest_die "referenced result file is not valid JSON: $suite_path"
    fi

    while IFS= read -r referenced; do
      [ -n "$referenced" ] || continue
      _build_site_validate_result_path "$referenced"
      if [ ! -f "$SITE_DIR/results/$referenced" ]; then
        eest_die "result entry references a public asset that was not copied: results/$referenced"
      fi
    done < <(_build_site_referenced_result_files "$suite_path")
  done < <(_build_site_listed_suite_files)
}

_build_site_validate_output() {
  local first_copied_result max_size_kb site_size_kb site_size_mb

  if [ ! -e "$SITE_DIR/listing.jsonl" ]; then
    eest_die "listing.jsonl was not created: $SITE_DIR/listing.jsonl"
  fi

  if [ ! -s "$SITE_DIR/index.html" ]; then
    eest_die "hive-ui index.html was not created: $SITE_DIR/index.html"
  fi

  if [ ! -s "$SITE_DIR/discovery.json" ]; then
    eest_die "discovery.json was not created or is empty: $SITE_DIR/discovery.json"
  fi

  if [ ! -s "$SITE_DIR/hive-ui-LICENSE" ] || [ ! -s "$SITE_DIR/hive-ui-SOURCE.txt" ]; then
    eest_die "hive-ui license/source notices were not created in $SITE_DIR"
  fi

  if ! jq -e 'type == "array" and length > 0 and all(.[]; (.name | type == "string") and (.address | type == "string"))' "$SITE_DIR/discovery.json" >/dev/null; then
    eest_die "discovery.json is not a valid hive-ui discovery file: $SITE_DIR/discovery.json"
  fi

  if [ -s "$SITE_DIR/listing.jsonl" ] && ! jq -e . "$SITE_DIR/listing.jsonl" >/dev/null; then
    eest_die "listing.jsonl is not valid JSON lines: $SITE_DIR/listing.jsonl"
  fi
  _build_site_validate_single_client_listing
  _build_site_validate_result_references

  first_copied_result="$(find "$SITE_DIR/results" -type f -print -quit)"
  if [ -z "$first_copied_result" ]; then
    eest_log "No non-skipped Hive result files were copied into $SITE_DIR/results"
  fi

  site_size_kb="$(du -sk "$SITE_DIR" | awk '{print $1}')"
  max_size_kb=$((SITE_MAX_SIZE_MB * 1024))
  if [ "$site_size_kb" -gt "$max_size_kb" ]; then
    site_size_mb=$(((site_size_kb + 1023) / 1024))
    eest_die "generated site is ${site_size_mb}MB, above SITE_MAX_SIZE_MB=$SITE_MAX_SIZE_MB"
  fi

  eest_log "Static site build complete at $SITE_DIR"
}

main() {
  _build_site_parse_args "$@"
  eest_require_cmd git Git
  eest_require_cmd go Go
  eest_require_cmd jq jq
  eest_require_cmd npm npm
  eest_require_cmd rsync rsync
  _build_site_validate_inputs
  _build_site_reset_site_dir
  _build_site_prepare_hive_ui_checkout
  _build_site_build_hive_ui_assets
  _build_site_generate_listing
  _build_site_copy_results
  _build_site_write_hive_ui_notices
  _build_site_write_discovery
  _build_site_validate_output
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
