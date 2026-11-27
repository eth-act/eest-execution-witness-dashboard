import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = "clients/nimbus-el/Dockerfile.git"
# Relevant structure of Hive befb5c9e's Nimbus Dockerfile.
UPSTREAM = '''# Docker container spec for building the master branch of nimbus.

FROM debian:testing-slim AS build

SHELL ["/bin/bash", "-c"]

RUN apt-get clean && apt update \\
 && apt -y install ca-certificates curl build-essential git-lfs

ARG tag=master
ARG github=status-im/nimbus-eth1
RUN git clone --branch "$tag" https://github.com/$github
# --------------------------------- #
FROM debian:testing-slim AS deploy

ARG parallel_state_root=""
ENV HIVE_PARALLEL_STATE_ROOT=${parallel_state_root}
ARG eager_state_root=""
ENV HIVE_EAGER_STATE_ROOT=${eager_state_root}

RUN apt-get clean && apt update \\
 && apt -y install build-essential jq curl
RUN apt update && apt -y upgrade
'''

LAUNCHER = '''#!/bin/sh
FLAGS=""
if [ "$HIVE_TERMINAL_TOTAL_DIFFICULTY" != "" ]; then
  echo "0x7365637265747365637265747365637265747365637265747365637265747365" > /jwtsecret
  FLAGS="$FLAGS --engine-api:true --engine-api-address:0.0.0.0 --engine-api-port:8551 --jwt-secret:/jwtsecret"
fi

echo "Running nimbus with flags $FLAGS"
$nimbus $FLAGS
'''

RETH_DOCKERFILE = "clients/reth/Dockerfile.git"
# Relevant structure of Hive e1ad8100's reth Dockerfile.
RETH_UPSTREAM = '''
### Build Reth From Git:
## Pulls reth from a git repository and builds it from source.

## Builder stage: Compiles reth from a git repository
FROM rust:latest as builder

ARG github=paradigmxyz/reth
ARG tag=main

RUN rustup update stable && rustup default stable
RUN apt-get update && apt-get install -y libclang-dev pkg-config build-essential \\
    && echo "Cloning: $github - $tag" \\
    && git clone --depth 1 --branch $tag https://github.com/$github reth \\
    && cd reth && cargo build --release -p reth --no-default-features \\
        --features jemalloc,otlp,otlp-logs,reth-revm/portable,js-tracer,keccak-cache-global,asm-keccak,min-trace-logs \\
    && cp target/release/reth /usr/local/bin/reth

## Final stage: Sets up the environment for running reth
FROM debian:latest
RUN apt-get update && apt-get install -y bash curl jq \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*
'''

ERIGON_DOCKERFILE = "clients/erigon/Dockerfile.git"
# Relevant structure of Hive 46fb6f4d's Erigon Dockerfile.
ERIGON_UPSTREAM = '''### Build Erigon From Git:

## Builder stage: Compiles erigon from a git repository
FROM golang:1.25.7-trixie as builder

ARG github=erigontech/erigon
ARG tag=main
ARG GOPROXY
'''

NETHERMIND_DOCKERFILE = "clients/nethermind/Dockerfile.git"
# Relevant structure of Hive befb5c9e's Nethermind Dockerfile.
NETHERMIND_UPSTREAM = '''### Build Nethermind From Git:

## Builder stage: Compiles nethermind from a git repository
FROM mcr.microsoft.com/dotnet/sdk:10.0.300-resolute@sha256:8b3c86c1a43c4d084c20be348dfa8821508003cf5caf02146d30de76256d1dab AS build

ARG github=nethermindeth/nethermind
ARG tag=master

RUN echo "Cloning: $github - $tag" && \\
    git clone -b $tag https://github.com/$github && \\
    cd /nethermind/src/Nethermind/Nethermind.Runner && \\
    dotnet build -c release

## Final stage: Sets up the environment for running nethermind
FROM mcr.microsoft.com/dotnet/aspnet:10.0.8-resolute@sha256:cceead03c842a491858079ca3046bd9fb598bec0ac14732cb8558c7b32a57c9a

ARG flatdb_disabled=""
ENV HIVE_FLATDB_DISABLED=${flatdb_disabled}
ARG statedb_key_scheme=""
'''


class SetupHiveTests(unittest.TestCase):
    def setUp(self):
        for command in ("git", "jq", "bash"):
            if shutil.which(command) is None:
                self.skipTest(f"{command} is required by setup-hive.sh")
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.remote = self.root / "upstream"
        self.checkout = self.root / "hive"
        self.remote.mkdir()
        self.git(self.remote, "init", "-b", "main")
        self.git(self.remote, "config", "user.name", "Test")
        self.git(self.remote, "config", "user.email", "test@example.com")
        source = self.remote / DOCKERFILE
        source.parent.mkdir(parents=True)
        source.write_text(UPSTREAM)
        (source.parent / "nimbus.sh").write_text(LAUNCHER)
        other = self.remote / "clients/ethrex/Dockerfile.git"
        other.parent.mkdir(parents=True)
        other.write_text("FROM scratch\n")
        nethermind = self.remote / NETHERMIND_DOCKERFILE
        nethermind.parent.mkdir(parents=True)
        nethermind.write_text(NETHERMIND_UPSTREAM)
        reth = self.remote / RETH_DOCKERFILE
        reth.parent.mkdir(parents=True)
        reth.write_text(RETH_UPSTREAM)
        erigon = self.remote / ERIGON_DOCKERFILE
        erigon.parent.mkdir(parents=True)
        erigon.write_text(ERIGON_UPSTREAM)
        self.commit()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        # Exercise real Git and setup logic without compiling Hive in unit tests.
        go = bin_dir / "go"
        go.write_text("#!/bin/sh\nprintf '#!/bin/sh\\n' > hive\nchmod +x hive\n")
        go.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "ROOT_DIR": str(REPO_ROOT),
            "HIVE_DIR": str(self.checkout),
            "HIVE_REPO": str(self.remote),
            "HIVE_REF": "main",
            "EL_CLIENT_CONFIG": str(REPO_ROOT / "config/el-clients.json"),
            "EL_CLIENTS": "nimbus-el",
            "EL_CLIENT_OVERRIDES_JSON": "{}",
        }

    def git(self, directory, *args):
        return subprocess.run(
            ["git", "-C", str(directory), *args],
            text=True, capture_output=True, check=True,
        ).stdout.strip()

    def commit(self):
        self.git(self.remote, "add", ".")
        self.git(self.remote, "-c", "commit.gpgsign=false", "commit", "-m", "Fixture")

    def setup_hive(self, *, success=True, **overrides):
        result = subprocess.run(
            ["bash", str(REPO_ROOT / "scripts/setup-hive.sh")],
            cwd=REPO_ROOT, env={**self.env, **overrides},
            text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_rest_setup_selects_branch_flags_and_both_transports(self):
        self.setup_hive(EL_CLIENTS="nimbus-el,nimbus-el-rest")
        dockerfile = (self.checkout / DOCKERFILE).read_text()
        launcher = (self.checkout / "clients/nimbus-el/nimbus.sh").read_text()
        clients = (self.checkout / "clients-local.yaml").read_text()
        self.assertIn("ARG engine_api_rest=false", dockerfile)
        self.assertIn("ENV HIVE_ENGINE_API_REST=$engine_api_rest", dockerfile)
        self.assertEqual(launcher.count("--debug-engine-api-rest"), 1)
        self.assertIn("witness-rest-ssz-endpoint", clients)
        self.assertIn("nametag: 'rest-ssz'", clients)
        self.assertIn("engine_api_rest: 'true'", clients)
        self.assertIn("nametag: 'rlp-engineapi'", clients)
        self.setup_hive(EL_CLIENTS="nimbus-el,nimbus-el-rest")
        self.assertEqual((self.checkout / DOCKERFILE).read_text(), dockerfile)
        self.setup_hive(EL_CLIENTS="nimbus-el")
        self.assertNotIn("engine_api_rest", (self.checkout / DOCKERFILE).read_text())
        self.assertEqual((self.checkout / "clients/nimbus-el/nimbus.sh").read_text(), LAUNCHER)

    def test_rest_setup_only_patches_selected_dockerfile(self):
        for descriptor, client, github, changed in (
            ("reth-rest", "reth", "paradigmxyz/reth", f"M {RETH_DOCKERFILE}"),
            ("nethermind-rest", "nethermind", "NethermindEth/nethermind", f"M {NETHERMIND_DOCKERFILE}"),
            ("erigon-rest", "erigon", "erigontech/erigon", f"M {ERIGON_DOCKERFILE}"),
        ):
            with self.subTest(descriptor=descriptor):
                self.setup_hive(EL_CLIENTS=descriptor)
                clients = (self.checkout / "clients-local.yaml").read_text()
                self.assertIn(f"client: '{client}'", clients)
                self.assertIn("nametag: 'rest-ssz'", clients)
                self.assertIn(f"github: '{github}'", clients)
                self.assertNotIn("engine_api_rest", clients)
                self.assertEqual(self.git(self.checkout, "status", "--porcelain", "clients"), changed)

    def test_github_override_changes_the_clone_source(self):
        self.setup_hive(
            EL_CLIENTS="ethrex",
            EL_CLIENT_OVERRIDES_JSON='{"ethrex":{"github":"me/ethrex","ref":"my-branch"}}',
        )
        clients = (self.checkout / "clients-local.yaml").read_text()
        self.assertIn("github: 'me/ethrex'", clients)
        self.assertIn("tag: 'my-branch'", clients)

    def test_reth_patch_swaps_portable_feature_once(self):
        self.setup_hive(EL_CLIENTS="reth-rest")
        first = (self.checkout / RETH_DOCKERFILE).read_text()
        self.setup_hive(EL_CLIENTS="reth-rest")
        self.assertEqual((self.checkout / RETH_DOCKERFILE).read_text(), first)
        self.assertNotIn("reth-revm/portable", first)
        self.assertEqual(first.count(",portable,"), 1)
        self.assertEqual(first.count("# eest-dashboard:"), 1)

    def test_deselecting_reth_removes_patch(self):
        self.setup_hive(EL_CLIENTS="reth-rest")
        self.setup_hive(EL_CLIENTS="nethermind-rest")
        self.assertEqual((self.checkout / RETH_DOCKERFILE).read_text(), RETH_UPSTREAM)

    def test_reth_patch_skipped_once_upstream_is_fixed(self):
        fixed = RETH_UPSTREAM.replace("reth-revm/portable", "portable")
        (self.remote / RETH_DOCKERFILE).write_text(fixed)
        self.commit()
        result = self.setup_hive(EL_CLIENTS="reth-rest")
        self.assertIn("skipping managed reth portable patch", result.stdout)
        self.assertEqual((self.checkout / RETH_DOCKERFILE).read_text(), fixed)

    def test_reth_patch_fails_on_changed_upstream_structure(self):
        (self.remote / RETH_DOCKERFILE).write_text(
            RETH_UPSTREAM.replace("RUN rustup update stable", "RUN rustup update nightly")
        )
        self.commit()
        result = self.setup_hive(success=False, EL_CLIENTS="reth-rest")
        self.assertIn("managed reth portable patch does not apply", result.stderr)
        self.assertEqual(
            (self.checkout / RETH_DOCKERFILE).read_text(),
            (self.remote / RETH_DOCKERFILE).read_text(),
        )

    def test_rest_patch_preserves_edited_launcher(self):
        self.setup_hive(EL_CLIENTS="nimbus-el-rest")
        path = self.checkout / "clients/nimbus-el/nimbus.sh"
        edited = path.read_text().replace("--debug-engine-api-rest", "--custom-rest")
        path.write_text(edited)
        result = self.setup_hive(success=False)
        self.assertIn("unable to remove managed Nimbus REST patch", result.stderr)
        self.assertEqual(path.read_text(), edited)

    def test_upstream_update_removes_then_reapplies_patch(self):
        self.setup_hive(EL_CLIENTS="reth-rest")
        (self.remote / RETH_DOCKERFILE).write_text(RETH_UPSTREAM + "LABEL updated=true\n")
        self.commit()
        self.setup_hive(EL_CLIENTS="reth-rest")
        self.assertEqual(
            self.git(self.checkout, "rev-parse", "HEAD"),
            self.git(self.remote, "rev-parse", "HEAD"),
        )
        content = (self.checkout / RETH_DOCKERFILE).read_text()
        self.assertIn("LABEL updated=true", content)
        self.assertNotIn("reth-revm/portable", content)
        self.assertEqual(content.count(",portable,"), 1)

    def test_disabling_patch_preserves_unrelated_local_edits(self):
        self.setup_hive(EL_CLIENTS="reth-rest")
        path = self.checkout / RETH_DOCKERFILE
        path.write_text(path.read_text() + "# local customization\n")
        self.setup_hive(
            EL_CLIENTS="reth-rest",
            EL_CLIENT_OVERRIDES_JSON='{"reth-rest":{"managed_patch":""}}',
        )
        self.assertEqual(path.read_text(), RETH_UPSTREAM + "# local customization\n")

    def test_edited_managed_patch_fails_without_discarding_edits(self):
        self.setup_hive(EL_CLIENTS="reth-rest")
        path = self.checkout / RETH_DOCKERFILE
        edited = path.read_text().replace(",portable,", ",portable,custom,")
        path.write_text(edited)
        result = self.setup_hive(success=False, EL_CLIENTS="reth-rest")
        self.assertIn("unable to remove managed reth portable patch", result.stderr)
        self.assertEqual(path.read_text(), edited)

    def test_nimbus_builds_without_a_managed_patch(self):
        self.setup_hive()
        self.assertEqual((self.checkout / DOCKERFILE).read_text(), UPSTREAM)
        self.assertEqual(self.git(self.checkout, "status", "--porcelain", "clients"), "")

    def test_managed_patch_must_match_the_descriptor(self):
        for patch, error in (
            ("unknown", "unsupported managed_patch for ethrex: unknown"),
            ("nimbus-rest", "unsupported managed_patch for ethrex: nimbus-rest"),
            ("reth-portable-feature", "reth-portable-feature requires hive_client=reth"),
        ):
            with self.subTest(patch=patch):
                result = self.setup_hive(
                    success=False,
                    EL_CLIENTS="ethrex",
                    EL_CLIENT_OVERRIDES_JSON=f'{{"ethrex":{{"managed_patch":"{patch}"}}}}',
                )
                self.assertIn(error, result.stderr)
                self.assertEqual(self.git(self.checkout, "status", "--porcelain", "clients"), "")


    def test_erigon_patch_bumps_go_once(self):
        self.setup_hive(EL_CLIENTS="erigon-rest")
        first = (self.checkout / ERIGON_DOCKERFILE).read_text()
        self.setup_hive(EL_CLIENTS="erigon-rest")
        self.assertEqual((self.checkout / ERIGON_DOCKERFILE).read_text(), first)
        self.assertNotIn("golang:1.25.7", first)
        self.assertEqual(first.count("FROM golang:1.26.8-trixie as builder"), 1)
        self.assertEqual(first.count("# eest-dashboard:"), 1)

    def test_deselecting_erigon_removes_patch(self):
        self.setup_hive(EL_CLIENTS="erigon-rest")
        self.setup_hive(EL_CLIENTS="nethermind-rest")
        self.assertEqual((self.checkout / ERIGON_DOCKERFILE).read_text(), ERIGON_UPSTREAM)

    def test_erigon_patch_skipped_once_upstream_is_fixed(self):
        fixed = ERIGON_UPSTREAM.replace("golang:1.25.7", "golang:1.26.8")
        (self.remote / ERIGON_DOCKERFILE).write_text(fixed)
        self.commit()
        result = self.setup_hive(EL_CLIENTS="erigon-rest")
        self.assertIn("skipping managed Erigon Go patch", result.stdout)
        self.assertEqual((self.checkout / ERIGON_DOCKERFILE).read_text(), fixed)

    def test_erigon_patch_fails_on_changed_upstream_structure(self):
        (self.remote / ERIGON_DOCKERFILE).write_text(
            ERIGON_UPSTREAM.replace("## Builder stage", "## Build stage")
        )
        self.commit()
        result = self.setup_hive(success=False, EL_CLIENTS="erigon-rest")
        self.assertIn("managed Erigon Go patch does not apply", result.stderr)
        self.assertEqual(
            (self.checkout / ERIGON_DOCKERFILE).read_text(),
            (self.remote / ERIGON_DOCKERFILE).read_text(),
        )

    def test_nethermind_patch_bumps_dotnet_once(self):
        self.setup_hive(EL_CLIENTS="nethermind,nethermind-rest")
        first = (self.checkout / NETHERMIND_DOCKERFILE).read_text()
        self.setup_hive(EL_CLIENTS="nethermind,nethermind-rest")
        self.assertEqual((self.checkout / NETHERMIND_DOCKERFILE).read_text(), first)
        self.assertNotIn("dotnet/sdk:10.", first)
        self.assertNotIn("dotnet/aspnet:10.", first)
        self.assertEqual(first.count("FROM mcr.microsoft.com/dotnet/sdk:11.0.100-resolute@"), 1)
        self.assertEqual(first.count("FROM mcr.microsoft.com/dotnet/aspnet:11.0.0-resolute@"), 1)
        self.assertEqual(first.count("# eest-dashboard:"), 1)

    def test_deselecting_nethermind_removes_patch(self):
        self.setup_hive(EL_CLIENTS="nethermind-rest")
        self.setup_hive(EL_CLIENTS="ethrex")
        self.assertEqual(
            (self.checkout / NETHERMIND_DOCKERFILE).read_text(), NETHERMIND_UPSTREAM
        )

    def test_nethermind_patch_skipped_once_upstream_is_fixed(self):
        fixed = NETHERMIND_UPSTREAM.replace(
            "dotnet/sdk:10.0.300", "dotnet/sdk:11.0.100"
        ).replace("dotnet/aspnet:10.0.8", "dotnet/aspnet:11.0.0")
        (self.remote / NETHERMIND_DOCKERFILE).write_text(fixed)
        self.commit()
        result = self.setup_hive(EL_CLIENTS="nethermind-rest")
        self.assertIn("skipping managed Nethermind .NET patch", result.stdout)
        self.assertEqual((self.checkout / NETHERMIND_DOCKERFILE).read_text(), fixed)

    def test_nethermind_patch_fails_on_changed_upstream_structure(self):
        (self.remote / NETHERMIND_DOCKERFILE).write_text(
            NETHERMIND_UPSTREAM.replace("## Builder stage", "## Build stage")
        )
        self.commit()
        result = self.setup_hive(success=False, EL_CLIENTS="nethermind-rest")
        self.assertIn("managed Nethermind .NET patch does not apply", result.stderr)
        self.assertEqual(
            (self.checkout / NETHERMIND_DOCKERFILE).read_text(),
            (self.remote / NETHERMIND_DOCKERFILE).read_text(),
        )


if __name__ == "__main__":
    unittest.main()
