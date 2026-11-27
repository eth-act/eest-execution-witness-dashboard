"""The pins in scripts/env.sh have to match the workflow defaults.

The refresh relies on the defaults of the workflows it calls, and local runs
rely on scripts/env.sh, so a bump has to change both. PR smoke's checks job
has no PyYAML, so the workflows are read line by line.
"""

import os
import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
TRIGGERS = ("workflow_dispatch", "workflow_call")


def env_defaults() -> dict[str, str]:
    # A clean environment, so values a CI job exports don't stand in for defaults.
    completed = subprocess.run(
        ["bash", str(REPO_ROOT / "scripts" / "env.sh"), "--print"],
        cwd=REPO_ROOT,
        env={"PATH": os.environ["PATH"]},
        text=True,
        capture_output=True,
        check=True,
    )
    return dict(
        line.split("=", 1) for line in completed.stdout.splitlines() if "=" in line
    )


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def input_defaults(workflow: str) -> dict[str, dict[str, str]]:
    """Return the input defaults of a workflow, by trigger and input name."""
    defaults: dict[str, dict[str, str]] = {}
    trigger = name = None
    for line in (WORKFLOWS / workflow).read_text(encoding="utf-8").splitlines():
        if re.match(r"\S", line):
            trigger = None
            continue
        match = re.match(r"  (\S+):\s*$", line)
        if match:
            trigger = match.group(1) if match.group(1) in TRIGGERS else None
            if trigger is not None:
                defaults[trigger] = {}
            continue
        if trigger is None:
            continue
        match = re.match(r"      ([A-Za-z0-9_]+):\s*$", line)
        if match:
            name = match.group(1)
            continue
        match = re.match(r"        default:\s*(.*?)\s*$", line)
        if match and name is not None:
            defaults[trigger][name] = unquote(match.group(1))
    return defaults


def refresh_eest_release_tag() -> str:
    text = (WORKFLOWS / "refresh-dashboard.yml").read_text(encoding="utf-8")
    tags = re.findall(r"^\s+eest_release_tag:\s*(\S+)\s*$", text, re.M)
    if len(tags) != 1:
        raise AssertionError(f"expected one eest_release_tag in the refresh, found {tags}")
    return unquote(tags[0])


class DefaultPinsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.env = env_defaults()
        cls.workflows = {
            workflow: input_defaults(workflow)
            for workflow in ("prepare-dataset.yml", "run-workloads.yml", "publish.yml")
        }

    def assert_workflow_default(self, workflow: str, name: str, expected: str) -> None:
        for trigger in TRIGGERS:
            with self.subTest(workflow=workflow, trigger=trigger, input=name):
                self.assertEqual(self.workflows[workflow][trigger][name], expected)

    def test_refresh_uses_the_eest_release_of_env_sh(self):
        self.assertEqual(refresh_eest_release_tag(), self.env["EEST_REF"])
        self.assert_workflow_default("prepare-dataset.yml", "eest_ref", self.env["EEST_REF"])
        self.assert_workflow_default("prepare-dataset.yml", "eest_repo", self.env["EEST_REPO"])

    def test_hive_pins_match(self):
        self.assert_workflow_default("prepare-dataset.yml", "hive_repo", self.env["HIVE_REPO"])
        self.assert_workflow_default("prepare-dataset.yml", "hive_ref", self.env["HIVE_REF"])

    def test_workload_pins_match(self):
        for name, variable in (
            ("zkevm_benchmark_workload_repo", "ZKEVM_BENCHMARK_WORKLOAD_REPO"),
            ("zkevm_benchmark_workload_ref", "ZKEVM_BENCHMARK_WORKLOAD_REF"),
            ("zkevm_rayon_threads", "ZKEVM_RAYON_THREADS"),
        ):
            self.assert_workflow_default("prepare-dataset.yml", name, self.env[variable])

    def test_site_pins_match(self):
        for name, variable in (
            ("hive_ui_repo", "HIVE_UI_REPO"),
            ("hive_ui_ref", "HIVE_UI_REF"),
            ("max_site_size_mb", "SITE_MAX_SIZE_MB"),
        ):
            self.assert_workflow_default("publish.yml", name, self.env[variable])

    def test_dispatch_and_call_defaults_agree(self):
        for workflow, triggers in self.workflows.items():
            with self.subTest(workflow=workflow):
                self.assertTrue(triggers["workflow_dispatch"])
                self.assertEqual(triggers["workflow_dispatch"], triggers["workflow_call"])


if __name__ == "__main__":
    unittest.main()
