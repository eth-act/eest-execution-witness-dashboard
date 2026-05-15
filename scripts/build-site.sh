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
_build_site_hive_ui_patch="$ROOT_DIR/patches/hive-ui-relative-paths.patch"
_build_site_hive_ui_patch_applied=0

_build_site_usage() {
  printf '%s\n' \
    'Usage: scripts/build-site.sh' \
    '' \
    'Build a static hive-ui site from HIVE_RESULTS_DIR.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  HIVE_DIR, HIVE_RESULTS_DIR, HIVE_UI_REPO, HIVE_UI_REF, HIVE_UI_DIR' \
    '  HIVE_UI_DISCOVERY_NAME, SITE_DIR, SITE_MAX_SIZE_MB' \
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

_build_site_validate_discovery_name() {
  case "$HIVE_UI_DISCOVERY_NAME" in
    '' | *[!A-Za-z0-9_.-]*)
      _build_site_die "HIVE_UI_DISCOVERY_NAME must contain only letters, numbers, dots, underscores, or hyphens: $HIVE_UI_DISCOVERY_NAME"
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
  local first_result

  _build_site_require_positive_int HIVEVIEW_LIST_LIMIT "$HIVEVIEW_LIST_LIMIT"
  _build_site_require_positive_int SITE_MAX_SIZE_MB "$SITE_MAX_SIZE_MB"
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

  if [ ! -f "$_build_site_hive_ui_patch" ]; then
    _build_site_die "hive-ui Pages patch does not exist: $_build_site_hive_ui_patch"
  fi

  if [ ! -d "$HIVE_DIR/cmd/hiveview" ]; then
    _build_site_die "Hiveview listing command does not exist; run scripts/setup-hive.sh first: $HIVE_DIR/cmd/hiveview"
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

_build_site_validate_output() {
  local first_copied_result first_listing_result max_size_kb site_size_kb site_size_mb

  if [ ! -s "$SITE_DIR/listing.jsonl" ]; then
    _build_site_die "listing.jsonl was not created or is empty: $SITE_DIR/listing.jsonl"
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
