# eest-execution-witness-dashboard

Publishes execution witness test results as a static
[hive-ui](https://github.com/ethpandaops/hive-ui) site on GitHub Pages:
<https://eth-act.github.io/eest-execution-witness-dashboard/>.

The dashboard combines two result sets built from the same EEST
`blockchain_test_engine` fixtures:

- **Hive:** each execution client runs EEST `consume engine-witness`, which
  checks the execution witnesses the client returns.
- **zkEVM:** `zkevm-benchmark-workload` runs stateless-validator guests on zkVMs.
  A converter turns their metrics into Hive-shaped results.

## Defaults

`scripts/env.sh` holds the shared defaults:

```bash
EEST_RELEASE_TAG=
EEST_REPO=https://github.com/ethereum/execution-specs.git
EEST_REF=tests-zkevm@v21.0.1
FILLER_PATH=tests/amsterdam/eip8025_optional_proofs
FORK=Amsterdam

HIVE_REPO=https://github.com/ethereum/hive.git
HIVE_REF=master

HIVE_UI_REPO=https://github.com/ethpandaops/hive-ui.git
HIVE_UI_REF=b5441f735366a4f7d13575a020ccd6517d7ecaf3
HIVE_UI_DISCOVERY_NAME=zkEVM

ZKEVM_BENCHMARK_WORKLOAD_REPO=https://github.com/eth-act/zkevm-benchmark-workload.git
ZKEVM_BENCHMARK_WORKLOAD_REF=v0.18.0
ZKEVM_WORKLOAD_RUNS=ethrex:zisk,reth:zisk
ZKEVM_RAYON_THREADS=10

EL_CLIENTS=go-ethereum,ethrex,nethermind,nimbus-el,besu
EL_CLIENT_CONFIG=config/el-clients.json
EL_GUEST_CONFIG=config/el-guests.json
EL_CLIENT_OVERRIDES_JSON={}
HIVE_CONSUME_ALLOW_FAILURE=1
HIVE_CLIENT_RESULTS_DIR=hive/workspace/client-results
SITE_MAX_SIZE_MB=900
```

### Execution clients

`config/el-clients.json` defines one JSON-RPC+RLP descriptor per client:

| Hive client | Repository | Ref |
| --- | --- | --- |
| `go-ethereum` | `ethereum/go-ethereum` | `v1.17.7` |
| `ethrex` | `lambdaclass/ethrex` | `v29.0.0` |
| `nethermind` | `NethermindEth/nethermind` | `2.1.0` |
| `nimbus-el` | `status-im/nimbus-eth1` | `master` |
| `besu` | `besu-eth/besu` | `main` |

The tags are each client's release for the Glamsterdam upgrade on Sepolia.
Besu uses `main` because its latest release lacks the witness RPC. Nimbus
generates witnesses on demand and needs no extra startup flags.

Hive builds each client from its `Dockerfile.git`, which clones the descriptor
`ref` with `git clone --branch`. Use a branch or tag name, not a commit SHA.

Nimbus REST+SSZ is available as the `nimbus-el-rest` descriptor, selected by CI
and opt-in for local runs. It builds `status-im/nimbus-eth1` at
`witness-rest-ssz-endpoint`, enables `--debug-engine-api-rest`, and runs
`consume engine-witness --ssz`. Results use `nimbus-el_rest-ssz`, so both
Nimbus transports can be selected together. The REST consumer ships in the
default EEST pin, `tests-zkevm@v21.0.1`; older refs lack `--ssz`.

### zkEVM guests

Workload `v0.18.0` downloads guests from the `ere-guests` `v0.18.0` release.
It provides Ethrex and Reth on SP1, ZisK, and OpenVM, and Nimbus on ZisK only.
The Nimbus guest ID is `nimbus`; its Hive client ID is `nimbus-el`.

### Generated directories

Scripts write checkouts and outputs to git-ignored directories:
`execution-specs/`, `hive/`, `hive-ui/`, `go-ethereum-src/`,
`zkevm-benchmark-workload/`, `zkevm-metrics/`, `fixtures/`, `site/`, and
`smoke-results/`.

## Publishing

### Refresh workflow

The **Refresh execution witness dashboard** workflow
(`.github/workflows/refresh-dashboard.yml`) prepares a dataset, runs six Hive
client configurations and seven zkEVM runs, and publishes the site. It runs
every Monday and Thursday at 03:17 UTC. To run it now:

```bash
gh workflow run refresh-dashboard.yml --ref main
```

Only one refresh runs at a time; a new one waits for the current one to finish.
Each refresh uses:

- The prefilled EEST release `tests-zkevm@v21.0.1`, Hive `master`,
  `zkevm-benchmark-workload` `v0.18.0`, and 10 Rayon threads.
- Hive clients `ethrex,go-ethereum,nimbus-el,nethermind,besu,nimbus-el-rest`,
  with the checked-in descriptors.
- zkEVM runs for Ethrex and Reth on SP1, ZisK, and OpenVM, and Nimbus on ZisK.
- hive-ui commit `b5441f735366a4f7d13575a020ccd6517d7ecaf3` and a 900 MiB
  site limit.

Branch refs, such as Hive `master` and Besu `main`, resolve on each run.

Failing tests and guest crashes are published as results. Infrastructure
failures, such as a failed job, missing Hive result JSON, or missing zkEVM
metrics, stop publication and leave the deployed site unchanged.

### Stages

The refresh calls three workflows. You can also dispatch each one alone to
reuse earlier results. All three must run from `main`.

1. `prepare-dataset.yml` prepares fixtures and pins EEST, Hive, and
   `zkevm-benchmark-workload`. Its run ID is the `dataset_run_id`.
2. `run-workloads.yml` runs selected Hive clients and zkEVM runs against a
   dataset.
3. `publish.yml` takes the newest successful artifact for each requested
   workload in the dataset, merges the results, and deploys the site.

A refresh's run ID is also its dataset ID, so standalone runs can reuse its
artifacts. For example:

```bash
gh workflow run prepare-dataset.yml --ref main
# Copy the completed prepare run's ID from its URL or job summary.
DATASET_RUN_ID=123456789

gh workflow run run-workloads.yml --ref main \
  -f dataset_run_id="$DATASET_RUN_ID" \
  -f el_clients=ethrex \
  -f zkevm_workload_runs=nimbus:zisk,ethrex:zisk,ethrex:sp1

gh workflow run publish.yml --ref main \
  -f dataset_run_id="$DATASET_RUN_ID" \
  -f el_clients=ethrex \
  -f zkevm_workload_runs=nimbus:zisk,ethrex:zisk,ethrex:sp1
```

To refresh one client after changing its ref, run `run-workloads.yml` for that
client with `zkevm_workload_runs=none`. Then run `publish.yml` with the full
site selection; it combines the new artifact with the latest successful
artifacts of the other workloads. Add a client the same way.

Publication rules:

- A failed run leaves the previous successful artifact in use. A new client
  with no successful artifact fails publication and leaves the site unchanged.
- `el_clients=none` publishes only zkEVM results; `zkevm_workload_runs=none`
  publishes only Hive results.
- `publish.yml` rejects result bundles from another dataset, expired
  artifacts, and runs outside `main`.

Datasets and result bundles last 90 days. When they expire, or when the shared
EEST, Hive, or benchmark settings change, prepare a new dataset and rerun every
workload. A release-mode dataset uses the whole fixture bundle; `filler_path`
and `fork` do not filter it.

The site's group title shows the release tag, for example
`tests-zkevm v21.0.1`. Fill-mode datasets use `execution-witness`.

`publish.yml` uploads the combined Hive results as a short-lived
`hive-combined-results-*` artifact. Failed runs upload debug artifacts with
the selected artifact metadata and staged results.

### Deployment

After the site passes `scripts/smoke-site.sh`, the workflow deploys it to
GitHub Pages and reruns the smoke test against the deployed `page_url`. Treat
`page_url` as the source of truth if the repository gets a custom domain.

Check a deployed site manually:

```bash
scripts/smoke-site.sh --url https://OWNER.github.io/REPOSITORY/
```

## Running locally

### Local prerequisites

Local runs use the same tools as CI:

- Docker, usable without `sudo`. Hive builds and runs client containers, so
  `docker info` must succeed.
- Git, Rust nightly with `cargo`, Go `1.24.x`, Node.js `22.x` with npm, and
  Python `3.12`.
- `uv`, `jq`, `curl`, and `rsync` on `PATH`.

### Environment

Scripts resolve paths from the repository root, so you can `cd` into
`execution-specs/` or `hive/` without moving outputs. Load or check the
defaults:

```bash
source scripts/env.sh
eest_dashboard_print_env
eest_dashboard_check_prereqs

scripts/env.sh --print
scripts/env.sh --check
scripts/env.sh --validate-eest-source
```

### Pipeline

A full local run calls these scripts in order:

```text
scripts/prepare-fixtures.sh
scripts/setup-eest.sh
scripts/run-hive-consume-client.sh CLIENT_ID
scripts/setup-zkevm-benchmark-workload.sh
scripts/run-zkevm-benchmark-workload.sh
scripts/convert-zkevm-metrics-to-hive-results.py
scripts/merge-hive-results.sh --source hive/workspace/zkevm-converted-results
scripts/build-site.sh
scripts/smoke-site.sh
```

### Fixtures

```bash
scripts/prepare-fixtures.sh
```

In fill mode, the default, the script checks out `execution-specs` at
`EEST_REF` and runs `uv sync`. It then fills `blockchain_test_engine` fixtures
for `FILLER_PATH` and `FORK` into `FIXTURES_DIR` and checks that
`.meta/index.json` lists that format.

To use a release's prefilled fixtures instead, set `EEST_RELEASE_TAG`:

```bash
EEST_RELEASE_TAG='tests-zkevm@v21.0.1' scripts/prepare-fixtures.sh
```

Release mode ignores `EEST_REPO` and `EEST_REF`. It checks out that tag for the
matching `consume` CLI and extracts the release's single `.tar.gz` asset.

### Hive

Generate `hive/clients-local.yaml`, then consume the fixtures:

```bash
scripts/setup-hive.sh
scripts/run-hive-consume.sh
```

`run-hive-consume.sh` runs each client in `EL_CLIENTS` separately, so hive-ui
shows one result entry per client. Set a subset, such as
`EL_CLIENTS=nimbus-el`, to run fewer clients.

`EL_CLIENT_OVERRIDES_JSON` overrides descriptor fields without editing the
config:

```bash
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"ref":"other-branch"}}' scripts/setup-hive.sh
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"hive_parallelism":4}}' scripts/run-hive-consume.sh
# A custom go-ethereum descriptor with managed_patch=geth-extra-flags:
EL_CLIENT_OVERRIDES_JSON='{"go-ethereum":{"hive_extra_flags":""}}' scripts/setup-hive.sh
```

Each descriptor must set `hive_parallelism`, which EEST passes to pytest-xdist
as `-n`. Direct `run-hive-consume-client.sh` runs can set `HIVE_PARALLELISM`
instead.

Each client writes results to `HIVE_CLIENT_RESULTS_DIR`. Once every selected
client has at least one top-level result JSON, the script merges them into
`HIVE_RESULTS_DIR`. The merge fails if a result entry names more than one
client. When a client fails, the script prints the tail of its
`hive-dev-<client>.log`.

These variables control failure handling and logs:

- `HIVE_CONSUME_ALLOW_FAILURE=1` (default) continues after
  `consume engine-witness` fails, so failures still reach the dashboard. Set
  it to `0` to stop before merging.
- `HIVE_DOCKER_OUTPUT=build` (default) limits Docker output to build logs.
- `HIVE_LOG_TO_STDOUT=1` streams Hive output to the console as well as to
  `hive-dev-<client>.log`. The default, `0`, writes only the log file.

### zkEVM workload

`ZKEVM_WORKLOAD_RUNS` lists `CLIENT:ZKVM` pairs. Resolve the matrix, prepare
the workload checkout, and run one entry:

```bash
scripts/list-zkevm-workload-runs.sh
ZKEVM_WORKLOAD_RUNS=nimbus:zisk,ethrex:zisk,ethrex:sp1 \
  scripts/list-zkevm-workload-runs.sh --github-matrix

scripts/setup-zkevm-benchmark-workload.sh
scripts/run-zkevm-benchmark-workload.sh ethrex zisk
```

The workload reads `FIXTURES_DIR/blockchain_tests_engine`, the same fixtures
Hive consumes. It writes metrics to `ZKEVM_METRICS_DIR` (default
`zkevm-metrics/`) as `<execution-client-version>/<zkvm-version>/*.json`.

To test other guest builds, set `guest_artifact_base_url` in
`config/el-guests.json`, or set `ZKEVM_WORKLOAD_GUEST_ARTIFACT_BASE_URL` for a
single run.

Convert the metrics, merge them with the Hive results, and build the site:

```bash
python3 scripts/convert-zkevm-metrics-to-hive-results.py \
  --input zkevm-metrics \
  --output hive/workspace/zkevm-converted-results \
  --clean-output
scripts/merge-hive-results.sh --source hive/workspace/zkevm-converted-results
scripts/build-site.sh
```

### Site

`scripts/build-site.sh` builds hive-ui at `HIVE_UI_REF` into a fresh
`SITE_DIR`. It uses Hive's `hiveview` to write `listing.jsonl`, writes
`discovery.json`, copies the listed suite JSON files into `results/`, and adds
hive-ui license notices. It fails if a listing entry names more than one client
or the site exceeds `SITE_MAX_SIZE_MB`.

To fit GitHub Pages, the build drops per-test descriptions and all logs. The
site keeps test names, results, timings, and client metadata; rows no longer
expand, and log links are hidden. The source results and the
`hive-combined-results-*` artifact keep everything. Set
`SITE_INCLUDE_CLIENT_LOGS=1` to keep descriptions and logs in a local build;
such builds can exceed the Pages size limit.

Preview the site over HTTP, not `file://`, so the browser fetches
`discovery.json`, `listing.jsonl`, and `results/`:

```bash
source scripts/env.sh
cd "$SITE_DIR"
python3 -m http.server 8081 --bind 127.0.0.1
```

Then open `http://127.0.0.1:8081/`.

Before publishing, run `scripts/smoke-site.sh`. It serves `SITE_DIR` under a
non-root path and fetches `discovery.json`, `listing.jsonl`, and the first
`results/` entry. It also checks that paths are relative and scans public logs
for secrets and private RPC URLs.

## PR smoke check

The **PR smoke** check runs the unit tests, then fills one empty-block
`blockchain_test_engine` test. Geth and Nimbus REST/SSZ run it on Hive and
Ethrex runs it on ZisK, using the same scripts as `run-workloads.yml`. The check
converts the zkEVM metrics and fails unless each workload produces exactly one
passing case. It does not generate proofs, publish datasets, or deploy the site.

The check runs on a disposable XL runner with a 90-minute timeout. Caches speed
up repeat runs, but cold runs still compile the benchmark and build Geth and
Nimbus. The job summary records elapsed time and cache hits. Fixtures, results,
and Hive logs stay available for seven days.

Use `PR smoke` as the required check name in branch protection. To reproduce
the run, see [the local commands](scripts/README.md#pr-smoke-check).
