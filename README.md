# eest-execution-witness-dashboard

This repository publishes execution witness test results as a static
[hive-ui](https://github.com/ethpandaops/hive-ui) site on GitHub Pages:
<https://eth-act.github.io/eest-execution-witness-dashboard/>.

The dashboard combines two result sets built from the same EEST
`blockchain_test_engine` fixtures:

- Hive: each execution client runs EEST `consume engine-witness`, which checks
  the execution witnesses the client returns.
- zkEVM: `zkevm-benchmark-workload` runs stateless-validator guests on zkVMs,
  and a converter turns their metrics into Hive-shaped results.

## Defaults

`scripts/env.sh` holds the shared defaults:

```bash
EEST_RELEASE_TAG=
EEST_REPO=https://github.com/ethereum/execution-specs.git
EEST_REF=tests-zkevm@v21.0.7
FILLER_PATH=tests/amsterdam/eip8025_optional_proofs
FORK=Amsterdam

HIVE_REPO=https://github.com/ethereum/hive.git
HIVE_REF=master

HIVE_UI_REPO=https://github.com/ethpandaops/hive-ui.git
HIVE_UI_REF=b5441f735366a4f7d13575a020ccd6517d7ecaf3
HIVE_UI_DISCOVERY_NAME=zkEVM

ZKEVM_BENCHMARK_WORKLOAD_REPO=https://github.com/eth-act/zkevm-benchmark-workload.git
ZKEVM_BENCHMARK_WORKLOAD_REF=v0.19.1
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

Scripts write checkouts and outputs to git-ignored directories:
`execution-specs/`, `hive/`, `hive-ui/`, `go-ethereum-src/`,
`zkevm-benchmark-workload/`, `zkevm-metrics/`, `fixtures/`, `site/`, and
`smoke-results/`.

### Execution clients

`config/el-clients.json` has one descriptor per client. These use JSON-RPC+RLP:

| Hive client | Repository | Ref |
| --- | --- | --- |
| `go-ethereum` | `ethereum/go-ethereum` | `master` |
| `ethrex` | `lambdaclass/ethrex` | `main` |
| `nethermind` | `NethermindEth/nethermind` | `master` |
| `nimbus-el` | `status-im/nimbus-eth1` | `master` |
| `besu` | `besu-eth/besu` | `main` |

These use REST+SSZ and run `consume engine-witness --ssz`. The refresh selects
them, and local runs opt in:

| Descriptor | Repository | Ref | Results |
| --- | --- | --- | --- |
| `nimbus-el-rest` | `status-im/nimbus-eth1` | `witness-rest-ssz-endpoint` | `nimbus-el_rest-ssz` |
| `reth-rest` | `paradigmxyz/reth` | `main` | `reth_rest-ssz` |
| `nethermind-rest` | `NethermindEth/nethermind` | `master` | `nethermind_rest-ssz` |

The REST results have their own client name, so Nimbus and Nethermind can run
both transports in the same site. The REST consumer ships in
`tests-zkevm@v21.0.1` and later; older refs lack `--ssz`.

Descriptors track each client's default branch, so every refresh tests current
code and shows fixes and regressions as they land. Releases wouldn't work for
every client anyway:

- Besu's latest release lacks the witness RPC.
- Nethermind `2.1.0` no longer builds. It pins .NET crypto packages with
  published security advisories, and Nethermind treats NuGet audit warnings as
  errors. Its REST endpoint also lacks two fixes: it's missing from
  `GET /engine/v1/capabilities`, so EEST skips every test, and it returns no
  witness for a payload it already knows.
- Reth `v2.7.0` has the REST endpoint but lacks a fix that keeps bytecode
  created during the block out of the witness. Reth's JSON-RPC witness method
  is still an open pull request, so Reth only runs over REST+SSZ.

Nimbus generates witnesses on demand and needs no extra startup flags;
`nimbus-el-rest` enables `--debug-engine-api-rest`. Reth and Nethermind serve
the REST witness endpoint on the Engine API port without extra flags.

Hive builds each client from its `Dockerfile.git`, which clones the descriptor
`ref` with `git clone --branch`. Use a branch or tag name, not a commit SHA.

### zkEVM guests

Workload `v0.19.1` downloads guests from the `ere-guests` `v0.19.1` release.
It provides Ethrex, Reth, and Zesu on SP1, ZisK, and OpenVM, Nimbus and
Nethermind on SP1 and ZisK, and Zilkworm on SP1 only. The Nimbus guest ID is
`nimbus`, and its Hive client ID is `nimbus-el`. Nethermind uses `nethermind`
for both.

## Publishing

### Refresh workflow

The Refresh execution witness dashboard workflow
(`.github/workflows/refresh-dashboard.yml`) prepares a dataset, runs eight Hive
client configurations and fourteen zkEVM runs, and publishes the site. It runs
every Monday and Thursday at 03:17 UTC. To run it now:

```bash
gh workflow run refresh-dashboard.yml --ref main
```

Only one refresh runs at a time; a new one waits for the current one to finish.
Each refresh uses the prefilled EEST release `tests-zkevm@v21.0.7`, every Hive
client in the two tables above, and every guest/zkVM pair the workload
provides. Hive, the workload, Rayon threads, hive-ui, and the site limit match
the defaults. Branch refs, such as Hive `master` and every client ref, resolve
on each run.

Failing tests and guest crashes are published as results. Infrastructure
failures, such as a failed job, missing Hive result JSON, or missing zkEVM
metrics, stop publication and leave the deployed site unchanged.

When a refresh fails, `rerun-failed-refresh.yml` reruns its failed jobs once.
If they fail again, the run stays failed so someone can look at it. Cancelled
refreshes aren't rerun.

### Stages

The refresh calls three workflows, which you can also dispatch alone to reuse
earlier results. All three must run from `main`.

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

To refresh or add one client, run `run-workloads.yml` for that client with
`zkevm_workload_runs=none`. Then run `publish.yml` with the full site
selection, and it combines the new artifact with the latest successful
artifacts of the other workloads.

Publication rules:

- A failed run leaves the previous successful artifact in use. A new client
  with no successful artifact fails publication and leaves the site unchanged.
- `el_clients=none` publishes only zkEVM results, and
  `zkevm_workload_runs=none` publishes only Hive results.
- `publish.yml` rejects result bundles from another dataset, expired
  artifacts, and runs outside `main`.

Datasets and result bundles last 90 days. When they expire, or when the shared
EEST, Hive, or benchmark settings change, prepare a new dataset and rerun every
workload. A release-mode dataset uses the whole fixture bundle; `filler_path`
and `fork` don't filter it.

The site's group title shows the release tag, for example
`tests-zkevm v21.0.7`. Fill-mode datasets use `execution-witness`.

`publish.yml` uploads the combined Hive results as a short-lived
`hive-combined-results-*` artifact. Failed runs upload debug artifacts with
the selected artifact metadata and staged results.

### Deployment

After the site passes `scripts/smoke-site.sh`, the workflow deploys it to
GitHub Pages and reruns the smoke test against the deployed `page_url`. Treat
`page_url` as the source of truth if the repository gets a custom domain.

To check a deployed site manually:

```bash
scripts/smoke-site.sh --url https://OWNER.github.io/REPOSITORY/
```

## Running locally

A full local run goes through the sections below in order.
[`scripts/README.md`](scripts/README.md) lists every script and covers the
details left out here.

### Local prerequisites

Local runs use the same tools as CI:

- Docker, usable without `sudo`. Hive builds and runs client containers, so
  `docker info` must succeed.
- Git, Rust stable with `cargo`, Go `1.24.x`, Node.js `22.x` with npm, and
  Python `3.12`.
- `uv`, `jq`, `curl`, and `rsync` on `PATH`.

### Environment

Scripts resolve paths from the repository root, so you can `cd` into
`execution-specs/` or `hive/` without moving outputs. To load or check the
defaults:

```bash
source scripts/env.sh
eest_dashboard_print_env
eest_dashboard_check_prereqs

scripts/env.sh --print
scripts/env.sh --check
scripts/env.sh --validate-eest-source
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
EEST_RELEASE_TAG='tests-zkevm@v21.0.7' scripts/prepare-fixtures.sh
```

Release mode ignores `EEST_REPO` and `EEST_REF`. It checks out
`ethereum/execution-specs` at that tag for the matching `consume` CLI, then
downloads the release's single `.tar.gz` asset, extracts it into
`FIXTURES_DIR`, and validates it.

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
  `consume engine-witness` fails, so failing tests still reach the dashboard.
  Set it to `0` to stop before merging.
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
hive-ui license and source notices. It fails if a listing entry names more than
one client or the site exceeds `SITE_MAX_SIZE_MB`.

To fit GitHub Pages, the build drops per-test descriptions and all logs. The
site keeps summary pages, test names, results, timings, comparisons, and client
metadata, but rows no longer expand and log links are hidden. The source
results and the `hive-combined-results-*` artifact keep everything. Set
`SITE_INCLUDE_CLIENT_LOGS=1` to keep descriptions and logs in a local build;
such builds can exceed the Pages size limit.

Preview the site over HTTP, not `file://`, so the browser fetches
`discovery.json`, `listing.jsonl`, and `results/` like the published site:

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

The PR smoke check runs the unit tests, then fills one empty-block
`blockchain_test_engine` test and runs it in parallel jobs. They use the same
scripts as `run-workloads.yml` and `publish.yml`:

- Geth runs it on Hive.
- Nimbus REST/SSZ runs it on Hive when the pull request changes the Hive
  scripts or patches, `scripts/setup-eest.sh`, `config/el-clients.json`,
  `scripts/env.sh`, the result checker, or the smoke workflow. Its image takes
  about 30 minutes to build, and the refresh always runs it. Geth
  already covers the fixture preparation scripts, so they don't trigger it.
- One job per zkVM runs every guest that the refresh runs on that zkVM. The
  pairs come from `refresh-dashboard.yml`, so new refresh pairs join the smoke.
  The benchmark downloads its guests and runtime images using its own
  dependency versions.
- A site job merges the Geth and zkEVM results, builds the hive-ui site, and
  runs `scripts/smoke-site.sh`.

Each workload must produce exactly one passing case, and the site must list
every result. The check doesn't generate proofs, publish datasets, or deploy
the site.

The jobs run on disposable XL runners. CI installs Python, Go, Rust stable,
uv, and the native packages listed in `.github/workflows/pr-smoke.yml` and
`.github/actions/smoke-setup`. The zkEVM jobs log in to GHCR with the job
token, and each one lists its guest results and Rust cache hit in its summary.

Pushes to `main` build the benchmark and save its Rust cache, which pull
requests and refreshes restore. Both use stable Rust, so the cache lasts until
the next Rust release or workload version. Cold runs take longer because they
build Geth, Nimbus, and the benchmark and pull the zkVM images. Results,
fixtures, Hive logs, and the built site stay available for seven days.

The final PR smoke gate requires every selected job to pass and notes when it
skipped Nimbus. Use `PR smoke` as the required check name in branch
protection. To reproduce the run locally, see
[the local commands](scripts/README.md#pr-smoke-check).
