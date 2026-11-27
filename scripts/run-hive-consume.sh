#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_run_hive_consume_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_run_hive_consume_script_dir" ] || eest_die "unable to resolve scripts directory"

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

_run_hive_consume_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _run_hive_consume_usage
        exit 0
        ;;
      *)
        _run_hive_consume_usage >&2
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_run_hive_consume_validate_inputs() {
  if [ ! -d "$EEST_DIR" ]; then
    eest_die "execution-specs checkout does not exist; run scripts/prepare-fixtures.sh first: $EEST_DIR"
  fi

  if [ ! -f "$FIXTURES_DIR/.meta/index.json" ]; then
    eest_die "fixture index does not exist; run scripts/prepare-fixtures.sh first: $FIXTURES_DIR/.meta/index.json"
  fi
}

_run_hive_consume_prepare_hive() {
  eest_require_bool RUN_HIVE_SETUP "$RUN_HIVE_SETUP"
  if eest_is_true "$RUN_HIVE_SETUP"; then
    "$_run_hive_consume_script_dir/setup-hive.sh"
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

_run_hive_consume_reset_client_results_dir() {
  HIVE_CLIENT_RESULTS_DIR="$(eest_normalize_path "$HIVE_CLIENT_RESULTS_DIR")"
  eest_guard_clean_dir HIVE_CLIENT_RESULTS_DIR "$HIVE_CLIENT_RESULTS_DIR"
  eest_log "Resetting isolated client results directory at $HIVE_CLIENT_RESULTS_DIR"
  rm -rf "$HIVE_CLIENT_RESULTS_DIR"
  mkdir -p "$HIVE_CLIENT_RESULTS_DIR"
}

_run_hive_consume_run_clients() {
  local descriptor full_name id parallelism resolved

  if ! resolved="$(eest_el_clients_resolve_descriptors)"; then
    eest_die "failed to resolve EL client descriptors"
  fi

  while IFS= read -r descriptor; do
    id="$(eest_el_clients_descriptor_field "$descriptor" '.id')"
    full_name="$(eest_el_clients_full_client_name "$descriptor")"
    parallelism="$(eest_el_clients_hive_parallelism "$descriptor")" ||
      eest_die "failed to resolve HIVE_PARALLELISM for $id"
    eest_log "Running per-client consume for $full_name"

    RUN_HIVE_SETUP=0 \
      HIVE_PARALLELISM="$parallelism" \
      HIVE_CONSUME_RESULT_DIR="$HIVE_CLIENT_RESULTS_DIR/$id" \
      HIVE_LOG_FILE="$HIVE_CLIENT_RESULTS_DIR/$id/hive-dev-$id.log" \
      "$_run_hive_consume_script_dir/run-hive-consume-client.sh" "$id"
  done < <(jq -c '.[]' <<< "$resolved")
}

main() {
  _run_hive_consume_parse_args "$@"
  eest_require_cmd jq jq
  eest_require_cmd uv uv
  _run_hive_consume_validate_inputs
  _run_hive_consume_prepare_hive
  _run_hive_consume_reset_client_results_dir
  _run_hive_consume_run_clients
  "$_run_hive_consume_script_dir/merge-hive-results.sh"

  eest_log "Per-client Hive consume runs complete"
}

main "$@"
