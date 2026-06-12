#!/usr/bin/env bash

# Shared EL client descriptor helpers. Source scripts/env.sh before using these
# functions so EL_CLIENT_CONFIG, EL_CLIENTS, and EL_CLIENT_OVERRIDES_JSON exist.

eest_el_clients_descriptor_field() {
  local descriptor filter

  descriptor="$1"
  filter="$2"
  jq -r "$filter // empty" <<< "$descriptor"
}

eest_el_clients_resolve_descriptors_for() {
  local selected

  selected="$1"
  if [ ! -f "$EL_CLIENT_CONFIG" ]; then
    printf 'error: EL client descriptor file does not exist: %s\n' "$EL_CLIENT_CONFIG" >&2
    return 1
  fi

  jq -c \
    --arg selected "$selected" \
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
}

eest_el_clients_resolve_descriptors() {
  eest_el_clients_resolve_descriptors_for "$EL_CLIENTS"
}

eest_el_clients_client_nametag() {
  local descriptor

  descriptor="$1"
  eest_el_clients_descriptor_field "$descriptor" '.nametag'
}

eest_el_clients_full_client_name() {
  local descriptor hive_client nametag

  descriptor="$1"
  hive_client="$(eest_el_clients_descriptor_field "$descriptor" '.hive_client')"
  nametag="$(eest_el_clients_client_nametag "$descriptor")"

  if [ -n "$nametag" ]; then
    printf '%s_%s\n' "$hive_client" "$nametag"
  else
    printf '%s\n' "$hive_client"
  fi
}

eest_el_clients_dockerfile_ext() {
  local descriptor dockerfile

  descriptor="$1"
  dockerfile="$(eest_el_clients_descriptor_field "$descriptor" '.dockerfile')"
  printf '%s\n' "${dockerfile:-git}"
}

eest_el_clients_validate_safe_id() {
  case "$1" in
    '' | *[!A-Za-z0-9_.-]*)
      printf 'error: invalid EL client id: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

eest_el_clients_artifact_name() {
  local id

  id="$1"
  eest_el_clients_validate_safe_id "$id" || return 1
  printf 'hive-results-%s\n' "$id"
}

eest_el_clients_hive_parallelism() {
  local descriptor

  descriptor="$1"

  jq -er '
    .id as $id
    | if (has("hive_parallelism") | not) then
        error("EL client descriptor \($id) is missing required hive_parallelism")
      else
        .hive_parallelism as $value
        | if ($value | type) == "number" then
            if ($value > 0 and $value == ($value | floor)) then
              ($value | tostring)
            else
              error("EL client descriptor \($id) hive_parallelism must be a positive integer")
            end
          elif ($value | type) == "string" then
            if ($value | test("^[1-9][0-9]*$")) then
              $value
            else
              error("EL client descriptor \($id) hive_parallelism must be a positive integer")
            end
          else
            error("EL client descriptor \($id) hive_parallelism must be a positive integer")
          end
      end
  ' <<< "$descriptor"
}

eest_el_clients_matrix_json() {
  local artifact descriptor full_name id objects parallelism resolved

  resolved="$(eest_el_clients_resolve_descriptors)" || return 1

  objects="$(
    while IFS= read -r descriptor; do
      id="$(eest_el_clients_descriptor_field "$descriptor" '.id')"
      full_name="$(eest_el_clients_full_client_name "$descriptor")"
      artifact="$(eest_el_clients_artifact_name "$id")" || return 1
      parallelism="$(eest_el_clients_hive_parallelism "$descriptor")" || return 1

      jq -cn \
        --arg id "$id" \
        --arg hive_client "$full_name" \
        --arg artifact "$artifact" \
        --arg hive_parallelism "$parallelism" \
        '{
          id: $id,
          hive_client: $hive_client,
          artifact: $artifact,
          hive_parallelism: $hive_parallelism
        }'
    done < <(jq -c '.[]' <<< "$resolved")
  )" || return 1

  jq -c -s '{include: .}' <<< "$objects"
}

eest_el_clients_selected_ids() {
  local resolved

  resolved="$(eest_el_clients_resolve_descriptors)" || return 1
  jq -r '.[].id' <<< "$resolved"
}
