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
# shellcheck source=scripts/lib/el-clients.sh
. "$_run_hive_consume_script_dir/lib/el-clients.sh"

RUN_HIVE_SETUP="${RUN_HIVE_SETUP:-1}"

_run_hive_consume_usage() {
  printf '%s\n' \
    'Usage: scripts/run-hive-consume.sh' \
    '' \
    'Run consume engine-witness once per selected EL client, then merge' \
    'the isolated per-client Hive results into HIVE_RESULTS_DIR.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  EEST_DIR, HIVE_DIR, FIXTURES_DIR, HIVE_RESULTS_DIR, HIVE_CLIENT_RESULTS_DIR' \
    '  HIVE_REPO, HIVE_REF, EL_CLIENTS, EL_CLIENT_OVERRIDES_JSON' \
    '  HIVE_SIMULATOR, HIVE_PARALLELISM, HIVE_DOCKER_OUTPUT, HIVE_LOG_TO_STDOUT' \
    '' \
    'Additional overrides passed through to the worker:' \
    '  HIVE_READY_ATTEMPTS, HIVE_READY_SLEEP, HIVE_CONSUME_ALLOW_FAILURE' \
    '  HIVE_LOG_TAIL_LINES' \
    '  HIVE_PRUNE_SKIPPED         Remove pytest-skipped Hive cases. Default: 1' \
    '  RUN_HIVE_SETUP             Set to 0 to skip the initial setup-hive.sh. Default: 1'
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

_run_hive_consume_normalize_path() {
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
          _run_hive_consume_die "path escapes filesystem root: $1"
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

_run_hive_consume_guard_clean_dir() {
  local dir label

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$HIVE_DIR" | "$EEST_DIR" | "$FIXTURES_DIR" | "$SITE_DIR" | "$HIVE_RESULTS_DIR")
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

_run_hive_consume_validate_inputs() {
  if [ ! -d "$EEST_DIR" ]; then
    _run_hive_consume_die "execution-specs checkout does not exist; run scripts/prepare-fixtures.sh first: $EEST_DIR"
  fi

  if [ ! -f "$FIXTURES_DIR/.meta/index.json" ]; then
    _run_hive_consume_die "fixture index does not exist; run scripts/prepare-fixtures.sh first: $FIXTURES_DIR/.meta/index.json"
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

_run_hive_consume_reset_client_results_dir() {
  HIVE_CLIENT_RESULTS_DIR="$(_run_hive_consume_normalize_path "$HIVE_CLIENT_RESULTS_DIR")"
  _run_hive_consume_guard_clean_dir HIVE_CLIENT_RESULTS_DIR "$HIVE_CLIENT_RESULTS_DIR"
  _run_hive_consume_log "Resetting isolated client results directory at $HIVE_CLIENT_RESULTS_DIR"
  rm -rf "$HIVE_CLIENT_RESULTS_DIR"
  mkdir -p "$HIVE_CLIENT_RESULTS_DIR"
}

_run_hive_consume_run_clients() {
  local descriptor full_name id parallelism resolved

  if ! resolved="$(eest_el_clients_resolve_descriptors)"; then
    _run_hive_consume_die "failed to resolve EL client descriptors"
  fi

  while IFS= read -r descriptor; do
    id="$(eest_el_clients_descriptor_field "$descriptor" '.id')"
    full_name="$(eest_el_clients_full_client_name "$descriptor")"
    parallelism="$(eest_el_clients_hive_parallelism "$descriptor")" ||
      _run_hive_consume_die "failed to resolve HIVE_PARALLELISM for $id"
    _run_hive_consume_log "Running per-client consume for $full_name"

    RUN_HIVE_SETUP=0 \
      HIVE_PARALLELISM="$parallelism" \
      HIVE_CONSUME_RESULT_DIR="$HIVE_CLIENT_RESULTS_DIR/$id" \
      HIVE_LOG_FILE="$HIVE_CLIENT_RESULTS_DIR/$id/hive-dev-$id.log" \
      "$_run_hive_consume_script_dir/run-hive-consume-client.sh" "$id"
  done < <(jq -c '.[]' <<< "$resolved")
}

main() {
  _run_hive_consume_parse_args "$@"
  _run_hive_consume_require_cmd jq jq
  _run_hive_consume_require_cmd uv uv
  _run_hive_consume_validate_inputs
  _run_hive_consume_prepare_hive
  _run_hive_consume_reset_client_results_dir
  _run_hive_consume_run_clients
  "$_run_hive_consume_script_dir/merge-hive-results.sh"

  _run_hive_consume_log "Per-client Hive consume runs complete"
}

main "$@"
