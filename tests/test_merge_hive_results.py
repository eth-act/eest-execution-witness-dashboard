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

    def test_merges_both_client_directory_names_and_additional_source(self):
        if shutil.which("jq") is None:
            self.skipTest("jq is required by merge-hive-results.sh")

        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_dir = root / "hive" / "workspace" / "client-results"
            results_dir = root / "hive" / "workspace" / "logs"
            additional_dir = root / "hive" / "workspace" / "converted"
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
            for client_id, directory_name in (
                ("go-ethereum", "go-ethereum"),
                ("ethrex", "hive-results-ethrex"),
            ):
                full_name = f"{client_id}_rlp-engineapi"
                write_json(
                    source_dir / directory_name / f"{client_id}.json",
                    {
                        "name": f"suite/{client_id}",
                        "clientVersions": {full_name: "version"},
                        "testCases": {},
                    },
                )
            write_json(
                additional_dir / "zkevm.json",
                {
                    "name": "suite/zkevm",
                    "clients": ["reth_zisk"],
                    "testCases": {},
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
                ["bash", str(SCRIPT_PATH), "--source", str(additional_dir)],
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
            self.assertEqual(
                sorted(path.name for path in results_dir.glob("*.json")),
                ["ethrex.json", "go-ethereum.json", "zkevm.json"],
            )

    def test_merges_additional_source_when_hive_clients_are_disabled(self):
        if shutil.which("jq") is None:
            self.skipTest("jq is required by merge-hive-results.sh")

        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            results_dir = root / "hive" / "workspace" / "logs"
            additional_dir = root / "hive" / "workspace" / "converted"
            write_json(
                additional_dir / "zkevm.json",
                {
                    "name": "suite/zkevm",
                    "clients": ["reth_zisk"],
                    "testCases": {},
                },
            )
            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DIR": str(root),
                    "EL_CLIENTS": "none",
                    "EL_CLIENT_OVERRIDES_JSON": "{}",
                    "HIVE_RESULTS_SOURCE_DIR": str(root / "does-not-exist"),
                    "HIVE_RESULTS_DIR": str(results_dir),
                }
            )

            completed = subprocess.run(
                ["bash", str(SCRIPT_PATH), "--source", str(additional_dir)],
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
            self.assertTrue((results_dir / "zkevm.json").is_file())

    def test_accepts_client_with_only_valid_pruned_results(self):
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
                        "ethrex": {
                            "hive_client": "ethrex",
                            "nametag": "rlp-engineapi",
                        }
                    }
                },
            )
            write_json(
                source_dir / "ethrex" / ".eest-prune-skipped-summary",
                {
                    "suite_files_seen": 1,
                    "suite_files_removed": 1,
                    "test_cases_pruned": 3,
                },
            )
            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DIR": str(root),
                    "EL_CLIENT_CONFIG": str(client_config),
                    "EL_CLIENTS": "ethrex",
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
            self.assertTrue(results_dir.is_dir())
            self.assertEqual(list(results_dir.iterdir()), [])

    def test_rejects_missing_prune_summary_and_preserves_existing_output(self):
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
                        "ethrex": {
                            "hive_client": "ethrex",
                            "nametag": "rlp-engineapi",
                        }
                    }
                },
            )
            (source_dir / "ethrex").mkdir(parents=True)
            results_dir.mkdir(parents=True)
            sentinel = results_dir / "sentinel"
            sentinel.write_text("keep\n", encoding="utf-8")
            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DIR": str(root),
                    "EL_CLIENT_CONFIG": str(client_config),
                    "EL_CLIENTS": "ethrex",
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

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("did not produce any top-level", completed.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")

    def test_rejects_wrong_expected_client(self):
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
                        "ethrex": {
                            "hive_client": "ethrex",
                            "nametag": "rlp-engineapi",
                        }
                    }
                },
            )
            write_json(
                source_dir / "ethrex" / "ethrex.json",
                {
                    "name": "suite/ethrex",
                    "clients": ["wrong-client"],
                    "testCases": {},
                },
            )
            env = os.environ.copy()
            env.update(
                {
                    "ROOT_DIR": str(root),
                    "EL_CLIENT_CONFIG": str(client_config),
                    "EL_CLIENTS": "ethrex",
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

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("not a single-client ethrex_rlp-engineapi", completed.stderr)


if __name__ == "__main__":
    unittest.main()
