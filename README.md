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
GETH_SOURCE_MODE=git
GETH_HIVE_EXTRA_FLAGS=--bal.executionmode=sequential
HIVE_PARALLELISM=1
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
- `uv`, `jq`, and `rsync` on `PATH`.

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

The default `GETH_SOURCE_MODE=git` uses Hive `Dockerfile.git` with
`GETH_GITHUB` and `GETH_REF`. Use `GETH_SOURCE_MODE=local` to clone
`GETH_REPO` at an exact commit or ref into `GETH_SRC_DIR`, copy it into
`hive/clients/go-ethereum/go-ethereum`, and use Hive `Dockerfile.local`.
`GETH_HIVE_EXTRA_FLAGS` is injected into Hive's `geth.sh`; set it empty to
remove the managed patch.

After fixtures exist, run Hive and consume them with:

```bash
scripts/run-hive-consume.sh
```

`HIVE_PARALLELISM=1` keeps consume sequential. Set it to a higher integer to
let EEST pass `-n <N>` to pytest-xdist.

Hive logs are preserved in `HIVE_RESULTS_DIR`; on failure, the script prints the
tail of `hive-dev.log` for startup or client-build debugging.
