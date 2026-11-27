#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_run_hive_client_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_run_hive_client_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_run_hive_client_script_dir/env.sh"
# shellcheck source=scripts/lib/el-clients.sh
. "$_run_hive_client_script_dir/lib/el-clients.sh"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
HIVE_READY_ATTEMPTS="${HIVE_READY_ATTEMPTS:-600}"
HIVE_READY_SLEEP="${HIVE_READY_SLEEP:-2}"
HIVE_LOG_TAIL_LINES="${HIVE_LOG_TAIL_LINES:-400}"
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

_run_hive_client_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _run_hive_client_usage
        exit 0
        ;;
      -*)
        _run_hive_client_usage >&2
        eest_die "unknown argument: $1"
        ;;
      *)
        if [ -n "$HIVE_CONSUME_CLIENT_ID" ]; then
          _run_hive_client_usage >&2
          eest_die "CLIENT_ID was provided more than once"
        fi
        HIVE_CONSUME_CLIENT_ID="$1"
        ;;
    esac
    shift
  done

  if [ -z "$HIVE_CONSUME_CLIENT_ID" ]; then
    _run_hive_client_usage >&2
    eest_die "CLIENT_ID is required"
  fi
}

_run_hive_client_resolve_client() {
  local resolved

  eest_el_clients_validate_safe_id "$HIVE_CONSUME_CLIENT_ID" >/dev/null ||
    eest_die "invalid CLIENT_ID: $HIVE_CONSUME_CLIENT_ID"

  if ! resolved="$(eest_el_clients_resolve_descriptors_for "$HIVE_CONSUME_CLIENT_ID")"; then
    eest_die "failed to resolve EL client descriptor: $HIVE_CONSUME_CLIENT_ID"
  fi

  if [ "$(jq 'length' <<< "$resolved")" -ne 1 ]; then
    eest_die "CLIENT_ID must resolve to exactly one descriptor: $HIVE_CONSUME_CLIENT_ID"
  fi

  _run_hive_client_descriptor="$(jq -c '.[0]' <<< "$resolved")"
  _run_hive_client_full_name="$(eest_el_clients_full_client_name "$_run_hive_client_descriptor")"
  _run_hive_client_result_dir="$(eest_normalize_path "${HIVE_CONSUME_RESULT_DIR:-$HIVE_CLIENT_RESULTS_DIR/$HIVE_CONSUME_CLIENT_ID}")"
  _run_hive_client_log_file="$(eest_normalize_path "${HIVE_LOG_FILE:-$_run_hive_client_result_dir/hive-dev-$HIVE_CONSUME_CLIENT_ID.log}")"
}

_run_hive_client_validate_inputs() {
  eest_require_positive_int HIVE_READY_ATTEMPTS "$HIVE_READY_ATTEMPTS"
  eest_require_positive_int HIVE_READY_SLEEP "$HIVE_READY_SLEEP"
  eest_require_positive_int HIVE_LOG_TAIL_LINES "$HIVE_LOG_TAIL_LINES"
  eest_require_positive_int HIVE_PARALLELISM "$HIVE_PARALLELISM"

  if [ ! -d "$EEST_DIR" ]; then
    eest_die "execution-specs checkout does not exist; run scripts/prepare-fixtures.sh first: $EEST_DIR"
  fi

  if [ ! -f "$FIXTURES_DIR/.meta/index.json" ]; then
    eest_die "fixture index does not exist; run scripts/prepare-fixtures.sh first: $FIXTURES_DIR/.meta/index.json"
  fi
}

_run_hive_client_check_docker() {
  eest_require_cmd docker Docker

  if ! docker info >/dev/null 2>&1; then
    eest_die 'Docker is installed, but `docker info` failed. Start Docker and check current-user permissions.'
  fi
}

_run_hive_client_prepare_hive() {
  eest_require_bool RUN_HIVE_SETUP "$RUN_HIVE_SETUP"
  if eest_is_true "$RUN_HIVE_SETUP"; then
    EL_CLIENTS="$HIVE_CONSUME_CLIENT_ID" "$_run_hive_client_script_dir/setup-hive.sh"
  else
    eest_log "Skipping Hive setup because RUN_HIVE_SETUP=$RUN_HIVE_SETUP"
  fi

  if [ ! -x "$HIVE_DIR/hive" ]; then
    eest_die "Hive binary does not exist or is not executable: $HIVE_DIR/hive"
  fi

  if [ ! -f "$HIVE_DIR/clients-local.yaml" ]; then
    eest_die "Hive client file does not exist: $HIVE_DIR/clients-local.yaml"
  fi
}

_run_hive_client_reset_result_dir() {
  eest_guard_clean_dir HIVE_CONSUME_RESULT_DIR "$_run_hive_client_result_dir"
  eest_log "Resetting isolated Hive result directory at $_run_hive_client_result_dir"
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

  eest_die "HIVE_SIMULATOR is already reachable at $HIVE_SIMULATOR; stop the existing process or choose a different simulator port"
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
      eest_log "Stopping Hive"
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

  eest_log "Starting Hive dev server for $_run_hive_client_full_name"

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
      eest_die "unsupported HIVE_DOCKER_OUTPUT: $HIVE_DOCKER_OUTPUT (expected all, build, or none)"
      ;;
  esac

  eest_require_bool HIVE_LOG_TO_STDOUT "$HIVE_LOG_TO_STDOUT"
  if eest_is_true "$HIVE_LOG_TO_STDOUT"; then
    (
      cd "$HIVE_DIR"
      exec "${hive_args[@]}" > >(tee "$_run_hive_client_log_file") 2>&1
    ) &
  else
    (
      cd "$HIVE_DIR"
      exec "${hive_args[@]}"
    ) > "$_run_hive_client_log_file" 2>&1 &
  fi

  _run_hive_client_hive_pid="$!"
  _run_hive_client_started=1
}

_run_hive_client_wait_for_hive() {
  local attempt host port ready sim_parts

  sim_parts="$(_run_hive_client_sim_host_port)"
  host="${sim_parts% *}"
  port="${sim_parts#* }"
  ready=0

  eest_log "Waiting for HIVE_SIMULATOR at $HIVE_SIMULATOR"

  for ((attempt = 1; attempt <= HIVE_READY_ATTEMPTS; attempt++)); do
    if ! kill -0 "$_run_hive_client_hive_pid" >/dev/null 2>&1; then
      eest_die "Hive exited before the simulator became ready"
    fi

    if _run_hive_client_port_open "$host" "$port"; then
      ready=1
      break
    fi

    sleep "$HIVE_READY_SLEEP"
  done

  if [ "$ready" -ne 1 ]; then
    eest_die "Hive simulator did not become ready at $HIVE_SIMULATOR"
  fi
}

_run_hive_client_run_consume() {
  local status transport
  local -a transport_args=()
  transport="$(eest_el_clients_descriptor_field "$_run_hive_client_descriptor" '.transport')"
  case "${transport:-json-rpc-rlp}" in
    json-rpc-rlp) ;;
    rest-ssz) transport_args+=(--ssz) ;;
    *) eest_die "unsupported transport: $transport" ;;
  esac

  eest_log "Running execution-specs consume engine-witness for $_run_hive_client_full_name"

  set +e
  (
    cd "$EEST_DIR"
    uv run consume engine-witness \
      --input "$FIXTURES_DIR" \
      "${transport_args[@]}" \
      -s \
      --timing-data
  )
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    return 0
  fi

  if eest_is_true "$HIVE_CONSUME_ALLOW_FAILURE"; then
    eest_log "consume exited with status $status; continuing because HIVE_CONSUME_ALLOW_FAILURE=$HIVE_CONSUME_ALLOW_FAILURE"
    return 0
  fi

  return "$status"
}

_run_hive_client_prune_skipped_results() {
  local summary_file

  summary_file="$_run_hive_client_result_dir/.eest-prune-skipped-summary"

  eest_require_bool HIVE_PRUNE_SKIPPED "$HIVE_PRUNE_SKIPPED"
  if eest_is_true "$HIVE_PRUNE_SKIPPED"; then
    eest_require_cmd python3 Python
    eest_log "Pruning pytest-skipped Hive cases"
    python3 "$_run_hive_client_script_dir/prune-skipped-hive-results.py" \
      --summary-file "$summary_file" \
      "$_run_hive_client_result_dir"
  else
    eest_log "Keeping pytest-skipped Hive cases because HIVE_PRUNE_SKIPPED=$HIVE_PRUNE_SKIPPED"
  fi
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
      eest_log "No non-skipped result JSON remains for $_run_hive_client_full_name"
      return 0
    fi
    eest_die "client $_run_hive_client_full_name did not produce a top-level Hive result JSON in $_run_hive_client_result_dir"
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
    eest_die "result JSON is not a single-client $_run_hive_client_full_name run: $invalid_json"
  fi

  eest_log "Validated $json_count result JSON file(s) for $_run_hive_client_full_name"
}

main() {
  _run_hive_client_parse_args "$@"
  eest_require_cmd jq jq
  eest_require_cmd uv uv
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

  eest_log "Hive consume run complete for $_run_hive_client_full_name"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
