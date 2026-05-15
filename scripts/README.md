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

Planned scripts:

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

Generate execution witness fixtures:

```bash
scripts/fill-fixtures.sh
```

The generation command targets `blockchain_test_engine`.

Prepare Hive and generate `clients-local.yaml`:

```bash
scripts/setup-hive.sh
```

By default, setup uses Hive `Dockerfile.git` with `GETH_GITHUB` and
`GETH_REF`, and injects `GETH_HIVE_EXTRA_FLAGS` into Hive's
`clients/go-ethereum/geth.sh`. The default extra flag is
`--bal.executionmode=sequential`; set `GETH_HIVE_EXTRA_FLAGS=` to disable the
managed patch. To build from an exact local checkout, select local mode without
changing the run command:

```bash
GETH_SOURCE_MODE=local GETH_REF=<commit-or-ref> scripts/setup-hive.sh
```

Run Hive and consume the generated fixtures:

```bash
scripts/run-hive-consume.sh
```

This script cleans `HIVE_RESULTS_DIR`, writes Hive stdout/stderr to
`$HIVE_RESULTS_DIR/hive-dev.log`, and prints the tail of that log when startup
or consume fails.
