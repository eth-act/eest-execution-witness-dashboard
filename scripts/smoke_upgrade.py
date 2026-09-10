"""Offline smoke orchestration used by smoke-upgrade.sh (Python 3.11+)."""

from __future__ import annotations

import argparse
from collections import Counter
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import parse_qs, urlsplit


SCRIPTS = Path(__file__).resolve().parent
HEADER_TEST = "tests/amsterdam/eip8025_optional_proofs/test_witness_headers.py"
SMOKE_TESTS = ("test_witness_headers_empty_block", "test_witness_headers_blockhash_at_offset")
GUEST_TAG = "v0.17.0"
LABEL = "eest.smoke.run"


class SmokeError(Exception):
    pass


def read_json(path: Path):
    return json.loads(path.read_text())


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def offline_environment():
    env = os.environ.copy()
    env.update(CARGO_NET_OFFLINE="true", UV_OFFLINE="1", UV_NO_SYNC="1",
               GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local", GOWORK="off", RUSTUP_AUTO_INSTALL="0")
    for key in ("ERE_FORCE_REBUILD_DOCKER_IMAGE", "GH_TOKEN", "GITHUB_TOKEN"):
        env.pop(key, None)
    return env


class Commands:
    """Run each command in an owned process group, including on interruption."""

    def __init__(self, env):
        self.env = env

    def run(self, args, *, cwd=None, env=None, log=None, timeout=120):
        args = [str(arg) for arg in args]
        output = open(log, "w") if log else subprocess.PIPE
        process = None
        try:
            process = subprocess.Popen(
                args, cwd=cwd, env=self.env | (env or {}), stdout=output,
                stderr=subprocess.STDOUT, text=True, start_new_session=True,
            )
            try:
                text, _ = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired as exc:
                raise SmokeError(f"timed out after {timeout}s: {' '.join(args)}") from exc
            if process.returncode:
                detail = f"see {log}" if log else (text or "")[-2400:]
                raise SmokeError(f"exit {process.returncode}: {' '.join(args)}\n{detail}")
            return (text or "").strip()
        finally:
            if process is not None:
                # Also terminate descendants if the group leader has already exited.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            if log:
                output.close()


def source_version(package):
    source = package.get("source", "") or ""
    if source.startswith("git+"):
        url = urlsplit(source[4:])
        return parse_qs(url.query).get("tag", [url.fragment[:7]])[0]
    return "v" + package["version"]


def guest_inventory(metadata, registry, zkvms):
    """Resolve selected SDKs using ere-catalog's direct dependency edges."""
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}

    def package(name):
        matches = [p for p in packages.values() if p["name"] == name]
        if len(matches) != 1:
            raise SmokeError(f"expected one locked {name} package, found {len(matches)}")
        return matches[0]

    catalog = package("ere-catalog")
    source = catalog.get("source", "")
    image_commit = urlsplit(source.removeprefix("git+")).fragment
    if not re.fullmatch(r"[0-9a-f]{40}", image_commit):
        raise SmokeError("ere-catalog must be locked to a git commit")
    for name in ("stateless-validator-catalog", "stateless-validator-common", "stateless-validator-downloader"):
        p = package(name)
        if source_version(p) != GUEST_TAG or not (p.get("source") or "").startswith(
            "git+https://github.com/eth-act/ere-guests?"
        ):
            raise SmokeError(f"{name} must resolve to ere-guests@{GUEST_TAG}")
    inventory = {}
    sdk_dependencies = {
        "zisk": ("ere-verifier-zisk", "zisk-verifier"),
        "sp1": ("ere-verifier-sp1", "sp1-verifier"),
        "openvm": ("ere-platform-openvm", "openvm"),
    }
    for zkvm in sorted(set(zkvms)):
        if zkvm not in sdk_dependencies:
            raise SmokeError(f"unsupported zkVM: {zkvm}")
        owner, dependency = sdk_dependencies[zkvm]
        parent = package(owner)
        dependencies = [packages[d["pkg"]] for d in nodes[parent["id"]]["deps"]]
        matches = [p for p in dependencies if p["name"] == dependency]
        if len(matches) != 1:
            raise SmokeError(f"cannot resolve {zkvm} SDK from locked dependency graph")
        prefix = registry.rstrip("/") + "/" if registry else ""
        inventory[zkvm] = {
            "sdk": source_version(matches[0]),
            "image": f"{prefix}ere-server-{zkvm}:{image_commit[:7]}",
        }
    return inventory


def fixture_expectations(root: Path):
    """Derive identities from actual fixtures, and cross-check the consume index."""
    index = read_json(root / ".meta/index.json")
    expected = {"hive": [], "zkevm": []}
    for directory, format_name, kind in (
        ("blockchain_tests", "blockchain_test", "zkevm"),
        ("blockchain_tests_engine", "blockchain_test_engine", "hive"),
    ):
        indexed = Counter((tc["id"], tc["json_path"]) for tc in index["test_cases"]
                          if tc["format"] == format_name)
        actual = Counter()
        for path in sorted((root / directory).rglob("*.json")):
            for name, case in read_json(path).items():
                relative = path.relative_to(root).as_posix()
                actual[(name, relative)] += 1
                if kind == "hive":
                    expected[kind].append(name)
                else:
                    blocks = case.get("blocks", [])
                    if not blocks:
                        raise SmokeError(f"{name}: no executable blocks")
                    for key in ("statelessInputBytes", "statelessOutputBytes"):
                        value = blocks[-1].get(key)
                        if not isinstance(value, str) or not re.fullmatch(r"(?:0x)?(?:[0-9a-fA-F]{2})+", value):
                            raise SmokeError(f"{name}: last block has no valid {key}")
                    expected[kind].append((name, relative, len(blocks) - 1))
        if not actual or actual != indexed or any(n != 1 for n in actual.values()):
            raise SmokeError(f"{directory}: empty, duplicate, or inconsistent fixture index")
    if len(set(expected["hive"])) != len(expected["hive"]):
        raise SmokeError("engine fixtures contain duplicate test IDs")
    return expected


def load_skip_checker():
    spec = importlib.util.spec_from_file_location("smoke_skips", SCRIPTS / "prune-skipped-hive-results.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_hive(result_dir, expected, row, client_name=None, *, exact_names=False):
    skip_checker = load_skip_checker()
    seen = []
    errors = []
    for path in skip_checker.suite_json_files(result_dir):
        suite = read_json(path)
        if client_name is not None and set(suite.get("clientVersions", {})) != {client_name}:
            errors.append(f"{path.name}: unexpected client identity")
        for case in suite.get("testCases", {}).values():
            row["executed"] += 1
            name = case.get("name", "")
            matches = [test for test in expected if (test == name if exact_names else test in name)]
            if len(matches) != 1:
                errors.append(f"unexpected or ambiguous case: {name}")
            else:
                seen.append(matches[0])
            skipped = skip_checker.is_skipped_case(result_dir=result_dir, suite=suite, test_case=case)
            summary = case.get("summaryResult", {})
            if skipped or summary.get("pass") is not True or summary.get("timeout"):
                errors.append(f"{'skipped' if skipped else 'failed'}: {name}")
            else:
                row["passed"] += 1
    if Counter(seen) != Counter(expected):
        errors.append("missing, duplicate, or unexpected Hive cases")
    if errors:
        raise SmokeError("; ".join(errors))


def validate_metrics(result_dir, expected, row, client, sdk):
    seen = []
    errors = []
    for path in sorted(result_dir.glob("*/*/*.json")):
        if path.name == "hardware.json":
            continue
        metrics = read_json(path)
        row["executed"] += 1
        if not path.parent.parent.name.startswith(client + "-") or path.parent.name != sdk:
            errors.append(f"unexpected metrics participant: {path.relative_to(result_dir)}")
        metadata = metrics.get("metadata") or {}
        seen.append((metadata.get("original_test_name"), metadata.get("source_path"), metadata.get("block_index")))
        execution = metrics.get("execution") or {}
        success = execution.get("success") or {}
        if success.get("output_matched") is not True or "crashed" in execution:
            errors.append(f"failed guest execution: {path.name}")
        else:
            row["passed"] += 1
    if Counter(seen) != Counter(map(tuple, expected)):
        errors.append("missing, duplicate, or unexpected guest cases")
    if errors:
        raise SmokeError("; ".join(errors))


class Smoke:
    def __init__(self, args, commands=None):
        self.args = args
        self.cmd = commands or Commands(offline_environment())
        self.root = Path(os.environ["ROOT_DIR"])
        self.eest = Path(os.environ["EEST_DIR"])
        self.workload = Path(os.environ["ZKEVM_BENCHMARK_WORKLOAD_DIR"])
        self.hive = Path(os.environ["HIVE_DIR"])
        self.timeout = int(os.environ.get("SMOKE_RUN_TIMEOUT_SECONDS", "600"))
        self.run_id = uuid.uuid4().hex
        self.output = None
        self.clients = []
        self.runs = []
        self.images = {}
        self.inventory = {}
        self.versions = {}
        self.rows = []
        self.failures = []
        self.docker = shutil.which("docker") or "docker"

    def image(self, reference):
        if not isinstance(reference, str) or not reference or reference.startswith("-"):
            raise SmokeError("image reference must be a nonempty string")
        info = json.loads(self.cmd.run([self.docker, "image", "inspect", reference]))[0]
        if info.get("Config", {}).get("OnBuild"):
            raise SmokeError(f"{reference}: ONBUILD instructions are not allowed in offline smoke images")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", info["Id"]):
            raise SmokeError(f"{reference}: invalid local image ID")
        return {"reference": reference, "id": info["Id"], "labels": info.get("Config", {}).get("Labels") or {}}

    def check_checkout(self, path, ref, label):
        head = self.cmd.run(["git", "-C", path, "rev-parse", "HEAD"])
        wanted = self.cmd.run(["git", "-C", path, "rev-parse", "--verify", f"{ref}^{{commit}}"])
        if head != wanted:
            raise SmokeError(f"{label}: checkout HEAD does not match locally available {ref}")
        if self.cmd.run(["git", "-C", path, "status", "--porcelain", "--untracked-files=no"]):
            raise SmokeError(f"{label}: tracked files are modified")
        self.versions[label] = {"ref": ref, "commit": head}

    def preflight(self):
        errors = []

        def check(label, action):
            try:
                return action()
            except (SmokeError, OSError, ValueError, KeyError, TypeError) as exc:
                errors.append(f"{label}: {exc}")
                return None

        for tool in ("bash", "git", "jq", "uv", "cargo", "go", "docker", "cmake", "clang", "pkg-config", "nasm"):
            if not shutil.which(tool):
                errors.append(f"missing tool: {tool}")
        if self.timeout <= 0:
            errors.append("SMOKE_RUN_TIMEOUT_SECONDS must be positive")
        check("EEST", lambda: self.check_checkout(self.eest, os.environ.get("EEST_RELEASE_TAG") or os.environ["EEST_REF"], "EEST"))
        check("workload", lambda: self.check_checkout(self.workload, os.environ["ZKEVM_BENCHMARK_WORKLOAD_REF"], "workload"))
        check("Hive", lambda: self.check_checkout(self.hive, os.environ["HIVE_REF"], "Hive"))
        self.clients = check("clients", lambda: json.loads(self.cmd.run(["bash", SCRIPTS / "list-el-clients.sh", "--json"]))) or []
        self.runs = check("guests", lambda: json.loads(self.cmd.run(["bash", SCRIPTS / "list-zkevm-workload-runs.sh", "--json"]))) or []
        for client in self.clients:
            for field in ("id", "hive_client"):
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", client.get(field, "")) or client[field] in (".", ".."):
                    errors.append(f"invalid client {field}: {client.get(field)}")
        if not os.environ.get("ZKEVM_RAYON_THREADS", "").isdigit() or int(os.environ.get("ZKEVM_RAYON_THREADS", "0")) <= 0:
            errors.append("ZKEVM_RAYON_THREADS must be a positive integer")
        if not self.clients and not self.runs:
            errors.append("select at least one EL client or zkEVM run")
        mapping = check("client images", lambda: read_json(self.args.client_images)) or {}
        if not isinstance(mapping, dict):
            errors.append("client images must be a JSON object mapping client IDs to image references")
            mapping = {}
        endpoint = check("Docker context", lambda: self.cmd.run([self.docker, "context", "inspect", "--format", "{{.Endpoints.docker.Host}} "]))
        endpoint = os.environ.get("DOCKER_HOST") or endpoint
        if not endpoint or not endpoint.startswith("unix://"):
            errors.append("offline smoke requires a local Docker daemon using a unix:// endpoint")
        else:
            self.cmd.env.pop("DOCKER_CONTEXT", None)
            self.cmd.env["DOCKER_HOST"] = endpoint
            check("Docker daemon", lambda: self.cmd.run([self.docker, "info", "--format", "{{.ServerVersion}} "]))
            for client in self.clients:
                info = check(client["id"], lambda c=client: self.image(mapping.get(c["id"])))
                if info:
                    recorded_ref = info["labels"].get("eest.smoke.ref")
                    if recorded_ref and recorded_ref != client["ref"]:
                        errors.append(f"{client['id']}: image ref {recorded_ref} differs from selected {client['ref']}")
                    self.images[client["id"]] = info
            if self.clients:
                proxy = check("Hive proxy", lambda: self.image(os.environ.get("SMOKE_HIVE_PROXY_IMAGE", "hive/hiveproxy:latest")))
                if proxy:
                    self.images["hiveproxy"] = proxy
        metadata = check("Cargo dependencies", lambda: json.loads(self.cmd.run(
            ["cargo", "metadata", "--locked", "--offline", "--format-version", "1"], cwd=self.workload)))
        if metadata:
            self.target = Path(metadata["target_directory"])
            self.inventory = check("guest catalog", lambda: guest_inventory(
                metadata, os.environ.get("ERE_IMAGE_REGISTRY", "ghcr.io/eth-act/ere"),
                (run["zkvm"] for run in self.runs))) or {}
        for run in self.runs:
            client, zkvm = run["execution_client"], run["zkvm"]
            if client == "zesu" and zkvm != "zisk":
                errors.append("Zesu supports ZisK only")
            if zkvm not in self.inventory:
                errors.append(f"missing catalog entry: {zkvm}")
                continue
            guest = self.inventory[zkvm]
            for suffix in ("elf", "vk"):
                path = self.args.guest_binaries / f"stateless-validator-{client}-{zkvm}-{guest['sdk']}.{suffix}"
                if not path.is_file() or path.stat().st_size == 0:
                    errors.append(f"missing guest artifact: {path}")
            if endpoint and endpoint.startswith("unix://"):
                info = check(guest["image"], lambda g=guest: self.image(g["image"]))
                if info:
                    self.images[f"ere-{zkvm}"] = info
        check("EEST environment", lambda: self.cmd.run(["uv", "run", "--offline", "--no-sync", "fill", "--help"], cwd=self.eest))
        if self.clients:
            for path in (self.hive, self.hive / "hiveproxy"):
                check(f"Go dependencies ({path})", lambda p=path: self.cmd.run(["go", "list", "-mod=readonly", "-deps", "./..."], cwd=p))
        if self.args.fixtures:
            check("fixture bundle", lambda: fixture_expectations(self.args.fixtures))
        elif not (self.eest / HEADER_TEST).is_file():
            errors.append(f"missing smoke filler: {self.eest / HEADER_TEST}")
        output = (self.args.output_dir or self.root / "smoke-results").resolve()
        protected = [self.eest, self.workload, self.hive, self.args.guest_binaries]
        if self.args.fixtures:
            protected.append(self.args.fixtures)
        if any(output == p.resolve() or output.is_relative_to(p.resolve()) or p.resolve().is_relative_to(output) for p in protected):
            errors.append("output directory overlaps a source/input directory")
        if self.args.output_dir:
            if output.exists() and (not output.is_dir() or any(output.iterdir())):
                errors.append("output directory must be absent or empty")
        return errors

    def prepare_output(self):
        if self.args.output_dir:
            self.output = self.args.output_dir.resolve()
            self.output.mkdir(parents=True, exist_ok=True)
        else:
            parent = self.root / "smoke-results"
            parent.mkdir(exist_ok=True)
            self.output = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
        (self.output / "logs").mkdir()
        self.rows = [dict(participant=f"hive/{c['id']}", expected=0, executed=0, passed=0, status="not run") for c in self.clients]
        self.rows += [dict(participant=f"zkevm/{r['execution_client']}/{r['zkvm']}", expected=0, executed=0, passed=0, status="not run") for r in self.runs]
        write_json(self.output / "versions.json", {"checkouts": self.versions, "guest_tag": GUEST_TAG, "catalog": self.inventory, "images": self.images, "clients": self.clients})
        # Ere uses the docker CLI. Never permit its fallback pull/build paths.
        bin_dir = self.output / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "docker"
        wrapper.write_text(
            f"#!{sys.executable}\nimport os, sys\nargs = sys.argv[1:]\n"
            "if args and (args[0] in ('pull', 'build', 'buildx', 'login') or args[:2] in (['image', 'pull'], ['image', 'build'])):\n"
            "    sys.exit('offline smoke forbids image downloads/builds through the Docker CLI')\n"
            "if args and args[0] in ('run', 'create'):\n"
            f"    args[1:1] = ['--pull=never', '--label', {LABEL + '=' + self.run_id!r}]\n"
            f"os.execv({self.docker!r}, [{self.docker!r}] + args)\n"
        )
        wrapper.chmod(0o755)
        self.cmd.env["PATH"] = str(bin_dir) + os.pathsep + self.cmd.env["PATH"]
        self.cmd.env["ERE_IMAGE_REGISTRY"] = os.environ.get("ERE_IMAGE_REGISTRY", "ghcr.io/eth-act/ere")
        self.summary()

    def logged(self, name, args, *, cwd=None, env=None, timeout=None):
        print(f"==> {name}", flush=True)
        return self.cmd.run(args, cwd=cwd, env=env, log=self.output / "logs" / f"{name}.log", timeout=timeout or self.timeout)

    def prepare_fixtures(self):
        fixtures = self.output / "fixtures"
        if self.args.fixtures:
            # consume writes reports/index caches under its input directory.
            shutil.copytree(self.args.fixtures, fixtures)
        else:
            self.logged("fill", ["uv", "run", "--offline", "--no-sync", "fill", "--output", fixtures,
                        "--fork", os.environ["FORK"], "-m", "blockchain_test or blockchain_test_engine", "-n", "0",
                        *[f"{HEADER_TEST}::{test}" for test in SMOKE_TESTS]], cwd=self.eest)
        expected = fixture_expectations(fixtures)
        if not self.args.fixtures:
            # The preset consists of one empty-block case and four offsets, per format.
            for kind, entries in expected.items():
                names = [entry[0] if isinstance(entry, tuple) else entry for entry in entries]
                counts = [sum(f"::{test}[" in name for name in names) for test in SMOKE_TESTS]
                if counts != [1, 4]:
                    raise SmokeError(f"{kind}: preset must contain one empty-block and four BLOCKHASH-offset cases; got {counts}")
        write_json(self.output / "expected.json", expected)
        for row in self.rows:
            row["expected"] = len(expected[row["participant"].split("/")[0]])
        return fixtures, expected

    def prepare_hive(self):
        stage = self.output / "hive"
        shutil.copytree(self.hive, stage, ignore=shutil.ignore_patterns(".git", "workspace", "clients", "simulators", "hive", "clients-local.yaml"))
        (stage / "clients").mkdir(exist_ok=True)
        (stage / "simulators").mkdir(exist_ok=True)
        proxy = stage / "hiveproxy" / "Dockerfile"
        proxy.write_text(f"FROM {self.images['hiveproxy']['id']}\nLABEL {LABEL}={self.run_id}\n")
        proxy_source = stage / "internal/libdocker/proxy.go"
        patched, count = re.subn(r'const hiveproxyTag = "hive/hiveproxy"',
                                f'const hiveproxyTag = "eest-smoke/hiveproxy:{self.run_id}"', proxy_source.read_text())
        if count != 1:
            raise SmokeError("cannot isolate this Hive version's proxy image tag")
        proxy_source.write_text(patched)
        configs = []
        self.hive_names = {}
        for client in self.clients:
            name = client["hive_client"]
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
                raise SmokeError(f"unsupported smoke client path: {name}")
            directory = stage / "clients" / name
            directory.mkdir()
            (directory / "Dockerfile").write_text(f"FROM {self.images[client['id']]['id']}\nLABEL {LABEL}={self.run_id}\n")
            nametag = f"smoke-{self.run_id}"
            configs.append(f"- client: {json.dumps(name)}\n  nametag: {json.dumps(nametag)}\n")
            self.hive_names[client["id"]] = f"{name}_{nametag}"
        (stage / "clients-local.yaml").write_text("".join(configs))
        self.logged("build-hive", ["go", "build", "-mod=readonly", "-buildvcs=false", "-o", "hive", "."], cwd=stage, timeout=3600)
        return stage

    def hive_run(self, stage, client, fixtures, destination):
        # Use the existing runner's readiness and teardown logic with isolated descriptors.
        config = dict(client, nametag=f"smoke-{self.run_id}", dockerfile="")
        config_path = self.output / f"client-{client['id']}.json"
        write_json(config_path, {"clients": {client["id"]: config}})
        self.logged(f"hive-{client['id']}", ["bash", SCRIPTS / "run-hive-consume-client.sh", client["id"]], env={
            "ROOT_DIR": str(self.output), "EEST_DIR": str(self.eest), "HIVE_DIR": str(stage),
            "FIXTURES_DIR": str(fixtures), "EL_CLIENT_CONFIG": str(config_path), "EL_CLIENT_OVERRIDES_JSON": "{}",
            "HIVE_CONSUME_RESULT_DIR": str(destination), "HIVE_LOG_FILE": str(destination / "hive.log"),
            "RUN_HIVE_SETUP": "0", "HIVE_CONSUME_ALLOW_FAILURE": "0", "HIVE_PRUNE_SKIPPED": "0",
            "HIVE_PARALLELISM": "1", "HIVE_SIMULATOR": "http://127.0.0.1:3000",
        })

    def run_participant(self, row, action, validate):
        try:
            action()
            validate()
            row["status"] = "passed"
        except (SmokeError, OSError, ValueError, KeyError, TypeError) as exc:
            row["status"] = "failed"
            row["error"] = str(exc)
            print(f"FAIL {row['participant']}: {exc}", file=sys.stderr)
        finally:
            self.summary()

    def execute(self):
        fixtures, expected = self.prepare_fixtures()
        self.logged("build-workload", ["cargo", "build", "--locked", "--offline", "--release", "-p", "ere-hosts"], cwd=self.workload, timeout=3600)
        stage = self.prepare_hive() if self.clients else None
        for client, row in zip(self.clients, self.rows):
            destination = self.output / "hive-results" / client["id"]
            self.run_participant(row, lambda c=client, d=destination: self.hive_run(stage, c, fixtures, d),
                          lambda d=destination, r=row, c=client: validate_hive(d, expected["hive"], r, self.hive_names[c["id"]]))
        for run, row in zip(self.runs, self.rows[len(self.clients):]):
            client, zkvm = run["execution_client"], run["zkvm"]
            destination = self.output / "metrics" / f"{client}-{zkvm}"

            def action():
                self.logged(f"guest-{client}-{zkvm}", [self.target / "release/ere-hosts", "--zkvms", zkvm,
                            "--action", "execute", "--output-folder", destination,
                            "--bin-path", self.args.guest_binaries, "stateless-validator",
                            "--execution-client", client, "--input-folder", fixtures], cwd=self.workload,
                            env={"RUST_LOG": "info", "RAYON_NUM_THREADS": os.environ["ZKEVM_RAYON_THREADS"]})
                self.logged(f"convert-{client}-{zkvm}", [sys.executable, SCRIPTS / "convert-zkevm-metrics-to-hive-results.py",
                            "--input", destination, "--output", self.output / "converted" / f"{client}-{zkvm}"])

            def validate():
                sdk = f"{zkvm}-{self.inventory[zkvm]['sdk']}"
                validate_metrics(destination, expected["zkevm"], row, client, sdk)
                names = [read_json(p)["name"] for p in destination.glob("*/*/*.json") if p.name != "hardware.json"]
                converted_row = dict(executed=0, passed=0)
                validate_hive(self.output / "converted" / f"{client}-{zkvm}", names, converted_row, f"{client}_{sdk}", exact_names=True)

            self.run_participant(row, action, validate)

    def summary(self):
        if not self.output:
            return
        success = bool(self.rows) and all(r["status"] == "passed" for r in self.rows) and not self.failures
        write_json(self.output / "summary.json", {"success": success, "participants": self.rows, "failures": self.failures})
        lines = ["# Execution witness smoke", "", f"Result: {'PASS' if success else 'NOT PASSED'}", "",
                 f"Guests: ere-guests@{GUEST_TAG}", ""]
        lines += [f"- {name}: `{v['ref']}` (`{v['commit']}`)" for name, v in self.versions.items()]
        lines += ["", "| Participant | Expected | Executed | Passed | Status |", "| --- | ---: | ---: | ---: | --- |"]
        lines += [f"| {r['participant']} | {r['expected']} | {r['executed']} | {r['passed']} | {r['status']} |" for r in self.rows]
        lines += ["", "Local image IDs:", ""]
        lines += [f"- {name}: `{info['reference']}` → `{info['id']}`" for name, info in self.images.items()]
        errors = self.failures + [f"{r['participant']}: {r['error']}" for r in self.rows if r.get("error")]
        if errors:
            lines += ["", "Failures:", "", *[f"- {e}" for e in errors]]
        (self.output / "summary.md").write_text("\n".join(lines) + "\n")

    def cleanup(self):
        if not self.output:
            return
        try:
            ids = self.cmd.run([self.docker, "ps", "-aq", "--filter", f"label={LABEL}={self.run_id}"])
            if ids:
                self.cmd.run([self.docker, "rm", "-f", *ids.split()])
        except (SmokeError, OSError) as exc:
            self.failures.append(f"container cleanup: {exc}")
        self.summary()


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="scripts/smoke-upgrade.sh", description=__doc__,
                                     epilog="Environment: EL_CLIENTS, ZKEVM_WORKLOAD_RUNS, SMOKE_RUN_TIMEOUT_SECONDS (600), SMOKE_HIVE_PROXY_IMAGE, ERE_IMAGE_REGISTRY, and checkout paths from scripts/env.sh.")
    parser.add_argument("--guest-binaries", required=True, type=Path, help="Local ere-guests v0.17.0 ELF/VK directory")
    parser.add_argument("--client-images", required=True, type=Path, help="JSON object mapping client IDs to local Hive-compatible images")
    parser.add_argument("--check-only", action="store_true", help="Check prerequisites without building or running")
    parser.add_argument("--fixtures", type=Path, help="Reuse a small prepared EEST bundle instead of filling")
    parser.add_argument("--output-dir", type=Path, help="Absent or empty directory; default: unique smoke-results/run-* directory")
    args = parser.parse_args(argv)
    for key in ("guest_binaries", "client_images", "fixtures", "output_dir"):
        value = getattr(args, key)
        if value is not None:
            setattr(args, key, value.resolve())
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        smoke = Smoke(args)
        errors = smoke.preflight()
    except (ValueError, KeyError, OSError) as exc:
        print(f"preflight: {exc}", file=sys.stderr)
        return 2
    if errors:
        print("Missing or incompatible local prerequisites:\n" + "\n".join(f"- {e}" for e in errors), file=sys.stderr)
        return 2
    if args.check_only:
        print("All local smoke prerequisites are available.")
        return 0
    try:
        smoke.prepare_output()
        print(f"Smoke output: {smoke.output}", flush=True)
        smoke.execute()
    except (SmokeError, OSError, ValueError, KeyError, TypeError, KeyboardInterrupt) as exc:
        smoke.failures.append(str(exc) or "interrupted")
        print(f"smoke failed: {exc}", file=sys.stderr)
    finally:
        smoke.cleanup()
    return 0 if smoke.rows and all(r["status"] == "passed" for r in smoke.rows) and not smoke.failures else 1


if __name__ == "__main__":
    # Turn cancellation into normal unwinding, so process groups and containers are cleaned.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    sys.exit(main())
