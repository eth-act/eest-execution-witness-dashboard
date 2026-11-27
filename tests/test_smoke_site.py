import json
import os
import shutil
import socket
import subprocess
import sys
import time
import unittest
import urllib.request
from pathlib import Path
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "smoke-site.sh"
RESULT = "1795000000-abc.json"
DETAILS = "details/1795000000--0.log"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_site(site: Path, *, index: str = '<script src="./assets/app.js"></script>', result: dict | None = None) -> None:
    write(site / "index.html", index)
    write(site / "assets" / "app.js", "fetch('./discovery.json')\n")
    write(site / "discovery.json", json.dumps([{"name": "zkEVM", "address": "."}]))
    write(site / "listing.jsonl", json.dumps({"name": "suite", "fileName": RESULT, "clients": ["geth"]}) + "\n")
    result = result if result is not None else {"name": "suite", "testDetailsLog": DETAILS, "testCases": {}}
    write(site / "results" / RESULT, json.dumps(result))
    write(site / "results" / DETAILS, "log\n")


class SmokeSiteTests(unittest.TestCase):
    def setUp(self):
        for command in ("curl", "jq"):
            if shutil.which(command) is None:
                self.skipTest(f"{command} is required by smoke-site.sh")
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.site = self.root / "site"

    def smoke(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "SITE_DIR": str(self.site),
            "SITE_SMOKE_PORT": str(free_port()),
            "TMPDIR": str(self.root),
        }
        return subprocess.run(
            ["bash", str(SCRIPT_PATH), *args],
            cwd=REPO_ROOT, env=env, text=True, capture_output=True, check=False, timeout=120,
        )

    def serve(self) -> str:
        """Serve the site under a subpath, as GitHub Pages serves a project."""
        (self.root / "pages").mkdir()
        (self.root / "pages" / "dashboard").symlink_to(self.site)
        port = free_port()
        server = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1",
             "--directory", str(self.root / "pages")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.addCleanup(server.wait)
        self.addCleanup(server.terminate)
        url = f"http://127.0.0.1:{port}/dashboard"
        for _ in range(100):
            try:
                urllib.request.urlopen(f"{url}/", timeout=1).close()
                return url
            except OSError:
                time.sleep(0.05)
        self.fail("test HTTP server did not start")

    def test_local_site_passes(self):
        make_site(self.site)
        result = self.smoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Fetched listing.jsonl and results/{RESULT} from the local server", result.stdout)
        self.assertIn(f"Verified referenced result asset results/{DETAILS} from the local server", result.stdout)

    def test_root_relative_asset_fails(self):
        make_site(self.site, index='<script src="/assets/app.js"></script>')
        result = self.smoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("root-relative asset or fetch paths", result.stderr)

    def test_result_referencing_a_missing_file_fails(self):
        make_site(self.site)
        (self.site / "results" / DETAILS).unlink()
        result = self.smoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"result entry references a file that was not copied: results/{DETAILS}", result.stderr)

    def test_secret_in_published_results_fails(self):
        make_site(self.site, result={"name": "suite", "testCases": {}, "note": "Authorization: Bearer abc123"})
        result = self.smoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("possible secret", result.stderr)

    def test_deployed_site_passes(self):
        make_site(self.site)
        result = self.smoke("--url", self.serve())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Verified referenced result asset results/{DETAILS} from the deployed site", result.stdout)
        self.assertIn("Deployed Pages smoke test passed", result.stdout)

    def test_deployed_site_missing_a_referenced_file_fails(self):
        make_site(self.site)
        url = self.serve()
        (self.site / "results" / DETAILS).unlink()
        result = self.smoke("--url", url)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("404", result.stderr)


if __name__ == "__main__":
    unittest.main()
