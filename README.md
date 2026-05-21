# eest-execution-witness-dashboard

Static dashboard scaffolding for publishing execution witness Hive results with
`ethpandaops/hive-ui`. Hiveview is still used to generate Hive's
`listing.jsonl` index.

## Phase 1 Defaults

The first implementation pass uses public branch refs rather than immutable
SHAs or tags. These refs were checked with `git ls-remote` on 2026-05-21:

```bash
EEST_RELEASE_TAG=
EEST_REPO=https://github.com/ethereum/execution-specs.git
EEST_REF=projects/zkevm-releases

HIVE_REPO=https://github.com/ethereum/hive.git
HIVE_REF=master

HIVE_UI_REPO=https://github.com/ethpandaops/hive-ui.git
HIVE_UI_REF=b5441f735366a4f7d13575a020ccd6517d7ecaf3
HIVE_UI_DISCOVERY_NAME=execution-witness

EL_CLIENTS=go-ethereum,ethrex,nethermind
EL_CLIENT_CONFIG=config/el-clients.json
EL_CLIENT_OVERRIDES_JSON={}
HIVE_PARALLELISM=1
HIVE_CONSUME_ALLOW_FAILURE=1
HIVE_CLIENT_RESULTS_DIR=hive/workspace/client-results
SITE_MAX_SIZE_MB=900
```

Default EL descriptors:

- `go-ethereum`: `https://github.com/jsign/go-ethereum.git` at
  `zkevm-v0.3.4-hive`, with `--bal.executionmode=sequential` injected into
  Hive's `geth.sh`.
- `ethrex`: `https://github.com/jsign/ethrex.git` at
  `jsign-engine-newpayload-with-witness-v5`, built through Hive's
  `clients/ethrex/Dockerfile.git`.
- `nethermind`: `https://github.com/Dyslex7c/nethermind.git` at
  `new-payload-with-witness-ssz`, built through Hive's
  `clients/nethermind/Dockerfile.git` and selected for RLP JSON-RPC mode.

Generated work directories are ignored by git:

- `execution-specs/`
- `hive/`
- `hive-ui/`
- `go-ethereum-src/`
- `fixtures/`
- `site/`

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

The default `EL_CLIENTS=go-ethereum,ethrex,nethermind` selects every default
execution client, but the dashboard now runs each selected EL independently.
This produces one Hive result entry per EL client, matching the shape expected
by hive-ui's grouping views. Use `EL_CLIENTS=go-ethereum`, `EL_CLIENTS=ethrex`,
or `EL_CLIENTS=nethermind` to run a subset.

`EL_CLIENT_OVERRIDES_JSON` can override descriptor fields without editing the
tracked config, for example:

```bash
EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"ref":"other-branch"}}' scripts/setup-hive.sh
```

The same override mechanism can also adjust go-ethereum settings, including
the Hive extra flags patch:

```bash
EL_CLIENT_OVERRIDES_JSON='{"go-ethereum":{"hive_extra_flags":""}}' scripts/setup-hive.sh
```

After fixtures exist, run Hive and consume them with:

```bash
scripts/run-hive-consume.sh
```

`HIVE_PARALLELISM=1` keeps consume sequential. Set it to a higher integer to
let EEST pass `-n <N>` to pytest-xdist.

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

## zkEVM Metrics Conversion

Convert `zkevm-benchmark-workload` output into Hive-compatible result files:

```bash
python3 scripts/convert-zkevm-metrics-to-hive-results.py \
  --input /data/code-data/zkevm-benchmark-workload/zkevm-metrics \
  --output hive/workspace/zkevm-converted-results \
  --clean-output
```

To publish both normal Hive runs and converted zkEVM metrics in one site,
merge the already-Hive-shaped result directories into a staging directory:

```bash
scripts/merge-hive-result-dirs.sh \
  --output hive/workspace/combined-results \
  --clean-output \
  hive/workspace/logs \
  hive/workspace/zkevm-converted-results
```

Then build from the merged result directory:

```bash
HIVE_RESULTS_DIR=hive/workspace/combined-results scripts/build-site.sh
```

## Static Site Build

After Hive results exist, build the static hive-ui site with:

```bash
scripts/build-site.sh
```

The script recreates `SITE_DIR`, builds the pinned `HIVE_UI_REF`, writes
`site/discovery.json`, writes `site/listing.jsonl`, copies merged Hive logs and
results into `site/results/`, writes hive-ui license/source notices, fails if
any listing entry has more than one client, and fails if the generated site
exceeds `SITE_MAX_SIZE_MB`.

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

Manual publishing is implemented in
`.github/workflows/publish.yml` as a `workflow_dispatch` workflow. The workflow
generates fixtures once, fans out a GitHub Actions matrix with one consume job
per selected EL client, merges the per-client Hive result artifacts, and then
builds the same static site:

```text
scripts/prepare-fixtures.sh
scripts/setup-eest.sh
scripts/run-hive-consume-client.sh CLIENT_ID
scripts/merge-hive-results.sh
scripts/build-site.sh
scripts/smoke-site.sh
```

The workflow inputs expose `eest_release_tag`, the execution-specs, Hive, and
hive-ui repos/refs, fixture selection, `EL_CLIENTS`, optional descriptor
override JSON, consume parallelism, an optional
`zkevm_benchmark_workload_output_url` `.tar.gz`, and max site size. Fill mode
uses the default empty `eest_release_tag` plus `eest_repo`/`eest_ref`. Release
mode uses a tag such as `tests-zkevm@v0.4.2`; when that tag is set, CI ignores
`eest_repo` and `eest_ref` so it can skip fixture filling.
When the zkEVM URL is not `none`,
the workflow downloads it, converts the benchmark metrics into Hive-compatible
results, merges those with the normal Hive consume results, and builds the site
from the combined result directory. In CI, `EL_CLIENTS` is still a
comma-separated selection, but each selected EL runs in its own matrix job.
Missing per-client result JSON is treated as an infrastructure failure;
ordinary failing tests can still publish when `HIVE_CONSUME_ALLOW_FAILURE=1`.
Failed runs upload debug artifacts containing per-client Hive logs and staged
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
