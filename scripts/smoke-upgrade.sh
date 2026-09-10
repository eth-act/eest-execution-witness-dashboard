#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/env.sh
. "$script_dir/env.sh"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
  printf '%s\n' 'error: smoke-upgrade.sh requires Python 3.11 or newer' >&2
  exit 2
fi

# Keep transitive Cargo/uv/Go invocations offline too.
export CARGO_NET_OFFLINE=true UV_OFFLINE=1 UV_NO_SYNC=1
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local RUSTUP_AUTO_INSTALL=0
unset ERE_FORCE_REBUILD_DOCKER_IMAGE
exec python3 "$script_dir/smoke_upgrade.py" "$@"
