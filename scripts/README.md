# Scripts

These scripts prepare fixtures, run Hive and `zkevm-benchmark-workload`, and
build the hive-ui site, both locally and in CI. They load their defaults from
`env.sh`, which you can source from any working directory, and resolve paths
from the repository root.

For a full local run, see [Running locally](../README.md#running-locally) in
the main README. This file lists what each script does and the details the
main README leaves out.

- `env.sh`: shared defaults and prerequisite checks.
- `prepare-fixtures.sh`: fills fixtures (fill mode) or downloads a release's
  prefilled fixtures (release mode) into `FIXTURES_DIR`, then validates them.
- `fill-fixtures.sh`: clones or updates `execution-specs`, runs `uv sync`,
  fills witness fixtures into `FIXTURES_DIR`, and validates the fixture index.
- `validate-fixtures.sh`: checks that an existing fixture directory contains
  `blockchain_test_engine` fixtures.
- `setup-eest.sh`: clones or updates `execution-specs` and runs `uv sync`
  without filling fixtures. In release mode, it checks out `EEST_RELEASE_TAG`.
  CI consume jobs run it after downloading the shared fixtures artifact.
- `download-run-artifact.sh`: downloads one artifact from a workflow run,
  checks its digest, and extracts it. A stalled or interrupted download resumes
  from the bytes already on disk. Workload jobs use it for the dataset
  fixtures.
- `setup-hive.sh`: clones or updates Hive, builds `./hive`, applies the
  managed patches, and generates `clients-local.yaml` from the selected client
  descriptors.
- `list-el-clients.sh`: resolves the selected client descriptors and prints a
  table, JSON, IDs, or a GitHub Actions matrix.
- `run-hive-consume-client.sh`: runs `consume engine-witness` for one client
  into its own result directory.
- `run-hive-consume.sh`: cleans `HIVE_CLIENT_RESULTS_DIR`, prepares Hive, runs
  `run-hive-consume-client.sh` once per selected client, and merges the results
  into `HIVE_RESULTS_DIR`. Each client's Hive stdout and stderr go to
  `hive-dev-<client>.log`.
- `list-zkevm-workload-runs.sh`: validates the selected `CLIENT:ZKVM` runs and
  prints them, or a GitHub Actions matrix with `--github-matrix`.
- `setup-zkevm-benchmark-workload.sh`: clones or updates
  `zkevm-benchmark-workload` and checks out `ZKEVM_BENCHMARK_WORKLOAD_REF`.
- `run-zkevm-benchmark-workload.sh`: runs one stateless-validator benchmark
  against `FIXTURES_DIR/blockchain_tests_engine`.
- `list-zkevm-metrics-roots.sh`: finds downloaded zkEVM metrics roots in either
  GitHub Actions download layout.
- `convert-zkevm-metrics-to-hive-results.py`: converts `zkevm-metrics/` output
  into Hive-shaped result files.
- `merge-hive-results.sh`: validates and merges the per-client Hive results and
  any extra Hive-shaped sources in one pass, without overwriting conflicting
  files.
- `merge-hive-result-dirs.py`: the validator and merge engine behind both merge
  scripts.
- `merge-hive-result-dirs.sh`: a compatibility entrypoint that merges arbitrary
  directories of Hive-shaped result JSON and logs.
- `dashboard-artifacts.py`: creates and validates immutable dataset and result
  manifests, and deterministically picks reusable artifacts across runs.
- `check-smoke-results.py`: requires one passing smoke case from one Hive
  client (`hive`) or one zkEVM guest, including metrics conversion (`zkevm`).
- `build-site.sh`: cleans `SITE_DIR` and builds the static hive-ui site into
  it.
- `smoke-site.sh`: checks a local site before publishing, or a deployed one
  after.

## Hive patches

`setup-hive.sh` applies the patch named in a descriptor's `managed_patch`
field. It removes managed patches before updating Hive and reapplies them when
the client is selected. Override `managed_patch` with an empty string to build
a custom descriptor without its patch.

`nimbus-skip-lfs` applies `patches/hive-nimbus-skip-lfs.patch` to Hive's
`clients/nimbus-el/Dockerfile.git`. It sets `GIT_LFS_SKIP_SMUDGE=1` in the
build stage before cloning, so the build skips unused network data in nested
submodules. One of those files, the `glamsterdam-devnets` consensus genesis,
ran out of its upstream Git LFS budget and blocked the
[September 24, 2026 run](https://github.com/eth-act/eest-execution-witness-dashboard/actions/runs/36032246820/job/107744808338).
Setup fails if the patch no longer matches the upstream Dockerfile. With Hive
`43ea47be`, Nimbus `4dc018eb`, and execution-specs `8cd0018e`, the image built
with LFS downloads disabled and the Amsterdam empty-block witness smoke test
passed (one case, no skips or timeouts). We didn't run the full witness suite
on it.

`reth-portable-feature` applies `patches/hive-reth-portable-feature.patch`.
Reth `main` removed the `reth-revm` crate in
[paradigmxyz/reth#25002](https://github.com/paradigmxyz/reth/pull/25002), but
Hive's `clients/reth/Dockerfile.git` still builds with `reth-revm/portable`,
which broke the Reth image build in the
[October 26, 2026 run](https://github.com/eth-act/eest-execution-witness-dashboard/actions/runs/40297073604/job/121899790269).
The patch uses the Reth binary's `portable` feature instead. Once Hive's
Dockerfile stops using `reth-revm/portable`, setup logs that it's skipping the
patch, and we can delete it.

## zkEVM workload

`ZKEVM_WORKLOAD_RUNS` defaults to `ethrex:zisk,reth:zisk` and also accepts
`zesu`, `nimbus`, `nethermind`, and `zilkworm` as execution clients. Set it to
an empty string, `none`, `skip`, or `empty` to skip workload runs.

Guest descriptors in `config/el-guests.json` can set `guest_artifact_base_url`
for a guest and override it per zkVM under
`zkvms.<zkvm>.guest_artifact_base_url`. The `--github-matrix` output includes
each resolved URL. Empty descriptors use the `ere-guests` release that the
workload locks. `ZKEVM_WORKLOAD_GUEST_ARTIFACT_BASE_URL` is only meant for a
temporary override of a single local run.

`run-zkevm-benchmark-workload.sh` takes the client and zkVM as two arguments,
or from `ZKEVM_WORKLOAD_EXECUTION_CLIENT` and `ZKEVM_WORKLOAD_ZKVM`. It resets
`ZKEVM_METRICS_DIR`, sets `RAYON_NUM_THREADS` from `ZKEVM_RAYON_THREADS` by
default, and runs `cargo run --locked --release -p ere-hosts` on the engine
fixtures. It fails unless that produces at least one metrics JSON.

## Merging results

In CI, `list-zkevm-metrics-roots.sh` runs after the metrics artifacts download.
It prints the directories that contain `<execution-client>/<zkvm>/*.json`,
whether GitHub Actions kept each artifact in its own directory or flattened a
single artifact into the download path:

```bash
scripts/list-zkevm-metrics-roots.sh zkevm-metrics-artifacts
```

The converter writes one result JSON per execution-client/zkVM pair and a
generated details log for each. To build a site from only the converted
results:

```bash
HIVE_RESULTS_DIR=hive/workspace/zkevm-converted-results scripts/build-site.sh
```

`merge-hive-results.sh` merges the selected per-client results and every
`--source` directory straight into `HIVE_RESULTS_DIR`. It skips empty sources.
A non-empty source must contain valid top-level suite JSON, holds one client by
default, and can't overwrite a conflicting path. When every input is already
Hive-shaped, `merge-hive-result-dirs.sh` merges arbitrary directories:

```bash
scripts/merge-hive-result-dirs.sh \
  --output hive/workspace/combined-results \
  --clean-output \
  hive/workspace/logs \
  hive/workspace/zkevm-converted-results
```

## Site smoke test

`smoke-site.sh` serves `SITE_DIR` at
`http://127.0.0.1:8765/eest-execution-witness-dashboard/` and checks that
`discovery.json`, `listing.jsonl`, the first suite result, and a result asset
it references load over HTTP. It fails on root-relative paths, which break
GitHub Pages project URLs, and scans `SITE_DIR/results/` for common secret,
credential, and private RPC URL patterns. `SITE_SMOKE_PORT` and
`SITE_SMOKE_BASE_PATH` override the port and project path.

With `--url`, it fetches `discovery.json`, `listing.jsonl`, the first listed
result, and one referenced result asset, if there is one, from a deployed site
instead.

## PR smoke check

To reproduce the [PR smoke check](../README.md#pr-smoke-check), run these
commands from the repository root with the
[local prerequisites](../README.md#local-prerequisites) installed. They update
the generated source checkouts and replace outputs under `smoke-results/`.

```bash
(
  export EEST_RELEASE_TAG=''
  export FILLER_PATH=tests/amsterdam/eip8025_optional_proofs/test_witness_headers.py::test_witness_headers_empty_block
  export FILL_TEST_NAME=0
  export FIXTURES_DIR="$PWD/smoke-results/fixtures"
  export HIVE_CLIENT_RESULTS_DIR="$PWD/smoke-results/hive-results" HIVE_PARALLELISM=1
  export HIVE_CONSUME_ALLOW_FAILURE=0 HIVE_PRUNE_SKIPPED=0 HIVE_LOG_TO_STDOUT=1
  export ZKEVM_RAYON_THREADS=2 ERE_IMAGE_REGISTRY=ghcr.io/eth-act/ere

  set -e
  scripts/prepare-fixtures.sh

  scripts/run-hive-consume-client.sh go-ethereum
  python3 scripts/check-smoke-results.py hive --fixtures "$FIXTURES_DIR" \
    --results "$HIVE_CLIENT_RESULTS_DIR/go-ethereum" --client go-ethereum_rlp-engineapi

  scripts/setup-zkevm-benchmark-workload.sh
  ZKEVM_METRICS_DIR="$PWD/smoke-results/metrics/ethrex-zisk" \
    scripts/run-zkevm-benchmark-workload.sh ethrex zisk
  python3 scripts/convert-zkevm-metrics-to-hive-results.py --clean-output \
    --input smoke-results/metrics/ethrex-zisk --output smoke-results/converted/ethrex-zisk
  python3 scripts/check-smoke-results.py zkevm --fixtures "$FIXTURES_DIR" \
    --metrics smoke-results/metrics/ethrex-zisk \
    --converted smoke-results/converted/ethrex-zisk --client ethrex --zkvm zisk
)
```

For another guest, repeat the run, convert, and check commands with its client
and zkVM. For a REST+SSZ client, pass its descriptor to
`run-hive-consume-client.sh` and its result name to `--client`, for example
`nimbus-el-rest` and `nimbus-el_rest-ssz`, `reth-rest` and `reth_rest-ssz`, or
`nethermind-rest` and `nethermind_rest-ssz`.

The `hive` check exits nonzero unless the engine fixture contains the selected
case and the named Hive client passes it without skipping. The `zkevm` check
also requires the guest output to match and the conversion to keep the passing
result. Both only read the fixture index and result files; they don't prepare
or run workloads.
