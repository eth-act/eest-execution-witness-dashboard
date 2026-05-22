#!/usr/bin/env python3
"""Convert zkevm-benchmark-workload metrics into HiveUI result files."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_SUITE_NAME = "zkevm-benchmark-workload/stateless-validator"
NANOS_PER_SECOND = 1_000_000_000
KNOWN_EL_PREFIXES = (
    "go-ethereum",
    "nimbus-el",
    "nethermind",
    "ethereumjs",
    "ethrex",
    "erigon",
    "besu",
    "geth",
    "reth",
)


class ConversionError(Exception):
    """Raised when metrics cannot be converted safely."""


@dataclass(frozen=True)
class MetricsSuite:
    el_version: str
    zkvm_version: str
    directory: Path
    files: tuple[Path, ...]


@dataclass(frozen=True)
class LogOffsets:
    begin: int
    end: int


@dataclass(frozen=True)
class ParsedExecutionResult:
    passed: bool
    success: dict[str, Any] | None
    status: str
    failure_reason: str | None


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert zkevm-benchmark-workload metrics into HiveUI results."
    )
    parser.add_argument(
        "--input",
        required=True,
        type=Path,
        help="Path to the zkevm-metrics directory.",
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Output directory for Hive-compatible result files.",
    )
    parser.add_argument(
        "--clean-output",
        action="store_true",
        help="Delete and recreate the output directory before writing.",
    )
    parser.add_argument(
        "--suite-name",
        default=DEFAULT_SUITE_NAME,
        help=f"Hive suite name to write into result files. Default: {DEFAULT_SUITE_NAME}",
    )
    return parser.parse_args(argv)


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as file:
            data = json.load(file)
    except OSError as exc:
        raise ConversionError(f"unable to read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConversionError(f"invalid JSON in {path}: {exc}") from exc

    if not isinstance(data, dict):
        raise ConversionError(f"expected JSON object in {path}")
    return data


def load_hardware_info(input_dir: Path) -> dict[str, Any] | None:
    hardware_path = input_dir / "hardware.json"
    if not hardware_path.exists():
        return None
    return load_json(hardware_path)


def discover_suites(input_dir: Path) -> list[MetricsSuite]:
    suites: list[MetricsSuite] = []
    for el_dir in sorted(input_dir.iterdir(), key=lambda path: path.name):
        if not el_dir.is_dir():
            continue
        for zkvm_dir in sorted(el_dir.iterdir(), key=lambda path: path.name):
            if not zkvm_dir.is_dir():
                continue
            files = tuple(
                path
                for path in sorted(zkvm_dir.glob("*.json"), key=lambda item: item.name)
                if path.name != "hardware.json"
            )
            if files:
                suites.append(
                    MetricsSuite(
                        el_version=el_dir.name,
                        zkvm_version=zkvm_dir.name,
                        directory=zkvm_dir,
                        files=files,
                    )
                )
    return suites


def logical_el_name(el_version: str) -> str:
    for prefix in sorted(KNOWN_EL_PREFIXES, key=len, reverse=True):
        if el_version == prefix or el_version.startswith(f"{prefix}-"):
            return prefix
    return el_version.split("-", 1)[0]


def sanitize_component(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-")
    return cleaned or "unknown"


def logical_client_name(el_version: str, zkvm_version: str) -> str:
    el_name = sanitize_component(logical_el_name(el_version))
    zkvm_name = sanitize_component(zkvm_version)
    return f"{el_name}_{zkvm_name}"


def stable_hex(value: str, length: int = 16) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:length]


def parse_rfc3339_nanos(value: str) -> int:
    match = re.fullmatch(
        r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)",
        value,
    )
    if not match:
        raise ConversionError(f"timestamp is not RFC3339: {value}")

    base_text, fractional_text, timezone_text = match.groups()
    timezone_suffix = "+00:00" if timezone_text == "Z" else timezone_text
    base = datetime.fromisoformat(f"{base_text}{timezone_suffix}")
    base = base.astimezone(timezone.utc)

    delta = base - datetime(1970, 1, 1, tzinfo=timezone.utc)
    seconds = delta.days * 86_400 + delta.seconds
    nanos = int(((fractional_text or "") + "0" * 9)[:9])
    return seconds * NANOS_PER_SECOND + nanos


def format_rfc3339_nanos(epoch_nanos: int) -> str:
    seconds, nanos = divmod(epoch_nanos, NANOS_PER_SECOND)
    timestamp = datetime.fromtimestamp(seconds, tz=timezone.utc)
    if nanos == 0:
        return timestamp.strftime("%Y-%m-%dT%H:%M:%SZ")
    fractional = f"{nanos:09d}".rstrip("0")
    return f"{timestamp.strftime('%Y-%m-%dT%H:%M:%S')}.{fractional}Z"


def duration_to_nanos(duration: Any) -> int | None:
    if not isinstance(duration, dict):
        return None
    secs = duration.get("secs")
    nanos = duration.get("nanos")
    if not isinstance(secs, int) or not isinstance(nanos, int):
        return None
    if secs < 0 or nanos < 0:
        return None
    return secs * NANOS_PER_SECOND + nanos


def format_duration(duration_nanos: int | None) -> str:
    if duration_nanos is None:
        return "unknown"
    seconds, nanos = divmod(duration_nanos, NANOS_PER_SECOND)
    if nanos == 0:
        return f"{seconds}s"
    return f"{seconds}.{nanos:09d}s"


def format_json_bool(value: bool) -> str:
    return json.dumps(value)


def execution_result(metrics: dict[str, Any]) -> ParsedExecutionResult:
    execution = metrics.get("execution")
    if not isinstance(execution, dict):
        return ParsedExecutionResult(False, None, "failed", "missing execution metrics")
    success = execution.get("success")
    if isinstance(success, dict):
        output_matched = success.get("output_matched")
        if not isinstance(output_matched, bool):
            raise ConversionError("execution.success.output_matched must be a boolean")
        if output_matched:
            return ParsedExecutionResult(True, success, "success", None)
        return ParsedExecutionResult(
            False,
            success,
            "output mismatch",
            "public output did not match expected values",
        )
    crashed = execution.get("crashed")
    if isinstance(crashed, dict):
        reason = crashed.get("reason")
        return ParsedExecutionResult(
            False,
            None,
            "crashed",
            reason if isinstance(reason, str) else "execution crashed",
        )
    return ParsedExecutionResult(False, None, "failed", "unsupported execution result")


def block_used_gas(metrics: dict[str, Any]) -> Any:
    metadata = metrics.get("metadata")
    if isinstance(metadata, dict):
        return metadata.get("block_used_gas")
    return None


def metric_end_nanos(metrics: dict[str, Any], source: Path) -> int:
    timestamp = metrics.get("timestamp_completed")
    if not isinstance(timestamp, str):
        raise ConversionError(f"missing string timestamp_completed in {source}")
    return parse_rfc3339_nanos(timestamp)


def metric_name(metrics: dict[str, Any], source: Path) -> str:
    name = metrics.get("name")
    if isinstance(name, str) and name:
        return name
    return source.stem


def test_description(
    *,
    metrics: dict[str, Any],
    source: Path,
    input_dir: Path,
    suite: MetricsSuite,
    client_name: str,
    execution_status: str,
    success: dict[str, Any] | None,
    failure_reason: str | None,
    duration_nanos_value: int | None,
) -> str:
    lines = [
        "Synthetic HiveUI result generated from zkevm-benchmark-workload metrics.",
        f"Source: {source.relative_to(input_dir)}",
        f"Execution client: {suite.el_version}",
        f"zkVM: {suite.zkvm_version}",
        f"Logical HiveUI client: {client_name}",
        f"Status: {execution_status}",
        f"Block used gas: {block_used_gas(metrics)}",
        f"Execution duration: {format_duration(duration_nanos_value)}",
    ]
    if success is not None:
        lines.append(f"Output matched: {format_json_bool(success['output_matched'])}")
        lines.append(f"Total cycles: {success.get('total_num_cycles')}")
    if failure_reason:
        label = "Crash reason" if execution_status == "crashed" else "Failure reason"
        lines.append(f"{label}: {failure_reason}")
    return "\n".join(lines)


def test_log_body(
    *,
    metrics: dict[str, Any],
    source: Path,
    input_dir: Path,
    suite: MetricsSuite,
    client_name: str,
    execution_status: str,
    success: dict[str, Any] | None,
    failure_reason: str | None,
    duration_nanos_value: int | None,
) -> str:
    lines = [
        f"source_path: {source.relative_to(input_dir)}",
        f"execution_client: {suite.el_version}",
        f"zkvm: {suite.zkvm_version}",
        f"logical_client: {client_name}",
        f"block_used_gas: {block_used_gas(metrics)}",
        f"status: {execution_status}",
        f"execution_duration: {format_duration(duration_nanos_value)}",
    ]
    if success is not None:
        lines.extend(
            [
                f"output_matched: {format_json_bool(success['output_matched'])}",
                f"total_num_cycles: {success.get('total_num_cycles')}",
                "region_cycles:",
                json.dumps(success.get("region_cycles", {}), indent=2, sort_keys=True),
            ]
        )
    if failure_reason:
        label = "crash_reason" if execution_status == "crashed" else "failure_reason"
        lines.append(f"{label}: {failure_reason}")
    lines.extend(
        [
            "raw_metrics:",
            json.dumps(metrics, indent=2, sort_keys=True),
        ]
    )
    return "\n".join(lines)


def write_log_entry(log_file: Any, offset: int, test_name: str, body: str) -> tuple[LogOffsets, int]:
    header = f"-- {test_name}\n".encode("utf-8")
    body_bytes = body.encode("utf-8")
    footer = b"\n\n"

    log_file.write(header)
    log_file.write(body_bytes)
    log_file.write(footer)

    begin = offset + len(header)
    end = begin + len(body_bytes)
    return LogOffsets(begin=begin, end=end), offset + len(header) + len(body_bytes) + len(footer)


def suite_description(
    input_dir: Path,
    suite: MetricsSuite,
    client_name: str,
    hardware_info: dict[str, Any] | None,
) -> str:
    lines = [
        "Synthetic HiveUI suite generated from zkevm-benchmark-workload metrics.",
        f"Input root: {input_dir}",
        f"Metrics directory: {suite.directory.relative_to(input_dir)}",
        f"Execution client: {suite.el_version}",
        f"zkVM: {suite.zkvm_version}",
        f"Logical HiveUI client: {client_name}",
    ]
    if hardware_info is not None:
        lines.extend(
            [
                "Hardware:",
                json.dumps(hardware_info, indent=2, sort_keys=True),
            ]
        )
    return "\n".join(lines)


def write_suite(
    *,
    input_dir: Path,
    output_dir: Path,
    suite_name: str,
    suite: MetricsSuite,
    hardware_info: dict[str, Any] | None,
) -> str:
    client_name = logical_client_name(suite.el_version, suite.zkvm_version)
    client_id = stable_hex(client_name, 8)
    suite_hash = stable_hex(f"{suite_name}|{suite.el_version}|{suite.zkvm_version}")

    loaded_metrics = [(path, load_json(path)) for path in suite.files]
    end_times = [metric_end_nanos(metrics, path) for path, metrics in loaded_metrics]
    latest_end = max(end_times)
    file_stem = f"{latest_end // NANOS_PER_SECOND}-{suite_hash}"
    result_file = output_dir / f"{file_stem}.json"
    details_log = Path("details") / f"{file_stem}.log"
    details_path = output_dir / details_log
    details_path.parent.mkdir(parents=True, exist_ok=True)

    test_cases: dict[str, Any] = {}
    offset = 0
    with details_path.open("wb") as log_file:
        preamble = "\n".join(
            [
                "Converted zkevm-benchmark-workload metrics",
                f"suite_name: {suite_name}",
                f"input_root: {input_dir}",
                f"metrics_directory: {suite.directory.relative_to(input_dir)}",
                f"execution_client: {suite.el_version}",
                f"zkvm: {suite.zkvm_version}",
                f"logical_client: {client_name}",
                "hardware:",
                json.dumps(hardware_info, indent=2, sort_keys=True)
                if hardware_info is not None
                else "null",
                "",
                "",
            ]
        ).encode("utf-8")
        log_file.write(preamble)
        offset += len(preamble)

        for index, (source, metrics) in enumerate(loaded_metrics, start=1):
            execution = execution_result(metrics)
            duration_nanos_value = (
                duration_to_nanos(execution.success.get("execution_duration"))
                if execution.success is not None
                else None
            )
            end_nanos = metric_end_nanos(metrics, source)
            start_nanos = (
                end_nanos - duration_nanos_value if duration_nanos_value else end_nanos
            )
            start = format_rfc3339_nanos(start_nanos)
            end = format_rfc3339_nanos(end_nanos)
            name = metric_name(metrics, source)

            body = test_log_body(
                metrics=metrics,
                source=source,
                input_dir=input_dir,
                suite=suite,
                client_name=client_name,
                execution_status=execution.status,
                success=execution.success,
                failure_reason=execution.failure_reason,
                duration_nanos_value=duration_nanos_value,
            )
            log_offsets, offset = write_log_entry(log_file, offset, name, body)

            summary_result: dict[str, Any] = {
                "pass": execution.passed,
                "log": {"begin": log_offsets.begin, "end": log_offsets.end},
            }

            test_cases[str(index)] = {
                "name": name,
                "description": test_description(
                    metrics=metrics,
                    source=source,
                    input_dir=input_dir,
                    suite=suite,
                    client_name=client_name,
                    execution_status=execution.status,
                    success=execution.success,
                    failure_reason=execution.failure_reason,
                    duration_nanos_value=duration_nanos_value,
                ),
                "start": start,
                "end": end,
                "summaryResult": summary_result,
                "clientInfo": {
                    client_id: {
                        "id": client_id,
                        "ip": "",
                        "name": client_name,
                        "instantiatedAt": start,
                        "logFile": details_log.as_posix(),
                        "logOffsets": {
                            "begin": log_offsets.begin,
                            "end": log_offsets.end,
                        },
                    }
                },
            }

    result = {
        "id": 0,
        "name": suite_name,
        "description": suite_description(input_dir, suite, client_name, hardware_info),
        "clientVersions": {
            client_name: f"{suite.el_version} / {suite.zkvm_version}",
        },
        "simLog": "",
        "testDetailsLog": details_log.as_posix(),
        "testCases": test_cases,
    }
    with result_file.open("w", encoding="utf-8") as file:
        json.dump(result, file, indent=2, sort_keys=True)
        file.write("\n")
    return result_file.name


def prepare_output_dir(input_dir: Path, output_dir: Path, clean_output: bool) -> None:
    if output_dir.parent == output_dir:
        raise ConversionError(f"refusing to use unsafe output directory: {output_dir}")
    if output_dir == input_dir:
        raise ConversionError("output directory must differ from input directory")
    if input_dir.is_relative_to(output_dir):
        raise ConversionError("output directory must not contain the input directory")
    if output_dir.is_relative_to(input_dir):
        raise ConversionError("output directory must not be inside the input directory")

    if clean_output and output_dir.exists():
        if not output_dir.is_dir():
            raise ConversionError(f"output path exists but is not a directory: {output_dir}")
        shutil.rmtree(output_dir)

    if output_dir.exists():
        if not output_dir.is_dir():
            raise ConversionError(f"output path exists but is not a directory: {output_dir}")
        if any(output_dir.iterdir()):
            raise ConversionError(
                f"output directory is not empty; pass --clean-output to recreate it: {output_dir}"
            )
    output_dir.mkdir(parents=True, exist_ok=True)


def convert(input_dir: Path, output_dir: Path, suite_name: str, clean_output: bool) -> list[str]:
    input_dir = input_dir.resolve()
    output_dir = output_dir.resolve()

    if not input_dir.is_dir():
        raise ConversionError(f"input directory does not exist: {input_dir}")

    prepare_output_dir(input_dir, output_dir, clean_output)
    hardware_info = load_hardware_info(input_dir)
    suites = discover_suites(input_dir)
    if not suites:
        raise ConversionError(f"no metrics suites found in {input_dir}")

    result_files = [
        write_suite(
            input_dir=input_dir,
            output_dir=output_dir,
            suite_name=suite_name,
            suite=suite,
            hardware_info=hardware_info,
        )
        for suite in suites
    ]
    return result_files


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        result_files = convert(args.input, args.output, args.suite_name, args.clean_output)
    except ConversionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"Converted {len(result_files)} Hive result file(s) into {args.output}")
    for result_file in result_files:
        print(f"  {result_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
