import json
import os
import subprocess
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

REPO_ROOT = Path(__file__).resolve().parents[1]


class ConsumeTransportTests(unittest.TestCase):
    def test_transport_controls_consume_arguments(self):
        for transport, expected in (("json-rpc-rlp", False), ("rest-ssz", True), ("bad", None)):
            with self.subTest(transport=transport), TemporaryDirectory() as tmp:
                root = Path(tmp)
                uv = root / "uv"
                uv.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\n')
                uv.chmod(0o755)
                result = subprocess.run(
                    ["bash", "-c", '''
source scripts/run-hive-consume-client.sh
_run_hive_client_descriptor="$DESCRIPTOR"
_run_hive_client_full_name=nimbus-el_rest-ssz
_run_hive_client_run_consume
'''],
                    cwd=REPO_ROOT,
                    env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                         "EEST_DIR": tmp, "FIXTURES_DIR": str(root / "fixtures"),
                         "CAPTURE": str(root / "args"),
                         "DESCRIPTOR": json.dumps({"transport": transport})},
                    capture_output=True, text=True,
                )
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((root / "args").exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = (root / "args").read_text().splitlines()
                    self.assertEqual("--ssz" in args, expected)
                    self.assertEqual(args[:3], ["run", "consume", "engine-witness"])
