# eest-execution-witness-dashboard

Static dashboard scaffolding for publishing execution witness Hive results with
Hiveview.

## Phase 1 Defaults

The first implementation pass uses public branch refs rather than immutable
SHAs or tags. These refs were checked with `git ls-remote` on 2026-05-15:

```bash
EEST_REPO=https://github.com/jsign/execution-specs.git
EEST_REF=jsign-zkevm-v0.3.4-hive

HIVE_REPO=https://github.com/ethereum/hive.git
HIVE_REF=master

GETH_REPO=https://github.com/jsign/go-ethereum.git
GETH_GITHUB=jsign/go-ethereum
GETH_REF=zkevm-v0.3.4-hive
GETH_SOURCE_MODE=auto
GETH_HIVE_EXTRA_FLAGS=--bal.executionmode=sequential
HIVE_PARALLELISM=1
SITE_MAX_SIZE_MB=900
```

Generated work directories are ignored by git:

- `execution-specs/`
- `hive/`
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
```

## Local Prerequisites

Local runs are expected to use the same tool versions planned for GitHub
Actions:

- Docker with the daemon running and usable by the current user without `sudo`.
- Go `1.24.x`.
- Python `3.12`.
- `uv`, `jq`, `curl`, and `rsync` on `PATH`.

Docker permissions are the main local-only concern: Hive builds and runs client
containers, so `docker info` should succeed before running the later scripts.

## Fixture Generation

Generate execution witness fixtures with:

```bash
scripts/fill-fixtures.sh
```

The script clones or updates `execution-specs` at `EEST_REF`, runs `uv sync`,
fills `blockchain_test_engine` fixtures into `FIXTURES_DIR`, and fails if
`fixtures/.meta/index.json` does not include `blockchain_test_engine`.

## Hive Consume

Prepare Hive and generate `hive/clients-local.yaml`:

```bash
scripts/setup-hive.sh
```

The default `GETH_SOURCE_MODE=auto` uses Hive `Dockerfile.git` for branch/tag
refs and switches to `Dockerfile.local` for full commit SHAs. Use
`GETH_SOURCE_MODE=local` to force the local checkout path for any ref.
`GETH_HIVE_EXTRA_FLAGS` is injected into Hive's `geth.sh`; set it empty to
remove the managed patch.

After fixtures exist, run Hive and consume them with:

```bash
scripts/run-hive-consume.sh
```

`HIVE_PARALLELISM=1` keeps consume sequential. Set it to a higher integer to
let EEST pass `-n <N>` to pytest-xdist.

Hive logs are preserved in `HIVE_RESULTS_DIR`; on failure, the script prints the
tail of `hive-dev.log` for startup or client-build debugging. Set
`HIVE_CONSUME_ALLOW_FAILURE=1` to continue after `consume engine-witness`
returns non-zero so downstream steps can publish the failure dashboard.
Set `HIVE_DOCKER_OUTPUT=build` and `HIVE_LOG_TO_STDOUT=1` to stream Docker
build output into the console while still writing `hive-dev.log`.

## Static Site Build

After Hive results exist, build the static Hiveview site with:

```bash
scripts/build-site.sh
```

The script recreates `SITE_DIR`, deploys Hiveview assets, writes
`site/listing.jsonl`, copies Hive logs and results into `site/results/`, and
fails if the generated site exceeds `SITE_MAX_SIZE_MB`.

## Local Preview and Smoke Test

Preview the current Hive results with Hiveview's built-in local server:

```bash
source scripts/env.sh
cd "$HIVE_DIR"
go run ./cmd/hiveview -serve -logdir "$HIVE_RESULTS_DIR"
```

Open `http://127.0.0.1:8080`.

Preview the generated static site with a simple HTTP server:

```bash
source scripts/env.sh
cd "$SITE_DIR"
python3 -m http.server 8081 --bind 127.0.0.1
```

Open `http://127.0.0.1:8081/`. Use HTTP rather than `file://` so browser
requests for `listing.jsonl` and `results/...` are exercised.

Before publishing, run:

```bash
scripts/smoke-site.sh
```

The smoke test serves `SITE_DIR` under a non-root project path, fetches
`listing.jsonl` and the first `results/...` entry over HTTP, checks that static
paths are relative for GitHub Pages project URLs, and scans public result logs
for common secret or private RPC URL patterns.

## GitHub Pages Publishing

Manual publishing is implemented in
`.github/workflows/publish.yml` as a `workflow_dispatch` workflow. The workflow
installs Go, Python, `uv`, `jq`, and `rsync`, then calls the same local scripts:

```text
scripts/fill-fixtures.sh
scripts/run-hive-consume.sh
scripts/build-site.sh
scripts/smoke-site.sh
```

The workflow inputs expose the execution-specs, Hive, and go-ethereum repos and
refs, plus the filler path, fork, geth source mode, consume parallelism, and max
site size. Failed runs upload debug artifacts containing Hive logs from
`hive/workspace/logs`.

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
