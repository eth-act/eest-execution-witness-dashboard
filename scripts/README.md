# Scripts

This directory is reserved for local and CI automation used to generate the
execution witness fixtures, run Hive, and build the static Hiveview site.

Implemented scripts:

- `env.sh`: shared defaults and prerequisite checks.
- `fill-fixtures.sh`: clone or update `execution-specs`, run `uv sync`,
  generate witness fixtures into `FIXTURES_DIR`, and validate the fixture index.
- `setup-hive.sh`: clone or update Hive, build `./hive`, and generate
  `clients-local.yaml` for either remote git or local geth source mode.
- `run-hive-consume.sh`: prepare Hive, start `./hive --dev`, run
  `consume engine-witness`, and preserve Hive logs in `HIVE_RESULTS_DIR`.
- `build-site.sh`: generate a static Hiveview site in `SITE_DIR`, write
  `listing.jsonl`, copy Hive logs into `results/`, and enforce
  `SITE_MAX_SIZE_MB`.

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

Generate execution witness fixtures:

```bash
scripts/fill-fixtures.sh
```

The generation command targets `blockchain_test_engine`.

Prepare Hive and generate `clients-local.yaml`:

```bash
scripts/setup-hive.sh
```

By default, `GETH_SOURCE_MODE=auto` uses Hive `Dockerfile.git` for branch/tag
refs and switches to `Dockerfile.local` for full commit SHAs. Setup also
injects `GETH_HIVE_EXTRA_FLAGS` into Hive's `clients/go-ethereum/geth.sh`. The
default extra flag is `--bal.executionmode=sequential`; set
`GETH_HIVE_EXTRA_FLAGS=` to disable the managed patch. To force the local
checkout path for any ref:

```bash
GETH_SOURCE_MODE=local GETH_REF=<commit-or-ref> scripts/setup-hive.sh
```

Run Hive and consume the generated fixtures:

```bash
scripts/run-hive-consume.sh
```

`HIVE_PARALLELISM=1` keeps consume sequential. Set it to a higher integer to
run multiple consume tests at once through pytest-xdist.

This script cleans `HIVE_RESULTS_DIR`, writes Hive stdout/stderr to
`$HIVE_RESULTS_DIR/hive-dev.log`, and prints the tail of that log when startup
or consume fails.

Build the static Hiveview site:

```bash
scripts/build-site.sh
```

The script cleans `SITE_DIR`, deploys Hiveview assets, generates
`listing.jsonl`, copies `HIVE_RESULTS_DIR` into `SITE_DIR/results/`, and fails
if the output is larger than `SITE_MAX_SIZE_MB` (default: `900`).
