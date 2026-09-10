#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/env.sh
. "$script_dir/env.sh"

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
  printf '%s\n' 'error: smoke-upgrade.sh requires Python 3.11 or newer' >&2
  exit 2
fi

exec python3 "$script_dir/smoke_upgrade.py" "$@"
