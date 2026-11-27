import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
COMMON = REPO_ROOT / "scripts" / "lib" / "common.sh"


def run(script: str, env: dict[str, str] | None = None, cwd: Path = REPO_ROOT):
    return subprocess.run(
        ["bash", "-c", f'set -Eeuo pipefail; . "{COMMON}"; {script}'],
        cwd=cwd,
        env={**os.environ, **(env or {})},
        text=True,
        capture_output=True,
        check=False,
    )


def git(directory: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(directory), "-c", "user.name=Test", "-c", "user.email=test@example.com",
         "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
        text=True, capture_output=True, check=True,
    ).stdout.strip()


class CommonHelpersTests(unittest.TestCase):
    def test_booleans_accept_one_true_yes_and_zero_false_no(self):
        for value in ("1", "true", "yes", "0", "false", "no"):
            with self.subTest(value=value):
                self.assertEqual(run(f'eest_require_bool FLAG "{value}"').returncode, 0)
        for value in ("1", "true", "yes"):
            with self.subTest(value=value):
                self.assertEqual(run(f'eest_is_true "{value}"').returncode, 0)
        for value in ("0", "false", "no", "", "on"):
            with self.subTest(value=value):
                self.assertNotEqual(run(f'eest_is_true "{value}"').returncode, 0)
        result = run('eest_require_bool FLAG on')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FLAG must be 1, true, yes, 0, false, or no: on", result.stderr)

    def test_integer_checks(self):
        self.assertEqual(run("eest_require_positive_int N 3").returncode, 0)
        self.assertIn("N must be greater than zero", run("eest_require_positive_int N 0").stderr)
        self.assertIn("N must be a positive integer: x", run("eest_require_positive_int N x").stderr)
        self.assertEqual(run("eest_require_uint N 0").returncode, 0)
        self.assertIn("N must be a non-negative integer: -1", run("eest_require_uint N -1").stderr)

    def test_require_cmd_names_the_missing_tool(self):
        self.assertEqual(run("eest_require_cmd bash Bash").returncode, 0)
        result = run("eest_require_cmd no-such-tool-here Thing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing required tool: Thing (no-such-tool-here not found on PATH)", result.stderr)

    def test_normalize_path(self):
        env = {"ROOT_DIR": "/repo"}
        self.assertEqual(run("eest_normalize_path site/../out/./x", env).stdout.strip(), "/repo/out/x")
        self.assertEqual(run("eest_normalize_path /a/b/../c", env).stdout.strip(), "/a/c")
        self.assertIn("path escapes filesystem root", run("eest_normalize_path /..", env).stderr)

    def test_guard_clean_dir_protects_every_named_directory_but_its_own(self):
        env = {
            "ROOT_DIR": "/repo",
            "SITE_DIR": "/repo/site",
            "FIXTURES_DIR": "/repo/fixtures",
            "HIVE_DIR": "/repo/hive",
        }
        for label, directory in (("SITE_DIR", "/repo/site"), ("scratch", "/repo/out"), ("scratch", "/tmp/x")):
            with self.subTest(label=label, directory=directory):
                self.assertEqual(run(f'eest_guard_clean_dir {label} "{directory}"', env).returncode, 0)
        for label, directory, error in (
            ("FIXTURES_DIR", "/repo/site", "/repo/site is SITE_DIR"),
            ("SITE_DIR", "/repo/hive", "/repo/hive is HIVE_DIR"),
            ("SITE_DIR", "/repo", "/repo is ROOT_DIR"),
            ("SITE_DIR", "/", "refusing to clean unsafe SITE_DIR: /"),
            ("SITE_DIR", "/elsewhere/site", "outside ROOT_DIR or /tmp"),
        ):
            with self.subTest(label=label, directory=directory):
                result = run(f'eest_guard_clean_dir {label} "{directory}"', env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)


class PrepareGitCheckoutTests(unittest.TestCase):
    def setUp(self):
        if shutil.which("git") is None:
            self.skipTest("git is required")
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        git(self.upstream, "init", "-q", "-b", "main")
        (self.upstream / "file").write_text("one\n")
        git(self.upstream, "add", "file")
        git(self.upstream, "commit", "-q", "-m", "one")
        self.first = git(self.upstream, "rev-parse", "HEAD")
        git(self.upstream, "tag", "v1")
        (self.upstream / "file").write_text("two\n")
        git(self.upstream, "commit", "-q", "-am", "two")
        self.second = git(self.upstream, "rev-parse", "HEAD")

    def prepare(self, ref: str, directory: Path):
        return run(f'eest_prepare_git_checkout Thing "{self.upstream}" "{ref}" "{directory}"')

    def test_clones_then_moves_between_refs_and_shas(self):
        checkout = self.root / "work" / "thing"
        result = self.prepare("v1", checkout)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(checkout, "rev-parse", "HEAD"), self.first)
        self.assertEqual(self.prepare(self.second, checkout).returncode, 0)
        self.assertEqual(git(checkout, "rev-parse", "HEAD"), self.second)
        self.assertEqual(self.prepare("main", checkout).returncode, 0)
        self.assertEqual(git(checkout, "rev-parse", "HEAD"), self.second)

    def test_points_an_existing_checkout_at_the_given_repo(self):
        checkout = self.root / "thing"
        self.prepare("v1", checkout)
        git(checkout, "remote", "set-url", "origin", "https://example.invalid/old.git")
        self.assertEqual(self.prepare("v1", checkout).returncode, 0)
        self.assertEqual(git(checkout, "remote", "get-url", "origin"), str(self.upstream))

    def test_refuses_a_plain_directory_inside_another_repository(self):
        outer = self.root / "outer"
        outer.mkdir()
        git(outer, "init", "-q", "-b", "main")
        git(outer, "remote", "add", "origin", "https://example.invalid/outer.git")
        (outer / "thing").mkdir()

        result = self.prepare("v1", outer / "thing")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Thing directory exists but is not a git checkout root", result.stderr)
        self.assertEqual(git(outer, "remote", "get-url", "origin"), "https://example.invalid/outer.git")


if __name__ == "__main__":
    unittest.main()
