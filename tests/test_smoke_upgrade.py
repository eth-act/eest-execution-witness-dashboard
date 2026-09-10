import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import smoke_upgrade as smoke
from smoke_ci import pin_dockerfile


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data))


def bundle(root):
    index = []
    for directory, format_name in (("blockchain_tests", "blockchain_test"), ("blockchain_tests_engine", "blockchain_test_engine")):
        cases = {}
        names = [(smoke.SMOKE_TESTS[0], "empty")] + [(smoke.SMOKE_TESTS[1], f"offset_{offset}") for offset in (1, 2, 5, 10)]
        for test, param in names:
            name = f"{smoke.HEADER_TEST}::{test}[fork_Amsterdam-{param}-{format_name}]"
            cases[name] = {"blocks": [{"statelessInputBytes": "0x0102", "statelessOutputBytes": "0x0304"}]}
            index.append(dict(id=name, json_path=f"{directory}/headers.json", format=format_name))
        write_json(root / directory / "headers.json", cases)
    write_json(root / ".meta/index.json", {"test_cases": index, "fixture_formats": ["blockchain_test", "blockchain_test_engine"]})


def metadata(root):
    packages, nodes = [], []

    def add(name, source=None, deps=()):
        packages.append(dict(name=name, id=name, version="1.0.0", source=source))
        nodes.append(dict(id=name, deps=[dict(pkg=p) for p in deps]))

    add("ere-catalog", "git+https://github.com/eth-act/ere?tag=v0.17.0#" + "a" * 40)
    for name in ("stateless-validator-catalog", "stateless-validator-common", "stateless-validator-downloader"):
        add(name, "git+https://github.com/eth-act/ere-guests?tag=v0.17.0#" + "b" * 40)
    for parent, child, tag in (("ere-verifier-zisk", "zisk-verifier", "v1.1.0-alpha"),
                               ("ere-verifier-sp1", "sp1-verifier", "v6.4.0"),
                               ("ere-platform-openvm", "openvm", "v2.1.0-preview")):
        add(child, f"git+https://example.test/{child}?tag={tag}#" + "c" * 40)
        add(parent, deps=[child])
    return dict(packages=packages, resolve=dict(nodes=nodes), target_directory=str(root / "target"))


# Every external build/runtime command is replaced. The shell entrypoint,
# orchestration, expected-case validation and converter all execute for real.
STUB = r'''
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ['SMOKE_STUB_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as f:
    f.write(json.dumps(dict(name=name, args=args, cwd=os.getcwd(), env={k:os.environ.get(k) for k in ('CARGO_NET_OFFLINE','UV_OFFLINE','UV_NO_SYNC','GOPROXY','GOSUMDB','GOTOOLCHAIN','RUN_HIVE_SETUP','HIVE_CONSUME_ALLOW_FAILURE','HIVE_PRUNE_SKIPPED')}))+'\n')
def arg(flag): return args[args.index(flag)+1]
def write(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value))
if name == 'git':
    if 'rev-parse' in args:
        if os.environ.get('STUB_BAD_REF') and args[-1] != 'HEAD': print('b'*40)
        else: print('a'*40)
elif name == 'cargo':
    if 'metadata' in args: print((root/'metadata.json').read_text())
    if 'build' in args:
        target=root/'target/release/ere-hosts'
        target.parent.mkdir(parents=True,exist_ok=True)
        target.symlink_to(root/'bin/stub')
elif name == 'go':
    if 'build' in args:
        target=Path.cwd()/'hive'
        target.write_text('#!/bin/sh\nexit 0\n')
        target.chmod(0o755)
elif name == 'uv':
    if 'fill' in args and '--help' not in args:
        shutil.copytree(root/'source-fixtures', arg('--output'))
elif name == 'docker':
    if args[:2] == ['context','inspect']: print('unix:///unused-smoke-test.sock')
    if args[:2] == ['image','inspect']:
        if os.environ.get('STUB_MISSING_IMAGE'): sys.exit(1)
        print(json.dumps([dict(Id='sha256:'+'d'*64, Config=dict(Labels={},OnBuild=[]))]))
    if args[:2] == ['rm','-f']:
        (root/'cleaned').write_text(' '.join(args[2:]))
    if args[:2] == ['ps','-aq']:
        print('owned-container')
elif name == 'bash':
    if Path(args[0]).name != 'run-hive-consume-client.sh':
        os.execv('/bin/bash',['/bin/bash']+args)
    client=args[-1]
    config=json.loads(Path(os.environ['EL_CLIENT_CONFIG']).read_text())['clients'][client]
    client_name=config['hive_client']+'_'+config['nametag']
    fixtures=Path(os.environ['FIXTURES_DIR'])
    tests=json.loads((fixtures/'blockchain_tests_engine/headers.json').read_text())
    cases={}
    for i,test in enumerate(tests):
        result=dict(pass_=True)
        result={'pass':True,'details':'OK'}
        if os.environ.get('STUB_HIVE_MODE')=='skip': result['details']='Test skipped. no witness RPC'
        cases[str(i)]=dict(name='test_blockchain_via_engine_witness['+test+'-'+client_name+']',summaryResult=result)
    write(Path(os.environ['HIVE_CONSUME_RESULT_DIR'])/'suite.json',dict(clientVersions={client_name:'devnet8'},testCases=cases))
    # Simulate consume's report writes; these must affect only the copied bundle.
    (fixtures/'.meta/report.txt').write_text('consumed')
elif name == 'ere-hosts':
    client=arg('--execution-client')
    if os.environ.get('STUB_FAIL_GUEST')==client: sys.exit(9)
    tests=json.loads((Path(arg('--input-folder'))/'blockchain_tests/headers.json').read_text())
    out=Path(arg('--output-folder'))/(client+'-v1')/'zisk-v1.1.0-alpha'
    for i,test in enumerate(tests):
        if os.environ.get('STUB_GUEST_MODE')=='missing' and i==0: continue
        write(out/(str(i)+'.json'),dict(name='case_'+str(i),timestamp_completed='2026-09-10T12:00:02Z',
            metadata=dict(original_test_name=test,source_path='blockchain_tests/headers.json',block_index=0),
            execution=dict(success=dict(output_matched=os.environ.get('STUB_GUEST_MODE')!='mismatch',execution_duration=dict(secs=2,nanos=0)))))
'''


class SmokeScriptTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which("jq"):
            self.skipTest("jq required")
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("bin", "eest", "workload", "hive", "guests"):
            (self.root / name).mkdir()
        (self.root / "eest" / smoke.HEADER_TEST).parent.mkdir(parents=True)
        (self.root / "eest" / smoke.HEADER_TEST).touch()
        proxy = self.root / "hive/internal/libdocker/proxy.go"
        proxy.parent.mkdir(parents=True)
        proxy.write_text('package libdocker\nconst hiveproxyTag = "hive/hiveproxy"\n')
        (self.root / "hive/hiveproxy").mkdir()
        (self.root / "hive/hiveproxy/Dockerfile").write_text("FROM upstream\nRUN network-install\n")
        bundle(self.root / "source-fixtures")
        write_json(self.root / "metadata.json", metadata(self.root))
        write_json(self.root / "images.json", {"ethrex": "ethrex:devnet8"})
        for client in ("ethrex", "reth"):
            for suffix in ("elf", "vk"):
                (self.root / "guests" / f"stateless-validator-{client}-zisk-v1.1.0-alpha.{suffix}").write_text("artifact")
        stub = self.root / "bin/stub"
        stub.write_text(f"#!{sys.executable}\n" + textwrap.dedent(STUB))
        stub.chmod(0o755)
        for command in ("bash", "git", "cargo", "go", "uv", "docker", "cmake", "clang", "pkg-config", "nasm"):
            (self.root / "bin" / command).symlink_to(stub)
        self.env = os.environ.copy() | {
            "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            "SMOKE_STUB_ROOT": str(self.root), "ROOT_DIR": str(self.root),
            "EEST_DIR": str(self.root / "eest"), "EEST_REF": "tests-zkevm@v0.8.4", "EEST_RELEASE_TAG": "",
            "HIVE_DIR": str(self.root / "hive"), "HIVE_REF": "master",
            "ZKEVM_BENCHMARK_WORKLOAD_DIR": str(self.root / "workload"), "ZKEVM_BENCHMARK_WORKLOAD_REF": "v0.17.0",
            "EL_CLIENT_CONFIG": str(REPO / "config/el-clients.json"), "EL_GUEST_CONFIG": str(REPO / "config/el-guests.json"),
            "EL_CLIENTS": "ethrex", "EL_CLIENT_OVERRIDES_JSON": "{}",
            "ZKEVM_WORKLOAD_RUNS": "ethrex:zisk,reth:zisk", "ERE_IMAGE_REGISTRY": "ghcr.io/eth-act/ere",
        }
        self.env.pop("DOCKER_HOST", None)
        self.args = ["/bin/bash", str(REPO / "scripts/smoke-upgrade.sh"), "--guest-binaries", str(self.root / "guests"),
                     "--client-images", str(self.root / "images.json"), "--output-dir", str(self.root / "output")]

    def run_script(self, *args, **env):
        return subprocess.run(self.args + list(args), env=self.env | env, text=True, capture_output=True, timeout=30)

    def commands(self):
        return [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]

    def test_complete_offline_run_fills_builds_and_converts(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = json.loads((self.root / "output/summary.json").read_text())
        self.assertTrue(summary["success"])
        self.assertEqual(len(summary["participants"]), 3)
        self.assertTrue(all(r["expected"] == r["executed"] == r["passed"] == 5 for r in summary["participants"]))
        commands = self.commands()
        cargo = next(c for c in commands if c["name"] == "cargo" and "build" in c["args"])
        self.assertEqual(cargo["args"], ["build", "--locked", "--offline", "--release", "-p", "ere-hosts"])
        self.assertEqual(cargo["env"]["CARGO_NET_OFFLINE"], "true")
        fill = next(c for c in commands if c["name"] == "uv" and "--output" in c["args"])
        self.assertIn("--offline", fill["args"])
        self.assertIn("--no-sync", fill["args"])
        guests = [c for c in commands if c["name"] == "ere-hosts"]
        self.assertEqual(len(guests), 2)
        self.assertTrue(all("--bin-path" in c["args"] and "--guest-artifact-base-url" not in c["args"] for c in guests))
        hive = next(c for c in commands if c["name"] == "bash" and "run-hive-consume-client.sh" in c["args"][0])
        self.assertEqual(hive["env"]["RUN_HIVE_SETUP"], "0")
        self.assertEqual(hive["env"]["HIVE_CONSUME_ALLOW_FAILURE"], "0")
        self.assertEqual(hive["env"]["HIVE_PRUNE_SKIPPED"], "0")
        proxy = (self.root / "output/hive/hiveproxy/Dockerfile").read_text()
        self.assertNotIn("RUN", proxy)
        self.assertIn("FROM sha256:", proxy)
        self.assertNotIn('"hive/hiveproxy"', (self.root / "output/hive/internal/libdocker/proxy.go").read_text())
        self.assertIn("RUN network-install", (self.root / "hive/hiveproxy/Dockerfile").read_text())
        self.assertEqual((self.root / "cleaned").read_text(), "owned-container")
        cleanup = next(c for c in commands if c["name"] == "docker" and c["args"][:2] == ["ps", "-aq"])
        self.assertIn("label=eest.smoke.run=", cleanup["args"][-1])
        docker_wrapper = self.root / "output/bin/docker"
        denied = subprocess.run([str(docker_wrapper), "pull", "never-download"], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn("forbids", denied.stderr)
        self.assertFalse(any(c["args"][:1] == ["pull"] for c in self.commands()))
        allowed = subprocess.run([str(docker_wrapper), "run", "prepared-image"], env=self.env, capture_output=True, text=True)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        call = self.commands()[-1]
        self.assertEqual(call["args"][:3], ["run", "--pull=never", "--label"])
        self.assertTrue(call["args"][3].startswith("eest.smoke.run="))

    def test_check_only_does_not_build_fill_or_create_output(self):
        result = self.run_script("--check-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "output").exists())
        self.assertFalse(any(c["args"] and c["args"][0] == "build" for c in self.commands()))
        self.assertFalse(any(c["name"] == "ere-hosts" for c in self.commands()))

    def test_preflight_reports_multiple_missing_inputs_without_building(self):
        shutil.rmtree(self.root / "guests")
        result = self.run_script(STUB_MISSING_IMAGE="1", STUB_BAD_REF="1")
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing guest artifact", result.stderr)
        self.assertIn("checkout HEAD does not match", result.stderr)
        self.assertIn("exit 1: ", result.stderr)
        self.assertFalse((self.root / "output").exists())

    def test_fixture_reuse_is_copied_and_does_not_fill(self):
        result = self.run_script("--fixtures", str(self.root / "source-fixtures"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "source-fixtures/.meta/report.txt").exists())
        self.assertTrue((self.root / "output/fixtures/.meta/report.txt").exists())
        self.assertFalse(any(c["name"] == "uv" and "--output" in c["args"] for c in self.commands()))

    def test_failure_aggregation_runs_other_guests(self):
        result = self.run_script(STUB_FAIL_GUEST="ethrex")
        self.assertEqual(result.returncode, 1)
        summary = json.loads((self.root / "output/summary.json").read_text())
        self.assertFalse(summary["success"])
        statuses = {r["participant"]: r["status"] for r in summary["participants"]}
        self.assertEqual(statuses["zkevm/ethrex/zisk"], "failed")
        self.assertEqual(statuses["zkevm/reth/zisk"], "passed")
        self.assertTrue((self.root / "output/logs/guest-ethrex-zisk.log").exists())
        self.assertTrue((self.root / "cleaned").exists())

    def test_skipped_hive_cases_cannot_pass(self):
        result = self.run_script(STUB_HIVE_MODE="skip")
        self.assertEqual(result.returncode, 1)
        self.assertIn("skipped:", result.stderr)

    def test_missing_guest_cases_cannot_pass(self):
        result = self.run_script(STUB_GUEST_MODE="missing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing, duplicate, or unexpected guest cases", result.stderr)

    def test_output_mismatches_cannot_pass(self):
        result = self.run_script(STUB_GUEST_MODE="mismatch")
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed guest execution", result.stderr)

    def test_output_directory_is_never_overwritten(self):
        existing = self.root / "output/keep.txt"
        existing.parent.mkdir()
        existing.write_text("keep")
        result = self.run_script()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(existing.read_text(), "keep")

    def test_output_cannot_overlap_inputs(self):
        result = self.run_script("--output-dir", str(self.root / "hive/new-run"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("overlaps", result.stderr)


class SmokeValidationTests(unittest.TestCase):
    def test_fixture_index_must_match_files_and_last_block_bytes(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            bundle(root)
            self.assertEqual(len(smoke.fixture_expectations(root)["zkevm"]), 5)
            path = root / "blockchain_tests/headers.json"
            cases = json.loads(path.read_text())
            next(iter(cases.values()))["blocks"][-1].pop("statelessInputBytes")
            write_json(path, cases)
            with self.assertRaisesRegex(smoke.SmokeError, "statelessInputBytes"):
                smoke.fixture_expectations(root)
            bundle(root)
            index = json.loads((root / ".meta/index.json").read_text())
            index["test_cases"].pop()
            write_json(root / ".meta/index.json", index)
            with self.assertRaisesRegex(smoke.SmokeError, "inconsistent fixture index"):
                smoke.fixture_expectations(root)

    def test_guest_catalog_uses_locked_direct_dependencies(self):
        data = metadata(Path("/tmp/example"))
        inventory = smoke.guest_inventory(data, "local/ere")
        self.assertEqual(inventory["zisk"], dict(sdk="v1.1.0-alpha", image="local/ere/ere-server-zisk:aaaaaaa"))
        for package in data["packages"]:
            if package["name"] == "stateless-validator-downloader":
                package["source"] = package["source"].replace("v0.17.0", "v0.16.0")
        with self.assertRaisesRegex(smoke.SmokeError, "ere-guests@v0.17.0"):
            smoke.guest_inventory(data, "local/ere")

    def test_commit_pinning_handles_current_clone_forms_and_rejects_drift(self):
        for clone, name in (("git clone --depth 1 --branch $tag https://github.com/$github", "go-ethereum"),
                            ("git clone --depth 1 --branch $tag https://github.com/$github ethrex", "ethrex"),
                            ("git clone -b $tag https://github.com/$github", "nethermind")):
            patched = pin_dockerfile("RUN " + clone + " && echo done\n", name)
            self.assertNotIn("git clone", patched)
            self.assertIn(f"git -C {name} fetch --depth 1 origin $tag", patched)
            self.assertIn("checkout --detach FETCH_HEAD", patched)
        with self.assertRaises(smoke.SmokeError):
            pin_dockerfile("RUN some-different-downloader", "ethrex")

    def test_duplicate_metrics_do_not_replace_missing_cases(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            record = dict(metadata=dict(original_test_name="a", source_path="p", block_index=0),
                          execution=dict(success=dict(output_matched=True)))
            for name in ("one", "two"):
                write_json(root / "ethrex-v1/zisk-v1" / f"{name}.json", record)
            row = dict(executed=0, passed=0)
            with self.assertRaisesRegex(smoke.SmokeError, "missing, duplicate"):
                smoke.validate_metrics(root, [("a", "p", 0), ("b", "p", 0)], row, "ethrex", "zisk-v1")

    def test_converted_case_names_are_matched_exactly(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_json(root / "suite.json", dict(testCases={str(i): dict(name=name, summaryResult={"pass": True})
                                                        for i, name in enumerate(("case1", "case10"))}))
            row = dict(executed=0, passed=0)
            smoke.validate_hive(root, ["case1", "case10"], row, exact_names=True)
            self.assertEqual(row["passed"], 2)

    def test_timeout_terminates_owned_process_group_and_preserves_log(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            code = "import subprocess,sys,time; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print(p.pid,flush=True); time.sleep(60)"
            log = root / "timeout.log"
            with self.assertRaisesRegex(smoke.SmokeError, "timed out"):
                smoke.Commands(os.environ.copy()).run([sys.executable, "-c", code], log=log, timeout=0.3)
            pid = int(log.read_text().strip())
            # A killed child can briefly remain a zombie until adopted/reaped.
            status = Path(f"/proc/{pid}/stat")
            if status.exists():
                self.assertEqual(status.read_text().split()[2], "Z")


if __name__ == "__main__":
    unittest.main()
