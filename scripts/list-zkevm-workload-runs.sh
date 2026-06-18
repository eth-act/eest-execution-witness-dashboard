#!/usr/bin/env bash

set -Eeuo pipefail

_list_zkevm_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_list_zkevm_script_dir="$(_list_zkevm_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_list_zkevm_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_list_zkevm_script_dir/env.sh"

_list_zkevm_usage() {
  printf '%s\n' \
    'Usage: scripts/list-zkevm-workload-runs.sh [--json | --github-matrix]' \
    '' \
    'Resolve the selected zkevm-benchmark-workload execution-client/zkVM runs.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  ZKEVM_WORKLOAD_EXECUTION_CLIENTS, ZKEVM_WORKLOAD_ZKVMS' \
    '  EL_GUEST_CONFIG'
}

_list_zkevm_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_list_zkevm_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _list_zkevm_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_list_zkevm_runs_json() {
  if [ ! -f "$EL_GUEST_CONFIG" ]; then
    _list_zkevm_die "EL guest descriptor file does not exist: $EL_GUEST_CONFIG"
  fi

  jq -c \
    --arg clients "$ZKEVM_WORKLOAD_EXECUTION_CLIENTS" \
    --arg zkvms "$ZKEVM_WORKLOAD_ZKVMS" '
      def trim: gsub("^\\s+|\\s+$"; "");
      def split_csv($value):
        ($value | trim) as $trimmed
        | ($trimmed | ascii_downcase) as $normalized
        | if $normalized == "none" or $normalized == "skip" or $normalized == "empty" then
            []
          else
            $value | split(",") | map(trim) | map(select(length > 0))
          end;
      def require_non_empty($label; $values):
        if ($values | length) == 0 then
          error("\($label) must select at least one value")
        else
          $values
        end;
      def require_unique($label; $values):
        if ($values | length) != ($values | unique | length) then
          error("\($label) contains duplicate values")
        else
          $values
        end;
      def require_safe($label; $values):
        if all($values[]; test("^[A-Za-z0-9_.-]+$")) then
          $values
        else
          error("\($label) values may contain only letters, numbers, dots, underscores, or hyphens")
        end;
      def require_guest_config:
        if (.guests | type) != "object" then
          error("EL_GUEST_CONFIG must contain a guests object")
        else
          .
        end;
      def guest_descriptor($client):
        .guests[$client] // error("unknown EL guest id: \($client)");
      def guest_artifact_base_url($client; $zkvm):
        guest_descriptor($client) as $guest
        | (($guest.zkvms[$zkvm].guest_artifact_base_url // $guest.guest_artifact_base_url // "") | tostring);
      def require_guest_artifact_base_url($client; $zkvm):
        guest_descriptor($client) as $guest
        | guest_artifact_base_url($client; $zkvm) as $url
        | if (($guest.requires_guest_artifact_base_url // false) == true) and ($url | length) == 0 then
            error("EL guest descriptor \($client) requires guest_artifact_base_url for zkVM \($zkvm)")
          else
            $url
          end;

      require_guest_config as $config
      | (split_csv($clients) | require_unique("ZKEVM_WORKLOAD_EXECUTION_CLIENTS"; .) | require_safe("ZKEVM_WORKLOAD_EXECUTION_CLIENTS"; .)) as $clients
      | if ($clients | length) == 0 then
          []
        else
          (split_csv($zkvms) | require_non_empty("ZKEVM_WORKLOAD_ZKVMS"; .) | require_unique("ZKEVM_WORKLOAD_ZKVMS"; .) | require_safe("ZKEVM_WORKLOAD_ZKVMS"; .)) as $zkvms
          | [
              $clients[] as $client
              | $config | guest_descriptor($client) as $guest
              | $zkvms[] as $zkvm
              | {
                  execution_client: $client,
                  zkvm: $zkvm,
                  guest_artifact_base_url: ($config | require_guest_artifact_base_url($client; $zkvm)),
                  artifact: ("zkevm-metrics-" + $client + "-" + $zkvm)
                }
            ]
        end
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
        _list_zkevm_die "unknown argument: $1"
        ;;
    esac
    shift
  done

  _list_zkevm_require_cmd jq jq
  runs="$(_list_zkevm_runs_json)"

  case "$mode" in
    json)
      printf '%s\n' "$runs"
      ;;
    github-matrix)
      jq -c '{include: .}' <<< "$runs"
      ;;
    table)
      jq -r '.[] | [.execution_client, .zkvm, .artifact] | @tsv' <<< "$runs"
      ;;
  esac
}

main "$@"
