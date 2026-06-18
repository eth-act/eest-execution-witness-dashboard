import json
import os
import shutil
import subprocess
import textwrap
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "run-zkevm-benchmark-workload.sh"
ZESU_URL = (
    "https://github.com/Consensys/zesu-zkvm/releases/download/"
    "bal-devnet-7-2026-06-12"
)


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


class RunZkevmBenchmarkWorkloadTests(unittest.TestCase):
    def run_script(
        self,
        *,
        execution_client: str,
        guest_artifact_base_url: str = "",
        guest_config: dict | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        if shutil.which("find") is None:
            self.skipTest("find is required by run-zkevm-benchmark-workload.sh")
        if shutil.which("jq") is None:
            self.skipTest("jq is required by run-zkevm-benchmark-workload.sh")

        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        workload = root / "workload"
        fixtures = root / "fixtures"
        metrics = root / "metrics"
        bin_dir = root / "bin"
        args_file = root / "cargo-args.txt"
        guest_config_path = root / "config" / "el-guests.json"

        workload.mkdir()
        fixtures.mkdir()
        bin_dir.mkdir()
        (workload / "Cargo.toml").write_text("[workspace]\n", encoding="utf-8")
        (bin_dir / "cargo").write_text(
            textwrap.dedent(
                f"""\
                #!/usr/bin/env bash
                printf '%s\\n' "$@" > {args_file}
                mkdir -p "$ZKEVM_METRICS_DIR/zesu-test/zisk-test"
                printf '{{}}\\n' > "$ZKEVM_METRICS_DIR/zesu-test/zisk-test/result.json"
                """
            ),
            encoding="utf-8",
        )
        (bin_dir / "cargo").chmod(0o755)
        if guest_config is not None:
            write_json(guest_config_path, guest_config)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env['PATH']}",
                "ZKEVM_BENCHMARK_WORKLOAD_DIR": str(workload),
                "FIXTURES_DIR": str(fixtures),
                "ZKEVM_METRICS_DIR": str(metrics),
                "ZKEVM_WORKLOAD_EXECUTION_CLIENT": execution_client,
                "ZKEVM_WORKLOAD_ZKVM": "zisk",
                "ZKEVM_RAYON_THREADS": "1",
                "ZKEVM_WORKLOAD_GUEST_ARTIFACT_BASE_URL": guest_artifact_base_url,
            }
        )
        if guest_config is not None:
            env["EL_GUEST_CONFIG"] = str(guest_config_path)

        completed = subprocess.run(
            ["bash", str(SCRIPT_PATH)],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        return completed, args_file

    def test_run_script_passes_guest_artifact_base_url_when_set(self):
        completed, args_file = self.run_script(
            execution_client="zesu",
            guest_artifact_base_url=ZESU_URL,
        )

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        args = args_file.read_text(encoding="utf-8")
        self.assertIn("--guest-artifact-base-url\n" + ZESU_URL, args)
        self.assertIn("--execution-client\nzesu", args)

    def test_run_script_omits_guest_artifact_base_url_when_unset(self):
        completed, args_file = self.run_script(execution_client="ethrex")

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

        args = args_file.read_text(encoding="utf-8")
        self.assertNotIn("--guest-artifact-base-url", args)
        self.assertIn("--execution-client\nethrex", args)

    def test_zesu_run_uses_configured_guest_artifact_base_url(self):
        completed, args_file = self.run_script(execution_client="zesu")

        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )
        args = args_file.read_text(encoding="utf-8")
        self.assertIn("--guest-artifact-base-url\n" + ZESU_URL, args)

    def test_zesu_run_fails_when_required_guest_artifact_base_url_is_unconfigured(self):
        completed, _args_file = self.run_script(
            execution_client="zesu",
            guest_config={
                "guests": {
                    "zesu": {
                        "requires_guest_artifact_base_url": True,
                    }
                }
            },
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "requires guest_artifact_base_url",
            completed.stderr,
        )


if __name__ == "__main__":
    unittest.main()
