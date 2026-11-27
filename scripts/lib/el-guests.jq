# Lookups over the EL guest descriptors in EL_GUEST_CONFIG. Load them with
# `jq -L scripts/lib 'include "el-guests"; ...'`.

def require_guest_config:
  if (.guests | type) != "object" then
    error("EL_GUEST_CONFIG must contain a guests object")
  else
    .
  end;

def guest_descriptor($client):
  .guests[$client] // error("unknown EL guest id: \($client)");

# The zkVM's own guest_artifact_base_url, else the guest's, else empty, which
# leaves the benchmark on its default guest artifacts.
def guest_artifact_base_url($client; $zkvm):
  guest_descriptor($client) as $guest
  | (($guest.zkvms[$zkvm].guest_artifact_base_url // $guest.guest_artifact_base_url // "") | tostring);
