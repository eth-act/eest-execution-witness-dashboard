#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

_list_zkevm_script_dir="$(eest_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
[ -n "$_list_zkevm_script_dir" ] || eest_die "unable to resolve scripts directory"

# shellcheck source=scripts/env.sh
. "$_list_zkevm_script_dir/env.sh"

_list_zkevm_usage() {
  printf '%s\n' \
    'Usage: scripts/list-zkevm-workload-runs.sh [--json | --github-matrix]' \
    '' \
    'Resolve the selected zkevm-benchmark-workload execution-client/zkVM runs.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  ZKEVM_WORKLOAD_RUNS (comma-separated CLIENT:ZKVM pairs)' \
    '  EL_GUEST_CONFIG'
}

_list_zkevm_runs_json() {
  if [ ! -f "$EL_GUEST_CONFIG" ]; then
    eest_die "EL guest descriptor file does not exist: $EL_GUEST_CONFIG"
  fi

  jq -c -L "$_list_zkevm_script_dir/lib" \
    --arg runs "$ZKEVM_WORKLOAD_RUNS" '
      include "el-guests";
      def trim: gsub("^\\s+|\\s+$"; "");
      def parse_runs($value):
        ($value | trim) as $trimmed
        | ($trimmed | ascii_downcase) as $normalized
        | if
            ($trimmed | length) == 0
            or $normalized == "none"
            or $normalized == "skip"
            or $normalized == "empty"
          then
            []
          else
            $value
            | split(",")
            | map(trim)
            | if any(.[]; length == 0) then
                error("ZKEVM_WORKLOAD_RUNS contains an empty CLIENT:ZKVM pair")
              else
                .
              end
            | map(
                . as $run
                | ($run | split(":")) as $parts
                | if ($parts | length) != 2 then
                    error("ZKEVM_WORKLOAD_RUNS entry must have CLIENT:ZKVM form: \($run)")
                  else
                    {
                      execution_client: ($parts[0] | trim),
                      zkvm: ($parts[1] | trim)
                    }
                  end
                | if (.execution_client | length) == 0 or (.zkvm | length) == 0 then
                    error("ZKEVM_WORKLOAD_RUNS entry must have non-empty CLIENT and ZKVM components: \($run)")
                  else
                    .
                  end
                | if (.execution_client | test("^[A-Za-z0-9_.-]+$")) and (.zkvm | test("^[A-Za-z0-9_.-]+$")) then
                    .
                  else
                    error("ZKEVM_WORKLOAD_RUNS components may contain only letters, numbers, dots, underscores, or hyphens: \($run)")
                  end
              )
          end;
      def require_unique_runs($runs):
        ($runs | map(.execution_client + ":" + .zkvm)) as $keys
        | if ($keys | length) != ($keys | unique | length) then
            error("ZKEVM_WORKLOAD_RUNS contains duplicate CLIENT:ZKVM pairs")
          else
            $runs
          end;
      require_guest_config as $config
      | (parse_runs($runs) | require_unique_runs(.)) as $runs
      | [
          $runs[] as $run
          | $run.execution_client as $client
          | $run.zkvm as $zkvm
          | {
              execution_client: $client,
              zkvm: $zkvm,
              guest_artifact_base_url: ($config | guest_artifact_base_url($client; $zkvm))
            }
        ]
    ' "$EL_GUEST_CONFIG"
}

main() {
  local mode runs

  mode=table
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        mode=json
        ;;
      --github-matrix)
        mode=github-matrix
        ;;
      --help | -h)
        _list_zkevm_usage
        exit 0
        ;;
      *)
        _list_zkevm_usage >&2
        eest_die "unknown argument: $1"
        ;;
    esac
    shift
  done

  eest_require_cmd jq jq
  runs="$(_list_zkevm_runs_json)"

  case "$mode" in
    json)
      printf '%s\n' "$runs"
      ;;
    github-matrix)
      jq -c '{include: .}' <<< "$runs"
      ;;
    table)
      jq -r '.[] | [.execution_client, .zkvm] | @tsv' <<< "$runs"
      ;;
  esac
}

main "$@"
