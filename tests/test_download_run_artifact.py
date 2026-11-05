import hashlib
import io
import json
import os
import shutil
import subprocess
import threading
import unittest
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import parse_qs, urlsplit


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "download-run-artifact.sh"
REPOSITORY = "owner/repo"
RUN_ID = "123"
ARTIFACT_ID = 7
ARTIFACT_NAME = "dataset-fixtures-123"
TOKEN = "test-token"


def make_zip() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        # Random-looking content so the zip is large enough to cut in half.
        archive.writestr("fixtures.tar.gz", os.urandom(256 * 1024))
    return buffer.getvalue()


class FakeGitHub:
    """Serves the artifacts API and a blob host that supports Range requests."""

    def __init__(self, zip_bytes: bytes, digest: str | None):
        self.zip_bytes = zip_bytes
        self.digest = digest
        self.cut_first_blob = False
        self.ignore_range = False
        self.blob_requests: list[dict[str, str | None]] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                url = urlsplit(self.path)
                if url.path == f"/repos/{REPOSITORY}/actions/runs/{RUN_ID}/artifacts":
                    fake.serve_list(self, parse_qs(url.query).get("name", [""])[0])
                elif url.path == f"/repos/{REPOSITORY}/actions/artifacts/{ARTIFACT_ID}/zip":
                    fake.serve_redirect(self)
                elif url.path == "/blob":
                    fake.serve_blob(self)
                else:
                    self.send_error(404)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def authorized(self, handler) -> bool:
        if handler.headers.get("Authorization") != f"Bearer {TOKEN}":
            handler.send_error(401)
            return False
        return True

    def serve_list(self, handler, name: str):
        if not self.authorized(handler):
            return
        artifacts = []
        if name == ARTIFACT_NAME:
            artifacts.append(
                {
                    "id": ARTIFACT_ID,
                    "name": ARTIFACT_NAME,
                    "size_in_bytes": len(self.zip_bytes),
                    "digest": self.digest,
                    "expired": False,
                }
            )
        body = json.dumps({"total_count": len(artifacts), "artifacts": artifacts}).encode()
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    def serve_redirect(self, handler):
        if not self.authorized(handler):
            return
        handler.send_response(302)
        handler.send_header("Location", f"{self.url}/blob")
        handler.send_header("Content-Length", "0")
        handler.end_headers()

    def serve_blob(self, handler):
        range_header = handler.headers.get("Range")
        self.blob_requests.append(
            {"range": range_header, "authorization": handler.headers.get("Authorization")}
        )
        total = len(self.zip_bytes)
        start = 0
        if range_header and not self.ignore_range:
            start = int(range_header.removeprefix("bytes=").split("-")[0])
        if start >= total:
            handler.send_response(416)
            handler.send_header("Content-Range", f"bytes */{total}")
            handler.send_header("Content-Length", "0")
            handler.end_headers()
            return

        body = self.zip_bytes[start:]
        handler.send_response(206 if start else 200)
        if start:
            handler.send_header("Content-Range", f"bytes {start}-{total - 1}/{total}")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        if self.cut_first_blob and len(self.blob_requests) == 1:
            # Drop the connection halfway, like a stalled blob download.
            handler.wfile.write(body[: len(body) // 2])
            handler.wfile.flush()
            handler.close_connection = True
            return
        handler.wfile.write(body)


class DownloadRunArtifactTests(unittest.TestCase):
    def setUp(self):
        for command in ("bash", "curl", "jq"):
            if shutil.which(command) is None:
                self.skipTest(f"{command} is required by download-run-artifact.sh")
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.zip_bytes = make_zip()
        self.digest = "sha256:" + hashlib.sha256(self.zip_bytes).hexdigest()

    def start_server(self, digest: str | None) -> FakeGitHub:
        fake = FakeGitHub(self.zip_bytes, digest)
        self.addCleanup(fake.close)
        return fake

    def run_script(self, fake: FakeGitHub, name: str = ARTIFACT_NAME, attempts: int = 3):
        env = os.environ.copy()
        env.pop("GITHUB_TOKEN", None)
        env.update(
            {
                "GH_TOKEN": TOKEN,
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_API_URL": fake.url,
                "RUNNER_TEMP": str(self.tmp),
                "ARTIFACT_DOWNLOAD_ATTEMPTS": str(attempts),
                "ARTIFACT_DOWNLOAD_RETRY_DELAY": "0",
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT_PATH), RUN_ID, name, str(self.tmp / "dataset")],
            cwd=REPO_ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_extracted(self, completed):
        self.assertEqual(completed.returncode, 0, completed.stderr)
        with zipfile.ZipFile(io.BytesIO(self.zip_bytes)) as archive:
            expected = archive.read("fixtures.tar.gz")
        self.assertEqual((self.tmp / "dataset" / "fixtures.tar.gz").read_bytes(), expected)
        self.assertEqual(list(self.tmp.glob("artifact-*.zip")), [])

    def test_downloads_and_extracts_artifact(self):
        fake = self.start_server(self.digest)

        completed = self.run_script(fake)

        self.assert_extracted(completed)
        self.assertEqual(fake.blob_requests, [{"range": None, "authorization": None}])

    def test_resumes_interrupted_download(self):
        fake = self.start_server(self.digest)
        fake.cut_first_blob = True

        completed = self.run_script(fake)

        self.assert_extracted(completed)
        self.assertEqual(len(fake.blob_requests), 2)
        resumed_from = len(self.zip_bytes) // 2
        self.assertEqual(fake.blob_requests[1]["range"], f"bytes={resumed_from}-")
        self.assertTrue(all(request["authorization"] is None for request in fake.blob_requests))

    def test_restarts_when_blob_host_ignores_range(self):
        fake = self.start_server(self.digest)
        fake.cut_first_blob = True
        fake.ignore_range = True

        completed = self.run_script(fake)

        self.assert_extracted(completed)
        self.assertEqual([request["range"] is None for request in fake.blob_requests], [True, False, True])

    def test_checks_zip_crcs_when_artifact_has_no_digest(self):
        fake = self.start_server(None)

        completed = self.run_script(fake)

        self.assert_extracted(completed)
        self.assertIn("checking zip CRCs", completed.stdout)

    def test_rejects_digest_mismatch(self):
        fake = self.start_server("sha256:" + "0" * 64)

        completed = self.run_script(fake, attempts=2)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does not match", completed.stderr)
        self.assertIn("after 2 attempts", completed.stderr)
        self.assertEqual(len(fake.blob_requests), 2)
        self.assertFalse((self.tmp / "dataset" / "fixtures.tar.gz").exists())

    def test_rejects_missing_artifact(self):
        fake = self.start_server(self.digest)

        completed = self.run_script(fake, name="dataset-fixtures-999")

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("no unexpired artifact named dataset-fixtures-999", completed.stderr)
        self.assertEqual(fake.blob_requests, [])


if __name__ == "__main__":
    unittest.main()
