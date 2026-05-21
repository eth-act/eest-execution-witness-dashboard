#!/usr/bin/env bash

set -Eeuo pipefail

_run_hive_client_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_run_hive_client_script_dir="$(_run_hive_client_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_run_hive_client_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_run_hive_client_script_dir/env.sh"
# shellcheck source=scripts/lib/el-clients.sh
. "$_run_hive_client_script_dir/lib/el-clients.sh"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
HIVE_READY_ATTEMPTS="${HIVE_READY_ATTEMPTS:-600}"
HIVE_READY_SLEEP="${HIVE_READY_SLEEP:-2}"
HIVE_LOG_TAIL_LINES="${HIVE_LOG_TAIL_LINES:-400}"
HIVE_CONSUME_ALLOW_FAILURE="${HIVE_CONSUME_ALLOW_FAILURE:-1}"
HIVE_DOCKER_OUTPUT="${HIVE_DOCKER_OUTPUT:-all}"
HIVE_LOG_TO_STDOUT="${HIVE_LOG_TO_STDOUT:-1}"
HIVE_PRUNE_SKIPPED="${HIVE_PRUNE_SKIPPED:-1}"
RUN_HIVE_SETUP="${RUN_HIVE_SETUP:-1}"
HIVE_CONSUME_CLIENT_ID="${HIVE_CONSUME_CLIENT_ID:-}"
export UV_CACHE_DIR HIVE_SIMULATOR HIVE_PARALLELISM

_run_hive_client_hive_pid=""
_run_hive_client_started=0
_run_hive_client_descriptor=""
_run_hive_client_full_name=""
_run_hive_client_result_dir=""
_run_hive_client_log_file=""

_run_hive_client_usage() {
  printf '%s\n' \
    'Usage: scripts/run-hive-consume-client.sh CLIENT_ID' \
    '' \
    'Start Hive with one selected EL client and run consume engine-witness.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_DIR, HIVE_DIR, FIXTURES_DIR, HIVE_CLIENT_RESULTS_DIR, HIVE_SIMULATOR' \
    '  HIVE_REPO, HIVE_REF, EL_CLIENT_CONFIG, EL_CLIENT_OVERRIDES_JSON' \
    '' \
    'Additional overrides:' \
    '  HIVE_CONSUME_RESULT_DIR     Isolated result directory for this client.' \
    '  RUN_HIVE_SETUP             Set to 0 to skip scripts/setup-hive.sh. Default: 1' \
    '  HIVE_READY_ATTEMPTS        Number of readiness attempts. Default: 600' \
    '  HIVE_READY_SLEEP           Seconds between readiness attempts. Default: 2' \
    '  HIVE_CONSUME_ALLOW_FAILURE Continue after consume exits non-zero. Default: 1' \
    '  HIVE_DOCKER_OUTPUT         Docker output relay mode: all, build, or none. Default: build' \
    '  HIVE_LOG_TO_STDOUT         Tee Hive stdout/stderr to stdout. Default: 0' \
    '  HIVE_PRUNE_SKIPPED         Remove pytest-skipped Hive cases from results. Default: 1' \
    '  HIVE_LOG_FILE              Hive stdout/stderr log path. Default: result dir hive-dev-CLIENT_ID.log' \
    '  HIVE_LOG_TAIL_LINES        Lines printed from Hive log on failure. Default: 400'
}

_run_hive_client_log() {
  printf '==> %s\n' "$*"
}

_run_hive_client_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_run_hive_client_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _run_hive_client_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_run_hive_client_require_positive_int() {
  local name value

  name="$1"
  value="$2"

  case "$value" in
    '' | *[!0-9]*)
      _run_hive_client_die "$name must be a positive integer: $value"
      ;;
    0)
      _run_hive_client_die "$name must be greater than zero"
      ;;
  esac
}

_run_hive_client_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _run_hive_client_usage
        exit 0
        ;;
      -*)
        _run_hive_client_usage >&2
        _run_hive_client_die "unknown argument: $1"
        ;;
      *)
        if [ -n "$HIVE_CONSUME_CLIENT_ID" ]; then
          _run_hive_client_usage >&2
          _run_hive_client_die "CLIENT_ID was provided more than once"
        fi
        HIVE_CONSUME_CLIENT_ID="$1"
        ;;
    esac
    shift
  done

  if [ -z "$HIVE_CONSUME_CLIENT_ID" ]; then
    _run_hive_client_usage >&2
    _run_hive_client_die "CLIENT_ID is required"
  fi
}

_run_hive_client_normalize_path() {
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
          _run_hive_client_die "path escapes filesystem root: $1"
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

_run_hive_client_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$SITE_DIR" | "$HIVE_RESULTS_DIR")
      _run_hive_client_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _run_hive_client_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_run_hive_client_resolve_client() {
  local resolved

  eest_el_clients_validate_safe_id "$HIVE_CONSUME_CLIENT_ID" >/dev/null ||
    _run_hive_client_die "invalid CLIENT_ID: $HIVE_CONSUME_CLIENT_ID"

  if ! resolved="$(eest_el_clients_resolve_descriptors_for "$HIVE_CONSUME_CLIENT_ID")"; then
    _run_hive_client_die "failed to resolve EL client descriptor: $HIVE_CONSUME_CLIENT_ID"
  fi

  if [ "$(jq 'length' <<< "$resolved")" -ne 1 ]; then
    _run_hive_client_die "CLIENT_ID must resolve to exactly one descriptor: $HIVE_CONSUME_CLIENT_ID"
  fi

  _run_hive_client_descriptor="$(jq -c '.[0]' <<< "$resolved")"
  _run_hive_client_full_name="$(eest_el_clients_full_client_name "$_run_hive_client_descriptor")"
  _run_hive_client_result_dir="$(_run_hive_client_normalize_path "${HIVE_CONSUME_RESULT_DIR:-$HIVE_CLIENT_RESULTS_DIR/$HIVE_CONSUME_CLIENT_ID}")"
  _run_hive_client_log_file="$(_run_hive_client_normalize_path "${HIVE_LOG_FILE:-$_run_hive_client_result_dir/hive-dev-$HIVE_CONSUME_CLIENT_ID.log}")"
}

_run_hive_client_validate_inputs() {
  _run_hive_client_require_positive_int HIVE_READY_ATTEMPTS "$HIVE_READY_ATTEMPTS"
  _run_hive_client_require_positive_int HIVE_READY_SLEEP "$HIVE_READY_SLEEP"
  _run_hive_client_require_positive_int HIVE_LOG_TAIL_LINES "$HIVE_LOG_TAIL_LINES"
  _run_hive_client_require_positive_int HIVE_PARALLELISM "$HIVE_PARALLELISM"

  if [ ! -d "$EEST_DIR" ]; then
    _run_hive_client_die "execution-specs checkout does not exist; run scripts/prepare-fixtures.sh first: $EEST_DIR"
  fi

  if [ ! -f "$FIXTURES_DIR/.meta/index.json" ]; then
    _run_hive_client_die "fixture index does not exist; run scripts/prepare-fixtures.sh first: $FIXTURES_DIR/.meta/index.json"
  fi
}

_run_hive_client_check_docker() {
  _run_hive_client_require_cmd docker Docker

  if ! docker info >/dev/null 2>&1; then
    _run_hive_client_die 'Docker is installed, but `docker info` failed. Start Docker and check current-user permissions.'
  fi
}

_run_hive_client_prepare_hive() {
  case "$RUN_HIVE_SETUP" in
    1 | true | yes)
      EL_CLIENTS="$HIVE_CONSUME_CLIENT_ID" "$_run_hive_client_script_dir/setup-hive.sh"
      ;;
    0 | false | no)
      _run_hive_client_log "Skipping Hive setup because RUN_HIVE_SETUP=$RUN_HIVE_SETUP"
      ;;
    *)
      _run_hive_client_die "unsupported RUN_HIVE_SETUP: $RUN_HIVE_SETUP (expected 1 or 0)"
      ;;
  esac

  if [ ! -x "$HIVE_DIR/hive" ]; then
    _run_hive_client_die "Hive binary does not exist or is not executable: $HIVE_DIR/hive"
  fi

  if [ ! -f "$HIVE_DIR/clients-local.yaml" ]; then
    _run_hive_client_die "Hive client file does not exist: $HIVE_DIR/clients-local.yaml"
  fi
}

_run_hive_client_reset_result_dir() {
  _run_hive_client_guard_clean_dir HIVE_CONSUME_RESULT_DIR "$_run_hive_client_result_dir"
  _run_hive_client_log "Resetting isolated Hive result directory at $_run_hive_client_result_dir"
  rm -rf "$_run_hive_client_result_dir"
  mkdir -p "$_run_hive_client_result_dir"
  mkdir -p "$(dirname "$_run_hive_client_log_file")"
}

_run_hive_client_sim_host_port() {
  local host_port port url

  url="${HIVE_SIMULATOR#*://}"
  host_port="${url%%/*}"
  port="${host_port##*:}"

  if [ "$host_port" = "$port" ]; then
    port=3000
  fi

  printf '%s %s\n' "${host_port%%:*}" "$port"
}

_run_hive_client_port_open() {
  local host port

  host="$1"
  port="$2"

  (: >"/dev/tcp/$host/$port") >/dev/null 2>&1
}

_run_hive_client_assert_simulator_port_free() {
  local host port sim_parts

  sim_parts="$(_run_hive_client_sim_host_port)"
  host="${sim_parts% *}"
  port="${sim_parts#* }"

  if ! _run_hive_client_port_open "$host" "$port"; then
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$port" >&2 || true
  fi

  _run_hive_client_die "HIVE_SIMULATOR is already reachable at $HIVE_SIMULATOR; stop the existing process or choose a different simulator port"
}

_run_hive_client_print_hive_log_tail() {
  if [ -f "$_run_hive_client_log_file" ]; then
    printf '\nHive dev log tail (%s):\n' "$_run_hive_client_log_file" >&2
    tail -n "$HIVE_LOG_TAIL_LINES" "$_run_hive_client_log_file" >&2 || true
  else
    printf '\nHive dev log was not created: %s\n' "$_run_hive_client_log_file" >&2
  fi
}

_run_hive_client_cleanup() {
  local status=$?
  trap - EXIT
  set +e

  if [ -n "$_run_hive_client_hive_pid" ]; then
    if kill -0 "$_run_hive_client_hive_pid" >/dev/null 2>&1; then
      _run_hive_client_log "Stopping Hive"
      kill "$_run_hive_client_hive_pid" >/dev/null 2>&1
      wait "$_run_hive_client_hive_pid" >/dev/null 2>&1
    fi
  fi

  if [ "$status" -ne 0 ] && [ "$_run_hive_client_started" -eq 1 ]; then
    _run_hive_client_print_hive_log_tail
  fi

  exit "$status"
}

_run_hive_client_start_hive() {
  local -a hive_args

  _run_hive_client_log "Starting Hive dev server for $_run_hive_client_full_name"

  hive_args=(
    ./hive
    --dev
    --client-file clients-local.yaml
    --client "$_run_hive_client_full_name"
    --results-root "$_run_hive_client_result_dir"
  )

  case "$HIVE_DOCKER_OUTPUT" in
    all | 1 | true | yes)
      hive_args+=(--docker.output)
      ;;
    build | build-only | buildoutput)
      hive_args+=(--docker.buildoutput)
      ;;
    none | 0 | false | no)
      ;;
    *)
      _run_hive_client_die "unsupported HIVE_DOCKER_OUTPUT: $HIVE_DOCKER_OUTPUT (expected all, build, or none)"
      ;;
  esac

  case "$HIVE_LOG_TO_STDOUT" in
    1 | true | yes)
      (
        cd "$HIVE_DIR"
        exec "${hive_args[@]}" > >(tee "$_run_hive_client_log_file") 2>&1
      ) &
      ;;
    0 | false | no)
      (
        cd "$HIVE_DIR"
        exec "${hive_args[@]}"
      ) > "$_run_hive_client_log_file" 2>&1 &
      ;;
    *)
      _run_hive_client_die "unsupported HIVE_LOG_TO_STDOUT: $HIVE_LOG_TO_STDOUT (expected 1 or 0)"
      ;;
  esac

  _run_hive_client_hive_pid="$!"
  _run_hive_client_started=1
}

_run_hive_client_wait_for_hive() {
  local attempt host port ready sim_parts

  sim_parts="$(_run_hive_client_sim_host_port)"
  host="${sim_parts% *}"
  port="${sim_parts#* }"
  ready=0

  _run_hive_client_log "Waiting for HIVE_SIMULATOR at $HIVE_SIMULATOR"

  for ((attempt = 1; attempt <= HIVE_READY_ATTEMPTS; attempt++)); do
    if ! kill -0 "$_run_hive_client_hive_pid" >/dev/null 2>&1; then
      _run_hive_client_die "Hive exited before the simulator became ready"
    fi

    if _run_hive_client_port_open "$host" "$port"; then
      ready=1
      break
    fi

    sleep "$HIVE_READY_SLEEP"
  done

  if [ "$ready" -ne 1 ]; then
    _run_hive_client_die "Hive simulator did not become ready at $HIVE_SIMULATOR"
  fi
}

_run_hive_client_run_consume() {
  local status

  _run_hive_client_log "Running execution-specs consume engine-witness for $_run_hive_client_full_name"

  set +e
  (
    cd "$EEST_DIR"
    uv run consume engine-witness \
      --input "$FIXTURES_DIR" \
      -s \
      --timing-data
  )
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    return 0
  fi

  case "$HIVE_CONSUME_ALLOW_FAILURE" in
    1 | true | yes)
      _run_hive_client_log "consume exited with status $status; continuing because HIVE_CONSUME_ALLOW_FAILURE=$HIVE_CONSUME_ALLOW_FAILURE"
      return 0
      ;;
  esac

  return "$status"
}

_run_hive_client_prune_skipped_results() {
  local summary_file

  summary_file="$_run_hive_client_result_dir/.eest-prune-skipped-summary"

  case "$HIVE_PRUNE_SKIPPED" in
    1 | true | yes)
      _run_hive_client_require_cmd python3 Python
      _run_hive_client_log "Pruning pytest-skipped Hive cases"
      python3 "$_run_hive_client_script_dir/prune-skipped-hive-results.py" \
        --summary-file "$summary_file" \
        "$_run_hive_client_result_dir"
      ;;
    0 | false | no)
      _run_hive_client_log "Keeping pytest-skipped Hive cases because HIVE_PRUNE_SKIPPED=$HIVE_PRUNE_SKIPPED"
      ;;
    *)
      _run_hive_client_die "unsupported HIVE_PRUNE_SKIPPED: $HIVE_PRUNE_SKIPPED (expected 1 or 0)"
      ;;
  esac
}

_run_hive_client_all_results_pruned() {
  local summary_file

  summary_file="$_run_hive_client_result_dir/.eest-prune-skipped-summary"
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

_run_hive_client_validate_results() {
  local first_json invalid_json json_count

  first_json="$(find "$_run_hive_client_result_dir" -maxdepth 1 -type f -name '*.json' -print -quit)"
  if [ -z "$first_json" ]; then
    if _run_hive_client_all_results_pruned; then
      _run_hive_client_log "No non-skipped result JSON remains for $_run_hive_client_full_name"
      return 0
    fi
    _run_hive_client_die "client $_run_hive_client_full_name did not produce a top-level Hive result JSON in $_run_hive_client_result_dir"
  fi

  json_count="$(find "$_run_hive_client_result_dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')"
  invalid_json="$(
    find "$_run_hive_client_result_dir" -maxdepth 1 -type f -name '*.json' -print0 |
      while IFS= read -r -d '' result_json; do
        if ! jq -e --arg client "$_run_hive_client_full_name" '
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
    _run_hive_client_die "result JSON is not a single-client $_run_hive_client_full_name run: $invalid_json"
  fi

  _run_hive_client_log "Validated $json_count result JSON file(s) for $_run_hive_client_full_name"
}

main() {
  _run_hive_client_parse_args "$@"
  _run_hive_client_require_cmd jq jq
  _run_hive_client_require_cmd uv uv
  _run_hive_client_resolve_client
  _run_hive_client_check_docker
  _run_hive_client_validate_inputs
  _run_hive_client_prepare_hive
  _run_hive_client_reset_result_dir

  trap _run_hive_client_cleanup EXIT
  _run_hive_client_assert_simulator_port_free
  _run_hive_client_start_hive
  _run_hive_client_wait_for_hive
  _run_hive_client_run_consume
  _run_hive_client_prune_skipped_results
  _run_hive_client_validate_results

  _run_hive_client_log "Hive consume run complete for $_run_hive_client_full_name"
}

main "$@"
