import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "list-zkevm-workload-runs.sh"
ZESU_URL = (
    "https://github.com/Consensys/zesu-zkvm/releases/download/"
    "bal-devnet-7-2026-06-12"
)
ZESU_OPENVM_URL = "https://example.com/zesu-openvm-release"


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


class ListZkevmWorkloadRunsTests(unittest.TestCase):
    def run_matrix(
        self,
        *,
        runs: str | None,
        guest_config_path: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if shutil.which("jq") is None:
            self.skipTest("jq is required by list-zkevm-workload-runs.sh")

        env = os.environ.copy()
        if runs is None:
            env.pop("ZKEVM_WORKLOAD_RUNS", None)
        else:
            env["ZKEVM_WORKLOAD_RUNS"] = runs
        if guest_config_path is not None:
            env["EL_GUEST_CONFIG"] = str(guest_config_path)

        return subprocess.run(
            ["bash", str(SCRIPT_PATH), "--github-matrix"],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_success(
        self,
        completed: subprocess.CompletedProcess[str],
    ) -> dict:
        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        return json.loads(completed.stdout)

    def test_default_runs_preserve_existing_local_matrix(self):
        matrix = self.assert_success(self.run_matrix(runs=None))

        self.assertEqual(
            [
                (entry["execution_client"], entry["zkvm"])
                for entry in matrix["include"]
            ],
            [("ethrex", "zisk"), ("reth", "zisk")],
        )

    def test_explicit_pairs_preserve_order_without_cartesian_product(self):
        completed = self.run_matrix(
            runs=" zesu : zisk , ethrex:zisk , ethrex : sp1 "
        )
        matrix = self.assert_success(completed)

        pairs = [
            (entry["execution_client"], entry["zkvm"])
            for entry in matrix["include"]
        ]
        self.assertEqual(
            pairs,
            [("zesu", "zisk"), ("ethrex", "zisk"), ("ethrex", "sp1")],
        )
        self.assertNotIn(("zesu", "sp1"), pairs)

    def test_guest_level_artifact_base_url_is_included(self):
        with TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "el-guests.json"
            write_json(
                config_path,
                {
                    "guests": {
                        "zesu": {
                            "guest_artifact_base_url": ZESU_URL,
                        }
                    }
                },
            )
            completed = self.run_matrix(
                runs="zesu:zisk",
                guest_config_path=config_path,
            )

        matrix = self.assert_success(completed)
        self.assertEqual(
            matrix["include"],
            [
                {
                    "execution_client": "zesu",
                    "zkvm": "zisk",
                    "guest_artifact_base_url": ZESU_URL,
                    "artifact": "zkevm-metrics-zesu-zisk",
                }
            ],
        )

    def test_existing_clients_keep_empty_guest_artifact_base_url(self):
        completed = self.run_matrix(runs="ethrex:zisk,reth:zisk")
        matrix = self.assert_success(completed)
        by_client = {
            entry["execution_client"]: entry for entry in matrix["include"]
        }

        self.assertEqual(by_client["ethrex"]["guest_artifact_base_url"], "")
        self.assertEqual(by_client["reth"]["guest_artifact_base_url"], "")

    def test_empty_and_skip_sentinels_select_no_runs(self):
        for runs in ("", "none", " SKIP ", "Empty"):
            with self.subTest(runs=runs):
                matrix = self.assert_success(self.run_matrix(runs=runs))
                self.assertEqual(matrix, {"include": []})

    def test_malformed_or_duplicate_runs_are_rejected(self):
        cases = {
            "ethrex": "must have CLIENT:ZKVM form",
            "ethrex:zisk:extra": "must have CLIENT:ZKVM form",
            ":zisk": "must have non-empty CLIENT and ZKVM",
            "ethrex:": "must have non-empty CLIENT and ZKVM",
            "eth/rex:zisk": "components may contain only",
            "ethrex:sp 1": "components may contain only",
            "ethrex:zisk,,reth:zisk": "contains an empty CLIENT:ZKVM pair",
            "ethrex:zisk,ethrex:zisk": "contains duplicate CLIENT:ZKVM pairs",
        }

        for runs, expected_error in cases.items():
            with self.subTest(runs=runs):
                completed = self.run_matrix(runs=runs)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn(expected_error, completed.stderr)

    def test_unknown_client_is_rejected(self):
        completed = self.run_matrix(runs="unknown:zisk")

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("unknown EL guest id: unknown", completed.stderr)

    def test_artifact_names_remain_client_and_zkvm_based(self):
        matrix = self.assert_success(
            self.run_matrix(runs="ethrex:zisk,ethrex:sp1")
        )

        self.assertEqual(
            [entry["artifact"] for entry in matrix["include"]],
            ["zkevm-metrics-ethrex-zisk", "zkevm-metrics-ethrex-sp1"],
        )

    def test_zesu_requires_guest_artifact_base_url(self):
        with TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "el-guests.json"
            write_json(
                config_path,
                {
                    "guests": {
                        "zesu": {
                            "requires_guest_artifact_base_url": True,
                        }
                    }
                },
            )
            completed = self.run_matrix(
                runs="zesu:zisk",
                guest_config_path=config_path,
            )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "requires guest_artifact_base_url",
            completed.stderr,
        )

    def test_per_zkvm_guest_artifact_base_url_overrides_guest_default(self):
        with TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "el-guests.json"
            write_json(
                config_path,
                {
                    "guests": {
                        "zesu2": {
                            "guest_artifact_base_url": ZESU_URL,
                            "zkvms": {
                                "openvm": {
                                    "guest_artifact_base_url": ZESU_OPENVM_URL,
                                }
                            },
                        }
                    }
                },
            )
            completed = self.run_matrix(
                runs="zesu2:zisk,zesu2:openvm",
                guest_config_path=config_path,
            )

        matrix = self.assert_success(completed)
        by_zkvm = {entry["zkvm"]: entry for entry in matrix["include"]}
        self.assertEqual(by_zkvm["zisk"]["guest_artifact_base_url"], ZESU_URL)
        self.assertEqual(by_zkvm["openvm"]["guest_artifact_base_url"], ZESU_OPENVM_URL)


if __name__ == "__main__":
    unittest.main()
