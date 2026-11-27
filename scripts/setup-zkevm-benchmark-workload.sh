#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_setup_zkevm_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_setup_zkevm_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_setup_zkevm_script_dir/env.sh"

_setup_zkevm_usage() {
  printf '%s\n' \
    'Usage: scripts/setup-zkevm-benchmark-workload.sh' \
    '' \
    'Clone or update zkevm-benchmark-workload and check out the configured ref.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  ZKEVM_BENCHMARK_WORKLOAD_REPO, ZKEVM_BENCHMARK_WORKLOAD_REF, ZKEVM_BENCHMARK_WORKLOAD_DIR'
}

_setup_zkevm_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _setup_zkevm_usage
        exit 0
        ;;
      *)
        _setup_zkevm_usage >&2
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_setup_zkevm_validate() {
  if [ -z "$ZKEVM_BENCHMARK_WORKLOAD_REPO" ]; then
    eest_die "ZKEVM_BENCHMARK_WORKLOAD_REPO must be set"
  fi
  if [ -z "$ZKEVM_BENCHMARK_WORKLOAD_REF" ]; then
    eest_die "ZKEVM_BENCHMARK_WORKLOAD_REF must be set"
  fi
}

_setup_zkevm_prepare_checkout() {
  eest_prepare_git_checkout zkevm-benchmark-workload \
    "$ZKEVM_BENCHMARK_WORKLOAD_REPO" "$ZKEVM_BENCHMARK_WORKLOAD_REF" "$ZKEVM_BENCHMARK_WORKLOAD_DIR"
}

main() {
  _setup_zkevm_parse_args "$@"
  eest_require_cmd git Git
  _setup_zkevm_validate
  _setup_zkevm_prepare_checkout
}

main "$@"
