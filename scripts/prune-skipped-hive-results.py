#!/usr/bin/env python3
"""Remove pytest-skipped cases from Hive suite result JSON files."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


IGNORED_TOP_LEVEL_JSON = {
    "hive.json",
    "errorReport.json",
    "containerErrorReport.json",
}
SKIPPED_DETAILS_PREFIX = "Test skipped."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Prune Hive test cases that EEST reported as pytest skips. "
            "Hive/EEST currently serializes those as pass=true with details "
            "that start with 'Test skipped.'."
        )
    )
    parser.add_argument("result_dir", type=Path)
    parser.add_argument("--summary-file", type=Path)
    return parser.parse_args()


def suite_json_files(result_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in result_dir.glob("*.json")
        if path.is_file()
        and not path.name.startswith(".")
        and path.name not in IGNORED_TOP_LEVEL_JSON
    )


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc

    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def log_slice_text(
    *,
    result_dir: Path,
    suite: dict[str, Any],
    test_case: dict[str, Any],
) -> str | None:
    summary_result = test_case.get("summaryResult")
    if not isinstance(summary_result, dict):
        return None

    inline_details = summary_result.get("details")
    if isinstance(inline_details, str):
        return inline_details

    offsets = summary_result.get("log")
    details_log = suite.get("testDetailsLog")
    if not isinstance(offsets, dict) or not isinstance(details_log, str):
        return None

    begin = offsets.get("begin")
    end = offsets.get("end")
    if not isinstance(begin, int) or not isinstance(end, int) or end < begin:
        return None

    details_path = result_dir / details_log
    if not details_path.is_file():
        return None

    with details_path.open("rb") as details_file:
        details_file.seek(begin)
        return details_file.read(end - begin).decode("utf-8", errors="replace")


def is_skipped_case(
    *,
    result_dir: Path,
    suite: dict[str, Any],
    test_case: Any,
) -> bool:
    if not isinstance(test_case, dict):
        return False

    details = log_slice_text(
        result_dir=result_dir,
        suite=suite,
        test_case=test_case,
    )
    return details is not None and details.lstrip().startswith(
        SKIPPED_DETAILS_PREFIX
    )


def write_suite(path: Path, suite: dict[str, Any]) -> None:
    path.write_text(json.dumps(suite, indent=2) + "\n", encoding="utf-8")


def prune_result_dir(result_dir: Path) -> dict[str, Any]:
    if not result_dir.is_dir():
        raise ValueError(f"result directory does not exist: {result_dir}")

    summary: dict[str, Any] = {
        "suite_files_seen": 0,
        "suite_files_rewritten": 0,
        "suite_files_removed": 0,
        "test_cases_seen": 0,
        "test_cases_pruned": 0,
        "removed_suite_files": [],
    }

    for suite_path in suite_json_files(result_dir):
        suite = load_json(suite_path)
        test_cases = suite.get("testCases")
        if not isinstance(test_cases, dict):
            raise ValueError(f"{suite_path}: expected .testCases to be an object")

        summary["suite_files_seen"] += 1
        summary["test_cases_seen"] += len(test_cases)

        pruned_cases = {
            test_id: test_case
            for test_id, test_case in test_cases.items()
            if not is_skipped_case(
                result_dir=result_dir,
                suite=suite,
                test_case=test_case,
            )
        }
        pruned_count = len(test_cases) - len(pruned_cases)
        if pruned_count == 0:
            continue

        summary["test_cases_pruned"] += pruned_count
        if pruned_cases:
            suite["testCases"] = pruned_cases
            write_suite(suite_path, suite)
            summary["suite_files_rewritten"] += 1
            continue

        suite_path.unlink()
        summary["suite_files_removed"] += 1
        summary["removed_suite_files"].append(suite_path.name)

    return summary


def main() -> int:
    args = parse_args()
    try:
        summary = prune_result_dir(args.result_dir)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.summary_file is not None:
        args.summary_file.write_text(
            json.dumps(summary, indent=2) + "\n", encoding="utf-8"
        )

    if summary["test_cases_pruned"] == 0:
        print(f"no skipped Hive test cases found in {args.result_dir}")
    else:
        print(
            "pruned "
            f"{summary['test_cases_pruned']} skipped Hive test case(s); "
            f"removed {summary['suite_files_removed']} empty suite file(s)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
