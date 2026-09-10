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
  both `blockchain_test` and `blockchain_test_engine` fixtures.
- `setup-hive.sh`: clone or update Hive, build `./hive`, and generate
  `clients-local.yaml` from the selected EL client descriptors.
- `list-el-clients.sh`: resolve selected EL descriptors and emit table, JSON,
  ids, or a GitHub Actions matrix.
- `list-zkevm-workload-runs.sh`: validate selected
  `zkevm-benchmark-workload` execution-client/zkVM runs and emit a GitHub
  Actions matrix.
- `setup-zkevm-benchmark-workload.sh`: clone or update
  `zkevm-benchmark-workload` and check out the configured ref.
- `run-zkevm-benchmark-workload.sh`: run one
  `zkevm-benchmark-workload` stateless-validator execution benchmark against
  `FIXTURES_DIR`.
- `run-hive-consume-client.sh`: run one selected EL client against
  `consume engine-witness` into an isolated result directory.
- `run-hive-consume.sh`: prepare Hive, run the single-client worker once per
  selected EL, and merge per-client results into `HIVE_RESULTS_DIR`.
- `merge-hive-results.sh`: validate and merge isolated per-client Hive result
  directories plus optional Hive-shaped sources in one pass without
  overwriting conflicting files.
- `merge-hive-result-dirs.py`: shared in-process validator and merge engine.
- `merge-hive-result-dirs.sh`: compatibility entrypoint for merging arbitrary
  directories that already contain Hive-shaped result JSON/log files.
- `list-zkevm-metrics-roots.sh`: discover downloaded zkEVM metrics roots across
  both artifact-wrapper and flattened GitHub Actions download layouts.
- `dashboard-artifacts.py`: create and validate immutable dataset/result
  manifests and deterministically select reusable cross-run artifacts.
- `convert-zkevm-metrics-to-hive-results.py`: convert `zkevm-benchmark-workload`
  `zkevm-metrics/` output into Hive-compatible result files.
- `check-smoke-results.py`: require one passing Geth/Hive case and one passing
  Ethrex/ZisK case, including metrics conversion; see PR smoke check below.
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

The generation command targets both `blockchain_test` and
`blockchain_test_engine`.

Prepare pre-filled release fixtures instead of filling locally:

```bash
EEST_RELEASE_TAG='tests-zkevm@v0.4.2' scripts/prepare-fixtures.sh
```

When `EEST_RELEASE_TAG` is set, the script ignores `EEST_REPO` and `EEST_REF`.
It uses the exact tag supplied by `EEST_RELEASE_TAG`: it checks out
`ethereum/execution-specs` at that tag for the matching `consume` CLI, downloads
the single `.tar.gz` asset attached to that GitHub release, extracts it into
`FIXTURES_DIR`, and validates the downloaded fixtures.

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

By default, `EL_CLIENTS=go-ethereum,ethrex,nethermind,nimbus-el` selects every default
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

For a custom go-ethereum descriptor using `managed_patch=geth-extra-flags`,
this clears its extra flags:

```bash
EL_CLIENT_OVERRIDES_JSON='{"go-ethereum":{"hive_extra_flags":""}}' scripts/setup-hive.sh
```

Run Hive and consume the generated fixtures once per selected EL:

```bash
scripts/run-hive-consume.sh
```

Each selected EL descriptor must define `hive_parallelism`, which runs multiple
consume tests at once through pytest-xdist. Use descriptor overrides for ad hoc
tuning:

```bash
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"hive_parallelism":4}}' scripts/run-hive-consume.sh
```

Direct single-client worker runs can still set `HIVE_PARALLELISM` explicitly.

This script cleans `HIVE_CLIENT_RESULTS_DIR`, writes each worker's Hive
stdout/stderr to `hive-dev-<client>.log`, requires every selected EL to produce
at least one top-level result JSON, then merges everything into
`HIVE_RESULTS_DIR`. By default, `HIVE_CONSUME_ALLOW_FAILURE=1` keeps going
after `consume engine-witness` exits non-zero, which is useful when publishing a
dashboard of failing tests. Set it to `0` to stop before merge/build on consume
failure. Set `HIVE_DOCKER_OUTPUT=build` and
`HIVE_LOG_TO_STDOUT=1` to stream Docker build output into the console while
still writing the per-client Hive log.

Resolve selected `zkevm-benchmark-workload` runs:

```bash
scripts/list-zkevm-workload-runs.sh
scripts/list-zkevm-workload-runs.sh --github-matrix
```

By default, `ZKEVM_WORKLOAD_RUNS=ethrex:zisk,reth:zisk`, producing the two
explicit execution-client/zkVM pairs in the list. `ethrex`, `reth`, and opt-in
`zesu` are accepted execution clients. Set `ZKEVM_WORKLOAD_RUNS` to an empty
string, `none`, `skip`, or `empty` to skip workload runs.

Workload guest descriptors live in `config/el-guests.json`. Descriptors can set
`guest_artifact_base_url` at the guest level and may override it per zkVM under
`zkvms.<zkvm>.guest_artifact_base_url`. Zesu can use this to locate release ELF
assets:

```bash
ZKEVM_WORKLOAD_RUNS=zesu:zisk,ethrex:zisk,ethrex:sp1 \
scripts/list-zkevm-workload-runs.sh --github-matrix
```

Workload `v0.17.0` locks `ere-guests` to `v0.17.0`. Empty guest descriptors
use that release automatically, including Zesu on ZisK; custom artifact URLs
remain optional overrides. The pinned EEST source is `tests-zkevm@v0.8.4`.

Prepare the workload checkout:

```bash
scripts/setup-zkevm-benchmark-workload.sh
```

The default checkout is
`https://github.com/eth-act/zkevm-benchmark-workload.git`
at `v0.17.0`.

Run one workload entry against prepared fixtures:

```bash
ZKEVM_WORKLOAD_EXECUTION_CLIENT=ethrex \
ZKEVM_WORKLOAD_ZKVM=zisk \
scripts/run-zkevm-benchmark-workload.sh
```

For a single Zesu run, `run-zkevm-benchmark-workload.sh` reads the URL from
`config/el-guests.json`. Set `ZKEVM_WORKLOAD_GUEST_ARTIFACT_BASE_URL` only when
you need a temporary local override.

This resets `ZKEVM_METRICS_DIR`, defaults `RAYON_NUM_THREADS` from
`ZKEVM_RAYON_THREADS`, runs `cargo run --locked --release -p ere-hosts`, and
requires at least one generated metrics JSON before returning successfully.

### PR smoke check

The PR workflow runs the production scripts against one empty-block test in
both fixture formats. Geth executes the engine fixture through Hive; Ethrex
executes the blockchain fixture on ZisK. The benchmark downloads its guest
and runtime image using its own dependency versions.

Run these commands from the dashboard repository root with the
[local prerequisites](../README.md#local-prerequisites) installed. They update
the generated source checkouts and replace outputs under `smoke-results/`.

```bash
(
  export EEST_RELEASE_TAG=''
  export FILLER_PATH=tests/amsterdam/eip8025_optional_proofs/test_witness_headers.py::test_witness_headers_empty_block
  export FILL_TEST_NAME=0
  export FIXTURES_DIR="$PWD/smoke-results/fixtures"
  export HIVE_CLIENT_RESULTS_DIR="$PWD/smoke-results/hive-results"
  export ZKEVM_METRICS_DIR="$PWD/smoke-results/metrics"
  export EL_CLIENTS=go-ethereum HIVE_PARALLELISM=1
  export HIVE_CONSUME_ALLOW_FAILURE=0 HIVE_PRUNE_SKIPPED=0 HIVE_LOG_TO_STDOUT=1
  export ZKEVM_RAYON_THREADS=2 ERE_IMAGE_REGISTRY=ghcr.io/eth-act/ere

  set -e
  scripts/setup-zkevm-benchmark-workload.sh
  scripts/prepare-fixtures.sh
  scripts/run-hive-consume-client.sh go-ethereum
  scripts/run-zkevm-benchmark-workload.sh ethrex zisk
  python3 scripts/convert-zkevm-metrics-to-hive-results.py \
    --input "$ZKEVM_METRICS_DIR" --output smoke-results/converted --clean-output
  python3 scripts/check-smoke-results.py \
    --fixtures "$FIXTURES_DIR" \
    --hive-results "$HIVE_CLIENT_RESULTS_DIR/go-ethereum" \
    --metrics "$ZKEVM_METRICS_DIR" \
    --converted-results smoke-results/converted
)
```

The result checker exits nonzero unless each fixture format contains the
selected case, Hive passes it without skipping, the guest output matches,
and conversion preserves the passing result. It reads the fixture index and
result files; it does not prepare or execute workloads.

CI installs Python, Go, Rust nightly, uv, and the native packages listed in
`.github/workflows/pr-smoke.yml`. It authenticates to GHCR with the job token,
caches dependencies and Rust build outputs, and runs on a disposable XL
runner with a 60-minute timeout. The summary records elapsed time and cache
hits. Cold runs can take longer because they build Geth and the benchmark.
Fixtures, results, and Hive logs are uploaded for seven days, with build output
in the step logs. The final **PR smoke** gate requires both local checks and
real execution to pass. It creates diagnostic artifacts only.

### Metrics conversion

Convert `zkevm-benchmark-workload` metrics into Hive-compatible results:

```bash
scripts/list-zkevm-metrics-roots.sh zkevm-metrics-artifacts
python3 scripts/convert-zkevm-metrics-to-hive-results.py \
  --input zkevm-metrics \
  --output hive/workspace/zkevm-converted-results \
  --clean-output
```

`list-zkevm-metrics-roots.sh` is used by CI after downloading metrics artifacts.
It emits directories that contain `<execution-client>/<zkvm>/*.json`, whether
GitHub Actions preserved each artifact under its own directory or flattened a
single artifact directly into the download path. The converter writes one result
JSON per execution-client/zkVM combination and a
generated details log for each result. To build a HiveUI site from only those
converted results:

```bash
HIVE_RESULTS_DIR=hive/workspace/zkevm-converted-results scripts/build-site.sh
```

Merge normal Hive results with converted zkEVM metrics:

```bash
scripts/merge-hive-results.sh \
  --source hive/workspace/zkevm-converted-results
```

The selected per-client results and every `--source` directory are validated
and merged directly into `HIVE_RESULTS_DIR`. Empty sources are skipped;
non-empty sources must contain valid top-level suite JSON, are single-client by
default, and may not overwrite a conflicting path. The generic compatibility
entrypoint remains available when all inputs are already Hive-shaped:

```bash
scripts/merge-hive-result-dirs.sh \
  --output hive/workspace/combined-results \
  --clean-output \
  hive/workspace/logs \
  hive/workspace/zkevm-converted-results
```

Build the static hive-ui site:

```bash
scripts/build-site.sh
```

The script cleans `SITE_DIR`, builds the pinned `HIVE_UI_REF`, generates
`discovery.json` and `listing.jsonl`, copies listed suite JSON files plus
public detail/simulator logs into `SITE_DIR/results/`, writes hive-ui
license/source notices, fails if any listing entry contains more than one
client, and fails if the output is larger than `SITE_MAX_SIZE_MB` (default:
`900`).

By default, the Pages site omits per-test client logs and removes their
`clientInfo.*.logFile` pointers from the published suite JSON. This keeps large
EEST runs under GitHub Pages' supported site size while preserving summary
pages and detail-log excerpts. Set `SITE_INCLUDE_CLIENT_LOGS=1` for local
debugging when full per-test log links are needed.

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
