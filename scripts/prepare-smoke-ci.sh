#!/usr/bin/env bash

set -Eeuo pipefail

# This is the online preparation step for future PR jobs, not a local validator.
if [ "${GITHUB_EVENT_NAME:-}" != pull_request ]; then
  printf '%s\n' 'error: smoke CI preparation may only run in a pull_request job' >&2
  exit 2
fi
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/env.sh
. "$script_dir/env.sh"
exec python3 "$script_dir/smoke_ci.py" "$@"
