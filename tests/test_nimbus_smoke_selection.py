import fnmatch
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "select-nimbus-smoke.sh"
PATHS_FILE = REPO_ROOT / "config" / "nimbus-smoke-paths.txt"

# At least one changed path for each pattern in config/nimbus-smoke-paths.txt.
TRIGGERS = (
    ".github/actions/smoke-setup/action.yml",
    ".github/workflows/pr-smoke.yml",
    "config/el-clients.json",
    "patches/hive-reth-portable-feature.patch",
    "patches/hive-nimbus-rest.patch",
    "scripts/env.sh",
    "scripts/lib/common.sh",
    "scripts/lib/el-guests.jq",
    "scripts/setup-hive.sh",
    "scripts/run-hive-consume-client.sh",
    "scripts/setup-eest.sh",
    "scripts/prune-skipped-hive-results.py",
    "scripts/check-smoke-results.py",
)


def patterns() -> list[str]:
    lines = PATHS_FILE.read_text(encoding="utf-8").splitlines()
    return [line for line in lines if line and not line.startswith("#")]


class NimbusSmokeSelectionTests(unittest.TestCase):
    def select(self, *paths: str) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            cwd=REPO_ROOT,
            input="".join(f"{path}\n" for path in paths),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assertSelects(self, paths: tuple[str, ...], expected: str) -> None:
        self.assertEqual(self.select(*paths).stdout, f"{expected}\n")

    def test_every_pattern_has_an_example(self):
        for pattern in patterns():
            with self.subTest(pattern=pattern):
                self.assertTrue(
                    any(fnmatch.fnmatchcase(path, pattern) for path in TRIGGERS),
                    f"add a path that matches {pattern} to TRIGGERS",
                )

    def test_listed_paths_trigger_nimbus(self):
        for path in TRIGGERS:
            with self.subTest(path=path):
                result = self.select(path)
                self.assertEqual(result.stdout, "true\n")
                self.assertIn(f"Nimbus runs because {path} changed", result.stderr)

    def test_fixture_scripts_covered_by_geth_skip_nimbus(self):
        for path in (
            "scripts/prepare-fixtures.sh",
            "scripts/fill-fixtures.sh",
            "scripts/validate-fixtures.sh",
        ):
            with self.subTest(path=path):
                self.assertSelects((path,), "false")

    def test_only_the_smoke_setup_action_triggers_nimbus(self):
        for path in (
            ".github/actions/fetch-dataset/action.yml",
            ".github/actions/result-bundle/action.yml",
            ".github/actions/zkevm-runner-setup/action.yml",
            ".github/workflows/publish.yml",
        ):
            with self.subTest(path=path):
                self.assertSelects((path,), "false")

    def test_unrelated_changes_skip_nimbus(self):
        for path in ("README.md", "config/refresh.json", "config/el-guests.json"):
            with self.subTest(path=path):
                self.assertSelects((path,), "false")

    def test_no_changes_skip_nimbus(self):
        self.assertSelects((), "false")

    def test_one_listed_path_among_others_triggers_nimbus(self):
        self.assertSelects(
            ("README.md", "scripts/fill-fixtures.sh", "scripts/setup-eest.sh"), "true"
        )


if __name__ == "__main__":
    unittest.main()
