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
SITE_INCLUDE_CLIENT_LOGS="${SITE_INCLUDE_CLIENT_LOGS:-0}"
_build_site_hive_ui_patch="$ROOT_DIR/patches/hive-ui-relative-paths.patch"
_build_site_hive_ui_patch_applied=0

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
    '  SITE_INCLUDE_CLIENT_LOGS   Copy per-test client logs into Pages. Default: 0'
}

_build_site_log() {
  printf '==> %s\n' "$*"
}

_build_site_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_build_site_cleanup() {
  local status=$?

  if [ "$_build_site_hive_ui_patch_applied" -eq 1 ] && [ -d "$HIVE_UI_DIR/.git" ]; then
    git -C "$HIVE_UI_DIR" apply --reverse "$_build_site_hive_ui_patch" >/dev/null 2>&1 || true
  fi

  exit "$status"
}

trap _build_site_cleanup EXIT

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

_build_site_require_bool() {
  local name value

  name="$1"
  value="$2"

  case "$value" in
    0 | 1 | true | false)
      ;;
    *)
      _build_site_die "$name must be 0, 1, true, or false: $value"
      ;;
  esac
}

_build_site_normalize_bool() {
  case "$1" in
    1 | true) printf '1\n' ;;
    0 | false) printf '0\n' ;;
    *) _build_site_die "invalid boolean value: $1" ;;
  esac
}

_build_site_validate_discovery_name() {
  case "$HIVE_UI_DISCOVERY_NAME" in
    '' | ' '* | *' ' | *[!A-Za-z0-9_.\ -]*)
      _build_site_die "HIVE_UI_DISCOVERY_NAME must contain only letters, numbers, spaces, dots, underscores, or hyphens, without leading or trailing spaces: $HIVE_UI_DISCOVERY_NAME"
      ;;
  esac
}

_build_site_ref_is_full_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
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
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$HIVE_UI_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$HIVE_RESULTS_DIR")
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

_build_site_guard_hive_ui_dir() {
  case "$HIVE_UI_DIR" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$HIVE_RESULTS_DIR" | "$SITE_DIR")
      _build_site_die "refusing to use unsafe HIVE_UI_DIR: $HIVE_UI_DIR"
      ;;
  esac

  case "$HIVE_UI_DIR" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _build_site_die "refusing to use HIVE_UI_DIR outside ROOT_DIR or /tmp: $HIVE_UI_DIR"
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
    '' | /* | *'//'*) _build_site_die "invalid result path: $path" ;;
  esac

  IFS='/'
  read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      '' | . | ..)
        _build_site_die "invalid result path segment in: $path"
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
    _build_site_die "unable to scan Hive results directory: $1"
  fi

  [ -n "$first_result" ]
}

_build_site_assert_listable_results() {
  local dir first_result phase

  phase="$1"
  dir="$2"

  if [ ! -d "$dir" ]; then
    _build_site_die "Hive results directory disappeared $phase: $dir"
  fi

  if ! first_result="$(_build_site_first_suite_json "$dir")"; then
    _build_site_die "unable to scan Hive results directory $phase: $dir"
  fi

  if [ -z "$first_result" ]; then
    _build_site_die "Hive results directory has no top-level suite JSON for hiveview $phase: $dir"
  fi
}

_build_site_prepare_git_checkout() {
  local checkout_dir label ref repo

  label="$1"
  repo="$2"
  ref="$3"
  checkout_dir="$4"

  _build_site_log "Preparing $label checkout at $checkout_dir"

  if [ -d "$checkout_dir" ]; then
    if ! git -C "$checkout_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _build_site_die "$label directory exists but is not a git checkout: $checkout_dir"
    fi

    if git -C "$checkout_dir" remote get-url origin >/dev/null 2>&1; then
      git -C "$checkout_dir" remote set-url origin "$repo"
    else
      git -C "$checkout_dir" remote add origin "$repo"
    fi

    if git -C "$checkout_dir" apply --reverse --check "$_build_site_hive_ui_patch" >/dev/null 2>&1; then
      _build_site_log "Reverting previous hive-ui Pages patch"
      git -C "$checkout_dir" apply --reverse "$_build_site_hive_ui_patch"
    fi

    if ! git -C "$checkout_dir" diff --quiet -- . || ! git -C "$checkout_dir" diff --cached --quiet -- .; then
      _build_site_die "$label checkout has local tracked changes: $checkout_dir"
    fi
  else
    mkdir -p "$(dirname "$checkout_dir")"
    git clone "$repo" "$checkout_dir"
  fi

  if _build_site_ref_is_full_sha "$ref"; then
    git -C "$checkout_dir" fetch --prune origin
    git -C "$checkout_dir" checkout --detach "$ref"
  else
    git -C "$checkout_dir" fetch --prune origin "$ref"
    git -C "$checkout_dir" checkout --detach FETCH_HEAD
  fi
}

_build_site_validate_inputs() {
  _build_site_require_positive_int HIVEVIEW_LIST_LIMIT "$HIVEVIEW_LIST_LIMIT"
  _build_site_require_positive_int SITE_MAX_SIZE_MB "$SITE_MAX_SIZE_MB"
  _build_site_require_bool SITE_INCLUDE_CLIENT_LOGS "$SITE_INCLUDE_CLIENT_LOGS"
  SITE_INCLUDE_CLIENT_LOGS="$(_build_site_normalize_bool "$SITE_INCLUDE_CLIENT_LOGS")"
  _build_site_validate_discovery_name

  ROOT_DIR="$(_build_site_normalize_path "$ROOT_DIR")"
  HIVE_DIR="$(_build_site_normalize_path "$HIVE_DIR")"
  HIVE_UI_DIR="$(_build_site_normalize_path "$HIVE_UI_DIR")"
  EEST_DIR="$(_build_site_normalize_path "$EEST_DIR")"
  FIXTURES_DIR="$(_build_site_normalize_path "$FIXTURES_DIR")"
  HIVE_RESULTS_DIR="$(_build_site_normalize_path "$HIVE_RESULTS_DIR")"
  SITE_DIR="$(_build_site_normalize_path "$SITE_DIR")"
  _build_site_hive_ui_patch="$ROOT_DIR/patches/hive-ui-relative-paths.patch"
  _build_site_guard_hive_ui_dir

  if _build_site_path_contains "$SITE_DIR" "$HIVE_RESULTS_DIR"; then
    _build_site_die "HIVE_RESULTS_DIR must not be inside SITE_DIR because the site reset would delete it: $HIVE_RESULTS_DIR"
  fi

  if _build_site_path_contains "$HIVE_RESULTS_DIR" "$SITE_DIR"; then
    _build_site_die "SITE_DIR must not be inside HIVE_RESULTS_DIR because result copying would mix generated site files into Hive results: $SITE_DIR"
  fi

  if [ ! -f "$_build_site_hive_ui_patch" ]; then
    _build_site_die "hive-ui Pages patch does not exist: $_build_site_hive_ui_patch"
  fi

  if [ ! -d "$HIVE_DIR/cmd/hiveview" ]; then
    _build_site_die "Hiveview listing command does not exist; run scripts/setup-hive.sh first: $HIVE_DIR/cmd/hiveview"
  fi

  if [ ! -d "$HIVE_RESULTS_DIR" ]; then
    _build_site_die "Hive results directory does not exist; run scripts/run-hive-consume.sh first: $HIVE_RESULTS_DIR"
  fi

  if ! _build_site_has_listable_results "$HIVE_RESULTS_DIR"; then
    _build_site_log "Hive results directory has no non-skipped suite JSON: $HIVE_RESULTS_DIR"
  fi
}

_build_site_reset_site_dir() {
  _build_site_guard_clean_dir SITE_DIR "$SITE_DIR"
  _build_site_log "Resetting static site directory at $SITE_DIR"
  rm -rf "$SITE_DIR"
  mkdir -p "$SITE_DIR"
}

_build_site_apply_hive_ui_patch() {
  if git -C "$HIVE_UI_DIR" apply --check "$_build_site_hive_ui_patch" >/dev/null 2>&1; then
    git -C "$HIVE_UI_DIR" apply "$_build_site_hive_ui_patch"
    _build_site_hive_ui_patch_applied=1
    return
  fi

  if git -C "$HIVE_UI_DIR" apply --reverse --check "$_build_site_hive_ui_patch" >/dev/null 2>&1; then
    _build_site_log "hive-ui Pages patch is already applied"
    _build_site_hive_ui_patch_applied=1
    return
  fi

  _build_site_die "hive-ui Pages patch does not apply to $HIVE_UI_REF"
}

_build_site_restore_hive_ui_patch() {
  if [ "$_build_site_hive_ui_patch_applied" -eq 1 ]; then
    git -C "$HIVE_UI_DIR" apply --reverse "$_build_site_hive_ui_patch"
    _build_site_hive_ui_patch_applied=0
  fi
}

_build_site_build_hive_ui_assets() {
  _build_site_log "Building hive-ui static assets"
  _build_site_apply_hive_ui_patch
  (
    cd "$HIVE_UI_DIR"
    npm ci
    npm run build -- --base=./
  )
  _build_site_restore_hive_ui_patch

  if [ ! -f "$HIVE_UI_DIR/dist/index.html" ]; then
    _build_site_die "hive-ui build did not create dist/index.html"
  fi

  _build_site_log "Copying hive-ui static assets"
  rsync -a --delete "$HIVE_UI_DIR/dist"/ "$SITE_DIR"/
}

_build_site_generate_listing() {
  local listing_source tmp

  listing_source="$HIVE_RESULTS_DIR"
  tmp="$SITE_DIR/listing.jsonl.tmp"

  _build_site_log "Generating listing.jsonl"
  if ! _build_site_has_listable_results "$listing_source"; then
    _build_site_log "No non-skipped Hive suite JSON found; writing empty listing.jsonl"
    : > "$SITE_DIR/listing.jsonl"
    return
  fi

  if ! (
    cd "$HIVE_DIR"
    go run ./cmd/hiveview -listing -limit "$HIVEVIEW_LIST_LIMIT" -logdir "$listing_source"
  ) | tee "$tmp" >/dev/null; then
    rm -f "$tmp"
    _build_site_die "hiveview failed to generate listing.jsonl from $listing_source"
  fi

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    _build_site_die "hiveview generated an empty listing.jsonl from $listing_source"
  fi

  mv "$tmp" "$SITE_DIR/listing.jsonl"
}

_build_site_listed_suite_files() {
  jq -r 'select(type == "object" and .fileName != null and .fileName != "") | .fileName' "$SITE_DIR/listing.jsonl"
}

_build_site_referenced_public_result_files() {
  local suite_file

  suite_file="$1"
  jq -r '[
    .simLog,
    .testDetailsLog
  ] | map(select(. != null and . != "")) | .[]' "$suite_file"
}

_build_site_referenced_all_result_files() {
  local suite_file

  suite_file="$1"
  jq -r '[
    .simLog,
    .testDetailsLog,
    (.testCases[]? | .clientInfo? // {} | to_entries[]? | .value.logFile?)
  ] | map(select(. != null and . != "")) | .[]' "$suite_file"
}

_build_site_referenced_result_files() {
  if [ "$SITE_INCLUDE_CLIENT_LOGS" -eq 1 ]; then
    _build_site_referenced_all_result_files "$1"
  else
    _build_site_referenced_public_result_files "$1"
  fi
}

_build_site_copy_result_file() {
  local destination relpath source

  relpath="$1"
  _build_site_validate_result_path "$relpath"

  source="$HIVE_RESULTS_DIR/$relpath"
  destination="$SITE_DIR/results/$relpath"

  if [ ! -f "$source" ]; then
    _build_site_die "result file referenced by listing does not exist: $relpath"
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
    _build_site_die "listing.jsonl references a suite result that does not exist: $relpath"
  fi

  mkdir -p "$(dirname "$destination")"
  if [ "$SITE_INCLUDE_CLIENT_LOGS" -eq 1 ]; then
    cp "$source" "$destination"
    return
  fi

  tmp="$destination.tmp"
  jq 'del(.testCases[]?.clientInfo?[]?.logFile, .testCases[]?.clientInfo?[]?.logOffsets)' "$source" > "$tmp"
  mv "$tmp" "$destination"
}

_build_site_copy_results() {
  local asset_count asset_list relpath suite_count suite_list

  _build_site_log "Copying listed Hive results into static site"
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
    _build_site_referenced_result_files "$HIVE_RESULTS_DIR/$relpath" >> "$asset_list"
  done < "$suite_list"
  sort -u -o "$asset_list" "$asset_list"
  asset_count="$(wc -l < "$asset_list" | tr -d ' ')"

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    _build_site_copy_result_file "$relpath"
  done < "$asset_list"

  rm -f "$suite_list" "$asset_list"

  if [ "$SITE_INCLUDE_CLIENT_LOGS" -eq 1 ]; then
    _build_site_log "Copied $suite_count listed suite result(s) and $asset_count referenced result asset(s)"
  else
    _build_site_log "Copied $suite_count listed suite result(s) and $asset_count public result asset(s); omitted per-test client logs"
  fi
}

_build_site_write_hive_ui_notices() {
  local commit

  _build_site_log "Writing hive-ui source notices"
  commit="$(git -C "$HIVE_UI_DIR" rev-parse HEAD)"
  cp "$HIVE_UI_DIR/LICENSE" "$SITE_DIR/hive-ui-LICENSE"
  printf 'hive-ui source: %s\nhive-ui ref: %s\nhive-ui commit: %s\n' \
    "$HIVE_UI_REPO" \
    "$HIVE_UI_REF" \
    "$commit" > "$SITE_DIR/hive-ui-SOURCE.txt"
}

_build_site_write_discovery() {
  _build_site_log "Writing discovery.json"
  jq -n \
    --arg name "$HIVE_UI_DISCOVERY_NAME" \
    --arg address "." \
    '[{name: $name, address: $address}]' > "$SITE_DIR/discovery.json"
}

_build_site_validate_single_client_listing() {
  if ! jq -s -e '
    all(.[]; (.clients | type == "array" and length == 1))
  ' "$SITE_DIR/listing.jsonl" >/dev/null; then
    _build_site_die "listing.jsonl must contain only per-client result entries with exactly one client"
  fi
}

_build_site_validate_result_references() {
  local relpath referenced suite_path

  while IFS= read -r relpath; do
    [ -n "$relpath" ] || continue
    _build_site_validate_result_path "$relpath"
    suite_path="$SITE_DIR/results/$relpath"

    if [ ! -f "$suite_path" ]; then
      _build_site_die "listing.jsonl references a result file that was not copied: results/$relpath"
    fi

    if ! jq -e . "$suite_path" >/dev/null; then
      _build_site_die "referenced result file is not valid JSON: $suite_path"
    fi

    while IFS= read -r referenced; do
      [ -n "$referenced" ] || continue
      _build_site_validate_result_path "$referenced"
      if [ ! -f "$SITE_DIR/results/$referenced" ]; then
        _build_site_die "result entry references a public asset that was not copied: results/$referenced"
      fi
    done < <(_build_site_referenced_public_result_files "$suite_path")
  done < <(_build_site_listed_suite_files)
}

_build_site_validate_output() {
  local first_copied_result first_listing_result max_size_kb site_size_kb site_size_mb

  if [ ! -e "$SITE_DIR/listing.jsonl" ]; then
    _build_site_die "listing.jsonl was not created: $SITE_DIR/listing.jsonl"
  fi

  if [ ! -s "$SITE_DIR/index.html" ]; then
    _build_site_die "hive-ui index.html was not created: $SITE_DIR/index.html"
  fi

  if [ ! -s "$SITE_DIR/discovery.json" ]; then
    _build_site_die "discovery.json was not created or is empty: $SITE_DIR/discovery.json"
  fi

  if [ ! -s "$SITE_DIR/hive-ui-LICENSE" ] || [ ! -s "$SITE_DIR/hive-ui-SOURCE.txt" ]; then
    _build_site_die "hive-ui license/source notices were not created in $SITE_DIR"
  fi

  if ! jq -e 'type == "array" and length > 0 and all(.[]; (.name | type == "string") and (.address | type == "string"))' "$SITE_DIR/discovery.json" >/dev/null; then
    _build_site_die "discovery.json is not a valid hive-ui discovery file: $SITE_DIR/discovery.json"
  fi

  if [ -s "$SITE_DIR/listing.jsonl" ] && ! jq -e . "$SITE_DIR/listing.jsonl" >/dev/null; then
    _build_site_die "listing.jsonl is not valid JSON lines: $SITE_DIR/listing.jsonl"
  fi
  _build_site_validate_single_client_listing
  _build_site_validate_result_references

  first_listing_result="$(jq -r 'select(.fileName != null) | .fileName' "$SITE_DIR/listing.jsonl" | sed -n '1p')"
  if [ -n "$first_listing_result" ] && [ ! -f "$SITE_DIR/results/$first_listing_result" ]; then
    _build_site_die "listing.jsonl references a result file that was not copied: results/$first_listing_result"
  fi

  first_copied_result="$(find "$SITE_DIR/results" -type f -print -quit)"
  if [ -z "$first_copied_result" ]; then
    _build_site_log "No non-skipped Hive result files were copied into $SITE_DIR/results"
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
  _build_site_require_cmd git Git
  _build_site_require_cmd go Go
  _build_site_require_cmd jq jq
  _build_site_require_cmd npm npm
  _build_site_require_cmd rsync rsync
  _build_site_validate_inputs
  _build_site_reset_site_dir
  _build_site_prepare_git_checkout hive-ui "$HIVE_UI_REPO" "$HIVE_UI_REF" "$HIVE_UI_DIR"
  _build_site_build_hive_ui_assets
  _build_site_generate_listing
  _build_site_copy_results
  _build_site_write_hive_ui_notices
  _build_site_write_discovery
  _build_site_validate_output
}

main "$@"
