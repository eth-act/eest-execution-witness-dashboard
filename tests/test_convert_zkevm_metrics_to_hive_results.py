import importlib.util
import json
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "convert-zkevm-metrics-to-hive-results.py"
)


def load_converter_module():
    spec = importlib.util.spec_from_file_location("convert_zkevm_metrics", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


converter = load_converter_module()


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


class ConvertZkEvmMetricsTests(unittest.TestCase):
    def test_converts_success_and_crash_as_plain_failure_and_skips_hardware(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / "zkevm metrics"
            output_dir = root / "converted results"
            suite_dir = metrics_dir / "ethrex-81484be" / "zisk-v0.16.1"

            write_json(
                metrics_dir / "hardware.json",
                {
                    "cpu_model": "Test CPU",
                    "total_ram_gib": 64,
                    "gpus": [{"model": "Test GPU"}],
                },
            )
            write_json(
                suite_dir / "test success with spaces.json",
                {
                    "name": "test_file.py::test_success[fork_Osaka-benchmark-gas-value_10M]",
                    "timestamp_completed": "2026-05-14T06:17:00.138864796Z",
                    "metadata": {"block_used_gas": 10_000_000},
                    "execution": {
                        "success": {
                            "output_matched": True,
                            "total_num_cycles": 570_661_285,
                            "region_cycles": {},
                            "execution_duration": {"secs": 9, "nanos": 555_227_399},
                        }
                    },
                },
            )
            write_json(
                suite_dir / "test timeout.json",
                {
                    "name": "test_file.py::test_timeout[fork_Osaka-benchmark-gas-value_60M]",
                    "timestamp_completed": "2026-05-14T06:18:00.000000001Z",
                    "metadata": {"block_used_gas": 60_000_000},
                    "execution": {
                        "crashed": {
                            "reason": "Operation timed out after 300s",
                        }
                    },
                },
            )

            written = converter.convert(
                metrics_dir,
                output_dir,
                converter.DEFAULT_SUITE_NAME,
                clean_output=True,
            )

            self.assertEqual(len(written), 1)
            result_path = output_dir / written[0]
            result = json.loads(result_path.read_text(encoding="utf-8"))

            self.assertEqual(result["name"], "zkevm-benchmark-workload/stateless-validator")
            self.assertEqual(
                result["clientVersions"],
                {"ethrex_zisk-v0.16.1": "ethrex-81484be / zisk-v0.16.1"},
            )
            self.assertIn("Test CPU", result["description"])
            self.assertEqual(len(result["testCases"]), 2)

            success_case = result["testCases"]["1"]
            self.assertTrue(success_case["summaryResult"]["pass"])
            self.assertEqual(success_case["start"], "2026-05-14T06:16:50.583637397Z")
            self.assertEqual(success_case["end"], "2026-05-14T06:17:00.138864796Z")
            self.assertNotIn("timeout", success_case["summaryResult"])
            self.assertEqual(
                next(iter(success_case["clientInfo"].values()))["name"],
                "ethrex_zisk-v0.16.1",
            )

            crash_case = result["testCases"]["2"]
            self.assertFalse(crash_case["summaryResult"]["pass"])
            self.assertNotIn("timeout", crash_case["summaryResult"])
            self.assertEqual(crash_case["start"], "2026-05-14T06:18:00.000000001Z")
            self.assertEqual(crash_case["end"], "2026-05-14T06:18:00.000000001Z")

            details_log = output_dir / result["testDetailsLog"]
            details_bytes = details_log.read_bytes()
            offsets = success_case["summaryResult"]["log"]
            excerpt = details_bytes[offsets["begin"] : offsets["end"]].decode("utf-8")
            self.assertIn(
                "source_path: ethrex-81484be/zisk-v0.16.1/test success with spaces.json",
                excerpt,
            )
            self.assertIn("total_num_cycles: 570661285", excerpt)
            self.assertIn("output_matched: true", excerpt)
            self.assertIn('"block_used_gas": 10000000', excerpt)

            preamble = details_bytes[: offsets["begin"]].decode("utf-8")
            self.assertIn("Test GPU", preamble)

    def test_converts_output_mismatch_as_failed_success(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / "metrics"
            output_dir = root / "out"
            suite_dir = metrics_dir / "ethrex-81484be" / "zisk-v0.16.1"

            write_json(
                suite_dir / "test mismatch.json",
                {
                    "name": "test_file.py::test_mismatch[fork_Osaka]",
                    "timestamp_completed": "2026-05-14T06:17:00Z",
                    "metadata": {"block_used_gas": 123},
                    "execution": {
                        "success": {
                            "output_matched": False,
                            "total_num_cycles": 99,
                            "region_cycles": {"execute": 99},
                            "execution_duration": {"secs": 2, "nanos": 0},
                        }
                    },
                },
            )

            written = converter.convert(
                metrics_dir,
                output_dir,
                converter.DEFAULT_SUITE_NAME,
                clean_output=True,
            )
            result = json.loads((output_dir / written[0]).read_text(encoding="utf-8"))
            test_case = result["testCases"]["1"]

            self.assertFalse(test_case["summaryResult"]["pass"])
            self.assertIn("Status: output mismatch", test_case["description"])
            self.assertIn("Output matched: false", test_case["description"])
            self.assertIn(
                "Failure reason: public output did not match expected values",
                test_case["description"],
            )

            details = (output_dir / result["testDetailsLog"]).read_text(encoding="utf-8")
            self.assertIn("status: output mismatch", details)
            self.assertIn("output_matched: false", details)
            self.assertIn("total_num_cycles: 99", details)
            self.assertIn(
                "failure_reason: public output did not match expected values",
                details,
            )

    def test_converts_non_timeout_crash_without_timeout_flag(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / "metrics"
            output_dir = root / "out"
            suite_dir = metrics_dir / "reth-v2.1.0" / "zisk-v0.16.1"

            write_json(
                suite_dir / "test crash.json",
                {
                    "name": "test_file.py::test_crash[fork_Osaka]",
                    "timestamp_completed": "2026-05-14T06:20:00Z",
                    "metadata": {"block_used_gas": 1},
                    "execution": {
                        "crashed": {
                            "reason": "zkVM method error: Emulator panicked",
                        }
                    },
                },
            )

            written = converter.convert(
                metrics_dir,
                output_dir,
                converter.DEFAULT_SUITE_NAME,
                clean_output=True,
            )
            result = json.loads((output_dir / written[0]).read_text(encoding="utf-8"))
            test_case = result["testCases"]["1"]

            self.assertEqual(
                result["clientVersions"],
                {"reth_zisk-v0.16.1": "reth-v2.1.0 / zisk-v0.16.1"},
            )
            self.assertFalse(test_case["summaryResult"]["pass"])
            self.assertNotIn("timeout", test_case["summaryResult"])

            details = (output_dir / result["testDetailsLog"]).read_text(encoding="utf-8")
            self.assertIn("crash_reason: zkVM method error: Emulator panicked", details)

    def test_refuses_non_empty_output_without_clean_output(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / "metrics"
            output_dir = root / "out"
            output_dir.mkdir()
            (output_dir / "existing.txt").write_text("keep", encoding="utf-8")
            write_json(
                metrics_dir / "ethrex-1" / "zisk-v1" / "test.json",
                {
                    "name": "test.py::test_case",
                    "timestamp_completed": "2026-05-14T06:17:00Z",
                    "metadata": {"block_used_gas": 1},
                    "execution": {
                        "success": {
                            "output_matched": True,
                            "total_num_cycles": 1,
                            "region_cycles": {},
                            "execution_duration": {"secs": 1, "nanos": 0},
                        }
                    },
                },
            )

            with self.assertRaises(converter.ConversionError):
                converter.convert(
                    metrics_dir,
                    output_dir,
                    converter.DEFAULT_SUITE_NAME,
                    clean_output=False,
                )

    def test_refuses_success_without_output_matched(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / "metrics"
            output_dir = root / "out"
            suite_dir = metrics_dir / "ethrex-1" / "zisk-v1"

            write_json(
                suite_dir / "test.json",
                {
                    "name": "test.py::test_case",
                    "timestamp_completed": "2026-05-14T06:17:00Z",
                    "metadata": {"block_used_gas": 1},
                    "execution": {
                        "success": {
                            "total_num_cycles": 1,
                            "region_cycles": {},
                            "execution_duration": {"secs": 1, "nanos": 0},
                        }
                    },
                },
            )

            with self.assertRaisesRegex(
                converter.ConversionError,
                "execution.success.output_matched must be a boolean",
            ):
                converter.convert(
                    metrics_dir,
                    output_dir,
                    converter.DEFAULT_SUITE_NAME,
                    clean_output=True,
                )

    def test_refuses_non_boolean_output_matched(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / "metrics"
            output_dir = root / "out"
            suite_dir = metrics_dir / "ethrex-1" / "zisk-v1"

            write_json(
                suite_dir / "test.json",
                {
                    "name": "test.py::test_case",
                    "timestamp_completed": "2026-05-14T06:17:00Z",
                    "metadata": {"block_used_gas": 1},
                    "execution": {
                        "success": {
                            "output_matched": "false",
                            "total_num_cycles": 1,
                            "region_cycles": {},
                            "execution_duration": {"secs": 1, "nanos": 0},
                        }
                    },
                },
            )

            with self.assertRaisesRegex(
                converter.ConversionError,
                "execution.success.output_matched must be a boolean",
            ):
                converter.convert(
                    metrics_dir,
                    output_dir,
                    converter.DEFAULT_SUITE_NAME,
                    clean_output=True,
                )


if __name__ == "__main__":
    unittest.main()
