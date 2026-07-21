import json
import os
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "merge-hive-result-dirs.sh"


def write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def write_suite(
    path: Path,
    *,
    clients: list[str] | None = None,
    name: str | None = None,
    test_cases: object | None = None,
) -> None:
    write_json(
        path,
        {
            "name": name if name is not None else f"suite/{path.stem}",
            "clients": clients if clients is not None else [path.stem],
            "testCases": {} if test_cases is None else test_cases,
        },
    )


class MergeHiveResultDirsTests(unittest.TestCase):
    def run_merge(
        self,
        root: Path,
        *args: str,
        output: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "ROOT_DIR": str(root),
                "HIVE_RESULTS_DIR": str(output or root / "merged"),
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT_PATH), *args],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_success(self, completed: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(
            completed.returncode,
            0,
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
        )

    def test_merges_sources_and_accepts_identical_duplicate_files(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "merged"
            write_suite(first / "first.json", clients=["first-client"])
            write_suite(second / "second.json", clients=["second-client"])
            (first / "details").mkdir(parents=True)
            (second / "details").mkdir(parents=True)
            (first / "details" / "shared.log").write_text("same\n", encoding="utf-8")
            (second / "details" / "shared.log").write_text("same\n", encoding="utf-8")

            completed = self.run_merge(
                root,
                "--output",
                str(output),
                "--clean-output",
                str(first),
                str(second),
                output=output,
            )

            self.assert_success(completed)
            self.assertEqual(
                sorted(
                    path.relative_to(output).as_posix()
                    for path in output.rglob("*")
                    if path.is_file()
                ),
                ["details/shared.log", "first.json", "second.json"],
            )

    def test_conflict_is_detected_before_cleaning_output(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            output = root / "merged"
            write_suite(first / "first.json", clients=["first-client"])
            write_suite(second / "second.json", clients=["second-client"])
            (first / "details").mkdir(parents=True)
            (second / "details").mkdir(parents=True)
            (first / "details" / "shared.log").write_text("first\n", encoding="utf-8")
            (second / "details" / "shared.log").write_text("second\n", encoding="utf-8")
            output.mkdir()
            sentinel = output / "sentinel"
            sentinel.write_text("keep\n", encoding="utf-8")

            completed = self.run_merge(
                root,
                "--output",
                str(output),
                "--clean-output",
                str(first),
                str(second),
                output=output,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("conflicting result path", completed.stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")

    def test_rejects_file_directory_collision(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "first"
            second = root / "second"
            write_suite(first / "first.json", clients=["first-client"])
            write_suite(second / "second.json", clients=["second-client"])
            (first / "details").write_text("file\n", encoding="utf-8")
            (second / "details").mkdir(parents=True)
            (second / "details" / "result.log").write_text("log\n", encoding="utf-8")

            completed = self.run_merge(
                root,
                "--clean-output",
                str(first),
                str(second),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("both a file and directory", completed.stderr)

    def test_multi_client_requires_compatibility_flag(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            write_suite(source / "multi.json", clients=["first", "second"])

            rejected = self.run_merge(root, "--clean-output", str(source))
            accepted = self.run_merge(
                root,
                "--clean-output",
                "--allow-multi-client",
                str(source),
            )

            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("multi-client", rejected.stderr)
            self.assert_success(accepted)

    def test_rejects_invalid_suite_structure(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            write_suite(source / "invalid.json", clients=["client"], test_cases=[])

            completed = self.run_merge(root, "--clean-output", str(source))

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("no testCases object", completed.stderr)

    def test_skips_empty_generic_source(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            empty = root / "empty"
            valid = root / "valid"
            empty.mkdir()
            write_suite(valid / "valid.json", clients=["client"])

            completed = self.run_merge(
                root,
                "--clean-output",
                str(empty),
                str(valid),
            )

            self.assert_success(completed)
            self.assertIn("Skipping source with no top-level", completed.stdout)
            self.assertTrue((root / "merged" / "valid.json").is_file())

    def test_rejects_invalid_prune_summary_for_expected_client(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            write_json(
                source / ".eest-prune-skipped-summary",
                {
                    "suite_files_seen": 1,
                    "suite_files_removed": 0,
                    "test_cases_pruned": 1,
                },
            )

            completed = self.run_merge(
                root,
                "--clean-output",
                "--client-source",
                "ethrex",
                "ethrex_rlp-engineapi",
                str(source),
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("did not produce any top-level", completed.stderr)

    def test_rejects_symbolic_links(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            write_suite(source / "valid.json", clients=["client"])
            (source / "target.log").write_text("log\n", encoding="utf-8")
            (source / "linked.log").symlink_to(source / "target.log")

            completed = self.run_merge(root, "--clean-output", str(source))

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("symbolic links", completed.stderr)

    def test_rejects_symbolic_link_source_directory(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            linked_source = root / "linked-source"
            write_suite(source / "valid.json", clients=["client"])
            linked_source.symlink_to(source, target_is_directory=True)

            completed = self.run_merge(root, "--clean-output", str(linked_source))

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("source directory may not be a symbolic link", completed.stderr)

    def test_rejects_source_output_overlap_and_unsafe_clean(self):
        with TemporaryDirectory() as tmp, TemporaryDirectory() as other_tmp:
            root = Path(tmp)
            source = root / "source"
            other_source = Path(other_tmp) / "source"
            write_suite(source / "valid.json", clients=["client"])
            write_suite(other_source / "valid.json", clients=["client"])

            overlap = self.run_merge(
                root,
                "--output",
                str(source / "output"),
                "--clean-output",
                str(source),
                output=source / "output",
            )
            unsafe = self.run_merge(
                root,
                "--output",
                str(root),
                "--clean-output",
                str(other_source),
                output=root,
            )

            self.assertNotEqual(overlap.returncode, 0)
            self.assertIn("output must not be inside source", overlap.stderr)
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertIn("unsafe output", unsafe.stderr)

    def test_requires_empty_output_without_clean_flag(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            output = root / "merged"
            write_suite(source / "valid.json", clients=["client"])
            output.mkdir()
            (output / "existing").write_text("keep\n", encoding="utf-8")

            completed = self.run_merge(root, str(source), output=output)

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("output directory is not empty", completed.stderr)


if __name__ == "__main__":
    unittest.main()
