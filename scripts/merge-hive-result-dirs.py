#!/usr/bin/env python3
"""Validate and merge Hive-shaped result directories efficiently."""

from __future__ import annotations

import argparse
import filecmp
import json
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterator, NoReturn


PRUNE_SUMMARY_NAME = ".eest-prune-skipped-summary"
EXCLUDED_SUITE_JSON = {
    "hive.json",
    "errorReport.json",
    "containerErrorReport.json",
}


class MergeError(ValueError):
    """Raised when result directories cannot be merged safely."""


@dataclass(frozen=True)
class SourceSpec:
    directory: Path
    label: str
    expected_client: str | None = None
    require_prune_summary_when_empty: bool = False


@dataclass(frozen=True)
class InventoryEntry:
    source: Path
    label: str


def fail(message: str) -> NoReturn:
    raise MergeError(message)


def log(message: str) -> None:
    print(f"==> {message}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and merge Hive-shaped result directories.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(os.environ["HIVE_RESULTS_DIR"])
        if os.environ.get("HIVE_RESULTS_DIR")
        else None,
        help="Output directory. Defaults to HIVE_RESULTS_DIR.",
    )
    parser.add_argument(
        "--clean-output",
        action="store_true",
        help="Delete and recreate the output directory before merging.",
    )
    parser.add_argument(
        "--allow-multi-client",
        action="store_true",
        help="Do not enforce one client per top-level result JSON in ordinary sources.",
    )
    parser.add_argument(
        "--client-source",
        action="append",
        nargs=3,
        metavar=("CLIENT_ID", "CLIENT_NAME", "DIR"),
        default=[],
        help="Add an expected per-client source. May be repeated.",
    )
    parser.add_argument(
        "sources",
        metavar="SOURCE_DIR",
        type=Path,
        nargs="*",
        help="Additional directories already containing Hive-shaped results.",
    )
    args = parser.parse_args(argv)
    if args.output is None:
        parser.error("--output is required when HIVE_RESULTS_DIR is not set")
    if not args.client_source and not args.sources:
        parser.error("at least one source directory is required")
    return args


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{label} does not exist: {path}")
    except OSError as exc:
        fail(f"unable to read {label} {path}: {exc}")
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON in {label} {path}: {exc}")


def suite_json_files(source: Path) -> list[Path]:
    result: list[Path] = []
    try:
        entries = sorted(source.iterdir(), key=lambda path: path.name)
    except OSError as exc:
        fail(f"unable to list source directory {source}: {exc}")

    for path in entries:
        if path.is_symlink():
            fail(f"source may not contain symbolic links: {path}")
        if (
            path.is_file()
            and path.suffix == ".json"
            and not path.name.startswith(".")
            and path.name not in EXCLUDED_SUITE_JSON
        ):
            result.append(path)
    return result


def clients_from_suite(value: dict[str, Any]) -> list[Any] | None:
    clients = value.get("clients")
    if clients is not None:
        return clients if isinstance(clients, list) else None
    versions = value.get("clientVersions")
    if versions is None:
        return []
    if not isinstance(versions, dict):
        return None
    return list(versions)


def validate_suite_structure(path: Path, value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"Hive result JSON must contain an object: {path}")
    name = value.get("name")
    if not isinstance(name, str) or not name:
        fail(f"Hive result JSON has no non-empty name: {path}")
    if not isinstance(value.get("testCases"), dict):
        fail(f"Hive result JSON has no testCases object: {path}")
    return value


def is_positive_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0


def has_valid_prune_summary(source: Path) -> bool:
    summary_path = source / PRUNE_SUMMARY_NAME
    if not summary_path.is_file() or summary_path.is_symlink():
        return False
    summary = load_json(summary_path, "prune summary")
    return isinstance(summary, dict) and all(
        is_positive_number(summary.get(field))
        for field in ("suite_files_seen", "suite_files_removed", "test_cases_pruned")
    )


def validate_source(spec: SourceSpec, *, require_single_client: bool) -> bool:
    source = spec.directory
    if source.is_symlink():
        fail(f"source directory may not be a symbolic link: {source}")
    if not source.is_dir():
        fail(f"source directory does not exist: {source}")

    suites = suite_json_files(source)
    if not suites:
        if spec.require_prune_summary_when_empty:
            if has_valid_prune_summary(source):
                log(f"Skipping {spec.label} because only skipped Hive cases were produced")
                return False
            fail(f"{spec.label} did not produce any top-level Hive result JSON in {source}")
        log(f"Skipping source with no top-level Hive suite JSON: {source}")
        return False

    for path in suites:
        suite = validate_suite_structure(path, load_json(path, "Hive result JSON"))
        clients = clients_from_suite(suite)
        if spec.expected_client is not None:
            if clients != [spec.expected_client]:
                fail(
                    f"result JSON is not a single-client {spec.expected_client} run: {path}"
                )
        elif require_single_client and (clients is None or len(clients) != 1):
            fail(f"source contains an invalid or multi-client result JSON: {path}")
    return True


def iter_source_files(root: Path) -> Iterator[tuple[PurePosixPath, Path]]:
    stack: list[tuple[Path, PurePosixPath]] = [(root, PurePosixPath())]
    while stack:
        directory, relative_dir = stack.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name, reverse=True)
        except OSError as exc:
            fail(f"unable to list source directory {directory}: {exc}")

        for entry in entries:
            path = Path(entry.path)
            relative = relative_dir / entry.name
            if entry.is_symlink():
                fail(f"source may not contain symbolic links: {path}")
            if entry.is_dir(follow_symlinks=False):
                stack.append((path, relative))
                continue
            if not entry.is_file(follow_symlinks=False):
                fail(f"source may contain only regular files and directories: {path}")
            if relative.as_posix() == PRUNE_SUMMARY_NAME:
                continue
            yield relative, path


def files_equal(left: Path, right: Path) -> bool:
    try:
        return filecmp.cmp(left, right, shallow=False)
    except OSError as exc:
        fail(f"unable to compare duplicate result files {left} and {right}: {exc}")


def add_to_inventory(
    inventory: dict[str, InventoryEntry],
    directory_paths: set[str],
    relative: PurePosixPath,
    source: Path,
    label: str,
) -> None:
    key = relative.as_posix()
    if key in directory_paths:
        fail(f"result path is both a file and directory: {key}")

    parents = [parent.as_posix() for parent in relative.parents if parent.as_posix() != "."]
    for parent in parents:
        if parent in inventory:
            fail(f"result path is both a file and directory: {parent}")

    existing = inventory.get(key)
    if existing is not None:
        if files_equal(existing.source, source):
            return
        fail(
            f"refusing to overwrite conflicting result path {key} "
            f"from {existing.label} with {label}"
        )

    inventory[key] = InventoryEntry(source=source, label=label)
    directory_paths.update(parents)


def root_directory() -> Path:
    configured = os.environ.get("ROOT_DIR")
    if configured:
        return Path(configured).expanduser().resolve(strict=False)
    return Path(__file__).resolve().parents[1]


def rooted_path(path: Path) -> Path:
    expanded = path.expanduser()
    return expanded if expanded.is_absolute() else root_directory() / expanded


def resolved_path(path: Path) -> Path:
    try:
        return rooted_path(path).resolve(strict=False)
    except OSError as exc:
        fail(f"unable to resolve path {path}: {exc}")


def resolved_source_path(path: Path) -> Path:
    rooted = rooted_path(path)
    if rooted.is_symlink():
        fail(f"source directory may not be a symbolic link: {rooted}")
    return resolved_path(rooted)


def path_contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
        return child != parent
    except ValueError:
        return False


def validate_source_output_separation(output: Path, sources: list[SourceSpec]) -> None:
    for spec in sources:
        source = spec.directory
        if source == output:
            fail(f"source and output must differ: {source}")
        if path_contains(source, output):
            fail(f"output must not be inside source: {output}")
        if path_contains(output, source):
            fail(f"source must not be inside output: {source}")


def environment_path(name: str) -> Path | None:
    value = os.environ.get(name)
    return resolved_path(Path(value)) if value else None


def validate_clean_output(output: Path) -> None:
    root = root_directory()
    tmp = Path("/tmp")
    protected = {Path("/"), tmp, root}
    for name in (
        "HIVE_DIR",
        "HIVE_UI_DIR",
        "EEST_DIR",
        "FIXTURES_DIR",
        "SITE_DIR",
        "HIVE_CLIENT_RESULTS_DIR",
    ):
        value = environment_path(name)
        if value is not None:
            protected.add(value)

    if output in protected:
        fail(f"refusing to clean unsafe output directory: {output}")
    if not path_contains(root, output) and not path_contains(tmp, output):
        fail(f"refusing to clean output directory outside ROOT_DIR or /tmp: {output}")


def prepare_output(output: Path, *, clean: bool) -> None:
    if output.is_symlink():
        fail(f"output directory may not be a symbolic link: {output}")
    validate_clean_output(output)
    if clean:
        log(f"Resetting merged Hive result directory at {output}")
        if output.is_dir():
            shutil.rmtree(output)
        elif output.exists():
            output.unlink()
        output.mkdir(parents=True)
        return

    if output.exists() and not output.is_dir():
        fail(f"output path exists but is not a directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    try:
        next(output.iterdir())
    except StopIteration:
        return
    except OSError as exc:
        fail(f"unable to inspect output directory {output}: {exc}")
    fail(f"output directory is not empty; pass --clean-output to recreate it: {output}")


def copy_inventory(output: Path, inventory: dict[str, InventoryEntry]) -> None:
    parent_dirs = {
        parent.as_posix()
        for key in inventory
        for parent in PurePosixPath(key).parents
        if parent.as_posix() != "."
    }
    for relative in sorted(parent_dirs, key=lambda item: (item.count("/"), item)):
        (output / relative).mkdir(exist_ok=True)

    for relative in sorted(inventory):
        entry = inventory[relative]
        target = output / relative
        try:
            shutil.copy2(entry.source, target, follow_symlinks=False)
        except OSError as exc:
            fail(f"unable to copy {entry.source} to {target}: {exc}")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    output_arg = rooted_path(args.output)
    if output_arg.is_symlink():
        fail(f"output directory may not be a symbolic link: {output_arg}")
    output = resolved_path(output_arg)

    sources: list[SourceSpec] = []
    for client_id, client_name, directory_text in args.client_source:
        sources.append(
            SourceSpec(
                directory=resolved_source_path(Path(directory_text)),
                label=f"client {client_id} ({client_name})",
                expected_client=client_name,
                require_prune_summary_when_empty=True,
            )
        )
    for directory in args.sources:
        resolved = resolved_source_path(directory)
        sources.append(SourceSpec(directory=resolved, label=str(resolved)))

    validate_source_output_separation(output, sources)
    active_sources = [
        spec
        for spec in sources
        if validate_source(spec, require_single_client=not args.allow_multi_client)
    ]

    inventory: dict[str, InventoryEntry] = {}
    directory_paths: set[str] = set()
    for spec in active_sources:
        if spec.expected_client is not None:
            log(f"Merging results for {spec.expected_client} from {spec.directory}")
        else:
            log(f"Merging Hive results from {spec.directory}")
        for relative, source in iter_source_files(spec.directory):
            add_to_inventory(inventory, directory_paths, relative, source, spec.label)

    prepare_output(output, clean=args.clean_output)
    copy_inventory(output, inventory)
    log(
        f"Merged {len(active_sources)} Hive result directories "
        f"({len(inventory)} files) into {output}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MergeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
