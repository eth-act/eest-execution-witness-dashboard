#!/usr/bin/env bash

set -Eeuo pipefail

_smoke_site_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_smoke_site_script_dir="$(_smoke_site_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_smoke_site_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_smoke_site_script_dir/env.sh"

SITE_SMOKE_HOST="${SITE_SMOKE_HOST:-127.0.0.1}"
SITE_SMOKE_PORT="${SITE_SMOKE_PORT:-8765}"
SITE_SMOKE_BASE_PATH="${SITE_SMOKE_BASE_PATH:-eest-execution-witness-dashboard}"
SITE_SMOKE_URL="${SITE_SMOKE_URL:-}"
SITE_SECRET_SCAN="${SITE_SECRET_SCAN:-1}"
SITE_SECRET_SCAN_MAX_MATCHES="${SITE_SECRET_SCAN_MAX_MATCHES:-40}"
SITE_SECRET_SCAN_PATTERN="${SITE_SECRET_SCAN_PATTERN:-authorization:|bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*|api[_-]?key|secret[_-]?key|private[_-]?key|password|passwd|mnemonic|seed phrase|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|GOOGLE_APPLICATION_CREDENTIALS|RPC[_-]?URL=|https?://[^[:space:]\"'<>]*(infura|alchemy|quicknode|ankr|drpc|llama|blastapi|nodereal|chainstack)[^[:space:]\"'<>]*}"

_smoke_site_tmp_dir=""
_smoke_site_server_pid=""
_smoke_site_server_log=""

_smoke_site_usage() {
  printf '%s\n' \
    'Usage: scripts/smoke-site.sh' \
    '' \
    'Smoke test the generated static hive-ui site over local HTTP.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  SITE_DIR' \
    '' \
    'Additional overrides:' \
    '  SITE_SMOKE_HOST              Host to bind. Default: 127.0.0.1' \
    '  SITE_SMOKE_PORT              Port to bind. Default: 8765' \
    '  SITE_SMOKE_BASE_PATH         Non-root URL path to test. Default: eest-execution-witness-dashboard' \
    '  SITE_SMOKE_URL               Public URL to test instead of serving SITE_DIR locally.' \
    '  SITE_SECRET_SCAN             Set to 0 to skip public-log secret scan. Default: 1' \
    '  SITE_SECRET_SCAN_PATTERN     Extended grep regex for suspicious public log content.' \
    '  SITE_SECRET_SCAN_MAX_MATCHES Max matches to print on failure. Default: 40' \
    '' \
    'Arguments:' \
    '  --url URL                    Same as SITE_SMOKE_URL.'
}

_smoke_site_log() {
  printf '==> %s\n' "$*"
}

_smoke_site_die() {
  printf 'error: %s\n' "$*" >&2
  if [ -n "$_smoke_site_server_log" ] && [ -s "$_smoke_site_server_log" ]; then
    printf 'HTTP server log:\n' >&2
    sed -n '1,120p' "$_smoke_site_server_log" >&2 || true
  fi
  exit 1
}

_smoke_site_cleanup() {
  if [ -n "$_smoke_site_server_pid" ] && kill -0 "$_smoke_site_server_pid" 2>/dev/null; then
    kill "$_smoke_site_server_pid" 2>/dev/null || true
    wait "$_smoke_site_server_pid" 2>/dev/null || true
  fi

  if [ -n "$_smoke_site_tmp_dir" ] && [ -d "$_smoke_site_tmp_dir" ]; then
    rm -rf "$_smoke_site_tmp_dir"
  fi
}

trap _smoke_site_cleanup EXIT

_smoke_site_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _smoke_site_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_smoke_site_python_cmd() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    printf '%s\n' python
    return 0
  fi

  return 1
}

_smoke_site_require_positive_int() {
  local name value

  name="$1"
  value="$2"

  case "$value" in
    '' | *[!0-9]*)
      _smoke_site_die "$name must be a positive integer: $value"
      ;;
    0)
      _smoke_site_die "$name must be greater than zero"
      ;;
  esac
}

_smoke_site_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url)
        shift
        if [ "$#" -eq 0 ]; then
          _smoke_site_usage >&2
          _smoke_site_die "--url requires a value"
        fi
        SITE_SMOKE_URL="$1"
        ;;
      --url=*)
        SITE_SMOKE_URL="${1#--url=}"
        ;;
      --help | -h)
        _smoke_site_usage
        exit 0
        ;;
      *)
        _smoke_site_usage >&2
        _smoke_site_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_smoke_site_normalize_base_path() {
  local path

  path="$1"
  while [ "${path#/}" != "$path" ]; do
    path="${path#/}"
  done
  while [ "${path%/}" != "$path" ]; do
    path="${path%/}"
  done

  case "$path" in
    '' | . | .. | *'/../'* | ../* | *'/..' | *'\'* | *'//'* | *'?'* | *'#'*)
      _smoke_site_die "SITE_SMOKE_BASE_PATH must be a non-root relative URL path: $1"
      ;;
  esac

  printf '%s\n' "$path"
}

_smoke_site_normalize_url() {
  local url

  url="$1"
  while [ "${url%/}" != "$url" ]; do
    url="${url%/}"
  done

  case "$url" in
    http://* | https://*) ;;
    *)
      _smoke_site_die "SITE_SMOKE_URL must start with http:// or https://: $1"
      ;;
  esac

  case "$url" in
    *$'\r'* | *$'\n'* | *' '*)
      _smoke_site_die "SITE_SMOKE_URL cannot contain whitespace: $1"
      ;;
  esac

  printf '%s\n' "$url"
}

_smoke_site_validate_relative_path() {
  local label path

  label="$1"
  path="$2"

  case "$path" in
    '' | /* | . | .. | *'/../'* | ../* | *'/..' | *'\'* | *'?'* | *'#'* | *$'\r'* | *$'\n'*)
      _smoke_site_die "$label is not a safe relative path: $path"
      ;;
  esac
}

_smoke_site_validate_inputs() {
  local first_copied_result

  _smoke_site_require_positive_int SITE_SMOKE_PORT "$SITE_SMOKE_PORT"
  _smoke_site_require_positive_int SITE_SECRET_SCAN_MAX_MATCHES "$SITE_SECRET_SCAN_MAX_MATCHES"
  SITE_SMOKE_BASE_PATH="$(_smoke_site_normalize_base_path "$SITE_SMOKE_BASE_PATH")"

  if [ ! -d "$SITE_DIR" ]; then
    _smoke_site_die "site directory does not exist; run scripts/build-site.sh first: $SITE_DIR"
  fi

  if [ ! -s "$SITE_DIR/listing.jsonl" ]; then
    _smoke_site_die "listing.jsonl is missing or empty: $SITE_DIR/listing.jsonl"
  fi

  if [ ! -s "$SITE_DIR/discovery.json" ]; then
    _smoke_site_die "discovery.json is missing or empty: $SITE_DIR/discovery.json"
  fi

  _smoke_site_check_discovery_file_from "$SITE_DIR/discovery.json" >/dev/null

  if ! jq -e . "$SITE_DIR/listing.jsonl" >/dev/null; then
    _smoke_site_die "listing.jsonl is not valid JSON lines: $SITE_DIR/listing.jsonl"
  fi

  if [ ! -d "$SITE_DIR/results" ]; then
    _smoke_site_die "results directory is missing: $SITE_DIR/results"
  fi

  first_copied_result="$(find "$SITE_DIR/results" -type f -print -quit)"
  if [ -z "$first_copied_result" ]; then
    _smoke_site_die "results directory is empty: $SITE_DIR/results"
  fi
}

_smoke_site_first_listing_file_from() {
  local listing_file

  listing_file="$1"
  jq -r 'select(type == "object" and .fileName != null and .fileName != "") | .fileName' \
    "$listing_file" | sed -n '1p'
}

_smoke_site_first_listing_file() {
  _smoke_site_first_listing_file_from "$SITE_DIR/listing.jsonl"
}

_smoke_site_check_discovery_file_from() {
  local discovery_file

  discovery_file="$1"
  if ! jq -e 'type == "array" and length > 0 and all(.[]; (.name | type == "string" and length > 0) and (.address | type == "string" and length > 0))' "$discovery_file" >/dev/null; then
    _smoke_site_die "discovery.json is not a valid hive-ui discovery file: $discovery_file"
  fi

  jq -r '.[0].address' "$discovery_file"
}

_smoke_site_first_referenced_result_file_from() {
  local suite_file_path

  suite_file_path="$1"
  jq -r '[.simLog, .testDetailsLog, (.testCases[]? | .clientInfo? // {} | to_entries[]? | .value.logFile?)] | map(select(. != null and . != "")) | .[0] // empty' \
    "$suite_file_path"
}

_smoke_site_first_referenced_result_file() {
  local suite_file

  suite_file="$1"
  _smoke_site_first_referenced_result_file_from "$SITE_DIR/results/$suite_file"
}

_smoke_site_check_listing_paths() {
  local first_result referenced_result

  first_result="$(_smoke_site_first_listing_file)"
  if [ -z "$first_result" ]; then
    _smoke_site_die "listing.jsonl does not contain any entries with fileName"
  fi

  _smoke_site_validate_relative_path "listing fileName" "$first_result"
  if [ ! -f "$SITE_DIR/results/$first_result" ]; then
    _smoke_site_die "listing.jsonl references a result file that was not copied: results/$first_result"
  fi

  if ! jq -e . "$SITE_DIR/results/$first_result" >/dev/null; then
    _smoke_site_die "referenced result file is not valid JSON: $SITE_DIR/results/$first_result"
  fi

  referenced_result="$(_smoke_site_first_referenced_result_file "$first_result")"
  if [ -n "$referenced_result" ]; then
    _smoke_site_validate_relative_path "referenced result asset" "$referenced_result"
    if [ ! -f "$SITE_DIR/results/$referenced_result" ]; then
      _smoke_site_die "result entry references a file that was not copied: results/$referenced_result"
    fi
  fi

  printf '%s\n' "$first_result"
}

_smoke_site_check_relative_sources() {
  local matches pattern

  pattern="href=\"/|src=\"/|url\\(['\"]?/|fetch\\(['\"]/"
  matches="$(
    find "$SITE_DIR" \
      \( -name '*.html' -o -name '*.js' -o -name '*.css' \) \
      ! -name '*.map' \
      -exec grep -InE "$pattern" {} + || true
  )"

  if [ -n "$matches" ]; then
    printf '%s\n' "$matches" >&2
    _smoke_site_die "generated site contains root-relative asset or fetch paths; GitHub Pages project URLs need relative paths"
  fi

  _smoke_site_log "Static assets and fetch paths are relative"
}

_smoke_site_check_public_logs() {
  local matches

  if [ "$SITE_SECRET_SCAN" = "0" ]; then
    _smoke_site_log "Skipping public-log secret scan because SITE_SECRET_SCAN=0"
    return
  fi

  matches="$(
    LC_ALL=C grep -RInEI --exclude-dir=.git "$SITE_SECRET_SCAN_PATTERN" "$SITE_DIR/results" \
      | sed -n "1,${SITE_SECRET_SCAN_MAX_MATCHES}p" || true
  )"

  if [ -n "$matches" ]; then
    printf '%s\n' "$matches" >&2
    _smoke_site_die "possible secret, credential, private RPC URL, or private test data found in public results"
  fi

  _smoke_site_log "No suspicious public-log strings found"
}

_smoke_site_start_server() {
  local base_dir python_cmd target_dir

  python_cmd="$1"
  _smoke_site_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hive-ui-site-smoke.XXXXXX")"
  _smoke_site_server_log="$_smoke_site_tmp_dir/http-server.log"
  target_dir="$_smoke_site_tmp_dir/$SITE_SMOKE_BASE_PATH"
  base_dir="$(dirname "$target_dir")"

  mkdir -p "$base_dir"
  ln -s "$SITE_DIR" "$target_dir"

  (
    cd "$_smoke_site_tmp_dir"
    "$python_cmd" -m http.server "$SITE_SMOKE_PORT" --bind "$SITE_SMOKE_HOST"
  ) >"$_smoke_site_server_log" 2>&1 &
  _smoke_site_server_pid="$!"
}

_smoke_site_wait_for_server() {
  local base_url

  base_url="$1"
  for _ in {1..30}; do
    if ! kill -0 "$_smoke_site_server_pid" 2>/dev/null; then
      _smoke_site_die "HTTP server exited before becoming ready"
    fi

    if curl --fail --silent --output /dev/null "$base_url/" 2>/dev/null; then
      return 0
    fi

    sleep 0.2
  done

  _smoke_site_die "HTTP server did not become ready at $base_url/"
}

_smoke_site_fetch() {
  local output url

  url="$1"
  output="$2"

  curl --fail --silent --show-error --location --output "$output" "$url"
}

_smoke_site_head() {
  local url

  url="$1"

  curl --fail --silent --show-error --location --head --output /dev/null "$url"
}

_smoke_site_check_remote() {
  local base_url discovery_http first_result listing_http referenced_result result_http

  base_url="$(_smoke_site_normalize_url "$SITE_SMOKE_URL")"
  _smoke_site_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hive-ui-site-smoke.XXXXXX")"
  discovery_http="$_smoke_site_tmp_dir/discovery.json"
  listing_http="$_smoke_site_tmp_dir/listing.jsonl"
  result_http="$_smoke_site_tmp_dir/result.json"

  _smoke_site_log "Testing deployed site at $base_url/"
  _smoke_site_fetch "$base_url/" "$_smoke_site_tmp_dir/index.html"
  _smoke_site_fetch "$base_url/discovery.json" "$discovery_http"
  _smoke_site_check_discovery_file_from "$discovery_http" >/dev/null
  _smoke_site_log "Fetched discovery.json from deployed site"

  _smoke_site_fetch "$base_url/listing.jsonl" "$listing_http"
  if ! jq -e . "$listing_http" >/dev/null; then
    _smoke_site_die "listing.jsonl fetched over HTTP is not valid JSON lines: $base_url/listing.jsonl"
  fi

  first_result="$(_smoke_site_first_listing_file_from "$listing_http")"
  if [ -z "$first_result" ]; then
    _smoke_site_die "deployed listing.jsonl does not contain any entries with fileName"
  fi

  _smoke_site_validate_relative_path "listing fileName" "$first_result"
  _smoke_site_fetch "$base_url/results/$first_result" "$result_http"
  if ! jq -e . "$result_http" >/dev/null; then
    _smoke_site_die "result entry fetched over HTTP is not valid JSON: $base_url/results/$first_result"
  fi
  _smoke_site_log "Fetched listing.jsonl and results/$first_result from deployed site"

  referenced_result="$(_smoke_site_first_referenced_result_file_from "$result_http")"
  if [ -n "$referenced_result" ]; then
    _smoke_site_validate_relative_path "referenced result asset" "$referenced_result"
    _smoke_site_head "$base_url/results/$referenced_result"
    _smoke_site_log "Verified deployed referenced result asset results/$referenced_result"
  fi

  _smoke_site_log "Deployed Pages smoke test passed"
}

_smoke_site_check_http() {
  local base_url discovery_http first_result listing_http referenced_result result_http

  first_result="$1"
  base_url="http://$SITE_SMOKE_HOST:$SITE_SMOKE_PORT/$SITE_SMOKE_BASE_PATH"
  discovery_http="$_smoke_site_tmp_dir/discovery.json"
  listing_http="$_smoke_site_tmp_dir/listing.jsonl"
  result_http="$_smoke_site_tmp_dir/result.json"

  _smoke_site_log "Serving $SITE_DIR at $base_url/"
  _smoke_site_wait_for_server "$base_url"

  _smoke_site_fetch "$base_url/index.html" "$_smoke_site_tmp_dir/index.html"
  _smoke_site_fetch "$base_url/discovery.json" "$discovery_http"
  _smoke_site_check_discovery_file_from "$discovery_http" >/dev/null
  _smoke_site_log "Fetched discovery.json over HTTP"

  _smoke_site_fetch "$base_url/listing.jsonl" "$listing_http"
  if ! jq -e . "$listing_http" >/dev/null; then
    _smoke_site_die "listing.jsonl fetched over HTTP is not valid JSON lines: $base_url/listing.jsonl"
  fi
  _smoke_site_log "Fetched listing.jsonl over HTTP"

  _smoke_site_fetch "$base_url/results/$first_result" "$result_http"
  if ! jq -e . "$result_http" >/dev/null; then
    _smoke_site_die "result entry fetched over HTTP is not valid JSON: $base_url/results/$first_result"
  fi
  _smoke_site_log "Fetched results/$first_result over HTTP"

  referenced_result="$(_smoke_site_first_referenced_result_file "$first_result")"
  if [ -n "$referenced_result" ]; then
    _smoke_site_head "$base_url/results/$referenced_result"
    _smoke_site_log "Verified referenced result asset results/$referenced_result over HTTP"
  fi
}

main() {
  local first_result python_cmd

  _smoke_site_parse_args "$@"
  _smoke_site_require_cmd curl curl
  _smoke_site_require_cmd jq jq
  if [ -n "$SITE_SMOKE_URL" ]; then
    _smoke_site_check_remote
    return
  fi

  if ! python_cmd="$(_smoke_site_python_cmd)"; then
    _smoke_site_die "missing required tool: Python (python3 or python not found on PATH)"
  fi

  _smoke_site_validate_inputs
  first_result="$(_smoke_site_check_listing_paths)"
  _smoke_site_check_relative_sources
  _smoke_site_check_public_logs
  _smoke_site_start_server "$python_cmd"
  _smoke_site_check_http "$first_result"
  _smoke_site_log "Static site smoke test passed"
}

main "$@"
