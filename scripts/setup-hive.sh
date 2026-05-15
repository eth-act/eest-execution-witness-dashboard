#!/usr/bin/env bash

set -Eeuo pipefail

_setup_hive_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

_setup_hive_script_dir="$(_setup_hive_abs_dir "$(dirname "${BASH_SOURCE[0]}")")"
if [ -z "$_setup_hive_script_dir" ]; then
  printf 'error: unable to resolve scripts directory\n' >&2
  exit 1
fi

# shellcheck source=scripts/env.sh
. "$_setup_hive_script_dir/env.sh"

_setup_hive_client_file="$HIVE_DIR/clients-local.yaml"
_setup_hive_local_geth_path="$HIVE_DIR/clients/go-ethereum/go-ethereum"
_setup_hive_local_geth_arg="./clients/go-ethereum/go-ethereum"

_setup_hive_usage() {
  printf '%s\n' \
    'Usage: scripts/setup-hive.sh' \
    '' \
    'Clone or update Hive, build the Hive binary, and generate clients-local.yaml.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  HIVE_REPO, HIVE_REF, HIVE_DIR' \
    '  GETH_REPO, GETH_GITHUB, GETH_REF, GETH_SRC_DIR, GETH_SOURCE_MODE' \
    '  GETH_HIVE_EXTRA_FLAGS' \
    '' \
    'GETH_SOURCE_MODE values:' \
    '  auto     Use git mode for branch/tag refs and local mode for full commit SHAs. Default.' \
    '  git      Use Hive clients/go-ethereum/Dockerfile.git.' \
    '  local    Clone GETH_REPO at GETH_REF, copy it under Hive, and use Dockerfile.local.' \
    '' \
    'GETH_HIVE_EXTRA_FLAGS is injected into Hive clients/go-ethereum/geth.sh.' \
    'Default: --bal.executionmode=sequential. Set it empty to remove the managed patch.'
}

_setup_hive_log() {
  printf '==> %s\n' "$*"
}

_setup_hive_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_setup_hive_require_cmd() {
  local cmd label

  cmd="$1"
  label="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _setup_hive_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

_setup_hive_parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        _setup_hive_usage
        exit 0
        ;;
      *)
        _setup_hive_usage >&2
        _setup_hive_die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

_setup_hive_yaml_quote() {
  local value

  value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

_setup_hive_ref_is_full_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

_setup_hive_prepare_git_checkout() {
  local checkout_dir label ref repo

  label="$1"
  repo="$2"
  ref="$3"
  checkout_dir="$4"

  _setup_hive_log "Preparing $label checkout at $checkout_dir"

  if [ -d "$checkout_dir" ]; then
    if ! git -C "$checkout_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _setup_hive_die "$label directory exists but is not a git checkout: $checkout_dir"
    fi

    if git -C "$checkout_dir" remote get-url origin >/dev/null 2>&1; then
      git -C "$checkout_dir" remote set-url origin "$repo"
    else
      git -C "$checkout_dir" remote add origin "$repo"
    fi
  else
    mkdir -p "$(dirname "$checkout_dir")"
    git clone "$repo" "$checkout_dir"
  fi

  if _setup_hive_ref_is_full_sha "$ref"; then
    git -C "$checkout_dir" fetch --prune origin
    git -C "$checkout_dir" checkout --detach "$ref"
  else
    git -C "$checkout_dir" fetch --prune origin "$ref"
    git -C "$checkout_dir" checkout --detach FETCH_HEAD
  fi
}

_setup_hive_build_hive() {
  _setup_hive_log "Building Hive"
  (cd "$HIVE_DIR" && go build .)

  if [ ! -x "$HIVE_DIR/hive" ]; then
    _setup_hive_die "Hive binary was not created: $HIVE_DIR/hive"
  fi
}

_setup_hive_validate_extra_flags() {
  case "$GETH_HIVE_EXTRA_FLAGS" in
    *$'\n'* | *'"'* | *'$'* | *'`'* | *'\\'*)
      _setup_hive_die 'GETH_HIVE_EXTRA_FLAGS cannot contain newline, ", $, `, or \ characters'
      ;;
  esac
}

_setup_hive_patch_geth_flags() {
  local begin geth_script tmp

  geth_script="$HIVE_DIR/clients/go-ethereum/geth.sh"
  begin='# eest-dashboard: begin managed geth extra flags'
  tmp="${geth_script}.tmp.$$"

  if [ ! -f "$geth_script" ]; then
    _setup_hive_die "Hive go-ethereum startup script does not exist: $geth_script"
  fi

  if ! grep -Fq 'FLAGS="--state.scheme=path"' "$geth_script"; then
    _setup_hive_die "unable to find initial FLAGS assignment in $geth_script"
  fi

  _setup_hive_validate_extra_flags
  cp "$geth_script" "$tmp"

  if ! awk \
    -v begin="$begin" \
    -v end='# eest-dashboard: end managed geth extra flags' \
    -v extra="$GETH_HIVE_EXTRA_FLAGS" '
      $0 == begin {
        skip = 1
        next
      }

      skip && $0 == end {
        skip = 0
        next
      }

      skip {
        next
      }

      {
        print
        if (!inserted && $0 == "FLAGS=\"--state.scheme=path\"") {
          if (extra != "") {
            print begin
            print "FLAGS=\"$FLAGS " extra "\""
            print end
          }
          inserted = 1
        }
      }

      END {
        if (!inserted) {
          exit 1
        }
      }
    ' "$geth_script" > "$tmp"; then
    rm -f "$tmp"
    _setup_hive_die "failed to patch $geth_script"
  fi

  mv "$tmp" "$geth_script"

  if [ -n "$GETH_HIVE_EXTRA_FLAGS" ]; then
    _setup_hive_log "Injected geth extra flags: $GETH_HIVE_EXTRA_FLAGS"
  else
    _setup_hive_log "Removed managed geth extra flags patch"
  fi
}

_setup_hive_write_git_client_file() {
  local tmp

  tmp="${_setup_hive_client_file}.tmp.$$"
  _setup_hive_log "Writing git-mode client config to $_setup_hive_client_file"

  {
    printf '%s\n' '- client: go-ethereum'
    printf '%s\n' '  dockerfile: git'
    printf '%s\n' '  nametag: newpayloadwithwitness'
    printf '%s\n' '  build_args:'
    printf '    github: '
    _setup_hive_yaml_quote "$GETH_GITHUB"
    printf '\n'
    printf '    tag: '
    _setup_hive_yaml_quote "$GETH_REF"
    printf '\n'
  } > "$tmp"

  mv "$tmp" "$_setup_hive_client_file"
}

_setup_hive_prepare_local_geth() {
  _setup_hive_require_cmd rsync rsync
  _setup_hive_prepare_git_checkout go-ethereum "$GETH_REPO" "$GETH_REF" "$GETH_SRC_DIR"

  _setup_hive_log "Copying local go-ethereum source into Hive client directory"
  mkdir -p "$_setup_hive_local_geth_path"
  rsync -a --delete --exclude .git "$GETH_SRC_DIR"/ "$_setup_hive_local_geth_path"/
}

_setup_hive_write_local_client_file() {
  local tmp

  tmp="${_setup_hive_client_file}.tmp.$$"
  _setup_hive_log "Writing local-mode client config to $_setup_hive_client_file"

  {
    printf '%s\n' '- client: go-ethereum'
    printf '%s\n' '  dockerfile: local'
    printf '%s\n' '  nametag: local-newpayloadwithwitness'
    printf '%s\n' '  build_args:'
    printf '    local_path: '
    _setup_hive_yaml_quote "$_setup_hive_local_geth_arg"
    printf '\n'
  } > "$tmp"

  mv "$tmp" "$_setup_hive_client_file"
}

_setup_hive_resolved_geth_source_mode() {
  case "$GETH_SOURCE_MODE" in
    auto)
      if _setup_hive_ref_is_full_sha "$GETH_REF"; then
        printf '%s\n' local
      else
        printf '%s\n' git
      fi
      ;;
    git | local)
      printf '%s\n' "$GETH_SOURCE_MODE"
      ;;
    *)
      _setup_hive_die "unsupported GETH_SOURCE_MODE: $GETH_SOURCE_MODE (expected auto, git, or local)"
      ;;
  esac
}

_setup_hive_configure_client() {
  local source_mode

  source_mode="$(_setup_hive_resolved_geth_source_mode)"

  if [ "$source_mode" != "$GETH_SOURCE_MODE" ]; then
    _setup_hive_log "Resolved GETH_SOURCE_MODE=$GETH_SOURCE_MODE to $source_mode for GETH_REF=$GETH_REF"
  fi

  case "$source_mode" in
    git)
      _setup_hive_write_git_client_file
      ;;
    local)
      _setup_hive_prepare_local_geth
      _setup_hive_write_local_client_file
      ;;
  esac
}

main() {
  _setup_hive_parse_args "$@"
  _setup_hive_require_cmd git Git
  _setup_hive_require_cmd go Go

  _setup_hive_prepare_git_checkout Hive "$HIVE_REPO" "$HIVE_REF" "$HIVE_DIR"
  _setup_hive_patch_geth_flags
  _setup_hive_build_hive
  _setup_hive_configure_client

  _setup_hive_log "Hive setup complete"
}

main "$@"
