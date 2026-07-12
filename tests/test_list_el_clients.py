import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "list-el-clients.sh"


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


class ListElClientsTests(unittest.TestCase):
    def run_matrix(
        self,
        *,
        clients: str = "ethrex",
        overrides: str = "{}",
        config_path: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        if shutil.which("jq") is None:
            self.skipTest("jq is required by list-el-clients.sh")

        env = os.environ.copy()
        env.update(
            {
                "EL_CLIENTS": clients,
                "EL_CLIENT_OVERRIDES_JSON": overrides,
            }
        )
        if config_path is not None:
            env["EL_CLIENT_CONFIG"] = str(config_path)

        return subprocess.run(
            ["bash", str(SCRIPT_PATH), "--github-matrix"],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_repo_matrix_includes_descriptor_parallelism(self):
        completed = self.run_matrix()

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        matrix = json.loads(completed.stdout)
        by_id = {entry["id"]: entry for entry in matrix["include"]}

        self.assertEqual(by_id["ethrex"]["hive_parallelism"], "16")
        self.assertEqual(set(by_id), {"ethrex"})

    def test_override_can_tune_one_client_parallelism(self):
        completed = self.run_matrix(
            overrides='{"ethrex":{"hive_parallelism":4}}',
        )

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        matrix = json.loads(completed.stdout)
        by_id = {entry["id"]: entry for entry in matrix["include"]}

        self.assertEqual(by_id["ethrex"]["hive_parallelism"], "4")

    def test_invalid_or_missing_parallelism_fails_matrix_generation(self):
        invalid_values = [
            None,
            0,
            -1,
            1.5,
            "0",
            "1.5",
            "fast",
            {},
            [],
        ]

        with TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "el-clients.json"

            for value in invalid_values:
                with self.subTest(value=value):
                    bad_descriptor: dict[str, object] = {
                        "hive_client": "bad",
                        "nametag": "rlp-engineapi",
                    }
                    if value is not None:
                        bad_descriptor["hive_parallelism"] = value

                    write_json(
                        config_path,
                        {
                            "clients": {
                                "bad": bad_descriptor,
                            }
                        },
                    )

                    completed = self.run_matrix(
                        clients="bad",
                        config_path=config_path,
                    )

                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("hive_parallelism", completed.stderr)

    def test_none_produces_empty_matrix(self):
        completed = self.run_matrix(clients="none")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), {"include": []})

    def test_skip_produces_empty_matrix(self):
        completed = self.run_matrix(clients="skip")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), {"include": []})


if __name__ == "__main__":
    unittest.main()
