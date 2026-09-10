"""Online preparation for PR smoke jobs. Never called by the offline smoke script."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys

from smoke_upgrade import Commands, GUEST_TAG, SCRIPTS, SmokeError, guest_inventory, read_json, write_json


def pin_dockerfile(text, directory):
    """Replace branch-only clones with a fetch that accepts an immutable commit."""
    pattern = r"git clone\s+(?:--depth(?:=|\s+)\d+\s+)?(?:--branch|-b)\s+\$tag\s+https://github\.com/\$github(?:\s+" + re.escape(directory) + r")?"
    replacement = (
        f"git init {directory} && git -C {directory} remote add origin https://github.com/$github"
        f" && git -C {directory} fetch --depth 1 origin $tag"
        f" && git -C {directory} checkout --detach FETCH_HEAD"
    )
    updated, count = re.subn(pattern, lambda _: replacement, text)
    if count != 1:
        raise SmokeError("Hive Dockerfile.git no longer has the expected branch clone; update pin_dockerfile before building")
    return updated


class Prepare:
    def __init__(self):
        self.root = Path(os.environ["ROOT_DIR"])
        self.inputs = self.root / "smoke-results" / "ci-inputs"
        self.inputs.mkdir(parents=True, exist_ok=True)
        self.logs = self.inputs / "logs"
        self.logs.mkdir(exist_ok=True)
        self.cmd = Commands(os.environ.copy())

    def run(self, name, args, cwd=None):
        print(f"==> Prepare {name} (log: {self.logs / (name + '.log')})", flush=True)
        self.cmd.run(args, cwd=cwd, log=self.logs / f"{name}.log", timeout=5400)

    def checkout(self, label, repo, ref, path):
        if path.exists():
            raise SmokeError(f"CI checkout must be absent: {path}")
        self.run(label + "-init", ["git", "init", "-q", path])
        self.run(label + "-remote", ["git", "-C", path, "remote", "add", "origin", repo])
        self.run(label + "-fetch", ["git", "-C", path, "fetch", "--depth=1", "origin", ref])
        self.run(label + "-checkout", ["git", "-C", path, "checkout", "--detach", "FETCH_HEAD"])
        commit = self.cmd.run(["git", "-C", path, "rev-parse", "HEAD"])
        try:
            self.cmd.run(["git", "-C", path, "rev-parse", "--verify", f"{ref}^{{commit}}"])
        except SmokeError:
            # A fetch of a branch can populate only FETCH_HEAD in a new repository.
            self.run(label + "-local-ref", ["git", "-C", path, "update-ref", f"refs/heads/{ref}", commit])
        return commit

    def sources(self):
        resolved = {}
        for label, prefix in (("eest", "EEST"), ("workload", "ZKEVM_BENCHMARK_WORKLOAD"), ("hive", "HIVE")):
            repo, ref, path = os.environ[prefix + "_REPO"], os.environ[prefix + "_REF"], Path(os.environ[prefix + "_DIR"])
            resolved[label] = dict(repo=repo, ref=ref, commit=self.checkout(label, repo, ref, path))
        clients = json.loads(self.cmd.run(["bash", SCRIPTS / "list-el-clients.sh", "--json"]))
        resolved["clients"] = {}
        for client in clients:
            name = client["id"]
            path = self.inputs / "client-sources" / name
            commit = self.checkout(name, client["repo"], client["ref"], path)
            resolved["clients"][name] = dict(client, commit=commit)
        write_json(self.inputs / "resolved.json", resolved)
        key = hashlib.sha256(json.dumps(resolved, sort_keys=True).encode()).hexdigest()
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as f:
                f.write(f"source_key={key}\n")

    def assets(self):
        eest, workload, hive = (Path(os.environ[key]) for key in ("EEST_DIR", "ZKEVM_BENCHMARK_WORKLOAD_DIR", "HIVE_DIR"))
        self.run("uv-sync", ["uv", "sync", "--locked"], cwd=eest)
        for name, path in (("hive", hive), ("hiveproxy", hive / "hiveproxy")):
            self.run(name + "-modules", ["go", "mod", "download"], cwd=path)
        self.run("cargo-fetch", ["cargo", "fetch", "--locked"], cwd=workload)
        metadata = json.loads(self.cmd.run(["cargo", "metadata", "--locked", "--offline", "--format-version", "1"], cwd=workload))
        inventory = guest_inventory(metadata, os.environ.get("ERE_IMAGE_REGISTRY", "ghcr.io/eth-act/ere"))
        guests = self.inputs / "guests"
        guests.mkdir(exist_ok=True)
        runs = json.loads(self.cmd.run(["bash", SCRIPTS / "list-zkevm-workload-runs.sh", "--json"]))
        for zkvm in sorted({r["zkvm"] for r in runs}):
            self.run(f"pull-ere-{zkvm}", ["docker", "pull", inventory[zkvm]["image"]])
        for run in runs:
            client, zkvm = run["execution_client"], run["zkvm"]
            for suffix in ("elf", "vk"):
                name = f"stateless-validator-{client}-{zkvm}-{inventory[zkvm]['sdk']}.{suffix}"
                self.run("download-" + name, ["curl", "--fail", "--show-error", "--location", "--retry", "3",
                         "--output", guests / name, f"https://github.com/eth-act/ere-guests/releases/download/{GUEST_TAG}/{name}"])
        resolved = read_json(self.inputs / "resolved.json")
        images = {}
        for name, client in resolved["clients"].items():
            context = self.inputs / "build" / name
            shutil.copytree(hive / "clients" / client["hive_client"], context)
            dockerfile = context / "Dockerfile.git"
            directory = client["repo"].rstrip("/").split("/")[-1].removesuffix(".git")
            dockerfile.write_text(pin_dockerfile(dockerfile.read_text(), directory))
            image = f"eest-smoke/{name}:{client['commit']}-{resolved['hive']['commit'][:7]}"
            args = ["docker", "build", "--pull", "-f", dockerfile, "-t", image,
                    "--label", f"org.opencontainers.image.revision={client['commit']}",
                    "--label", f"eest.smoke.ref={client['ref']}",
                    "--label", f"eest.smoke.hive={resolved['hive']['commit']}"]
            build_args = (client.get("build_args") or {}) | {"github": client["github"], "tag": client["commit"]}
            for key, value in build_args.items():
                args += ["--build-arg", f"{key}={value}"]
            self.run("build-" + name, [*args, context])
            images[name] = json.loads(self.cmd.run(["docker", "image", "inspect", image]))[0]["Id"]
            resolved["clients"][name]["image_id"] = images[name]
            self.run("version-" + name, ["docker", "run", "--pull=never", "--rm", "--entrypoint", "cat", images[name], "/version.txt"])
        self.run("build-hiveproxy", ["docker", "build", "--pull", "-t", "hive/hiveproxy:latest", hive / "hiveproxy"])
        write_json(self.inputs / "client-images.json", images)
        write_json(self.inputs / "resolved.json", resolved)


def main():
    if os.environ.get("GITHUB_EVENT_NAME") != "pull_request":
        raise SmokeError("online preparation is restricted to pull_request jobs")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("sources", "assets"))
    args = parser.parse_args()
    getattr(Prepare(), args.stage)()


if __name__ == "__main__":
    try:
        main()
    except (SmokeError, OSError, ValueError, KeyError) as exc:
        print(f"CI preparation failed: {exc}", file=sys.stderr)
        sys.exit(1)
