import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "merge-hive-results.sh"


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


class MergeHiveResultsTests(unittest.TestCase):
    def test_ignores_per_client_prune_summary_metadata_when_merging(self):
        if shutil.which("jq") is None:
            self.skipTest("jq is required by merge-hive-results.sh")

        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_dir = root / "hive" / "workspace" / "client-results"
            results_dir = root / "hive" / "workspace" / "logs"
            client_config = root / "config" / "el-clients.json"

            write_json(
                client_config,
                {
                    "clients": {
                        "go-ethereum": {
                            "hive_client": "go-ethereum",
                            "nametag": "rlp-engineapi",
                        },
                        "ethrex": {
                            "hive_client": "ethrex",
                            "nametag": "rlp-engineapi",
                        },
                    }
                },
            )

            for client_id, full_name in (
                ("go-ethereum", "go-ethereum_rlp-engineapi"),
                ("ethrex", "ethrex_rlp-engineapi"),
            ):
                client_dir = source_dir / f"hive-results-{client_id}"
                write_json(
                    client_dir / f"{client_id}.json",
                    {
                        "name": f"test-suite/{client_id}",
                        "clientVersions": {full_name: "test-version"},
                        "testCases": {},
                    },
                )
                write_json(
                    client_dir / ".eest-prune-skipped-summary",
                    {
                        "suite_files_seen": 1,
                        "suite_files_rewritten": 1 if client_id == "go-ethereum" else 0,
                        "suite_files_removed": 0 if client_id == "go-ethereum" else 1,
                        "test_cases_seen": 2,
                        "test_cases_pruned": 1,
                        "removed_suite_files": [],
                    },
                )

            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DIR": str(root),
                    "EL_CLIENT_CONFIG": str(client_config),
                    "EL_CLIENTS": "go-ethereum,ethrex",
                    "EL_CLIENT_OVERRIDES_JSON": "{}",
                    "HIVE_CLIENT_RESULTS_DIR": str(source_dir),
                    "HIVE_RESULTS_SOURCE_DIR": str(source_dir),
                    "HIVE_RESULTS_DIR": str(results_dir),
                }
            )

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH)],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                completed.returncode,
                0,
                f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            self.assertTrue((results_dir / "go-ethereum.json").is_file())
            self.assertTrue((results_dir / "ethrex.json").is_file())
            self.assertFalse((results_dir / ".eest-prune-skipped-summary").exists())


if __name__ == "__main__":
    unittest.main()
