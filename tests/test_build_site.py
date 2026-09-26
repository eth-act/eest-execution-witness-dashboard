import copy
import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "build-site.sh"


@unittest.skipUnless(shutil.which("jq"), "jq is required by build-site.sh")
class BuildSiteResultsTests(unittest.TestCase):
    def publish(self, root, suite, *, include_logs=False, create_logs=True):
        source = root / "source"
        site = root / "site"
        source.mkdir()
        site.mkdir()
        original = json.dumps(suite, indent=2) + "\n"
        (source / "suite.json").write_text(original)
        (source / "unlisted.json").write_text(original)
        if create_logs:
            for name in ("sim.log", "details.log", "client.log"):
                (source / name).write_text(name)
        listing = {"fileName": "suite.json", "clients": ["client"],
                   "ntests": 2, "passes": 1, "fails": 1, "simLog": "sim.log"}
        (site / "listing.jsonl").write_text(json.dumps(listing) + "\n")
        env = dict(os.environ, HIVE_RESULTS_DIR=str(source), SITE_DIR=str(site),
                   SITE_INCLUDE_CLIENT_LOGS="1" if include_logs else "0")
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; _build_site_copy_results; '
             '_build_site_validate_result_references', "bash", str(SCRIPT_PATH)],
            env=env, cwd=REPO_ROOT, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((source / "suite.json").read_text(), original)
        self.assertEqual((source / "unlisted.json").read_text(), original)
        return site, listing

    def suite(self):
        case = {
            "name": "test", "description": "HTML and rerun instructions",
            "start": "2026-09-25T13:00:00Z", "end": "2026-09-25T13:00:01Z",
            "summaryResult": {"pass": True, "details": "inline log",
                              "log": {"begin": 0, "end": 10}},
            "clientInfo": {"client": {"name": "client", "id": "1",
                                      "logFile": "client.log",
                                      "logOffsets": {"begin": 0, "end": 10}}},
        }
        failed = copy.deepcopy(case)
        failed["name"] = "failing test"
        failed["summaryResult"]["pass"] = False
        return {"name": "suite", "description": "Suite metadata",
                "clientVersions": {"client": "version"}, "simLog": "sim.log",
                "testDetailsLog": "details.log", "testCases": {"1": case, "2": failed}}

    def test_pages_preserves_results_without_publishing_details_or_logs(self):
        suite = self.suite()
        with TemporaryDirectory() as tmp:
            site, listing = self.publish(Path(tmp), suite)
            published = json.loads((site / "results/suite.json").read_text())
            expected = copy.deepcopy(suite)
            del expected["simLog"], expected["testDetailsLog"]
            for case in expected["testCases"].values():
                del case["description"]
                del case["summaryResult"]["details"], case["summaryResult"]["log"]
                del case["clientInfo"]["client"]["logFile"]
                del case["clientInfo"]["client"]["logOffsets"]
            self.assertEqual(published, expected)
            self.assertEqual([p.name for p in (site / "results").iterdir()], ["suite.json"])
            del listing["simLog"]
            self.assertEqual(json.loads((site / "listing.jsonl").read_text()), listing)

    def test_pages_does_not_require_omitted_logs_or_optional_fields(self):
        suite = self.suite()
        suite["testCases"]["3"] = {"name": "minimal", "summaryResult": {"pass": True}}
        with TemporaryDirectory() as tmp:
            site, _ = self.publish(Path(tmp), suite, create_logs=False)
            published = json.loads((site / "results/suite.json").read_text())
            self.assertEqual(published["testCases"]["3"], suite["testCases"]["3"])

    def test_local_debug_build_keeps_full_descriptions_and_referenced_logs(self):
        suite = self.suite()
        with TemporaryDirectory() as tmp:
            site, listing = self.publish(Path(tmp), suite, include_logs=True)
            self.assertEqual(json.loads((site / "results/suite.json").read_text()), suite)
            self.assertEqual(json.loads((site / "listing.jsonl").read_text()), listing)
            self.assertEqual({p.name for p in (site / "results").iterdir()},
                             {"suite.json", "sim.log", "details.log", "client.log"})


if __name__ == "__main__":
    unittest.main()
