import importlib.util
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/check-smoke-results.py"
SPEC = importlib.util.spec_from_file_location("check_smoke_results", SCRIPT)
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


def read_json(path):
    return json.loads(path.read_text())


class CheckSmokeResultsTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.paths = {name: self.root / name for name in
                      ("fixtures", "hive_results", "metrics", "converted_results")}
        index = []
        for directory, format_name in (
            ("blockchain_tests", "blockchain_test"),
            ("blockchain_tests_engine", "blockchain_test_engine"),
        ):
            name = ("tests/amsterdam/eip8025_optional_proofs/test_witness_headers.py"
                    f"::test_witness_headers_empty_block[fork_Amsterdam-{format_name}]")
            entry = {"id": name, "format": format_name, "json_path": f"{directory}/empty.json"}
            index.append(entry)
            write_json(self.paths["fixtures"] / entry["json_path"], {
                name: {"blocks": [{"statelessInputBytes": "0x0102", "statelessOutputBytes": "0x0304"}]}
            })
        self.index_path = self.paths["fixtures"] / ".meta/index.json"
        write_json(self.index_path, {"test_cases": index})
        self.hive_path = self.paths["hive_results"] / "suite.json"
        write_json(self.hive_path, {
            "clientVersions": {"go-ethereum_rlp-engineapi": "version"},
            "testCases": {"1": {
                "name": f"test_engine_witness[go-ethereum-{index[1]['id']}]",
                "summaryResult": {"pass": True},
            }},
        })
        self.metric_path = self.paths["metrics"] / "ethrex-26.0.0/zisk-v1.1.0-alpha/empty.json"
        write_json(self.metric_path, {
            "name": "eest__witness_headers_empty_block__block0",
            "timestamp_completed": "2026-09-10T12:00:00Z",
            "metadata": {"original_test_name": index[0]["id"],
                         "source_path": index[0]["json_path"], "block_index": 0},
            "execution": {"success": {"output_matched": True,
                                      "execution_duration": {"secs": 1, "nanos": 0}}},
        })
        write_json(self.paths["metrics"] / "hardware.json", {})
        result = subprocess.run(
            [sys.executable, str(REPO / "scripts/convert-zkevm-metrics-to-hive-results.py"),
             "--input", str(self.paths["metrics"]), "--output", str(self.paths["converted_results"])],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.converted_path = next(self.paths["converted_results"].glob("*.json"))

    def check(self):
        smoke.check(**self.paths)

    def run_cli(self):
        args = [sys.executable, str(SCRIPT)]
        for key, path in self.paths.items():
            args += ["--" + key.replace("_", "-"), str(path)]
        return subprocess.run(args, capture_output=True, text=True, timeout=10)

    def test_real_conversion_and_checker_cli_pass(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Smoke passed", result.stdout)

    def test_missing_outputs_fail_including_hardware_only_metrics(self):
        for path in (self.hive_path, self.metric_path, self.converted_path):
            with self.subTest(path=path):
                content = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(ValueError, "expected exactly one, found 0"):
                    self.check()
                path.write_bytes(content)

    def test_duplicate_outputs_fail(self):
        for path in (self.hive_path, self.metric_path, self.converted_path):
            with self.subTest(path=path):
                duplicate = path.with_name("duplicate.json")
                duplicate.write_bytes(path.read_bytes())
                with self.assertRaisesRegex(ValueError, "expected exactly one, found 2"):
                    self.check()
                duplicate.unlink()

    def test_missing_or_duplicate_suite_cases_fail(self):
        for path in (self.hive_path, self.converted_path):
            suite = read_json(path)
            for count in (0, 2):
                with self.subTest(path=path, count=count):
                    changed = dict(suite, testCases={str(i): suite["testCases"]["1"] for i in range(count)})
                    write_json(path, changed)
                    with self.assertRaisesRegex(ValueError, "expected exactly one"):
                        self.check()
            write_json(path, suite)

    def test_skipped_pass_and_timeout_fail(self):
        for path in (self.hive_path, self.converted_path):
            original = path.read_bytes()
            for summary in ({"pass": False}, {"pass": True, "timeout": True},
                            {"pass": True, "details": "Test skipped. unsupported fork"}):
                with self.subTest(path=path, summary=summary):
                    suite = read_json(path)
                    suite["testCases"]["1"]["summaryResult"] = summary
                    write_json(path, suite)
                    with self.assertRaisesRegex(ValueError, "skipped|failed or timed-out"):
                        self.check()
            path.write_bytes(original)

    def test_skip_in_details_log_fails(self):
        suite = read_json(self.hive_path)
        log = b"preamble\nTest skipped. unsupported fork"
        (self.hive_path.parent / "details.log").write_bytes(log)
        suite["testDetailsLog"] = "details.log"
        suite["testCases"]["1"]["summaryResult"] = {
            "pass": True, "log": {"begin": len(b"preamble\n"), "end": len(log)}
        }
        write_json(self.hive_path, suite)
        with self.assertRaisesRegex(ValueError, "skipped"):
            self.check()

    def test_wrong_suite_case_or_client_fails(self):
        for path in (self.hive_path, self.converted_path):
            original = path.read_bytes()
            for field in ("name", "clientVersions"):
                with self.subTest(path=path, field=field):
                    suite = json.loads(original)
                    if field == "name":
                        suite["testCases"]["1"]["name"] = "unrelated-test"
                    else:
                        suite["clientVersions"] = {"reth_sp1": "version"}
                    write_json(path, suite)
                    with self.assertRaises(ValueError):
                        self.check()
            path.write_bytes(original)

    def test_guest_crash_mismatch_or_missing_execution_fails(self):
        metric = read_json(self.metric_path)
        for execution in ({"crashed": {"reason": "timed out"}},
                          {"success": {"output_matched": False}}, {}, None,
                          {"success": {"output_matched": True}, "crashed": {}}):
            with self.subTest(execution=execution):
                write_json(self.metric_path, dict(metric, execution=execution))
                with self.assertRaisesRegex(ValueError, "guest execution failed"):
                    self.check()

    def test_wrong_metric_case_fails(self):
        metric = read_json(self.metric_path)
        for field, value in (("original_test_name", "wrong"), ("source_path", "wrong"), ("block_index", 1)):
            with self.subTest(field=field):
                changed = dict(metric, metadata=dict(metric["metadata"], **{field: value}))
                write_json(self.metric_path, changed)
                with self.assertRaisesRegex(ValueError, "unexpected metric case"):
                    self.check()

    def test_wrong_metric_client_or_zkvm_fails(self):
        for directory in ("reth-v1/zisk-v1", "ethrex-v1/sp1-v1"):
            with self.subTest(directory=directory):
                target = self.paths["metrics"] / directory / "empty.json"
                target.parent.mkdir(parents=True)
                self.metric_path.rename(target)
                with self.assertRaisesRegex(ValueError, "unexpected metric client or zkVM"):
                    self.check()
                target.rename(self.metric_path)

    def test_missing_or_duplicate_fixture_index_entry_fails(self):
        index = read_json(self.index_path)
        for entries in (index["test_cases"][1:], index["test_cases"] + [index["test_cases"][0]]):
            with self.subTest(entries=entries):
                write_json(self.index_path, {"test_cases": entries})
                with self.assertRaisesRegex(ValueError, "expected exactly one"):
                    self.check()

    def test_fixture_index_must_match_actual_files(self):
        index = read_json(self.index_path)
        index["test_cases"][0]["id"] = "wrong"
        write_json(self.index_path, index)
        with self.assertRaisesRegex(ValueError, "fixture does not match index"):
            self.check()

    def test_extra_fixture_fails(self):
        fixture = self.paths["fixtures"] / "blockchain_tests/empty.json"
        fixture.with_name("extra.json").write_bytes(fixture.read_bytes())
        with self.assertRaisesRegex(ValueError, "expected exactly one, found 2"):
            self.check()

    def test_fixture_requires_one_block_and_stateless_bytes(self):
        path = self.paths["fixtures"] / "blockchain_tests/empty.json"
        original = path.read_bytes()
        for invalid in ("blocks", "statelessInputBytes", "statelessOutputBytes"):
            with self.subTest(invalid=invalid):
                data = json.loads(original)
                case = next(iter(data.values()))
                if invalid == "blocks":
                    case["blocks"] *= 2
                else:
                    case["blocks"][0][invalid] = "0x"
                write_json(path, data)
                with self.assertRaises(ValueError):
                    self.check()

    def test_malformed_result_exits_with_error(self):
        self.metric_path.write_text("invalid json")
        result = self.run_cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn("smoke failed:", result.stderr)


if __name__ == "__main__":
    unittest.main()
