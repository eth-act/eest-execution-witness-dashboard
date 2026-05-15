# Scripts

This directory is reserved for local and CI automation used to generate the
execution witness fixtures, run Hive, and build the static hive-ui site.

Implemented scripts:

- `env.sh`: shared defaults and prerequisite checks.
- `fill-fixtures.sh`: clone or update `execution-specs`, run `uv sync`,
  generate witness fixtures into `FIXTURES_DIR`, and validate the fixture index.
- `setup-hive.sh`: clone or update Hive, build `./hive`, and generate
  `clients-local.yaml` from the selected EL client descriptors.
- `run-hive-consume.sh`: prepare Hive, start `./hive --dev`, run
  `consume engine-witness`, and preserve Hive logs in `HIVE_RESULTS_DIR`.
- `build-site.sh`: generate a static hive-ui site in `SITE_DIR`, write
  `discovery.json` and `listing.jsonl`, copy Hive logs into `results/`, and
  enforce `SITE_MAX_SIZE_MB`.
- `smoke-site.sh`: serve `SITE_DIR` over local HTTP under a non-root project
  path, verify `discovery.json`, `listing.jsonl`, and `results/...` fetches,
  check relative paths, and scan public logs for suspicious secret strings.

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

By default, `EL_CLIENTS=go-ethereum,ethrex` renders both clients from
`config/el-clients.json` into one Hive client file. Use a comma-separated
subset to run fewer clients:

```bash
EL_CLIENTS=ethrex scripts/setup-hive.sh
```

Use `EL_CLIENT_OVERRIDES_JSON` for temporary repo/ref changes:

```bash
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"ref":"other-branch"}}' scripts/setup-hive.sh
```

The same override mechanism applies to go-ethereum. For example, this disables
the default Hive extra flags patch:

```bash
EL_CLIENT_OVERRIDES_JSON='{"go-ethereum":{"hive_extra_flags":""}}' scripts/setup-hive.sh
```

Run Hive and consume the generated fixtures:

```bash
scripts/run-hive-consume.sh
```

`HIVE_PARALLELISM=1` keeps consume sequential. Set it to a higher integer to
run multiple consume tests at once through pytest-xdist.

This script cleans `HIVE_RESULTS_DIR`, writes Hive stdout/stderr to
`$HIVE_RESULTS_DIR/hive-dev.log`, and prints the tail of that log when startup
or consume fails. Set `HIVE_CONSUME_ALLOW_FAILURE=1` to keep going after
`consume engine-witness` exits non-zero, which is useful when publishing a
dashboard of failing tests. Set `HIVE_DOCKER_OUTPUT=build` and
`HIVE_LOG_TO_STDOUT=1` to stream Docker build output into the console while
still writing `hive-dev.log`.

Build the static hive-ui site:

```bash
scripts/build-site.sh
```

The script cleans `SITE_DIR`, builds the pinned `HIVE_UI_REF`, generates
`discovery.json` and `listing.jsonl`, copies `HIVE_RESULTS_DIR` into
`SITE_DIR/results/`, writes hive-ui license/source notices, and fails if the
output is larger than `SITE_MAX_SIZE_MB` (default: `900`).

Preview the generated static site with a simple HTTP server:

```bash
source scripts/env.sh
cd "$SITE_DIR"
python3 -m http.server 8081 --bind 127.0.0.1
```

Open `http://127.0.0.1:8081/`. Use HTTP, not `file://`, so browser requests
for `listing.jsonl` and `results/...` behave like the published site.

Smoke test the generated site before publishing:

```bash
scripts/smoke-site.sh
```

The smoke test serves `SITE_DIR` at
`http://127.0.0.1:8765/eest-execution-witness-dashboard/`, verifies that
`discovery.json`, `listing.jsonl`, the first suite result, and a referenced
result asset load over HTTP, fails on root-relative paths that would break
GitHub Pages project URLs, and scans `SITE_DIR/results/` for common secret,
credential, and private RPC URL patterns. Override the port or project path
with `SITE_SMOKE_PORT` and `SITE_SMOKE_BASE_PATH`.

The same script can smoke test a deployed GitHub Pages URL without local
serving:

```bash
scripts/smoke-site.sh --url https://OWNER.github.io/REPOSITORY/
```

Remote mode fetches `discovery.json`, `listing.jsonl`, the first listed result
under `results/...`, and one referenced result asset when present.
