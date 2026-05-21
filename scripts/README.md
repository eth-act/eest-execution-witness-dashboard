# Scripts

This directory is reserved for local and CI automation used to generate the
execution witness fixtures, run Hive, and build the static hive-ui site.

Implemented scripts:

- `env.sh`: shared defaults and prerequisite checks.
- `setup-eest.sh`: clone or update `execution-specs` and run `uv sync`.
  Release mode checks out `EEST_RELEASE_TAG`.
- `prepare-fixtures.sh`: choose fill mode or release mode and prepare
  validated fixtures in `FIXTURES_DIR`.
- `fill-fixtures.sh`: clone or update `execution-specs`, run `uv sync`,
  generate witness fixtures into `FIXTURES_DIR`, and validate the fixture index.
- `validate-fixtures.sh`: validate an existing fixture directory contains
  `blockchain_test_engine` fixtures.
- `setup-hive.sh`: clone or update Hive, build `./hive`, and generate
  `clients-local.yaml` from the selected EL client descriptors.
- `list-el-clients.sh`: resolve selected EL descriptors and emit table, JSON,
  ids, or a GitHub Actions matrix.
- `run-hive-consume-client.sh`: run one selected EL client against
  `consume engine-witness` into an isolated result directory.
- `run-hive-consume.sh`: prepare Hive, run the single-client worker once per
  selected EL, and merge per-client results into `HIVE_RESULTS_DIR`.
- `merge-hive-results.sh`: validate and merge isolated per-client Hive result
  directories without overwriting conflicting files.
- `merge-hive-result-dirs.sh`: merge directories that already contain
  Hive-shaped result JSON/log files, such as normal Hive logs plus converted
  zkEVM metrics.
- `convert-zkevm-metrics-to-hive-results.py`: convert `zkevm-benchmark-workload`
  `zkevm-metrics/` output into Hive-compatible result files.
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
scripts/env.sh --validate-eest-source
```

Prepare execution witness fixtures in the default fill mode:

```bash
scripts/prepare-fixtures.sh
```

The generation command targets `blockchain_test_engine`.

Prepare pre-filled release fixtures instead of filling locally:

```bash
EEST_RELEASE_TAG='tests-zkevm@v0.4.2' \
EEST_REPO= \
EEST_REF= \
scripts/prepare-fixtures.sh
```

When `EEST_RELEASE_TAG` is set, `EEST_REPO` and `EEST_REF` must both be empty.
The script uses the exact tag supplied by `EEST_RELEASE_TAG`: it checks out
`ethereum/execution-specs` at that tag for the matching `consume` CLI,
downloads the single `.tar.gz` asset attached to that GitHub release, extracts
it into `FIXTURES_DIR`, and validates the downloaded fixtures.

Prepare `execution-specs` without regenerating fixtures:

```bash
scripts/setup-eest.sh
```

This is used by CI consume jobs after they download the shared fixtures
artifact. In release mode, the checkout ref is exactly `EEST_RELEASE_TAG`, for
example `tests-zkevm@v0.4.2`.

Prepare Hive and generate `clients-local.yaml`:

```bash
scripts/setup-hive.sh
```

By default, `EL_CLIENTS=go-ethereum,ethrex,nethermind` selects every default
client from `config/el-clients.json`. The consume orchestration runs selected
clients independently so the final dashboard has one listing entry per EL. Use
a comma-separated subset to run fewer clients:

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

Run Hive and consume the generated fixtures once per selected EL:

```bash
scripts/run-hive-consume.sh
```

`HIVE_PARALLELISM=1` keeps consume sequential. Set it to a higher integer to
run multiple consume tests at once through pytest-xdist.

This script cleans `HIVE_CLIENT_RESULTS_DIR`, writes each worker's Hive
stdout/stderr to `hive-dev-<client>.log`, requires every selected EL to produce
at least one top-level result JSON, then merges everything into
`HIVE_RESULTS_DIR`. By default, `HIVE_CONSUME_ALLOW_FAILURE=1` keeps going
after `consume engine-witness` exits non-zero, which is useful when publishing a
dashboard of failing tests. Set it to `0` to stop before merge/build on consume
failure. Set `HIVE_DOCKER_OUTPUT=build` and
`HIVE_LOG_TO_STDOUT=1` to stream Docker build output into the console while
still writing the per-client Hive log.

Convert `zkevm-benchmark-workload` metrics into Hive-compatible results:

```bash
python3 scripts/convert-zkevm-metrics-to-hive-results.py \
  --input /data/code-data/zkevm-benchmark-workload/zkevm-metrics \
  --output hive/workspace/zkevm-converted-results \
  --clean-output
```

This writes one result JSON per execution-client/zkVM combination and a
generated details log for each result. To build a HiveUI site from only those
converted results:

```bash
HIVE_RESULTS_DIR=hive/workspace/zkevm-converted-results scripts/build-site.sh
```

Merge normal Hive results with converted zkEVM metrics:

```bash
scripts/merge-hive-result-dirs.sh \
  --output hive/workspace/combined-results \
  --clean-output \
  hive/workspace/logs \
  hive/workspace/zkevm-converted-results
```

This script is for directories that are already in Hive result format. It
requires each source to contain at least one top-level suite JSON, rejects
invalid or multi-client result JSON by default, and refuses to overwrite
conflicting files. Build a site from the merged output with:

```bash
HIVE_RESULTS_DIR=hive/workspace/combined-results scripts/build-site.sh
```

Build the static hive-ui site:

```bash
scripts/build-site.sh
```

The script cleans `SITE_DIR`, builds the pinned `HIVE_UI_REF`, generates
`discovery.json` and `listing.jsonl`, copies merged `HIVE_RESULTS_DIR` into
`SITE_DIR/results/`, writes hive-ui license/source notices, fails if any
listing entry contains more than one client, and fails if the output is larger
than `SITE_MAX_SIZE_MB` (default: `900`).

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
