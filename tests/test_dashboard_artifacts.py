import importlib.util
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "dashboard-artifacts.py"
SPEC = importlib.util.spec_from_file_location("dashboard_artifacts", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
dashboard_artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dashboard_artifacts)


ArtifactError = dashboard_artifacts.ArtifactError


def producer(workflow: str, *, ref: str = "refs/heads/main", run_id: int = 100) -> dict:
    repository = "eth-act/eest-execution-witness-dashboard"
    return {
        "repository": repository,
        "ref": ref,
        "sha": "a" * 40,
        "workflow_ref": f"{repository}/{workflow}@{ref}",
        "run_id": run_id,
        "run_attempt": 1,
        "created_at": "2026-07-12T12:00:00Z",
    }


def dataset_manifest(*, dataset_id: str = "100", ref: str = "refs/heads/main") -> dict:
    return {
        "schema_version": 1,
        "dataset_id": dataset_id,
        "producer": producer(
            ".github/workflows/prepare-dataset.yml",
            ref=ref,
            run_id=int(dataset_id),
        ),
        "fixtures": {"archive_sha256": "b" * 64},
        "eest": {
            "repo": "https://github.com/ethereum/execution-specs.git",
            "requested_ref": "projects/zkevm-releases",
            "release_tag": "",
            "commit": "c" * 40,
            "filler_path": "tests/amsterdam/eip8025_optional_proofs",
            "fork": "Amsterdam",
        },
        "hive": {
            "repo": "https://github.com/ethereum/hive.git",
            "requested_ref": "master",
            "commit": "d" * 40,
        },
        "zkevm_benchmark": {
            "repo": "https://github.com/eth-act/zkevm-benchmark-workload.git",
            "requested_ref": "v0.5.0",
            "commit": "e" * 40,
            "rayon_threads": 10,
        },
    }


def result_manifest(dataset: dict, payload: Path, *, kind: str = "hive") -> dict:
    config = (
        {"id": "ethrex", "ref": "main"}
        if kind == "hive"
        else {"execution_client": "ethrex", "zkvm": "zisk"}
    )
    workload = {
        "kind": kind,
        "id": "ethrex" if kind == "hive" else "ethrex:zisk",
        "client_id": "ethrex",
        "config": config,
    }
    if kind == "zkevm":
        workload["zkvm"] = "zisk"
    return {
        "schema_version": 1,
        "dataset_id": dataset["dataset_id"],
        "producer": producer(
            ".github/workflows/run-workloads.yml",
            run_id=200,
        ),
        "workload": workload,
        "toolchains": dashboard_artifacts.result_toolchains(dataset),
        "payload_sha256": dashboard_artifacts.tree_sha256(payload),
    }


def artifact(
    name: str,
    *,
    artifact_id: int,
    run_id: int,
    branch: str = "main",
    expired: bool = False,
    created_at: str = "2026-07-12T12:00:00Z",
    conclusion: str | None = None,
    head_sha: str = "a" * 40,
) -> dict:
    workflow_run = {"id": run_id, "head_branch": branch, "head_sha": head_sha}
    if conclusion is not None:
        workflow_run["conclusion"] = conclusion
    return {
        "id": artifact_id,
        "name": name,
        "expired": expired,
        "created_at": created_at,
        "workflow_run": workflow_run,
    }


class DatasetManifestTests(unittest.TestCase):
    def test_valid_main_dataset(self):
        dataset = dataset_manifest()

        self.assertIs(dashboard_artifacts.validate_dataset(dataset), dataset)

    def test_non_main_dataset_is_rejected_for_consumption(self):
        dataset = dataset_manifest(ref="refs/heads/feature")

        with self.assertRaisesRegex(ArtifactError, "refs/heads/main"):
            dashboard_artifacts.validate_dataset(dataset)

    def test_dataset_id_must_equal_prepare_run_id(self):
        dataset = dataset_manifest()
        dataset["producer"]["run_id"] = 101

        with self.assertRaisesRegex(ArtifactError, "must equal"):
            dashboard_artifacts.validate_dataset(dataset)

    def test_manifest_strings_reject_newlines(self):
        dataset = dataset_manifest()
        dataset["hive"]["repo"] = "https://example.invalid/repo\nINJECTED=value"

        with self.assertRaisesRegex(ArtifactError, "control characters"):
            dashboard_artifacts.validate_dataset(dataset)


class ResultManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.payload = Path(self.temp_dir.name) / "payload"
        (self.payload / "ethrex").mkdir(parents=True)
        (self.payload / "ethrex" / "result.json").write_text(
            '{"ok":true}\n', encoding="utf-8"
        )
        self.dataset = dataset_manifest()

    def test_valid_hive_bundle(self):
        result = result_manifest(self.dataset, self.payload)

        validated = dashboard_artifacts.validate_result(
            result,
            dataset=self.dataset,
            payload=self.payload,
        )

        self.assertIs(validated, result)

    def test_valid_zkevm_bundle(self):
        result = result_manifest(self.dataset, self.payload, kind="zkevm")

        validated = dashboard_artifacts.validate_result(
            result,
            dataset=self.dataset,
            payload=self.payload,
        )

        self.assertEqual(validated["workload"]["id"], "ethrex:zisk")

    def test_dataset_mismatch_is_rejected(self):
        result = result_manifest(self.dataset, self.payload)
        result["dataset_id"] = "101"

        with self.assertRaisesRegex(ArtifactError, "dataset mismatch"):
            dashboard_artifacts.validate_result(
                result,
                dataset=self.dataset,
                payload=self.payload,
            )

    def test_toolchain_mismatch_is_rejected(self):
        result = result_manifest(self.dataset, self.payload)
        result["toolchains"]["hive_commit"] = "f" * 40

        with self.assertRaisesRegex(ArtifactError, "toolchains"):
            dashboard_artifacts.validate_result(
                result,
                dataset=self.dataset,
                payload=self.payload,
            )

    def test_payload_digest_mismatch_is_rejected(self):
        result = result_manifest(self.dataset, self.payload)
        (self.payload / "ethrex" / "result.json").write_text(
            '{"ok":false}\n', encoding="utf-8"
        )

        with self.assertRaisesRegex(ArtifactError, "payload SHA-256 mismatch"):
            dashboard_artifacts.validate_result(
                result,
                dataset=self.dataset,
                payload=self.payload,
            )

    def test_hive_payload_may_not_stage_another_client(self):
        result = result_manifest(self.dataset, self.payload)
        (self.payload / "other").mkdir()

        with self.assertRaisesRegex(ArtifactError, "exactly one top-level"):
            dashboard_artifacts.validate_result(
                result,
                dataset=self.dataset,
                payload=self.payload,
            )

    def test_unsafe_workload_id_is_rejected(self):
        result = result_manifest(self.dataset, self.payload)
        result["workload"]["client_id"] = "../ethrex"

        with self.assertRaisesRegex(ArtifactError, "unsafe"):
            dashboard_artifacts.validate_result(
                result,
                dataset=self.dataset,
                payload=self.payload,
            )

    def test_wrong_producer_workflow_is_rejected(self):
        result = result_manifest(self.dataset, self.payload)
        result["producer"]["workflow_ref"] = (
            "eth-act/eest-execution-witness-dashboard/"
            ".github/workflows/other.yml@refs/heads/main"
        )

        with self.assertRaisesRegex(ArtifactError, "workflow_ref"):
            dashboard_artifacts.validate_result(
                result,
                dataset=self.dataset,
                payload=self.payload,
            )


class ArtifactSelectionTests(unittest.TestCase):
    def setUp(self):
        self.name = "hive-results-v1-100-ethrex"

    def select(self, artifacts: list[dict]) -> list[dict]:
        return dashboard_artifacts.select_artifacts(
            {"artifacts": artifacts},
            dataset_id="100",
            hive_clients=["ethrex"],
            zkevm_runs=[],
            branch="main",
        )

    def test_newest_run_id_wins_even_when_older_run_uploads_later(self):
        selected = self.select(
            [
                artifact(
                    self.name,
                    artifact_id=12,
                    run_id=200,
                    created_at="2026-07-12T13:00:00Z",
                    head_sha="b" * 40,
                ),
                artifact(
                    self.name,
                    artifact_id=11,
                    run_id=201,
                    created_at="2026-07-12T12:00:00Z",
                    head_sha="c" * 40,
                ),
            ]
        )

        self.assertEqual(selected[0]["run_id"], 201)
        self.assertEqual(selected[0]["artifact_id"], 11)
        self.assertEqual(selected[0]["head_sha"], "c" * 40)

    def test_artifact_id_breaks_ties_between_attempts(self):
        selected = self.select(
            [
                artifact(self.name, artifact_id=11, run_id=200),
                artifact(self.name, artifact_id=12, run_id=200),
            ]
        )

        self.assertEqual(selected[0]["artifact_id"], 12)

    def test_expired_and_non_main_artifacts_are_ignored(self):
        selected = self.select(
            [
                artifact(self.name, artifact_id=30, run_id=300, expired=True),
                artifact(self.name, artifact_id=29, run_id=299, branch="feature"),
                artifact(self.name, artifact_id=10, run_id=100),
            ]
        )

        self.assertEqual(selected[0]["run_id"], 100)

    def test_overall_failed_matrix_run_is_not_filtered(self):
        selected = self.select(
            [artifact(self.name, artifact_id=10, run_id=100, conclusion="failure")]
        )

        self.assertEqual(selected[0]["artifact_id"], 10)

    def test_failed_refresh_without_artifact_leaves_previous_success(self):
        selected = self.select([artifact(self.name, artifact_id=10, run_id=100)])

        self.assertEqual(selected[0]["run_id"], 100)

    def test_missing_required_artifact_fails_atomically(self):
        with self.assertRaisesRegex(ArtifactError, "missing publish artifacts"):
            self.select([])

    def test_hive_and_zkevm_requirements_are_both_resolved(self):
        zkevm_name = "zkevm-metrics-v1-100-zesu-zisk"
        selected = dashboard_artifacts.select_artifacts(
            [
                {"artifacts": [artifact(self.name, artifact_id=10, run_id=100)]},
                {"artifacts": [artifact(zkevm_name, artifact_id=11, run_id=101)]},
            ],
            dataset_id="100",
            hive_clients=["ethrex"],
            zkevm_runs=["zesu:zisk"],
            branch="main",
        )

        self.assertEqual([entry["kind"] for entry in selected], ["hive", "zkevm"])

    def test_duplicate_or_unsafe_requirements_are_rejected(self):
        with self.assertRaisesRegex(ArtifactError, "duplicate"):
            dashboard_artifacts.expected_artifacts("100", ["ethrex", "ethrex"], [])
        with self.assertRaisesRegex(ArtifactError, "unsafe"):
            dashboard_artifacts.expected_artifacts("100", ["../ethrex"], [])


class CommandValidationTests(unittest.TestCase):
    def test_fixture_digest_mismatch_fails_cli_command(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest_path = root / "dataset.json"
            fixture_path = root / "fixtures.tar.gz"
            manifest_path.write_text(json.dumps(dataset_manifest()), encoding="utf-8")
            fixture_path.write_bytes(b"not the recorded fixture archive")

            args = SimpleNamespace(
                manifest=manifest_path,
                dataset_id="100",
                fixture_archive=fixture_path,
                repository=None,
                allow_non_main=False,
            )
            with self.assertRaisesRegex(
                ArtifactError, "fixture archive SHA-256 mismatch"
            ):
                dashboard_artifacts.command_validate_dataset(args)


if __name__ == "__main__":
    unittest.main()
