#!/usr/bin/env bash

set -Eeuo pipefail

_run_zkevm_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_run_zkevm_script_dir="$(_run_zkevm_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_run_zkevm_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_run_zkevm_script_dir/env.sh"

_run_zkevm_usage() {
  printf '%s\n' \
    'Usage: scripts/run-zkevm-benchmark-workload.sh [EXECUTION_CLIENT ZKVM]' \
    '' \
    'Run one zkevm-benchmark-workload stateless-validator execution benchmark.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  ZKEVM_BENCHMARK_WORKLOAD_DIR, FIXTURES_DIR, ZKEVM_METRICS_DIR' \
    '  ZKEVM_WORKLOAD_EXECUTION_CLIENT, ZKEVM_WORKLOAD_ZKVM, ZKEVM_RAYON_THREADS'
}

_run_zkevm_log() {
  printf '==> %s\n' "$*"
}

_run_zkevm_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_run_zkevm_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _run_zkevm_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_run_zkevm_require_positive_int() {
  local name value

  name="$1"
  value="$2"

  case "$value" in
    '' | *[!0-9]*)
      _run_zkevm_die "$name must be a positive integer: $value"
      ;;
    0)
      _run_zkevm_die "$name must be greater than zero"
      ;;
  esac
}

_run_zkevm_validate_component() {
  local label value

  label="$1"
  value="$2"

  case "$value" in
    '' | *[!A-Za-z0-9_.-]*)
      _run_zkevm_die "$label may contain only letters, numbers, dots, underscores, or hyphens: $value"
      ;;
  esac
}

_run_zkevm_guard_clean_dir() {
  local dir

  dir="$1"
  case "$dir" in
    '' | / | /tmp | /tmp/ | "$ROOT_DIR" | "$EEST_DIR" | "$HIVE_DIR" | "$HIVE_UI_DIR" | "$FIXTURES_DIR" | "$SITE_DIR" | "$ZKEVM_BENCHMARK_WORKLOAD_DIR")
      _run_zkevm_die "refusing to clean unsafe ZKEVM_METRICS_DIR: $dir"
      ;;
  esac

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      _run_zkevm_die "refusing to clean ZKEVM_METRICS_DIR outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

_run_zkevm_parse_args() {
  if [ "$#" -eq 1 ]; then
    case "$1" in
      --help | -h)
        _run_zkevm_usage
        exit 0
        ;;
    esac
  fi

  case "$#" in
    0)
      ;;
    2)
      ZKEVM_WORKLOAD_EXECUTION_CLIENT="$1"
      ZKEVM_WORKLOAD_ZKVM="$2"
      ;;
    *)
      _run_zkevm_usage >&2
      _run_zkevm_die "expected either no positional arguments or EXECUTION_CLIENT ZKVM"
      ;;
  esac
}

_run_zkevm_validate() {
  if [ "$ZKEVM_WORKLOAD_EXECUTION_CLIENT" != ethrex ] && [ "$ZKEVM_WORKLOAD_EXECUTION_CLIENT" != reth ]; then
    _run_zkevm_die "ZKEVM_WORKLOAD_EXECUTION_CLIENT supports only ethrex and reth: $ZKEVM_WORKLOAD_EXECUTION_CLIENT"
  fi

  _run_zkevm_validate_component ZKEVM_WORKLOAD_ZKVM "$ZKEVM_WORKLOAD_ZKVM"
  _run_zkevm_require_positive_int ZKEVM_RAYON_THREADS "$ZKEVM_RAYON_THREADS"

  if [ ! -d "$ZKEVM_BENCHMARK_WORKLOAD_DIR" ]; then
    _run_zkevm_die "ZKEVM_BENCHMARK_WORKLOAD_DIR does not exist; run scripts/setup-zkevm-benchmark-workload.sh first: $ZKEVM_BENCHMARK_WORKLOAD_DIR"
  fi
  if [ ! -f "$ZKEVM_BENCHMARK_WORKLOAD_DIR/Cargo.toml" ]; then
    _run_zkevm_die "zkevm-benchmark-workload Cargo.toml does not exist: $ZKEVM_BENCHMARK_WORKLOAD_DIR/Cargo.toml"
  fi
  if [ ! -d "$FIXTURES_DIR" ]; then
    _run_zkevm_die "FIXTURES_DIR does not exist: $FIXTURES_DIR"
  fi
  if { [ -f "$FIXTURES_DIR/.meta/index.json" ] || [ -d "$FIXTURES_DIR/blockchain_tests_engine" ]; } &&
    [ ! -d "$FIXTURES_DIR/blockchain_tests" ]; then
    _run_zkevm_die "FIXTURES_DIR is an EEST fixture bundle but does not contain blockchain_tests; zkevm-benchmark-workload requires blockchain_test fixtures"
  fi
}

_run_zkevm_prepare_output() {
  _run_zkevm_guard_clean_dir "$ZKEVM_METRICS_DIR"
  _run_zkevm_log "Resetting zkEVM metrics directory at $ZKEVM_METRICS_DIR"
  rm -rf "$ZKEVM_METRICS_DIR"
  mkdir -p "$ZKEVM_METRICS_DIR"
}

_run_zkevm_run() {
  _run_zkevm_log "Running zkevm-benchmark-workload for $ZKEVM_WORKLOAD_EXECUTION_CLIENT on $ZKEVM_WORKLOAD_ZKVM"

  (
    cd "$ZKEVM_BENCHMARK_WORKLOAD_DIR"
    RUST_LOG=info RAYON_NUM_THREADS="$ZKEVM_RAYON_THREADS" \
      cargo run --locked --release -p ere-hosts -- \
        --zkvms "$ZKEVM_WORKLOAD_ZKVM" \
        --action execute \
        --output-folder "$ZKEVM_METRICS_DIR" \
        stateless-validator \
        --execution-client "$ZKEVM_WORKLOAD_EXECUTION_CLIENT" \
        --input-folder "$FIXTURES_DIR"
  )
}

_run_zkevm_validate_output() {
  local first_metric

  first_metric="$(
    find "$ZKEVM_METRICS_DIR" \
      -mindepth 3 \
      -maxdepth 3 \
      -type f \
      -name '*.json' \
      ! -name hardware.json \
      -print \
      -quit
  )"

  if [ -z "$first_metric" ]; then
    _run_zkevm_die "zkevm-benchmark-workload did not produce any metrics JSON under $ZKEVM_METRICS_DIR"
  fi

  _run_zkevm_log "zkEVM metrics written to $ZKEVM_METRICS_DIR"
}

main() {
  _run_zkevm_parse_args "$@"
  _run_zkevm_require_cmd cargo Cargo
  _run_zkevm_require_cmd find find
  _run_zkevm_validate
  _run_zkevm_prepare_output
  _run_zkevm_run
  _run_zkevm_validate_output
}

main "$@"
