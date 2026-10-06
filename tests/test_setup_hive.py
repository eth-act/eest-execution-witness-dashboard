import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = "clients/nimbus-el/Dockerfile.git"
# Relevant structure of Hive 43ea47be's Nimbus Dockerfile.
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

    def test_rest_patch_preserves_edited_launcher(self):
        self.setup_hive(EL_CLIENTS="nimbus-el-rest")
        path = self.checkout / "clients/nimbus-el/nimbus.sh"
        edited = path.read_text().replace("--debug-engine-api-rest", "--custom-rest")
        path.write_text(edited)
        result = self.setup_hive(success=False)
        self.assertIn("unable to remove managed Nimbus REST patch", result.stderr)
        self.assertEqual(path.read_text(), edited)

    def test_repeated_setup_applies_once_inside_build_stage(self):
        self.setup_hive()
        first = (self.checkout / DOCKERFILE).read_text()
        self.setup_hive()
        self.assertEqual((self.checkout / DOCKERFILE).read_text(), first)
        setting = "ENV GIT_LFS_SKIP_SMUDGE=1"
        self.assertEqual(first.count(setting), 1)
        self.assertLess(first.index("AS build"), first.index(setting))
        self.assertLess(first.index(setting), first.index("RUN git clone"))
        self.assertNotIn("GIT_LFS_SKIP_SMUDGE", first.split("AS deploy")[1])

    def test_upstream_update_removes_then_reapplies_patch(self):
        self.setup_hive()
        (self.remote / DOCKERFILE).write_text(UPSTREAM + "LABEL updated=true\n")
        self.commit()
        self.setup_hive()
        self.assertEqual(
            self.git(self.checkout, "rev-parse", "HEAD"),
            self.git(self.remote, "rev-parse", "HEAD"),
        )
        content = (self.checkout / DOCKERFILE).read_text()
        self.assertIn("LABEL updated=true", content)
        self.assertEqual(content.count("ENV GIT_LFS_SKIP_SMUDGE=1"), 1)

    def test_disabling_patch_preserves_unrelated_local_edits(self):
        self.setup_hive()
        path = self.checkout / DOCKERFILE
        path.write_text(path.read_text() + "# local customization\n")
        self.setup_hive(EL_CLIENT_OVERRIDES_JSON='{"nimbus-el":{"managed_patch":""}}')
        self.assertEqual(path.read_text(), UPSTREAM + "# local customization\n")

    def test_deselecting_nimbus_removes_patch(self):
        self.setup_hive()
        self.setup_hive(EL_CLIENTS="ethrex")
        self.assertEqual((self.checkout / DOCKERFILE).read_text(), UPSTREAM)

    def test_changed_upstream_structure_fails_without_partial_patch(self):
        (self.remote / DOCKERFILE).write_text(
            UPSTREAM.replace("FROM debian:testing-slim AS build", "FROM ubuntu AS build")
        )
        self.commit()
        result = self.setup_hive(success=False)
        self.assertIn("managed Nimbus LFS patch does not apply", result.stderr)
        self.assertEqual(
            (self.checkout / DOCKERFILE).read_text(),
            (self.remote / DOCKERFILE).read_text(),
        )

    def test_edited_managed_patch_fails_without_discarding_edits(self):
        self.setup_hive()
        path = self.checkout / DOCKERFILE
        edited = path.read_text().replace("GIT_LFS_SKIP_SMUDGE=1", "GIT_LFS_SKIP_SMUDGE=0")
        path.write_text(edited)
        result = self.setup_hive(success=False)
        self.assertIn("unable to remove managed Nimbus LFS patch", result.stderr)
        self.assertEqual(path.read_text(), edited)


if __name__ == "__main__":
    unittest.main()
