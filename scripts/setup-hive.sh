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

_setup_hive_usage() {
  printf '%s\n' \
    'Usage: scripts/setup-hive.sh' \
    '' \
    'Clone or update Hive, build the Hive binary, and generate clients-local.yaml.' \
    '' \
    'Environment overrides from scripts/env.sh:' \
    '  HIVE_REPO, HIVE_REF, HIVE_DIR' \
    '  EL_CLIENT_CONFIG, EL_CLIENTS, EL_CLIENT_OVERRIDES_JSON' \
    '' \
    'EL_CLIENTS is a comma-separated list of descriptor ids. Default: go-ethereum,ethrex.' \
    'EL_CLIENT_OVERRIDES_JSON may be either {"id": {...}} or {"clients": {"id": {...}}}.'
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

_setup_hive_validate_yaml_key() {
  case "$1" in
    '' | *[!A-Za-z0-9_.-]*)
      _setup_hive_die "invalid YAML key: $1"
      ;;
  esac
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
  local extra_flags

  extra_flags="$1"
  case "$extra_flags" in
    *$'\n'* | *'"'* | *'$'* | *'`'* | *'\\'*)
      _setup_hive_die 'geth extra flags cannot contain newline, ", $, `, or \ characters'
      ;;
  esac
}

_setup_hive_patch_geth_flags() {
  local begin extra_flags geth_script tmp

  extra_flags="$1"
  geth_script="$HIVE_DIR/clients/go-ethereum/geth.sh"
  begin='# eest-dashboard: begin managed geth extra flags'
  tmp="${geth_script}.tmp.$$"

  if [ ! -f "$geth_script" ]; then
    _setup_hive_die "Hive go-ethereum startup script does not exist: $geth_script"
  fi

  if ! grep -Fq 'FLAGS="--state.scheme=path"' "$geth_script"; then
    _setup_hive_die "unable to find initial FLAGS assignment in $geth_script"
  fi

  _setup_hive_validate_extra_flags "$extra_flags"
  cp "$geth_script" "$tmp"

  if ! awk \
    -v begin="$begin" \
    -v end='# eest-dashboard: end managed geth extra flags' \
    -v extra="$extra_flags" '
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

  if [ -n "$extra_flags" ]; then
    _setup_hive_log "Injected geth extra flags: $extra_flags"
  else
    _setup_hive_log "Removed managed geth extra flags patch"
  fi
}

_setup_hive_descriptor_field() {
  local descriptor filter

  descriptor="$1"
  filter="$2"
  jq -r "$filter // empty" <<< "$descriptor"
}

_setup_hive_resolve_client_descriptors() {
  local resolved

  if [ ! -f "$EL_CLIENT_CONFIG" ]; then
    _setup_hive_die "EL client descriptor file does not exist: $EL_CLIENT_CONFIG"
  fi

  if ! resolved="$(
    jq -c \
      --arg selected "$EL_CLIENTS" \
      --arg overrides_raw "$EL_CLIENT_OVERRIDES_JSON" '
        def trim: gsub("^\\s+|\\s+$"; "");
        def parsed_overrides:
          if ($overrides_raw | trim) == "" then
            {}
          else
            ($overrides_raw | fromjson)
          end;
        def override_for($id; $overrides):
          if ($overrides | type) != "object" then
            error("EL_CLIENT_OVERRIDES_JSON must be a JSON object")
          elif ($overrides | has("clients")) then
            ($overrides.clients[$id] // {})
          else
            ($overrides[$id] // {})
          end;

        ($selected | split(",") | map(trim) | map(select(length > 0))) as $ids
        | if ($ids | length) == 0 then
            error("EL_CLIENTS must select at least one client")
          else
            .
          end
        | if ($ids | length) != ($ids | unique | length) then
            error("EL_CLIENTS contains duplicate client ids")
          else
            .
          end
        | parsed_overrides as $overrides
        | [
            $ids[] as $id
            | (.clients[$id] // error("unknown EL client id: \($id)")) as $base
            | override_for($id; $overrides) as $override
            | (
                $base
                + $override
                + {
                  id: $id,
                  _override_repo: ($override | has("repo")),
                  _override_github: ($override | has("github"))
                }
              )
          ]
      ' "$EL_CLIENT_CONFIG"
  )"; then
    _setup_hive_die "failed to resolve EL client descriptors"
  fi

  printf '%s\n' "$resolved"
}

_setup_hive_client_nametag() {
  local descriptor

  descriptor="$1"
  _setup_hive_descriptor_field "$descriptor" '.nametag'
}

_setup_hive_full_client_name() {
  local descriptor hive_client nametag

  descriptor="$1"
  hive_client="$(_setup_hive_descriptor_field "$descriptor" '.hive_client')"
  nametag="$(_setup_hive_client_nametag "$descriptor")"

  if [ -n "$nametag" ]; then
    printf '%s_%s\n' "$hive_client" "$nametag"
  else
    printf '%s\n' "$hive_client"
  fi
}

_setup_hive_dockerfile_ext() {
  local descriptor dockerfile

  descriptor="$1"
  dockerfile="$(_setup_hive_descriptor_field "$descriptor" '.dockerfile')"
  printf '%s\n' "${dockerfile:-git}"
}

_setup_hive_validate_hive_client() {
  local descriptor dockerfile_ext dockerfile_path hive_client id transport

  descriptor="$1"
  id="$(_setup_hive_descriptor_field "$descriptor" '.id')"
  hive_client="$(_setup_hive_descriptor_field "$descriptor" '.hive_client')"
  dockerfile_ext="$(_setup_hive_dockerfile_ext "$descriptor")"
  transport="$(_setup_hive_descriptor_field "$descriptor" '.transport')"

  if [ -z "$hive_client" ]; then
    _setup_hive_die "EL client descriptor $id is missing hive_client"
  fi

  case "${transport:-json-rpc-rlp}" in
    json-rpc-rlp) ;;
    *)
      _setup_hive_die "unsupported transport for $id: $transport (only json-rpc-rlp is supported in this pipeline)"
      ;;
  esac

  case "$hive_client" in
    '' | /* | . | .. | *'/../'* | ../* | *'/..' | *'\'* | *$'\r'* | *$'\n'*)
      _setup_hive_die "invalid Hive client path for $id: $hive_client"
      ;;
  esac

  if [ -n "$dockerfile_ext" ]; then
    _setup_hive_validate_yaml_key "$dockerfile_ext"
    dockerfile_path="$HIVE_DIR/clients/$hive_client/Dockerfile.$dockerfile_ext"
  else
    dockerfile_path="$HIVE_DIR/clients/$hive_client/Dockerfile"
  fi

  if [ ! -f "$dockerfile_path" ]; then
    _setup_hive_die "Hive client Dockerfile for $id does not exist: $dockerfile_path"
  fi
}

_setup_hive_apply_descriptor_setup() {
  local descriptor extra_flags managed_patch

  descriptor="$1"
  managed_patch="$(_setup_hive_descriptor_field "$descriptor" '.managed_patch')"

  case "$managed_patch" in
    '')
      ;;
    geth-extra-flags)
      extra_flags="$(_setup_hive_descriptor_field "$descriptor" '.hive_extra_flags')"
      _setup_hive_patch_geth_flags "$extra_flags"
      ;;
    *)
      _setup_hive_die "unsupported managed_patch for $(_setup_hive_descriptor_field "$descriptor" '.id'): $managed_patch"
      ;;
  esac
}

_setup_hive_append_client_yaml() {
  local build_arg_key build_arg_value descriptor dockerfile_ext github hive_client nametag repo target tmp_build_args

  descriptor="$1"
  target="$2"

  hive_client="$(_setup_hive_descriptor_field "$descriptor" '.hive_client')"
  dockerfile_ext="$(_setup_hive_dockerfile_ext "$descriptor")"
  nametag="$(_setup_hive_client_nametag "$descriptor")"

  {
    printf -- '- client: '
    _setup_hive_yaml_quote "$hive_client"
    printf '\n'

    if [ -n "$dockerfile_ext" ]; then
      printf '  dockerfile: '
      _setup_hive_yaml_quote "$dockerfile_ext"
      printf '\n'
    fi

    if [ -n "$nametag" ]; then
      printf '  nametag: '
      _setup_hive_yaml_quote "$nametag"
      printf '\n'
    fi

    printf '%s\n' '  build_args:'
  } >> "$target"

  repo="$(_setup_hive_descriptor_field "$descriptor" '.repo')"
  github="$(_setup_hive_descriptor_field "$descriptor" '.github')"
  if [ "$(_setup_hive_descriptor_field "$descriptor" '._override_repo')" = true ] &&
    [ "$(_setup_hive_descriptor_field "$descriptor" '._override_github')" != true ]; then
    github="$(_eest_dashboard_github_slug "$repo" 2>/dev/null || printf '%s\n' "$github")"
  fi
  tmp_build_args="${target}.build-args.$$"
  jq -c \
    --arg github "$github" \
    --arg ref "$(_setup_hive_descriptor_field "$descriptor" '.ref')" '
      ((.build_args // {})
        + (if $github != "" then {github: $github} else {} end)
        + (if $ref != "" then {tag: $ref} else {} end))
    ' <<< "$descriptor" > "$tmp_build_args"

  while IFS=$'\t' read -r build_arg_key build_arg_value; do
    _setup_hive_validate_yaml_key "$build_arg_key"
    printf '    %s: ' "$build_arg_key" >> "$target"
    _setup_hive_yaml_quote "$build_arg_value" >> "$target"
    printf '\n' >> "$target"
  done < <(jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv' "$tmp_build_args")

  rm -f "$tmp_build_args"
}

_setup_hive_write_client_file() {
  local descriptor resolved tmp

  resolved="$1"
  tmp="${_setup_hive_client_file}.tmp.$$"

  _setup_hive_log "Writing EL client config to $_setup_hive_client_file"
  : > "$tmp"

  while IFS= read -r descriptor; do
    _setup_hive_append_client_yaml "$descriptor" "$tmp"
  done < <(jq -c '.[]' <<< "$resolved")

  mv "$tmp" "$_setup_hive_client_file"
}

_setup_hive_configure_clients() {
  local descriptor full_name resolved
  local -A seen_clients=()

  resolved="$(_setup_hive_resolve_client_descriptors)"

  while IFS= read -r descriptor; do
    _setup_hive_validate_hive_client "$descriptor"
    full_name="$(_setup_hive_full_client_name "$descriptor")"

    if [ -n "${seen_clients[$full_name]:-}" ]; then
      _setup_hive_die "duplicate Hive client name after descriptor resolution: $full_name"
    fi
    seen_clients[$full_name]=1

    _setup_hive_apply_descriptor_setup "$descriptor"
  done < <(jq -c '.[]' <<< "$resolved")

  _setup_hive_write_client_file "$resolved"
}

main() {
  _setup_hive_parse_args "$@"
  _setup_hive_require_cmd git Git
  _setup_hive_require_cmd go Go
  _setup_hive_require_cmd jq jq

  _setup_hive_prepare_git_checkout Hive "$HIVE_REPO" "$HIVE_REF" "$HIVE_DIR"
  _setup_hive_configure_clients
  _setup_hive_build_hive

  _setup_hive_log "Hive setup complete"
}

main "$@"
