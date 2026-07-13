#!/usr/bin/env python3

"""Create, validate, and select dashboard dataset/result artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, NoReturn


SCHEMA_VERSION = 1
DATASET_WORKFLOW = ".github/workflows/prepare-dataset.yml"
RESULT_WORKFLOW = ".github/workflows/run-workloads.yml"
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")


class ArtifactError(ValueError):
    """Raised when artifact metadata or contents are invalid."""


def fail(message: str) -> NoReturn:
    raise ArtifactError(message)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"JSON file does not exist: {path}")
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {path}: {exc}")


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_string(obj: dict[str, Any], key: str, label: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        fail(f"{label}.{key} must be a non-empty string")
    if "\n" in value or "\r" in value or "\0" in value:
        fail(f"{label}.{key} may not contain control characters")
    return value


def require_int(
    obj: dict[str, Any], key: str, label: str, *, positive: bool = True
) -> int:
    value = obj.get(key)
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or (positive and value <= 0)
    ):
        qualifier = "positive " if positive else ""
        fail(f"{label}.{key} must be a {qualifier}integer")
    return value


def require_safe_id(value: str, label: str) -> str:
    if not SAFE_ID_RE.fullmatch(value):
        fail(f"{label} contains unsafe characters: {value}")
    return value


def require_dataset_id(value: str) -> str:
    if not value.isdigit() or int(value) <= 0:
        fail(f"dataset_id must be a positive numeric workflow run ID: {value}")
    return value


def require_sha(value: str, label: str) -> str:
    if not SHA_RE.fullmatch(value):
        fail(f"{label} must be a full 40-character Git commit SHA")
    return value.lower()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except FileNotFoundError:
        fail(f"file does not exist: {path}")
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    if not root.is_dir():
        fail(f"payload directory does not exist: {root}")

    digest = hashlib.sha256()
    files = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            fail(f"payload may not contain symbolic links: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        digest.update(b"\0")
        files += 1

    if files == 0:
        fail(f"payload directory is empty: {root}")
    return digest.hexdigest()


def producer_object(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "repository": args.repository,
        "ref": args.ref,
        "sha": require_sha(args.sha, "producer sha"),
        "workflow_ref": args.workflow_ref,
        "run_id": int(require_dataset_id(str(args.run_id))),
        "run_attempt": int(args.run_attempt),
        "created_at": args.created_at,
    }


def validate_producer(
    value: Any,
    *,
    label: str,
    workflow_path: str,
    require_main: bool,
) -> dict[str, Any]:
    producer = require_object(value, label)
    repository = require_string(producer, "repository", label)
    ref = require_string(producer, "ref", label)
    require_sha(require_string(producer, "sha", label), f"{label}.sha")
    workflow_ref = require_string(producer, "workflow_ref", label)
    require_int(producer, "run_id", label)
    require_int(producer, "run_attempt", label)
    require_string(producer, "created_at", label)

    if require_main and ref != "refs/heads/main":
        fail(f"{label}.ref must be refs/heads/main, got {ref}")
    expected_workflow_ref = f"{repository}/{workflow_path}@{ref}"
    if workflow_ref != expected_workflow_ref:
        fail(
            f"{label}.workflow_ref must be {expected_workflow_ref}, got {workflow_ref}"
        )
    return producer


def validate_dataset(value: Any, *, require_main: bool = True) -> dict[str, Any]:
    dataset = require_object(value, "dataset manifest")
    if dataset.get("schema_version") != SCHEMA_VERSION:
        fail(f"unsupported dataset schema_version: {dataset.get('schema_version')}")
    dataset_id = require_dataset_id(require_string(dataset, "dataset_id", "dataset"))
    producer = validate_producer(
        dataset.get("producer"),
        label="dataset.producer",
        workflow_path=DATASET_WORKFLOW,
        require_main=require_main,
    )
    if producer["run_id"] != int(dataset_id):
        fail("dataset_id must equal dataset.producer.run_id")

    fixtures = require_object(dataset.get("fixtures"), "dataset.fixtures")
    archive_sha = require_string(fixtures, "archive_sha256", "dataset.fixtures")
    if not re.fullmatch(r"[0-9a-f]{64}", archive_sha):
        fail("dataset.fixtures.archive_sha256 must be a lowercase SHA-256")

    eest = require_object(dataset.get("eest"), "dataset.eest")
    require_string(eest, "repo", "dataset.eest")
    require_string(eest, "requested_ref", "dataset.eest")
    release_tag = eest.get("release_tag")
    if not isinstance(release_tag, str):
        fail("dataset.eest.release_tag must be a string")
    if "\n" in release_tag or "\r" in release_tag or "\0" in release_tag:
        fail("dataset.eest.release_tag may not contain control characters")
    require_sha(require_string(eest, "commit", "dataset.eest"), "dataset.eest.commit")
    require_string(eest, "filler_path", "dataset.eest")
    require_string(eest, "fork", "dataset.eest")

    hive = require_object(dataset.get("hive"), "dataset.hive")
    require_string(hive, "repo", "dataset.hive")
    require_string(hive, "requested_ref", "dataset.hive")
    require_sha(require_string(hive, "commit", "dataset.hive"), "dataset.hive.commit")

    zkevm = require_object(dataset.get("zkevm_benchmark"), "dataset.zkevm_benchmark")
    require_string(zkevm, "repo", "dataset.zkevm_benchmark")
    require_string(zkevm, "requested_ref", "dataset.zkevm_benchmark")
    require_sha(
        require_string(zkevm, "commit", "dataset.zkevm_benchmark"),
        "dataset.zkevm_benchmark.commit",
    )
    require_int(zkevm, "rayon_threads", "dataset.zkevm_benchmark")
    return dataset


def command_write_dataset(args: argparse.Namespace) -> None:
    dataset_id = require_dataset_id(args.dataset_id)
    dataset = {
        "schema_version": SCHEMA_VERSION,
        "dataset_id": dataset_id,
        "producer": producer_object(args),
        "fixtures": {"archive_sha256": file_sha256(args.fixture_archive)},
        "eest": {
            "repo": args.eest_repo,
            "requested_ref": args.eest_requested_ref,
            "release_tag": args.eest_release_tag,
            "commit": require_sha(args.eest_commit, "EEST commit"),
            "filler_path": args.filler_path,
            "fork": args.fork,
        },
        "hive": {
            "repo": args.hive_repo,
            "requested_ref": args.hive_requested_ref,
            "commit": require_sha(args.hive_commit, "Hive commit"),
        },
        "zkevm_benchmark": {
            "repo": args.zkevm_repo,
            "requested_ref": args.zkevm_requested_ref,
            "commit": require_sha(args.zkevm_commit, "zkEVM benchmark commit"),
            "rayon_threads": int(args.rayon_threads),
        },
    }
    validate_dataset(dataset, require_main=False)
    write_json(args.output, dataset)


def command_validate_dataset(args: argparse.Namespace) -> None:
    dataset = validate_dataset(
        load_json(args.manifest), require_main=not args.allow_non_main
    )
    if args.dataset_id and dataset["dataset_id"] != require_dataset_id(args.dataset_id):
        fail(
            f"dataset ID mismatch: expected {args.dataset_id}, "
            f"got {dataset['dataset_id']}"
        )
    if args.repository and dataset["producer"]["repository"] != args.repository:
        fail(
            f"dataset producer repository mismatch: expected {args.repository}, "
            f"got {dataset['producer']['repository']}"
        )
    if args.fixture_archive:
        actual = file_sha256(args.fixture_archive)
        expected = dataset["fixtures"]["archive_sha256"]
        if actual != expected:
            fail(f"fixture archive SHA-256 mismatch: expected {expected}, got {actual}")


def result_toolchains(dataset: dict[str, Any]) -> dict[str, Any]:
    return {
        "eest_commit": dataset["eest"]["commit"],
        "hive_commit": dataset["hive"]["commit"],
        "zkevm_benchmark_commit": dataset["zkevm_benchmark"]["commit"],
        "rayon_threads": dataset["zkevm_benchmark"]["rayon_threads"],
    }


def validate_workload(value: Any) -> dict[str, Any]:
    workload = require_object(value, "result.workload")
    kind = require_string(workload, "kind", "result.workload")
    if kind not in {"hive", "zkevm"}:
        fail(f"result.workload.kind must be hive or zkevm, got {kind}")
    client_id = require_safe_id(
        require_string(workload, "client_id", "result.workload"),
        "result.workload.client_id",
    )
    zkvm = workload.get("zkvm")
    if kind == "hive" and zkvm is not None:
        fail("Hive result workload may not contain zkvm")
    if kind == "zkevm":
        if not isinstance(zkvm, str) or not zkvm:
            fail("zkEVM result workload requires zkvm")
        require_safe_id(zkvm, "result.workload.zkvm")
    config = workload.get("config")
    config = require_object(config, "result.workload.config")
    expected_id = client_id if kind == "hive" else f"{client_id}:{zkvm}"
    if workload.get("id") != expected_id:
        fail(f"result.workload.id must be {expected_id}")
    if kind == "hive" and config.get("id") != client_id:
        fail("Hive result workload config ID does not match client_id")
    if kind == "zkevm" and (
        config.get("execution_client") != client_id or config.get("zkvm") != zkvm
    ):
        fail("zkEVM result workload config does not match client_id and zkvm")
    return workload


def validate_result(
    value: Any,
    *,
    dataset: dict[str, Any],
    payload: Path | None,
    require_main: bool = True,
) -> dict[str, Any]:
    result = require_object(value, "result manifest")
    if result.get("schema_version") != SCHEMA_VERSION:
        fail(f"unsupported result schema_version: {result.get('schema_version')}")
    if result.get("dataset_id") != dataset["dataset_id"]:
        fail(
            f"result dataset mismatch: expected {dataset['dataset_id']}, "
            f"got {result.get('dataset_id')}"
        )
    validate_producer(
        result.get("producer"),
        label="result.producer",
        workflow_path=RESULT_WORKFLOW,
        require_main=require_main,
    )
    workload = validate_workload(result.get("workload"))
    if result.get("toolchains") != result_toolchains(dataset):
        fail("result toolchains do not match the dataset manifest")
    payload_sha = require_string(result, "payload_sha256", "result")
    if not re.fullmatch(r"[0-9a-f]{64}", payload_sha):
        fail("result.payload_sha256 must be a lowercase SHA-256")
    if payload is not None:
        if not payload.is_dir():
            fail(f"payload directory does not exist: {payload}")
        if workload["kind"] == "hive":
            expected_dir = payload / workload["client_id"]
            top_level = {path.name for path in payload.iterdir()}
            if not expected_dir.is_dir() or top_level != {workload["client_id"]}:
                fail(
                    "Hive result payload must contain exactly one top-level "
                    f"{workload['client_id']} directory"
                )
        actual = tree_sha256(payload)
        if actual != payload_sha:
            fail(
                f"result payload SHA-256 mismatch: expected {payload_sha}, got {actual}"
            )
    return result


def command_write_result(args: argparse.Namespace) -> None:
    dataset = validate_dataset(load_json(args.dataset_manifest), require_main=True)
    client_id = require_safe_id(args.client_id, "client_id")
    if args.kind == "zkevm":
        if not args.zkvm:
            fail("--zkvm is required for zkevm results")
        zkvm = require_safe_id(args.zkvm, "zkvm")
        workload_id = f"{client_id}:{zkvm}"
    else:
        if args.zkvm:
            fail("--zkvm is only valid for zkevm results")
        zkvm = None
        workload_id = client_id

    config = require_object(load_json(args.config), "workload config")
    workload: dict[str, Any] = {
        "kind": args.kind,
        "id": workload_id,
        "client_id": client_id,
        "config": config,
    }
    if zkvm is not None:
        workload["zkvm"] = zkvm

    result = {
        "schema_version": SCHEMA_VERSION,
        "dataset_id": dataset["dataset_id"],
        "producer": producer_object(args),
        "workload": workload,
        "toolchains": result_toolchains(dataset),
        "payload_sha256": tree_sha256(args.payload),
    }
    validate_result(result, dataset=dataset, payload=args.payload, require_main=True)
    write_json(args.output, result)


def command_validate_result(args: argparse.Namespace) -> None:
    dataset = validate_dataset(load_json(args.dataset_manifest), require_main=True)
    result = validate_result(
        load_json(args.manifest),
        dataset=dataset,
        payload=args.payload,
        require_main=True,
    )
    workload = result["workload"]
    if args.kind and workload["kind"] != args.kind:
        fail(f"result kind mismatch: expected {args.kind}, got {workload['kind']}")
    if args.client_id and workload["client_id"] != args.client_id:
        fail(
            f"result client mismatch: expected {args.client_id}, "
            f"got {workload['client_id']}"
        )
    actual_zkvm = workload.get("zkvm")
    if args.zkvm and actual_zkvm != args.zkvm:
        fail(f"result zkVM mismatch: expected {args.zkvm}, got {actual_zkvm}")
    producer = result["producer"]
    if args.producer_run_id and producer["run_id"] != args.producer_run_id:
        fail(
            f"result producer run mismatch: expected {args.producer_run_id}, "
            f"got {producer['run_id']}"
        )
    if args.producer_sha and producer["sha"] != args.producer_sha.lower():
        fail(
            f"result producer SHA mismatch: expected {args.producer_sha.lower()}, "
            f"got {producer['sha']}"
        )
    if args.repository and producer["repository"] != args.repository:
        fail(
            f"result producer repository mismatch: expected {args.repository}, "
            f"got {producer['repository']}"
        )


def flatten_artifacts(value: Any) -> list[dict[str, Any]]:
    pages = value if isinstance(value, list) else [value]
    artifacts: list[dict[str, Any]] = []
    for page_index, page_value in enumerate(pages):
        page = require_object(page_value, f"artifact inventory page {page_index}")
        page_artifacts = page.get("artifacts")
        if not isinstance(page_artifacts, list):
            fail(f"artifact inventory page {page_index}.artifacts must be an array")
        for artifact in page_artifacts:
            artifacts.append(require_object(artifact, "artifact inventory entry"))
    return artifacts


def expected_artifacts(
    dataset_id: str,
    hive_clients: list[str],
    zkevm_runs: list[str],
) -> list[dict[str, str]]:
    expected: list[dict[str, str]] = []
    seen: set[str] = set()
    for client in hive_clients:
        client = require_safe_id(client, "Hive client ID")
        name = f"hive-results-v1-{dataset_id}-{client}"
        if name in seen:
            fail(f"duplicate expected artifact: {name}")
        seen.add(name)
        expected.append({"name": name, "kind": "hive", "client_id": client})
    for run in zkevm_runs:
        parts = run.split(":")
        if len(parts) != 2:
            fail(f"zkEVM run must have CLIENT:ZKVM form: {run}")
        client = require_safe_id(parts[0], "zkEVM client ID")
        zkvm = require_safe_id(parts[1], "zkVM ID")
        name = f"zkevm-metrics-v1-{dataset_id}-{client}-{zkvm}"
        if name in seen:
            fail(f"duplicate expected artifact: {name}")
        seen.add(name)
        expected.append(
            {"name": name, "kind": "zkevm", "client_id": client, "zkvm": zkvm}
        )
    if not expected:
        fail("at least one Hive client or zkEVM run must be selected")
    return expected


def select_artifacts(
    inventory: Any,
    *,
    dataset_id: str,
    hive_clients: list[str],
    zkevm_runs: list[str],
    branch: str,
) -> list[dict[str, Any]]:
    expected = expected_artifacts(dataset_id, hive_clients, zkevm_runs)
    artifacts = flatten_artifacts(inventory)
    selected: list[dict[str, Any]] = []
    missing: list[str] = []

    for requirement in expected:
        candidates: list[tuple[int, int, dict[str, Any]]] = []
        for artifact in artifacts:
            if (
                artifact.get("name") != requirement["name"]
                or artifact.get("expired") is not False
            ):
                continue
            workflow_run = artifact.get("workflow_run")
            if (
                not isinstance(workflow_run, dict)
                or workflow_run.get("head_branch") != branch
            ):
                continue
            artifact_id = artifact.get("id")
            run_id = workflow_run.get("id")
            head_sha = workflow_run.get("head_sha")
            if (
                not isinstance(artifact_id, int)
                or not isinstance(run_id, int)
                or not isinstance(head_sha, str)
                or not SHA_RE.fullmatch(head_sha)
            ):
                continue
            candidates.append((run_id, artifact_id, artifact))

        if not candidates:
            missing.append(requirement["name"])
            continue
        run_id, artifact_id, artifact = max(
            candidates, key=lambda item: (item[0], item[1])
        )
        selected_workflow_run = artifact["workflow_run"]
        selected.append(
            {
                **requirement,
                "artifact_id": artifact_id,
                "run_id": run_id,
                "head_sha": selected_workflow_run["head_sha"].lower(),
                "created_at": artifact.get("created_at", ""),
            }
        )

    if missing:
        fail("missing publish artifacts: " + ", ".join(missing))
    return selected


def command_resolve(args: argparse.Namespace) -> None:
    dataset_id = require_dataset_id(args.dataset_id)
    selected = select_artifacts(
        load_json(args.inventory),
        dataset_id=dataset_id,
        hive_clients=args.hive_client,
        zkevm_runs=args.zkevm_run,
        branch=args.branch,
    )
    write_json(args.output, selected)


def add_producer_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repository", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--workflow-ref", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True, type=int)
    parser.add_argument("--created-at", required=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    write_dataset = subparsers.add_parser("write-dataset")
    write_dataset.add_argument("--output", type=Path, required=True)
    write_dataset.add_argument("--dataset-id", required=True)
    write_dataset.add_argument("--fixture-archive", type=Path, required=True)
    write_dataset.add_argument("--eest-repo", required=True)
    write_dataset.add_argument("--eest-requested-ref", required=True)
    write_dataset.add_argument("--eest-release-tag", default="")
    write_dataset.add_argument("--eest-commit", required=True)
    write_dataset.add_argument("--filler-path", required=True)
    write_dataset.add_argument("--fork", required=True)
    write_dataset.add_argument("--hive-repo", required=True)
    write_dataset.add_argument("--hive-requested-ref", required=True)
    write_dataset.add_argument("--hive-commit", required=True)
    write_dataset.add_argument("--zkevm-repo", required=True)
    write_dataset.add_argument("--zkevm-requested-ref", required=True)
    write_dataset.add_argument("--zkevm-commit", required=True)
    write_dataset.add_argument("--rayon-threads", required=True, type=int)
    add_producer_arguments(write_dataset)
    write_dataset.set_defaults(handler=command_write_dataset)

    validate_dataset_parser = subparsers.add_parser("validate-dataset")
    validate_dataset_parser.add_argument("--manifest", type=Path, required=True)
    validate_dataset_parser.add_argument("--dataset-id")
    validate_dataset_parser.add_argument("--fixture-archive", type=Path)
    validate_dataset_parser.add_argument("--repository")
    validate_dataset_parser.add_argument("--allow-non-main", action="store_true")
    validate_dataset_parser.set_defaults(handler=command_validate_dataset)

    write_result = subparsers.add_parser("write-result")
    write_result.add_argument("--output", type=Path, required=True)
    write_result.add_argument("--dataset-manifest", type=Path, required=True)
    write_result.add_argument("--payload", type=Path, required=True)
    write_result.add_argument("--kind", choices=("hive", "zkevm"), required=True)
    write_result.add_argument("--client-id", required=True)
    write_result.add_argument("--zkvm")
    write_result.add_argument("--config", type=Path, required=True)
    add_producer_arguments(write_result)
    write_result.set_defaults(handler=command_write_result)

    validate_result_parser = subparsers.add_parser("validate-result")
    validate_result_parser.add_argument("--manifest", type=Path, required=True)
    validate_result_parser.add_argument("--dataset-manifest", type=Path, required=True)
    validate_result_parser.add_argument("--payload", type=Path, required=True)
    validate_result_parser.add_argument("--kind", choices=("hive", "zkevm"))
    validate_result_parser.add_argument("--client-id")
    validate_result_parser.add_argument("--zkvm")
    validate_result_parser.add_argument("--producer-run-id", type=int)
    validate_result_parser.add_argument("--producer-sha")
    validate_result_parser.add_argument("--repository")
    validate_result_parser.set_defaults(handler=command_validate_result)

    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--inventory", type=Path, required=True)
    resolve.add_argument("--output", type=Path, required=True)
    resolve.add_argument("--dataset-id", required=True)
    resolve.add_argument("--hive-client", action="append", default=[])
    resolve.add_argument("--zkevm-run", action="append", default=[])
    resolve.add_argument("--branch", default="main")
    resolve.set_defaults(handler=command_resolve)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.handler(args)
    except ArtifactError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
