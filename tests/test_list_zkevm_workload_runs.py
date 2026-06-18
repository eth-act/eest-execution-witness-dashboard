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
        clients: str,
        zkvms: str = "zisk",
        guest_config_path: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if shutil.which("jq") is None:
            self.skipTest("jq is required by list-zkevm-workload-runs.sh")

        env = os.environ.copy()
        env.update(
            {
                "ZKEVM_WORKLOAD_EXECUTION_CLIENTS": clients,
                "ZKEVM_WORKLOAD_ZKVMS": zkvms,
            }
        )
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

    def test_zesu_matrix_includes_guest_artifact_base_url(self):
        completed = self.run_matrix(clients="zesu")

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        matrix = json.loads(completed.stdout)
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
        completed = self.run_matrix(clients="ethrex,reth")

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        matrix = json.loads(completed.stdout)
        by_client = {entry["execution_client"]: entry for entry in matrix["include"]}

        self.assertEqual(by_client["ethrex"]["guest_artifact_base_url"], "")
        self.assertEqual(by_client["reth"]["guest_artifact_base_url"], "")

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
                clients="zesu",
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
                clients="zesu2",
                zkvms="zisk,openvm",
                guest_config_path=config_path,
            )

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        matrix = json.loads(completed.stdout)
        by_zkvm = {entry["zkvm"]: entry for entry in matrix["include"]}
        self.assertEqual(by_zkvm["zisk"]["guest_artifact_base_url"], ZESU_URL)
        self.assertEqual(by_zkvm["openvm"]["guest_artifact_base_url"], ZESU_OPENVM_URL)


if __name__ == "__main__":
    unittest.main()
