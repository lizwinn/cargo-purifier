# SPDX-License-Identifier: MIT
"""cargo purify: write cargo-purifier.lock.json at the workspace root.

Cargo.lock already pins every crates.io download by name, version and
checksum, so the purifier lockfile records only what Cargo.lock leaves out:
the NAR hash of each git dependency's checkout, and the workspace's packages
with their binaries. It also records the hash of the Cargo.lock it read, so
a Nix build can tell when the two files no longer belong together.

Usage: cargo purify [--manifest-path <path>]
"""

import argparse
import base64
import hashlib
import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

LOCK_NAME = "cargo-purifier.lock.json"
FORMAT = 1
# A git source in Cargo.lock: git+<url>[?rev=…|?tag=…|?branch=…]#<commit>
GIT_SOURCE = re.compile(r"git\+([^?#]+)(?:\?[^#]*)?#([0-9a-f]+)")
LIB_KINDS = {"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"}


def run(command, capture=True):
    result = subprocess.run(command, check=True, text=True, capture_output=capture)
    return result.stdout if capture else None


def sri_sha256(data):
    return "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()


def git_hash(url, rev):
    """The NAR hash of a checkout with its submodules, as nixpkgs fetchgit
    computes it."""
    out = run(["nix-prefetch-git", "--url", url, "--rev", rev, "--fetch-submodules", "--quiet"])
    return json.loads(out)["hash"]


def main(argv):
    args = argv[1:]
    # cargo runs an external subcommand with the subcommand's name first.
    if args[:1] == ["purify"]:
        args = args[1:]
    parser = argparse.ArgumentParser(prog="cargo purify", description=__doc__.splitlines()[0])
    parser.add_argument("--manifest-path", help="a Cargo.toml of the workspace")
    options = parser.parse_args(args)
    manifest = ["--manifest-path", options.manifest_path] if options.manifest_path else []

    root_manifest = run(["cargo", "locate-project", "--workspace", "--message-format", "plain", *manifest]).strip()
    root = Path(root_manifest).parent
    workspace = ["--manifest-path", root_manifest]

    # Brings Cargo.lock up to date with the manifests, changing no more than
    # it must, and downloads what it names. Its output goes to the terminal.
    run(["cargo", "fetch", *workspace], capture=False)

    metadata = json.loads(run(["cargo", "metadata", "--format-version", "1", "--no-deps", "--locked", *workspace]))
    members = set(metadata["workspace_members"])
    packages = {}
    for package in metadata["packages"]:
        if package["id"] not in members:
            continue
        targets = package["targets"]
        packages[package["name"]] = {
            "manifest": Path(package["manifest_path"]).relative_to(root).as_posix(),
            "bins": sorted(t["name"] for t in targets if "bin" in t["kind"]),
            "lib": any(kind in LIB_KINDS for t in targets for kind in t["kind"]),
        }

    cargo_lock_bytes = (root / "Cargo.lock").read_bytes()
    cargo_lock = tomllib.loads(cargo_lock_bytes.decode())

    lock_path = root / LOCK_NAME
    previous = {}
    if lock_path.exists():
        try:
            for entry in json.loads(lock_path.read_text()).get("git", []):
                previous[(entry["git"]["url"], entry["git"]["rev"])] = entry["hash"]
        except (ValueError, KeyError, TypeError):
            previous = {}

    checkouts = set()
    for package in cargo_lock.get("package", []):
        source = package.get("source", "")
        if source.startswith("git+"):
            match = GIT_SOURCE.fullmatch(source)
            if not match:
                sys.exit(f"cargo purify: cannot read the git source {source!r} of {package['name']}")
            checkouts.add((match.group(1), match.group(2)))

    git = []
    for url, rev in sorted(checkouts):
        digest = previous.get((url, rev))
        if digest is None:
            print(f"cargo purify: hashing {url} at {rev}", file=sys.stderr)
            digest = git_hash(url, rev)
        git.append({
            "path": f"git/{rev}",
            "git": {"url": url, "rev": rev, "submodules": True},
            "hash": digest,
        })

    lock = {
        "version": FORMAT,
        "cargoLock": sri_sha256(cargo_lock_bytes),
        "git": git,
        "packages": packages,
    }
    lock_path.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")
    print(f"cargo purify: wrote {lock_path}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            sys.stderr.write(error.stderr)
        sys.exit(f"cargo purify: {' '.join(error.cmd)} failed")
