#!/usr/bin/env bash

# Shared local/CI defaults for the execution witness dashboard scripts.
# Source this file from bash/zsh, or execute it with --print / --check.

_eest_dashboard_is_sourced() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
      *:file:*) return 0 ;;
      *) return 1 ;;
    esac
  fi

  if [ -n "${BASH_VERSION:-}" ]; then
    [ "${BASH_SOURCE[0]}" != "$0" ]
    return
  fi

  return 1
}

_eest_dashboard_source_path() {
  if [ -n "${BASH_VERSION:-}" ]; then
    printf '%s\n' "${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    printf '%s\n' "${(%):-%x}"
  else
    printf '%s\n' "$0"
  fi
}

_eest_dashboard_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_eest_dashboard_script_dir="$(_eest_dashboard_abs_dir "$(dirname "$(_eest_dashboard_source_path)")")"
if [ -z "$_eest_dashboard_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  if _eest_dashboard_is_sourced; then return 1; else exit 1; fi
fi

_eest_dashboard_default_root="$(_eest_dashboard_abs_dir "$_eest_dashboard_script_dir/..")"
if [ -z "$_eest_dashboard_default_root" ]; then
  printf 'error: unable to resolve dashboard repository root\n' >&2
  if _eest_dashboard_is_sourced; then return 1; else exit 1; fi
fi

ROOT_DIR="${ROOT_DIR:-$_eest_dashboard_default_root}"
_eest_dashboard_requested_root="$ROOT_DIR"
ROOT_DIR="$(_eest_dashboard_abs_dir "$ROOT_DIR")"
if [ -z "$ROOT_DIR" ]; then
  printf 'error: ROOT_DIR does not exist: %s\n' "$_eest_dashboard_requested_root" >&2
  if _eest_dashboard_is_sourced; then return 1; else exit 1; fi
fi

_eest_dashboard_root_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
  esac
}

_eest_dashboard_github_slug() {
  local owner repo repo_name slug

  repo="$1"
  case "$repo" in
    https://github.com/*)
      slug="${repo#https://github.com/}"
      ;;
    git@github.com:*)
      slug="${repo#git@github.com:}"
      ;;
    github.com:*)
      slug="${repo#github.com:}"
      ;;
    github.com/*)
      slug="${repo#github.com/}"
      ;;
    *)
      return 1
      ;;
  esac

  slug="${slug%%#*}"
  slug="${slug%%\?*}"
  owner="${slug%%/*}"
  repo_name="${slug#*/}"
  repo_name="${repo_name%%/*}"
  repo_name="${repo_name%.git}"

  if [ -z "$owner" ] || [ -z "$repo_name" ] || [ "$owner" = "$repo_name" ]; then
    return 1
  fi

  printf '%s/%s\n' "$owner" "$repo_name"
}

if [ -z "${EEST_RELEASE_TAG+x}" ]; then
  EEST_RELEASE_TAG=""
fi
if [ -z "${EEST_REPO+x}" ]; then
  EEST_REPO="https://github.com/ethereum/execution-specs.git"
fi
if [ -z "${EEST_REF+x}" ]; then
  EEST_REF="projects/zkevm-releases"
fi
if [ -n "$EEST_RELEASE_TAG" ]; then
  # workflow_dispatch text inputs with defaults can arrive populated even when
  # users clear them in the UI. Release mode is selected solely by the tag.
  EEST_REPO=""
  EEST_REF=""
fi
EEST_DIR="$(_eest_dashboard_root_path "${EEST_DIR:-execution-specs}")"
FILLER_PATH="${FILLER_PATH:-tests/amsterdam/eip8025_optional_proofs}"
FORK="${FORK:-Amsterdam}"

HIVE_REPO="${HIVE_REPO:-https://github.com/ethereum/hive.git}"
HIVE_REF="${HIVE_REF:-master}"
HIVE_DIR="$(_eest_dashboard_root_path "${HIVE_DIR:-hive}")"
HIVE_UI_REPO="${HIVE_UI_REPO:-https://github.com/ethpandaops/hive-ui.git}"
HIVE_UI_REF="${HIVE_UI_REF:-b5441f735366a4f7d13575a020ccd6517d7ecaf3}"
HIVE_UI_DIR="$(_eest_dashboard_root_path "${HIVE_UI_DIR:-hive-ui}")"
HIVE_UI_DISCOVERY_NAME="${HIVE_UI_DISCOVERY_NAME:-zkEVM}"

ZKEVM_BENCHMARK_WORKLOAD_REPO="${ZKEVM_BENCHMARK_WORKLOAD_REPO:-https://github.com/eth-act/zkevm-benchmark-workload.git}"
ZKEVM_BENCHMARK_WORKLOAD_REF="${ZKEVM_BENCHMARK_WORKLOAD_REF:-master}"
ZKEVM_BENCHMARK_WORKLOAD_DIR="$(_eest_dashboard_root_path "${ZKEVM_BENCHMARK_WORKLOAD_DIR:-zkevm-benchmark-workload}")"
if [ -z "${ZKEVM_WORKLOAD_EXECUTION_CLIENTS+x}" ]; then
  ZKEVM_WORKLOAD_EXECUTION_CLIENTS="ethrex,reth"
fi
if [ -z "${ZKEVM_WORKLOAD_ZKVMS+x}" ]; then
  ZKEVM_WORKLOAD_ZKVMS="zisk"
fi
ZKEVM_RAYON_THREADS="${ZKEVM_RAYON_THREADS:-10}"
ZKEVM_WORKLOAD_EXECUTION_CLIENT="${ZKEVM_WORKLOAD_EXECUTION_CLIENT:-}"
ZKEVM_WORKLOAD_ZKVM="${ZKEVM_WORKLOAD_ZKVM:-}"
ZKEVM_METRICS_DIR="$(_eest_dashboard_root_path "${ZKEVM_METRICS_DIR:-zkevm-metrics}")"

EL_CLIENT_CONFIG="$(_eest_dashboard_root_path "${EL_CLIENT_CONFIG:-config/el-clients.json}")"
EL_CLIENTS="${EL_CLIENTS:-go-ethereum,ethrex,nethermind}"
if [ -z "${EL_CLIENT_OVERRIDES_JSON+x}" ] || [ -z "$EL_CLIENT_OVERRIDES_JSON" ]; then
  EL_CLIENT_OVERRIDES_JSON="{}"
fi

FIXTURES_DIR="$(_eest_dashboard_root_path "${FIXTURES_DIR:-fixtures}")"
HIVE_RESULTS_DIR="$(_eest_dashboard_root_path "${HIVE_RESULTS_DIR:-$HIVE_DIR/workspace/logs}")"
HIVE_CLIENT_RESULTS_DIR="$(_eest_dashboard_root_path "${HIVE_CLIENT_RESULTS_DIR:-$HIVE_DIR/workspace/client-results}")"
HIVE_SIMULATOR="${HIVE_SIMULATOR:-http://127.0.0.1:3000}"
HIVE_PARALLELISM="${HIVE_PARALLELISM:-1}"
HIVE_CONSUME_ALLOW_FAILURE="${HIVE_CONSUME_ALLOW_FAILURE:-1}"
HIVE_DOCKER_OUTPUT="${HIVE_DOCKER_OUTPUT:-build}"
HIVE_LOG_TO_STDOUT="${HIVE_LOG_TO_STDOUT:-0}"
SITE_DIR="$(_eest_dashboard_root_path "${SITE_DIR:-site}")"
SITE_MAX_SIZE_MB="${SITE_MAX_SIZE_MB:-900}"

export ROOT_DIR
export EEST_REPO EEST_REF EEST_RELEASE_TAG EEST_DIR
export HIVE_REPO HIVE_REF HIVE_DIR
export HIVE_UI_REPO HIVE_UI_REF HIVE_UI_DIR HIVE_UI_DISCOVERY_NAME
export ZKEVM_BENCHMARK_WORKLOAD_REPO ZKEVM_BENCHMARK_WORKLOAD_REF ZKEVM_BENCHMARK_WORKLOAD_DIR
export ZKEVM_WORKLOAD_EXECUTION_CLIENTS ZKEVM_WORKLOAD_ZKVMS ZKEVM_RAYON_THREADS
export ZKEVM_WORKLOAD_EXECUTION_CLIENT ZKEVM_WORKLOAD_ZKVM ZKEVM_METRICS_DIR
export EL_CLIENT_CONFIG EL_CLIENTS EL_CLIENT_OVERRIDES_JSON
export FILLER_PATH FORK FIXTURES_DIR HIVE_RESULTS_DIR HIVE_CLIENT_RESULTS_DIR HIVE_SIMULATOR HIVE_PARALLELISM HIVE_CONSUME_ALLOW_FAILURE HIVE_DOCKER_OUTPUT HIVE_LOG_TO_STDOUT SITE_DIR SITE_MAX_SIZE_MB

eest_dashboard_print_env() {
  local name value

  for name in \
    ROOT_DIR \
    EEST_REPO EEST_REF EEST_RELEASE_TAG EEST_DIR \
    HIVE_REPO HIVE_REF HIVE_DIR \
    HIVE_UI_REPO HIVE_UI_REF HIVE_UI_DIR HIVE_UI_DISCOVERY_NAME \
    ZKEVM_BENCHMARK_WORKLOAD_REPO ZKEVM_BENCHMARK_WORKLOAD_REF ZKEVM_BENCHMARK_WORKLOAD_DIR \
    ZKEVM_WORKLOAD_EXECUTION_CLIENTS ZKEVM_WORKLOAD_ZKVMS ZKEVM_RAYON_THREADS \
    ZKEVM_WORKLOAD_EXECUTION_CLIENT ZKEVM_WORKLOAD_ZKVM ZKEVM_METRICS_DIR \
    EL_CLIENT_CONFIG EL_CLIENTS EL_CLIENT_OVERRIDES_JSON \
    FILLER_PATH FORK FIXTURES_DIR HIVE_RESULTS_DIR HIVE_CLIENT_RESULTS_DIR HIVE_SIMULATOR HIVE_PARALLELISM HIVE_CONSUME_ALLOW_FAILURE HIVE_DOCKER_OUTPUT HIVE_LOG_TO_STDOUT SITE_DIR SITE_MAX_SIZE_MB
  do
    eval "value=\${$name}"
    printf '%s=%s\n' "$name" "$value"
  done
}

eest_dashboard_eest_source_mode() {
  if [ -n "$EEST_RELEASE_TAG" ]; then
    printf '%s\n' release
  else
    printf '%s\n' fill
  fi
}

eest_dashboard_validate_eest_source() {
  if [ -n "$EEST_RELEASE_TAG" ]; then
    return 0
  fi

  if [ -z "$EEST_REPO" ] || [ -z "$EEST_REF" ]; then
    printf '%s\n' \
      'error: EEST_RELEASE_TAG is empty, so EEST_REPO and EEST_REF must both be set.' \
      '       Set eest_repo/eest_ref for fill mode, or set eest_release_tag for release mode.' >&2
    return 1
  fi

  return 0
}

_eest_dashboard_require_cmd() {
  local cmd label version

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'error: missing required tool: %s (%s not found on PATH)\n' "$label" "$cmd" >&2
    return 1
  fi

  case "$cmd" in
    docker) version="$(docker --version 2>&1)" ;;
    cargo) version="$(cargo --version 2>&1)" ;;
    git) version="$(git --version 2>&1)" ;;
    go) version="$(go version 2>&1)" ;;
    node) version="$(node --version 2>&1)" ;;
    npm) version="$(npm --version 2>&1)" ;;
    uv) version="$(uv --version 2>&1)" ;;
    jq) version="$(jq --version 2>&1)" ;;
    curl) version="$(curl --version 2>&1 | sed -n '1p')" ;;
    rsync) version="$(rsync --version 2>&1 | sed -n '1p')" ;;
    *) version="$cmd found" ;;
  esac

  printf 'ok: %s: %s\n' "$label" "$version"
}

_eest_dashboard_python_cmd() {
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

eest_dashboard_check_prereqs() {
  local missing python_cmd

  missing=0

  _eest_dashboard_require_cmd docker Docker || missing=1
  _eest_dashboard_require_cmd cargo Cargo || missing=1
  _eest_dashboard_require_cmd git Git || missing=1
  _eest_dashboard_require_cmd go Go || missing=1
  _eest_dashboard_require_cmd node Node.js || missing=1
  _eest_dashboard_require_cmd npm npm || missing=1

  if python_cmd="$(_eest_dashboard_python_cmd)"; then
    printf 'ok: Python: %s\n' "$("$python_cmd" --version 2>&1)"
  else
    printf 'error: missing required tool: Python (python3 or python not found on PATH)\n' >&2
    missing=1
  fi

  _eest_dashboard_require_cmd uv uv || missing=1
  _eest_dashboard_require_cmd jq jq || missing=1
  _eest_dashboard_require_cmd curl curl || missing=1
  _eest_dashboard_require_cmd rsync rsync || missing=1

  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
      printf 'ok: Docker daemon is reachable\n'
    else
      printf 'error: Docker is installed, but `docker info` failed. Start Docker and check current-user permissions.\n' >&2
      missing=1
    fi
  fi

  if [ "$missing" -ne 0 ]; then
    return 1
  fi

  printf 'All prerequisites found.\n'
}

_eest_dashboard_usage() {
  printf '%s\n' \
    'Usage:' \
    '  source scripts/env.sh' \
    '  eest_dashboard_print_env' \
    '  eest_dashboard_check_prereqs' \
    '' \
    '  scripts/env.sh --print' \
    '  scripts/env.sh --check' \
    '  scripts/env.sh --validate-eest-source'
}

if ! _eest_dashboard_is_sourced; then
  case "${1:-}" in
    '' | --print)
      eest_dashboard_print_env
      exit $?
      ;;
    --check)
      eest_dashboard_check_prereqs
      exit $?
      ;;
    --validate-eest-source)
      eest_dashboard_validate_eest_source
      exit $?
      ;;
    --help | -h)
      _eest_dashboard_usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n\n' "$1" >&2
      _eest_dashboard_usage >&2
      exit 2
      ;;
  esac
fi

unset _eest_dashboard_default_root
unset _eest_dashboard_requested_root
unset _eest_dashboard_script_dir
