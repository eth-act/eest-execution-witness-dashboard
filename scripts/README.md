# Scripts

This directory is reserved for local and CI automation used to generate the
execution witness fixtures, run Hive, and build the static Hiveview site.

Implemented scripts:

- `env.sh`: shared defaults and prerequisite checks.

Planned scripts:

- `fill-fixtures.sh`
- `run-hive-consume.sh`
- `build-site.sh`

Load the shared defaults from any working directory:

```bash
source /path/to/eest-execution-witness-dashboard/scripts/env.sh
eest_dashboard_print_env
eest_dashboard_check_prereqs
```

The same file can be executed directly:

```bash
scripts/env.sh --print
scripts/env.sh --check
```
