import json
import os
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "list-zkevm-metrics-roots.sh"


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


class ListZkevmMetricsRootsTests(unittest.TestCase):
    def run_script(self, input_dir: Path) -> subprocess.CompletedProcess[bytes]:
        env = os.environ.copy()
        return subprocess.run(
            ["bash", str(SCRIPT_PATH), "--null", str(input_dir)],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            check=False,
        )

    def parse_null_paths(self, stdout: bytes) -> list[str]:
        parts = stdout.split(b"\0")
        if parts and parts[-1] == b"":
            parts.pop()
        return [part.decode("utf-8") for part in parts]

    def test_discovers_flattened_single_artifact_layout(self):
        with TemporaryDirectory() as tmp:
            artifacts_dir = Path(tmp) / "zkevm-metrics-artifacts"
            write_json(artifacts_dir / "hardware.json", {"cpu_model": "Test CPU"})
            write_json(
                artifacts_dir / "zesu-bal-devnet-7-2026-06-12" / "zisk-v0.18.0" / "result.json",
                {"execution": {"success": {"output_matched": True}}},
            )

            completed = self.run_script(artifacts_dir)

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout!r}\nstderr:\n{completed.stderr.decode()}",
        )
        self.assertEqual(self.parse_null_paths(completed.stdout), [str(artifacts_dir.resolve())])

    def test_discovers_artifact_wrapper_layout(self):
        with TemporaryDirectory() as tmp:
            artifacts_dir = Path(tmp) / "zkevm-metrics-artifacts"
            artifact_dir = artifacts_dir / "zkevm-metrics-zesu-zisk"
            write_json(artifact_dir / "hardware.json", {"cpu_model": "Test CPU"})
            write_json(
                artifact_dir / "zesu-bal-devnet-7-2026-06-12" / "zisk-v0.18.0" / "result.json",
                {"execution": {"success": {"output_matched": True}}},
            )

            completed = self.run_script(artifacts_dir)

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout!r}\nstderr:\n{completed.stderr.decode()}",
        )
        self.assertEqual(self.parse_null_paths(completed.stdout), [str(artifact_dir.resolve())])

    def test_discovers_multiple_artifact_wrappers_in_sorted_order(self):
        with TemporaryDirectory() as tmp:
            artifacts_dir = Path(tmp) / "zkevm-metrics-artifacts"
            zesu_dir = artifacts_dir / "zkevm-metrics-zesu-zisk"
            ethrex_dir = artifacts_dir / "zkevm-metrics-ethrex-zisk"
            write_json(
                zesu_dir / "zesu-bal-devnet-7-2026-06-12" / "zisk-v0.18.0" / "result.json",
                {"execution": {"success": {"output_matched": True}}},
            )
            write_json(
                ethrex_dir / "ethrex-81484be" / "zisk-v0.16.1" / "result.json",
                {"execution": {"success": {"output_matched": True}}},
            )

            completed = self.run_script(artifacts_dir)

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout!r}\nstderr:\n{completed.stderr.decode()}",
        )
        self.assertEqual(
            self.parse_null_paths(completed.stdout),
            [str(ethrex_dir.resolve()), str(zesu_dir.resolve())],
        )

    def test_ignores_directories_without_metrics_root_shape(self):
        with TemporaryDirectory() as tmp:
            artifacts_dir = Path(tmp) / "zkevm-metrics-artifacts"
            write_json(
                artifacts_dir / "too-shallow" / "result.json",
                {"execution": {"success": {"output_matched": True}}},
            )
            write_json(
                artifacts_dir / "too-deep" / "client" / "zkvm" / "nested" / "result.json",
                {"execution": {"success": {"output_matched": True}}},
            )

            completed = self.run_script(artifacts_dir)

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout!r}\nstderr:\n{completed.stderr.decode()}",
        )
        self.assertEqual(self.parse_null_paths(completed.stdout), [])


if __name__ == "__main__":
    unittest.main()
