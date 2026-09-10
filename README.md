# eest-execution-witness-dashboard

Static dashboard scaffolding for publishing execution witness Hive results with
`ethpandaops/hive-ui`. Hiveview is still used to generate Hive's
`listing.jsonl` index.

## Phase 1 Defaults

Default repositories, refs, and runtime settings:

```bash
EEST_RELEASE_TAG=
EEST_REPO=https://github.com/ethereum/execution-specs.git
EEST_REF=tests-zkevm@v0.8.4

HIVE_REPO=https://github.com/ethereum/hive.git
HIVE_REF=master

HIVE_UI_REPO=https://github.com/ethpandaops/hive-ui.git
HIVE_UI_REF=b5441f735366a4f7d13575a020ccd6517d7ecaf3
HIVE_UI_DISCOVERY_NAME=execution-witness

ZKEVM_BENCHMARK_WORKLOAD_REPO=https://github.com/eth-act/zkevm-benchmark-workload.git
ZKEVM_BENCHMARK_WORKLOAD_REF=v0.17.0
ZKEVM_WORKLOAD_RUNS=ethrex:zisk,reth:zisk
ZKEVM_RAYON_THREADS=10

EL_CLIENTS=go-ethereum,ethrex,nethermind,nimbus-el
EL_CLIENT_CONFIG=config/el-clients.json
EL_GUEST_CONFIG=config/el-guests.json
EL_CLIENT_OVERRIDES_JSON={}
HIVE_CONSUME_ALLOW_FAILURE=1
HIVE_CLIENT_RESULTS_DIR=hive/workspace/client-results
SITE_MAX_SIZE_MB=900
```

Default EL descriptors use JSON-RPC+RLP. These clients use `glamsterdam-devnet-8`:

- `go-ethereum`: `https://github.com/ethereum/go-ethereum.git`.
- `ethrex`: `https://github.com/lambdaclass/ethrex.git`.
- `nethermind`: `https://github.com/NethermindEth/nethermind.git`.

Nimbus (`nimbus-el`) uses `https://github.com/status-im/nimbus-eth1.git` at
`engine-new-payload-with-witness`, which provides `engine_newPayloadWithWitnessV5`
and generates witnesses on demand without extra startup flags.

All four build through Hive's corresponding `Dockerfile.git`. Besu is omitted
until its devnet 8 branch includes the required witness RPC.

Generated work directories are ignored by git:

- `execution-specs/`
- `hive/`
- `hive-ui/`
- `go-ethereum-src/`
- `zkevm-benchmark-workload/`
- `zkevm-metrics/`
- `fixtures/`
- `site/`
- `smoke-results/`

## Shared Environment

The shared defaults live in `scripts/env.sh`. They are resolved from the
dashboard repository root, so commands can safely `cd` into cloned
`execution-specs` or `hive` directories without moving generated outputs.

```bash
source scripts/env.sh
eest_dashboard_print_env
eest_dashboard_check_prereqs
```

The file can also be run directly:

```bash
scripts/env.sh --print
scripts/env.sh --check
scripts/env.sh --validate-eest-source
```

## Local Prerequisites

Local runs are expected to use the same tool versions planned for GitHub
Actions:

- Docker with the daemon running and usable by the current user without `sudo`.
- Git.
- Rust nightly with `cargo`.
- Go `1.24.x`.
- Node.js `22.x` and npm.
- Python `3.12`.
- `uv`, `jq`, `curl`, and `rsync` on `PATH`.

Docker permissions are the main local-only concern: Hive builds and runs client
containers, so `docker info` should succeed before running the later scripts.

## Fixture Generation

Prepare execution witness fixtures with:

```bash
scripts/prepare-fixtures.sh
```

With the default empty `EEST_RELEASE_TAG`, the script clones or updates
`execution-specs` at `EEST_REF`, runs `uv sync`, fills
`blockchain_test_engine` fixtures into `FIXTURES_DIR`, and fails if
`fixtures/.meta/index.json` does not include `blockchain_test_engine`.

To use pre-filled EEST release fixtures, set `EEST_RELEASE_TAG` to the exact
release tag:

```bash
EEST_RELEASE_TAG='tests-zkevm@v0.4.2' scripts/prepare-fixtures.sh
```

Release mode checks out `ethereum/execution-specs` at `EEST_RELEASE_TAG` for
the matching `consume` CLI, ignores `EEST_REPO` and `EEST_REF`, then downloads
and extracts the single `.tar.gz` asset attached to that exact GitHub release.

## Hive Consume

Prepare Hive and generate `hive/clients-local.yaml`:

```bash
scripts/setup-hive.sh
```

The default `EL_CLIENTS=go-ethereum,ethrex,nethermind,nimbus-el` selects every default
execution client, but the dashboard now runs each selected EL independently.
This produces one Hive result entry per EL client, matching the shape expected
by hive-ui's grouping views. Use a comma-separated subset, such as
`EL_CLIENTS=nimbus-el`, to run fewer clients.

`EL_CLIENT_OVERRIDES_JSON` can override descriptor fields without editing the
tracked config, for example:

```bash
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"ref":"other-branch"}}' scripts/setup-hive.sh
```

Per-client consume parallelism is also descriptor-owned. Use the same override
mechanism for ad hoc tuning:

```bash
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"hive_parallelism":4}}' scripts/run-hive-consume.sh
```

A custom go-ethereum descriptor with `managed_patch=geth-extra-flags` can
also configure its extra flags:

```bash
EL_CLIENT_OVERRIDES_JSON='{"go-ethereum":{"hive_extra_flags":""}}' scripts/setup-hive.sh
```

After fixtures exist, run Hive and consume them with:

```bash
scripts/run-hive-consume.sh
```

Each selected EL descriptor must define `hive_parallelism`, which lets EEST
pass `-n <N>` to pytest-xdist for that client. Direct single-client worker runs
can still set `HIVE_PARALLELISM` explicitly.

Per-client Hive results are staged in `HIVE_CLIENT_RESULTS_DIR` and merged into
`HIVE_RESULTS_DIR` after every selected EL produces at least one top-level
result JSON. The merged result set fails validation if any result entry contains
more than one client. On failure, the worker prints the tail of the relevant
`hive-dev-<client>.log` for startup or client-build debugging. By default,
`HIVE_CONSUME_ALLOW_FAILURE=1` continues after `consume engine-witness` returns
non-zero so downstream steps can publish the failure dashboard. Set it to `0`
when you want a failing consume run to stop before merge/build.
By default, `HIVE_DOCKER_OUTPUT=build` keeps Hive Docker output limited to
build logs and `HIVE_LOG_TO_STDOUT=0` writes Hive stdout/stderr only to
`hive-dev-<client>.log`. Set `HIVE_LOG_TO_STDOUT=1` to stream the same log to
the console.

## zkEVM Benchmark Workload

The dashboard can run `zkevm-benchmark-workload` directly against the same
prepared fixtures used by Hive. `ZKEVM_WORKLOAD_RUNS` is an explicit,
comma-separated list of `CLIENT:ZKVM` pairs. The default list runs both
`ethrex` and `reth` on `zisk`.

Resolve the workload matrix:

```bash
scripts/list-zkevm-workload-runs.sh
scripts/list-zkevm-workload-runs.sh --github-matrix
ZKEVM_WORKLOAD_RUNS=zesu:zisk,ethrex:zisk,ethrex:sp1 \
  scripts/list-zkevm-workload-runs.sh --github-matrix
```

Prepare the workload checkout:

```bash
scripts/setup-zkevm-benchmark-workload.sh
```

Run one workload entry:

```bash
ZKEVM_WORKLOAD_EXECUTION_CLIENT=ethrex \
ZKEVM_WORKLOAD_ZKVM=zisk \
scripts/run-zkevm-benchmark-workload.sh
```

Zesu guest artifact URLs can be configured in `config/el-guests.json`. Run an
opt-in Zesu workload entry:

```bash
ZKEVM_WORKLOAD_EXECUTION_CLIENT=zesu \
ZKEVM_WORKLOAD_ZKVM=zisk \
scripts/run-zkevm-benchmark-workload.sh
```

For one-off local testing, `ZKEVM_WORKLOAD_GUEST_ARTIFACT_BASE_URL` can override
the URL from `config/el-guests.json`.

Workload `v0.17.0` locks `ere-guests` to `v0.17.0`. Empty guest descriptors
use that release automatically, including Zesu on ZisK; custom artifact URLs
remain optional overrides. The pinned EEST source is `tests-zkevm@v0.8.4`.

The run writes metrics under `ZKEVM_METRICS_DIR`, defaulting to
`zkevm-metrics/`, in the shape expected by the converter:
`zkevm-metrics/<execution-client-version>/<zkvm-version>/*.json`.

## zkEVM Metrics Conversion

Convert `zkevm-benchmark-workload` output into Hive-compatible result files:

```bash
python3 scripts/convert-zkevm-metrics-to-hive-results.py \
  --input zkevm-metrics \
  --output hive/workspace/zkevm-converted-results \
  --clean-output
```

To publish both normal Hive runs and converted zkEVM metrics in one site, merge
the converted directory with the selected per-client results in one pass:

```bash
scripts/merge-hive-results.sh \
  --source hive/workspace/zkevm-converted-results
```

Then build from `HIVE_RESULTS_DIR` as usual:

```bash
scripts/build-site.sh
```

## Local upgrade smoke and PR check

Run the reusable smoke test with already prepared local inputs:

```bash
scripts/smoke-upgrade.sh \
  --guest-binaries /path/to/ere-guests-v0.17.0 \
  --client-images /path/to/local-client-images.json \
  --check-only
```

Remove `--check-only` to fill five header-witness cases in both fixture formats,
build the workload, execute the selected clients and guests, and convert the
metrics. `--fixtures PATH` reuses a small fixture bundle by copying it into the
run directory. Inputs and existing results are left intact. See
[the script reference](scripts/README.md#local-upgrade-smoke) for image mappings,
prerequisites, and output details.

Dependency checks and compilation may download Cargo, Go, and Python packages.
Cargo and uv use `--locked`, and Go uses `-mod=readonly`. Execution uses the
prepared local images and guest binaries. Logs and summaries are preserved
under `smoke-results/run-*`.

The PR-only workflow prepares source checkouts, images, and guests on disposable
XL runners, then invokes this same script for Geth, Ethrex, Nethermind, Nimbus, and
Ethrex/Reth/Zesu on ZisK. It does not publish datasets or deploy the dashboard. Its stable
**PR smoke** check succeeds only when both local checks and execution smoke
succeed. Missing, skipped, duplicate, failed, or timed-out cases fail the check.
Diagnostics are retained for seven days.

A green check covers this small execution-and-conversion path. It does not
certify the full optional-proofs suite or SP1/OpenVM. The workflow file does not
configure branch protection; `PR smoke` is the check name to use if protection
is configured separately.

## Static Site Build

After Hive results exist, build the static hive-ui site with:

```bash
scripts/build-site.sh
```

The script recreates `SITE_DIR`, builds the pinned `HIVE_UI_REF`, writes
`site/discovery.json`, writes `site/listing.jsonl`, copies the listed suite
JSON files and public detail/simulator logs into `site/results/`, writes hive-ui
license/source notices, fails if any listing entry has more than one client,
and fails if the generated site exceeds `SITE_MAX_SIZE_MB`.

Per-test client logs are omitted from the Pages site by default because large
EEST runs can exceed GitHub Pages' supported site size. Set
`SITE_INCLUDE_CLIENT_LOGS=1` for local debugging when you need the per-test log
links and are not publishing to Pages.

## Local Preview and Smoke Test

Preview the generated static site with a simple HTTP server:

```bash
source scripts/env.sh
cd "$SITE_DIR"
python3 -m http.server 8081 --bind 127.0.0.1
```

Open `http://127.0.0.1:8081/`. Use HTTP rather than `file://` so browser
requests for `discovery.json`, `listing.jsonl`, and `results/...` are
exercised.

Before publishing, run:

```bash
scripts/smoke-site.sh
```

The smoke test serves `SITE_DIR` under a non-root project path, fetches
`discovery.json`, `listing.jsonl`, and the first `results/...` entry over HTTP,
checks that static paths are relative for GitHub Pages project URLs, and scans
public result logs for common secret or private RPC URL patterns.

## GitHub Pages Publishing

Publishing is split into three manually dispatched workflows so successful
client results can be reused independently:

1. `.github/workflows/prepare-dataset.yml` prepares fixtures and pins the
   shared EEST, Hive, and zkevm-benchmark-workload toolchains. Its workflow run
   ID is the immutable `dataset_run_id`.
2. `.github/workflows/run-workloads.yml` runs any selected subset of Hive
   clients and zkEVM execution-client/zkVM pairs against that dataset.
3. `.github/workflows/publish.yml` selects the newest successful artifact for
   every requested workload in the dataset, merges the results, and deploys an
   atomic Pages site.

All three publishable stages must run from `main`. A typical operation is:

```bash
gh workflow run prepare-dataset.yml --ref main
# Copy the completed prepare workflow's run ID from its URL or job summary.
DATASET_RUN_ID=123456789

gh workflow run run-workloads.yml --ref main \
  -f dataset_run_id="$DATASET_RUN_ID" \
  -f el_clients=ethrex \
  -f zkevm_workload_runs=zesu:zisk,ethrex:zisk,ethrex:sp1

gh workflow run publish.yml --ref main \
  -f dataset_run_id="$DATASET_RUN_ID" \
  -f el_clients=ethrex \
  -f zkevm_workload_runs=zesu:zisk,ethrex:zisk,ethrex:sp1
```

The underlying pipeline remains:

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

Dataset preparation supports both fill mode and an exact release tag such as
`tests-zkevm@v0.4.2`. Dataset manifests and fixture archives are retained for
90 days. Reusable result bundles are also retained for 90 days and contain a
validated manifest plus their Hive results or zkEVM metrics payload.
When a release tag is present, the published HiveUI group title displays it as
`tests-zkevm v0.4.2`; fill-mode datasets retain the `execution-witness` title.

To refresh one client after changing its descriptor ref, dispatch
`run-workloads.yml` with that client and `zkevm_workload_runs=none`,
then dispatch `publish.yml` with the complete desired site selection. The
publisher combines the new client artifact with the preceding successful
artifacts for the other clients. Adding a client follows the same process. If
a refresh fails before producing a reusable artifact, the previous successful
artifact remains eligible; a new client with no successful artifact causes
publication to fail without changing the deployed site.

Set `el_clients=none` to run or publish only zkEVM results, or set
`zkevm_workload_runs=none` for Hive-only operation. Result bundles
from another dataset, an expired artifact, or a non-`main` run are rejected.
When the dataset artifacts expire or shared EEST/Hive/benchmark settings must
change, prepare a new dataset and run every required workload once.

Missing Hive result JSON or missing zkEVM metrics is treated as an
infrastructure failure. Ordinary failing Hive tests and per-fixture zkEVM
guest crashes are still published as dashboard results. Publish runs upload
the full combined Hive results as a short-retention artifact, while failed
runs upload debug artifacts containing selected artifact metadata and staged
results.

After the generated site passes the local smoke test, the workflow configures
GitHub Pages, uploads `site/` as a Pages artifact, deploys it, and runs the
same smoke script against the deployed `page_url`.

The expected repository Pages URL is:

```text
https://eth-act.github.io/eest-execution-witness-dashboard/
```

The workflow's `page_url` output is the source of truth after deployment,
especially if the repository is later configured with a custom domain.

To check a deployed site manually:

```bash
scripts/smoke-site.sh --url https://OWNER.github.io/REPOSITORY/
```
