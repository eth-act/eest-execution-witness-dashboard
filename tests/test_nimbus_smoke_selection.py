import os
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "pr-smoke.yml"


def nimbus_selection_script() -> str:
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    step = lines.index("      - name: Decide whether Nimbus runs")
    start = lines.index("        run: |", step + 1) + 1
    body = []
    for line in lines[start:]:
        if line and not line.startswith("          "):
            break
        body.append(line[10:] if line else "")
    return "\n".join(body)


class NimbusSmokeSelectionTests(unittest.TestCase):
    def run_selection(self, changed_path: str) -> str:
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            git = directory / "git"
            git.write_text(
                '#!/bin/sh\n'
                'if [ "$*" != "diff --name-only HEAD^1 HEAD" ]; then exit 1; fi\n'
                'printf "%s\\n" "$CHANGED_PATH"\n',
                encoding="utf-8",
            )
            git.chmod(0o755)
            output = directory / "github-output"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{directory}:{env.get('PATH', '')}",
                    "CHANGED_PATH": changed_path,
                    "GITHUB_OUTPUT": str(output),
                }
            )
            result = subprocess.run(
                ["bash", "-c", nimbus_selection_script()],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return output.read_text(encoding="utf-8").strip()

    def test_setup_eest_triggers_nimbus(self):
        self.assertEqual(self.run_selection("scripts/setup-eest.sh"), "nimbus=true")

    def test_fixture_scripts_covered_by_geth_skip_nimbus(self):
        for path in (
            "scripts/prepare-fixtures.sh",
            "scripts/fill-fixtures.sh",
            "scripts/validate-fixtures.sh",
        ):
            with self.subTest(path=path):
                self.assertEqual(self.run_selection(path), "nimbus=false")

    def test_unrelated_change_skips_nimbus(self):
        self.assertEqual(self.run_selection("README.md"), "nimbus=false")

    def test_setup_eest_among_other_changes_triggers_nimbus(self):
        self.assertEqual(
            self.run_selection("scripts/fill-fixtures.sh\nscripts/setup-eest.sh"),
            "nimbus=true",
        )


if __name__ == "__main__":
    unittest.main()
