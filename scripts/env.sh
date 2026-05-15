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

EEST_REPO="${EEST_REPO:-https://github.com/jsign/execution-specs.git}"
EEST_REF="${EEST_REF:-jsign-zkevm-v0.3.4-hive}"
EEST_DIR="$(_eest_dashboard_root_path "${EEST_DIR:-execution-specs}")"

HIVE_REPO="${HIVE_REPO:-https://github.com/ethereum/hive.git}"
HIVE_REF="${HIVE_REF:-master}"
HIVE_DIR="$(_eest_dashboard_root_path "${HIVE_DIR:-hive}")"

GETH_REPO="${GETH_REPO:-https://github.com/jsign/go-ethereum.git}"
GETH_GITHUB="${GETH_GITHUB:-jsign/go-ethereum}"
GETH_REF="${GETH_REF:-zkevm-v0.3.4-hive}"
GETH_SRC_DIR="$(_eest_dashboard_root_path "${GETH_SRC_DIR:-go-ethereum-src}")"

FILLER_PATH="${FILLER_PATH:-tests/amsterdam/eip8025_optional_proofs}"
FORK="${FORK:-Amsterdam}"
FIXTURES_DIR="$(_eest_dashboard_root_path "${FIXTURES_DIR:-fixtures}")"
HIVE_RESULTS_DIR="$(_eest_dashboard_root_path "${HIVE_RESULTS_DIR:-$HIVE_DIR/workspace/logs}")"
SITE_DIR="$(_eest_dashboard_root_path "${SITE_DIR:-site}")"

export ROOT_DIR
export EEST_REPO EEST_REF EEST_DIR
export HIVE_REPO HIVE_REF HIVE_DIR
export GETH_REPO GETH_GITHUB GETH_REF GETH_SRC_DIR
export FILLER_PATH FORK FIXTURES_DIR HIVE_RESULTS_DIR SITE_DIR

eest_dashboard_print_env() {
  local name value

  for name in \
    ROOT_DIR \
    EEST_REPO EEST_REF EEST_DIR \
    HIVE_REPO HIVE_REF HIVE_DIR \
    GETH_REPO GETH_GITHUB GETH_REF GETH_SRC_DIR \
    FILLER_PATH FORK FIXTURES_DIR HIVE_RESULTS_DIR SITE_DIR
  do
    eval "value=\${$name}"
    printf '%s=%s\n' "$name" "$value"
  done
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
    go) version="$(go version 2>&1)" ;;
    uv) version="$(uv --version 2>&1)" ;;
    jq) version="$(jq --version 2>&1)" ;;
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
  _eest_dashboard_require_cmd go Go || missing=1

  if python_cmd="$(_eest_dashboard_python_cmd)"; then
    printf 'ok: Python: %s\n' "$("$python_cmd" --version 2>&1)"
  else
    printf 'error: missing required tool: Python (python3 or python not found on PATH)\n' >&2
    missing=1
  fi

  _eest_dashboard_require_cmd uv uv || missing=1
  _eest_dashboard_require_cmd jq jq || missing=1
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
    '  scripts/env.sh --check'
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
