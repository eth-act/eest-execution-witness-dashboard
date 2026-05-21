#!/usr/bin/env bash

set -Eeuo pipefail

_prepare_fixtures_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_prepare_fixtures_script_dir="$(_prepare_fixtures_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_prepare_fixtures_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_prepare_fixtures_script_dir/env.sh"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
export UV_CACHE_DIR

_prepare_fixtures_usage() {
  printf '%s\n' \
    'Usage: scripts/prepare-fixtures.sh' \
    '' \
    'Prepare execution witness fixtures in FIXTURES_DIR.' \
    'Fill mode uses EEST_REPO and EEST_REF to generate fixtures.' \
    'Release mode downloads the .tar.gz asset from the exact EEST_RELEASE_TAG.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_REPO, EEST_REF, EEST_RELEASE_TAG, EEST_DIR, FILLER_PATH, FORK, FIXTURES_DIR'
}

_prepare_fixtures_log() {
  printf '==> %s\n' "$*"
}

_prepare_fixtures_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_prepare_fixtures_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _prepare_fixtures_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_prepare_fixtures_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _prepare_fixtures_usage
        exit 0
        ;;
      *)
        _prepare_fixtures_usage >&2
        _prepare_fixtures_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_prepare_fixtures_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$EEST_DIR" | "$HIVE_DIR" | "$SITE_DIR")
      _prepare_fixtures_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _prepare_fixtures_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_prepare_fixtures_reset_dir() {
  local dir

  dir="$1"
  _prepare_fixtures_guard_clean_dir FIXTURES_DIR "$dir"
  _prepare_fixtures_log "Resetting fixtures directory at $dir"
  rm -rf "$dir"
  mkdir -p "$dir"
}

_prepare_fixtures_normalize_release_output() {
  local fixture_root index_path normalized_dir

  if [ -f "$FIXTURES_DIR/.meta/index.json" ]; then
    return 0
  fi

  index_path="$(
    find "$FIXTURES_DIR" \
      -mindepth 2 \
      -maxdepth 6 \
      -path '*/.meta/index.json' \
      -print \
      -quit
  )"

  if [ -z "$index_path" ]; then
    _prepare_fixtures_die "downloaded release did not contain .meta/index.json under $FIXTURES_DIR"
  fi

  fixture_root="${index_path%/.meta/index.json}"
  normalized_dir="$FIXTURES_DIR.normalized.$$"
  _prepare_fixtures_guard_clean_dir normalized-fixtures "$normalized_dir"
  rm -rf "$normalized_dir"
  mkdir -p "$normalized_dir"

  _prepare_fixtures_log "Normalizing downloaded fixture root from $fixture_root"
  cp -a "$fixture_root"/. "$normalized_dir"/
  rm -rf "$FIXTURES_DIR"
  mv "$normalized_dir" "$FIXTURES_DIR"
}

_prepare_fixtures_download_release() {
  local archive asset_count asset_name asset_url encoded_tag release_api_url release_json

  _prepare_fixtures_require_cmd uv uv
  _prepare_fixtures_require_cmd curl curl
  _prepare_fixtures_require_cmd jq jq
  _prepare_fixtures_require_cmd python3 Python

  _prepare_fixtures_log "Preparing EEST release checkout for $EEST_RELEASE_TAG"
  "$_prepare_fixtures_script_dir/setup-eest.sh"

  _prepare_fixtures_reset_dir "$FIXTURES_DIR"
  archive="$(mktemp /tmp/eest-release-fixtures.XXXXXXXX.tar.gz)"
  encoded_tag="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$EEST_RELEASE_TAG")"
  release_api_url="https://api.github.com/repos/ethereum/execution-specs/releases/tags/$encoded_tag"

  _prepare_fixtures_log "Resolving EEST release asset for $EEST_RELEASE_TAG"
  release_json="$(curl --fail --show-error --location "$release_api_url")"
  asset_count="$(
    jq '[.assets[]? | select(.name | endswith(".tar.gz"))] | length' <<< "$release_json"
  )"

  case "$asset_count" in
    0)
      _prepare_fixtures_die "release $EEST_RELEASE_TAG does not have a .tar.gz asset"
      ;;
    1)
      ;;
    *)
      printf 'matching .tar.gz assets for %s:\n' "$EEST_RELEASE_TAG" >&2
      jq -r '.assets[]? | select(.name | endswith(".tar.gz")) | .name' <<< "$release_json" >&2
      _prepare_fixtures_die "release $EEST_RELEASE_TAG has more than one .tar.gz asset"
      ;;
  esac

  asset_name="$(
    jq -r '.assets[]? | select(.name | endswith(".tar.gz")) | .name' <<< "$release_json"
  )"
  asset_url="$(
    jq -r '.assets[]? | select(.name | endswith(".tar.gz")) | .browser_download_url' <<< "$release_json"
  )"

  _prepare_fixtures_log "Downloading $asset_name into $FIXTURES_DIR"
  curl --fail --show-error --location --output "$archive" "$asset_url"
  tar -xzf "$archive" -C "$FIXTURES_DIR"
  rm -f "$archive"

  _prepare_fixtures_normalize_release_output
  "$_prepare_fixtures_script_dir/validate-fixtures.sh"
}

main() {
  _prepare_fixtures_parse_args "$@"
  eest_dashboard_validate_eest_source

  case "$(eest_dashboard_eest_source_mode)" in
    fill)
      "$_prepare_fixtures_script_dir/fill-fixtures.sh"
      ;;
    release)
      _prepare_fixtures_download_release
      ;;
    *)
      _prepare_fixtures_die "unsupported EEST source mode: $(eest_dashboard_eest_source_mode)"
      ;;
  esac
}

main "$@"
