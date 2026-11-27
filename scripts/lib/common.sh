#!/usr/bin/env bash

# Helpers shared by the scripts in scripts/. Each script sources this first:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# It's separate from env.sh, which people also source into their own shell.

eest_log() {
  printf '==> %s\n' "$*"
}

eest_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

eest_abs_dir() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

# eest_require_cmd CMD [LABEL]
eest_require_cmd() {
  local cmd label

  cmd="$1"
  label="${2:-$1}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    eest_die "missing required tool: $label ($cmd not found on PATH)"
  fi
}

eest_require_positive_int() {
  local name value

  name="$1"
  value="$2"
  case "$value" in
    '' | *[!0-9]*)
      eest_die "$name must be a positive integer: $value"
      ;;
    0)
      eest_die "$name must be greater than zero"
      ;;
  esac
}

eest_require_uint() {
  case "$2" in
    '' | *[!0-9]*)
      eest_die "$1 must be a non-negative integer: $2"
      ;;
  esac
}

# Booleans take 1, true, or yes, and 0, false, or no.
eest_require_bool() {
  case "$2" in
    1 | true | yes | 0 | false | no) ;;
    *)
      eest_die "$1 must be 1, true, yes, 0, false, or no: $2"
      ;;
  esac
}

eest_is_true() {
  case "$1" in
    1 | true | yes) return 0 ;;
  esac
  return 1
}

# Prints PATH as an absolute path without . or .. parts, resolving a relative
# PATH against ROOT_DIR. Unlike realpath, it doesn't need PATH to exist.
eest_normalize_path() {
  local IFS part path result
  local -a parts=() stack=()

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
          eest_die "path escapes filesystem root: $1"
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

# eest_guard_clean_dir LABEL DIR
#
# Refuses to let a script delete DIR unless it's under ROOT_DIR or /tmp and is
# none of the directories env.sh names, apart from the one LABEL names, which
# is the directory the script is meant to clean.
eest_guard_clean_dir() {
  local label dir name protected

  label="$1"
  dir="$2"

  case "$dir" in
    '' | / | /tmp | /tmp/)
      eest_die "refusing to clean unsafe $label: $dir"
      ;;
  esac

  for name in ROOT_DIR EEST_DIR HIVE_DIR HIVE_UI_DIR FIXTURES_DIR SITE_DIR \
    HIVE_RESULTS_DIR HIVE_CLIENT_RESULTS_DIR ZKEVM_BENCHMARK_WORKLOAD_DIR ZKEVM_METRICS_DIR; do
    [ "$name" = "$label" ] && continue
    protected="${!name:-}"
    if [ -n "$protected" ] && [ "$dir" = "$protected" ]; then
      eest_die "refusing to clean unsafe $label: $dir is $name"
    fi
  done

  case "$dir" in
    "$ROOT_DIR"/* | /tmp/*) ;;
    *)
      eest_die "refusing to clean $label outside ROOT_DIR or /tmp: $dir"
      ;;
  esac
}

eest_ref_is_full_sha() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

# Succeeds when DIR is the top of its own git work tree. A directory that's
# merely inside one, such as a plain directory in this repository, isn't.
eest_is_git_checkout_root() {
  local dir top

  dir="$(eest_abs_dir "$1")"
  [ -n "$dir" ] || return 1
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$top" = "$dir" ]
}

# eest_prepare_git_checkout LABEL REPO REF DIR
#
# Clones REPO into DIR, or points an existing checkout's origin at REPO, then
# detaches at REF. A full commit SHA is checked out after fetching every ref;
# anything else is fetched by name.
eest_prepare_git_checkout() {
  local dir label ref repo

  label="$1"
  repo="$2"
  ref="$3"
  dir="$4"

  eest_log "Preparing $label checkout at $dir"
  eest_log "Using $repo at $ref"

  if [ -d "$dir" ]; then
    if ! eest_is_git_checkout_root "$dir"; then
      eest_die "$label directory exists but is not a git checkout root: $dir"
    fi
    if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      git -C "$dir" remote set-url origin "$repo"
    else
      git -C "$dir" remote add origin "$repo"
    fi
  else
    mkdir -p "$(dirname "$dir")"
    git clone "$repo" "$dir"
  fi

  if eest_ref_is_full_sha "$ref"; then
    git -C "$dir" fetch --prune origin
    git -C "$dir" checkout --detach "$ref"
  else
    git -C "$dir" fetch --prune origin "$ref"
    git -C "$dir" checkout --detach FETCH_HEAD
  fi
}
