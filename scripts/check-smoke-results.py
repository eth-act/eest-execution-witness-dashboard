#!/usr/bin/env python3
"""Check the Geth/Hive and Ethrex/ZisK empty-block smoke results."""

import argparse
import importlib.util
from pathlib import Path
import re
import sys


SPEC = importlib.util.spec_from_file_location(
    "prune_skipped", Path(__file__).with_name("prune-skipped-hive-results.py")
)
prune = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prune)
SMOKE_TEST = (
    "tests/amsterdam/eip8025_optional_proofs/test_witness_headers.py"
    "::test_witness_headers_empty_block"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def one(items, label):
    items = list(items)
    require(len(items) == 1, f"{label}: expected exactly one, found {len(items)}")
    return items[0]


def fixture(root, index, directory, format_name):
    entry = one((case for case in index if case["format"] == format_name), format_name)
    name, path, case = one(
        ((name, path.relative_to(root).as_posix(), case)
         for path in (root / directory).rglob("*.json")
         for name, case in prune.load_json(path).items()),
        f"{format_name} fixture",
    )
    require((name, path) == (entry["id"], entry["json_path"]),
            f"{format_name}: fixture does not match index")
    require(name.startswith(SMOKE_TEST + "["), f"unexpected fixture: {name}")
    return name, path, case


def hive_case(directory):
    path = one(prune.suite_json_files(directory), f"{directory} suite")
    suite = prune.load_json(path)
    case = one(suite["testCases"].values(), f"{directory} test case")
    summary = case["summaryResult"]
    require(not prune.is_skipped_case(result_dir=directory, suite=suite, test_case=case),
            f"{directory}: skipped case")
    require(summary.get("pass") is True and not summary.get("timeout"),
            f"{directory}: failed or timed-out case")
    client = one(suite["clientVersions"], f"{directory} client")
    return case["name"], client


def check(fixtures, hive_results, metrics, converted_results):
    index = prune.load_json(fixtures / ".meta/index.json")["test_cases"]
    engine_name, _, _ = fixture(
        fixtures, index, "blockchain_tests_engine", "blockchain_test_engine"
    )
    block_name, block_path, block_case = fixture(
        fixtures, index, "blockchain_tests", "blockchain_test"
    )
    block = one(block_case["blocks"], "empty-block fixture block")
    for field in ("statelessInputBytes", "statelessOutputBytes"):
        require(re.fullmatch(r"(?:0x)?(?:[0-9a-fA-F]{2})+", block.get(field, "")),
                f"fixture has no valid {field}")

    name, client = hive_case(hive_results)
    require(engine_name in name, f"unexpected Hive case: {name}")
    require(client == "go-ethereum" or client.startswith("go-ethereum_"),
            f"unexpected Hive client: {client}")

    path = one((path for path in metrics.glob("*/*/*.json") if path.name != "hardware.json"),
               "Ethrex/ZisK metric")
    require(path.parent.parent.name.startswith("ethrex-") and path.parent.name.startswith("zisk-"),
            f"unexpected metric client or zkVM: {path}")
    metric = prune.load_json(path)
    metadata = metric["metadata"]
    require((metadata["original_test_name"], metadata["source_path"], metadata["block_index"])
            == (block_name, block_path, 0), f"unexpected metric case: {path}")
    execution = metric.get("execution") or {}
    require("crashed" not in execution and
            (execution.get("success") or {}).get("output_matched") is True,
            f"guest execution failed or output mismatched: {path}")

    name, client = hive_case(converted_results)
    require(name == metric["name"], f"converted case does not match metric: {name}")
    require(client == f"ethrex_{path.parent.name}", f"unexpected converted client: {client}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("fixtures", "hive-results", "metrics", "converted-results"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        check(**vars(args))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        print(f"smoke failed: {exc}", file=sys.stderr)
        return 1
    print("Smoke passed: one Geth/Hive case and one Ethrex/ZisK case, including conversion.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
