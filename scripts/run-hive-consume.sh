#!/usr/bin/env bash

set -Eeuo pipefail

_run_hive_consume_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_run_hive_consume_script_dir="$(_run_hive_consume_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_run_hive_consume_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_run_hive_consume_script_dir/env.sh"

UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
HIVE_READY_ATTEMPTS="${HIVE_READY_ATTEMPTS:-600}"
HIVE_READY_SLEEP="${HIVE_READY_SLEEP:-2}"
HIVE_LOG_TAIL_LINES="${HIVE_LOG_TAIL_LINES:-400}"
HIVE_CONSUME_ALLOW_FAILURE="${HIVE_CONSUME_ALLOW_FAILURE:-0}"
HIVE_DOCKER_OUTPUT="${HIVE_DOCKER_OUTPUT:-all}"
HIVE_LOG_TO_STDOUT="${HIVE_LOG_TO_STDOUT:-1}"
RUN_HIVE_SETUP="${RUN_HIVE_SETUP:-1}"
HIVE_LOG_FILE="${HIVE_LOG_FILE:-$HIVE_RESULTS_DIR/hive-dev.log}"
export UV_CACHE_DIR HIVE_SIMULATOR HIVE_PARALLELISM

_run_hive_consume_hive_pid=""
_run_hive_consume_started=0

_run_hive_consume_usage() {
  printf '%s\n' \
    'Usage: scripts/run-hive-consume.sh' \
    '' \
    'Prepare Hive, start ./hive --dev, wait for HIVE_SIMULATOR, and run' \
    'uv run consume engine-witness against FIXTURES_DIR.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_DIR, HIVE_DIR, FIXTURES_DIR, HIVE_RESULTS_DIR, HIVE_SIMULATOR' \
    '  HIVE_PARALLELISM' \
    '  HIVE_REPO, HIVE_REF, EL_CLIENTS, EL_CLIENT_OVERRIDES_JSON' \
    '' \
    'Additional overrides:' \
    '  RUN_HIVE_SETUP             Set to 0 to skip scripts/setup-hive.sh. Default: 1' \
    '  HIVE_READY_ATTEMPTS        Number of readiness attempts. Default: 600' \
    '  HIVE_READY_SLEEP           Seconds between readiness attempts. Default: 2' \
    '  HIVE_CONSUME_ALLOW_FAILURE Continue after consume exits non-zero. Default: 0' \
    '  HIVE_DOCKER_OUTPUT         Docker output relay mode: all, build, or none. Default: all' \
    '  HIVE_LOG_TO_STDOUT         Tee Hive stdout/stderr to stdout. Default: 1' \
    '  HIVE_LOG_FILE              Hive stdout/stderr log path. Default: HIVE_RESULTS_DIR/hive-dev.log' \
    '  HIVE_LOG_TAIL_LINES        Lines printed from Hive log on failure. Default: 400'
}

_run_hive_consume_log() {
  printf '==> %s\n' "$*"
}

_run_hive_consume_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_run_hive_consume_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _run_hive_consume_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_run_hive_consume_require_positive_int() {
  local name value

  name="$1"
  value="$2"

  case "$value" in
    '' | *[!0-9]*)
      _run_hive_consume_die "$name must be a positive integer: $value"
      ;;
    0)
      _run_hive_consume_die "$name must be greater than zero"
      ;;
  esac
}

_run_hive_consume_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _run_hive_consume_usage
        exit 0
        ;;
      *)
        _run_hive_consume_usage >&2
        _run_hive_consume_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_run_hive_consume_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$SITE_DIR")
      _run_hive_consume_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _run_hive_consume_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_run_hive_consume_sim_host_port() {
  local host_port port url

  url="${HIVE_SIMULATOR#*://}"
  host_port="${url%%/*}"
  port="${host_port##*:}"

  if [ "$host_port" = "$port" ]; then
    port=3000
  fi

  printf '%s %s\n' "${host_port%%:*}" "$port"
}

_run_hive_consume_port_open() {
  local host port

  host="$1"
  port="$2"

  (: >"/dev/tcp/$host/$port") >/dev/null 2>&1
}

_run_hive_consume_print_hive_log_tail() {
  if [ -f "$HIVE_LOG_FILE" ]; then
    printf '\nHive dev log tail (%s):\n' "$HIVE_LOG_FILE" >&2
    tail -n "$HIVE_LOG_TAIL_LINES" "$HIVE_LOG_FILE" >&2 || true
  else
    printf '\nHive dev log was not created: %s\n' "$HIVE_LOG_FILE" >&2
  fi
}

_run_hive_consume_cleanup() {
  local status=$?
  trap - EXIT
  set +e

  if [ -n "$_run_hive_consume_hive_pid" ]; then
    if kill -0 "$_run_hive_consume_hive_pid" >/dev/null 2>&1; then
      _run_hive_consume_log "Stopping Hive"
      kill "$_run_hive_consume_hive_pid" >/dev/null 2>&1
      wait "$_run_hive_consume_hive_pid" >/dev/null 2>&1
    fi
  fi

  if [ "$status" -ne 0 ] && [ "$_run_hive_consume_started" -eq 1 ]; then
    _run_hive_consume_print_hive_log_tail
  fi

  exit "$status"
}

_run_hive_consume_validate_inputs() {
  _run_hive_consume_require_positive_int HIVE_READY_ATTEMPTS "$HIVE_READY_ATTEMPTS"
  _run_hive_consume_require_positive_int HIVE_READY_SLEEP "$HIVE_READY_SLEEP"
  _run_hive_consume_require_positive_int HIVE_LOG_TAIL_LINES "$HIVE_LOG_TAIL_LINES"
  _run_hive_consume_require_positive_int HIVE_PARALLELISM "$HIVE_PARALLELISM"

  if [ ! -d "$EEST_DIR" ]; then
    _run_hive_consume_die "execution-specs checkout does not exist; run scripts/fill-fixtures.sh first: $EEST_DIR"
  fi

  if [ ! -f "$FIXTURES_DIR/.meta/index.json" ]; then
    _run_hive_consume_die "fixture index does not exist; run scripts/fill-fixtures.sh first: $FIXTURES_DIR/.meta/index.json"
  fi
}

_run_hive_consume_check_docker() {
  _run_hive_consume_require_cmd docker Docker

  if ! docker info >/dev/null 2>&1; then
    _run_hive_consume_die 'Docker is installed, but `docker info` failed. Start Docker and check current-user permissions.'
  fi
}

_run_hive_consume_prepare_hive() {
  case "$RUN_HIVE_SETUP" in
    1 | true | yes)
      "$_run_hive_consume_script_dir/setup-hive.sh"
      ;;
    0 | false | no)
      _run_hive_consume_log "Skipping Hive setup because RUN_HIVE_SETUP=$RUN_HIVE_SETUP"
      ;;
    *)
      _run_hive_consume_die "unsupported RUN_HIVE_SETUP: $RUN_HIVE_SETUP (expected 1 or 0)"
      ;;
  esac

  if [ ! -x "$HIVE_DIR/hive" ]; then
    _run_hive_consume_die "Hive binary does not exist or is not executable: $HIVE_DIR/hive"
  fi

  if [ ! -f "$HIVE_DIR/clients-local.yaml" ]; then
    _run_hive_consume_die "Hive client file does not exist: $HIVE_DIR/clients-local.yaml"
  fi
}

_run_hive_consume_reset_results_dir() {
  _run_hive_consume_guard_clean_dir HIVE_RESULTS_DIR "$HIVE_RESULTS_DIR"
  _run_hive_consume_log "Resetting Hive results directory at $HIVE_RESULTS_DIR"
  rm -rf "$HIVE_RESULTS_DIR"
  mkdir -p "$HIVE_RESULTS_DIR"
  mkdir -p "$(dirname "$HIVE_LOG_FILE")"
}

_run_hive_consume_start_hive() {
  local -a hive_args

  _run_hive_consume_log "Starting Hive dev server"

  hive_args=(
    ./hive
    --dev
    --client-file clients-local.yaml
    --results-root "$HIVE_RESULTS_DIR"
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
      _run_hive_consume_die "unsupported HIVE_DOCKER_OUTPUT: $HIVE_DOCKER_OUTPUT (expected all, build, or none)"
      ;;
  esac

  case "$HIVE_LOG_TO_STDOUT" in
    1 | true | yes)
      (
        cd "$HIVE_DIR"
        "${hive_args[@]}" > >(tee "$HIVE_LOG_FILE") 2>&1
      ) &
      ;;
    0 | false | no)
      (
        cd "$HIVE_DIR"
        "${hive_args[@]}"
      ) > "$HIVE_LOG_FILE" 2>&1 &
      ;;
    *)
      _run_hive_consume_die "unsupported HIVE_LOG_TO_STDOUT: $HIVE_LOG_TO_STDOUT (expected 1 or 0)"
      ;;
  esac

  _run_hive_consume_hive_pid="$!"
  _run_hive_consume_started=1
}

_run_hive_consume_wait_for_hive() {
  local attempt host port ready sim_parts

  sim_parts="$(_run_hive_consume_sim_host_port)"
  host="${sim_parts% *}"
  port="${sim_parts#* }"
  ready=0

  _run_hive_consume_log "Waiting for HIVE_SIMULATOR at $HIVE_SIMULATOR"

  for ((attempt = 1; attempt <= HIVE_READY_ATTEMPTS; attempt++)); do
    if ! kill -0 "$_run_hive_consume_hive_pid" >/dev/null 2>&1; then
      _run_hive_consume_die "Hive exited before the simulator became ready"
    fi

    if _run_hive_consume_port_open "$host" "$port"; then
      ready=1
      break
    fi

    sleep "$HIVE_READY_SLEEP"
  done

  if [ "$ready" -ne 1 ]; then
    _run_hive_consume_die "Hive simulator did not become ready at $HIVE_SIMULATOR"
  fi
}

_run_hive_consume_run_consume() {
  local status

  _run_hive_consume_log "Running execution-specs consume engine-witness"

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
      _run_hive_consume_log "consume exited with status $status; continuing because HIVE_CONSUME_ALLOW_FAILURE=$HIVE_CONSUME_ALLOW_FAILURE"
      return 0
      ;;
  esac

  return "$status"
}

main() {
  _run_hive_consume_parse_args "$@"
  _run_hive_consume_require_cmd uv uv
  _run_hive_consume_check_docker
  _run_hive_consume_validate_inputs
  _run_hive_consume_prepare_hive
  _run_hive_consume_reset_results_dir

  trap _run_hive_consume_cleanup EXIT
  _run_hive_consume_start_hive
  _run_hive_consume_wait_for_hive
  _run_hive_consume_run_consume

  _run_hive_consume_log "Hive consume run complete"
}

main "$@"
