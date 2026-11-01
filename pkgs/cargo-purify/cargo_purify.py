# SPDX-License-Identifier: MIT
"""cargo purify: lock a cargo workspace for Nix, and publish what Nix packaged.

`cargo purify` writes cargo-purifier.lock.json at the workspace root.
Cargo.lock already pins every registry download by name, version and
checksum, so the purifier lockfile records only what Cargo.lock leaves out:
the NAR hash of each git dependency's checkout, the download URL template
of each registry other than crates.io, and the workspace's packages with
their binaries. It also records the hash of the Cargo.lock it read, so a
Nix build can tell when the two files no longer belong together.

`cargo purify publish` has Nix package a workspace package as a .crate,
the way `cargo package` does in the sandbox, and uploads that file to the
registry with the registry's publish API.
"""

import argparse
import base64
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

LOCK_NAME = "cargo-purifier.lock.json"
FORMAT = 1
CRATES_IO_INDEX = "https://github.com/rust-lang/crates.io-index"
CRATES_IO_SOURCE = "registry+" + CRATES_IO_INDEX
CRATES_IO_API = "https://crates.io"
# A git source in Cargo.lock: git+<url>[?rev=…|?tag=…|?branch=…]#<commit>
GIT_SOURCE = re.compile(r"git\+([^?#]+)(?:\?[^#]*)?#([0-9a-f]+)")
LIB_KINDS = {"lib", "rlib", "dylib", "cdylib", "staticlib", "proc-macro"}


class Failure(Exception):
    pass


def run(command, capture=True, cwd=None):
    result = subprocess.run(command, check=True, text=True, capture_output=capture, cwd=cwd)
    return result.stdout if capture else None


def sri_sha256(data):
    return "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode()


def cargo_home():
    return Path(os.environ.get("CARGO_HOME") or Path.home() / ".cargo")


def env_name(name):
    return re.sub(r"[^A-Z0-9]", "_", name.upper())


class CargoConfig:
    """The registries and tokens cargo would read for a workspace: from
    .cargo/config.toml in the workspace root and its ancestors, from
    $CARGO_HOME/config.toml, from $CARGO_HOME/credentials.toml and from
    CARGO_REGISTRIES_<NAME>_* and CARGO_REGISTRY_TOKEN."""

    def __init__(self, root):
        self.indexes = {}
        self.tokens = {}
        files = []
        for directory in [root, *root.parents]:
            for name in ("config.toml", "config"):
                path = directory / ".cargo" / name
                if path.is_file():
                    files.append(path)
                    break
        for name in ("config.toml", "config"):
            path = cargo_home() / name
            if path.is_file() and path not in files:
                files.append(path)
                break
        # Files nearer the workspace take precedence.
        for path in reversed(files):
            data = tomllib.loads(path.read_text())
            for name, registry in data.get("registries", {}).items():
                if "index" in registry:
                    self.indexes[name] = registry["index"]
                if "token" in registry:
                    self.tokens[name] = registry["token"]
            if "token" in data.get("registry", {}):
                self.tokens["crates-io"] = data["registry"]["token"]
        for name in ("credentials.toml", "credentials"):
            path = cargo_home() / name
            if path.is_file():
                data = tomllib.loads(path.read_text())
                for registry_name, registry in data.get("registries", {}).items():
                    if "token" in registry:
                        self.tokens[registry_name] = registry["token"]
                if "token" in data.get("registry", {}):
                    self.tokens["crates-io"] = data["registry"]["token"]
                break
        prefix = "CARGO_REGISTRIES_"
        for key, value in os.environ.items():
            if key.startswith(prefix) and key.endswith("_INDEX"):
                wanted = key[len(prefix):-len("_INDEX")]
                for name in list(self.indexes) or []:
                    if env_name(name) == wanted:
                        self.indexes[name] = value
        if os.environ.get("CARGO_REGISTRY_TOKEN"):
            self.tokens["crates-io"] = os.environ["CARGO_REGISTRY_TOKEN"]
        for name in self.indexes:
            token = os.environ.get(f"CARGO_REGISTRIES_{env_name(name)}_TOKEN")
            if token:
                self.tokens[name] = token

    def name_of_source(self, source):
        """The configured name of the registry a Cargo.lock source names."""
        for name, index in self.indexes.items():
            if source in (index, "registry+" + index):
                return name
        return None

    def token_for_source(self, source):
        name = self.name_of_source(source)
        return self.tokens.get(name) if name else None


def http_get(url, token=None):
    request = urllib.request.Request(url)
    if token:
        request.add_header("Authorization", token)
    with urllib.request.urlopen(request) as response:
        return response.read()


def index_config(source, config):
    """The index configuration (config.json) of the registry a Cargo.lock
    source names: over HTTP for a sparse index, from a shallow clone for a
    git index."""
    if source.startswith("sparse+"):
        url = source[len("sparse+"):]
        if not url.endswith("/"):
            url += "/"
        try:
            return json.loads(http_get(url + "config.json"))
        except urllib.error.HTTPError as error:
            token = config.token_for_source(source)
            if error.code in (401, 403) and token:
                return json.loads(http_get(url + "config.json", token))
            raise Failure(f"cannot read {url}config.json: {error}") from error
    if source.startswith("registry+"):
        url = source[len("registry+"):]
        with tempfile.TemporaryDirectory() as directory:
            run(["git", "clone", "--quiet", "--depth", "1", url, directory])
            return json.loads((Path(directory) / "config.json").read_text())
    raise Failure(f"{source} is not a registry")


def fetch_url(url):
    """The URL a Nix build fetches a git dependency from. The sandbox holds
    no SSH keys, so an ssh:// dependency is fetched over HTTPS from the same
    host and path."""
    if not url.startswith("ssh://"):
        return url
    authority, _, path = url[len("ssh://"):].partition("/")
    host = authority.rsplit("@", 1)[-1].split(":", 1)[0]
    return f"https://{host}/{path}"


def git_hash(url, rev):
    """The NAR hash of a checkout with its submodules, as nixpkgs fetchgit
    computes it."""
    out = run([
        "nix-prefetch-git", "--url", url, "--rev", rev,
        "--fetch-submodules", "--no-add-path", "--quiet",
    ])
    return json.loads(out)["hash"]


def workspace_root(manifest_path):
    """The workspace root and its Cargo.toml. cargo reads its configuration
    from the current directory and its ancestors, so cargo runs from the
    manifest's directory here and from the workspace root afterwards."""
    if manifest_path:
        manifest = Path(manifest_path).resolve()
        found = run(["cargo", "locate-project", "--workspace", "--message-format", "plain",
                     "--manifest-path", str(manifest)], cwd=manifest.parent)
    else:
        found = run(["cargo", "locate-project", "--workspace", "--message-format", "plain"])
    root_manifest = found.strip()
    return Path(root_manifest).parent, root_manifest


def lock(options):
    root, root_manifest = workspace_root(options.manifest_path)
    workspace = ["--manifest-path", root_manifest]

    # Brings Cargo.lock up to date with the manifests, changing no more than
    # it must, and downloads what it names. Its output goes to the terminal.
    run(["cargo", "fetch", *workspace], capture=False, cwd=root)

    metadata = json.loads(run(["cargo", "metadata", "--format-version", "1", "--no-deps", "--locked", *workspace],
                              cwd=root))
    members = set(metadata["workspace_members"])
    packages = {}
    for package in metadata["packages"]:
        if package["id"] not in members:
            continue
        targets = package["targets"]
        libs = [t for t in targets if LIB_KINDS & set(t["kind"])]
        packages[package["name"]] = {
            "manifest": Path(package["manifest_path"]).relative_to(root).as_posix(),
            "bins": sorted(t["name"] for t in targets if "bin" in t["kind"]),
            # The library target, whose name the files cargo writes for it
            # carry, with '-' as '_'.
            "lib": {
                "name": libs[0]["name"].replace("-", "_"),
                "kinds": sorted(libs[0]["crate_types"]),
            } if libs else None,
        }

    cargo_lock_bytes = (root / "Cargo.lock").read_bytes()
    cargo_lock = tomllib.loads(cargo_lock_bytes.decode())

    lock_path = root / LOCK_NAME
    previous_git = {}
    previous_registries = {}
    if lock_path.exists():
        try:
            previous = json.loads(lock_path.read_text())
            for entry in previous.get("git", []):
                previous_git[(entry["git"]["url"], entry["git"]["rev"])] = entry["hash"]
            previous_registries = previous.get("registries", {})
        except (ValueError, KeyError, TypeError):
            previous_git, previous_registries = {}, {}

    checkouts = set()
    registry_sources = set()
    for package in cargo_lock.get("package", []):
        source = package.get("source", "")
        if source.startswith("git+"):
            match = GIT_SOURCE.fullmatch(source)
            if not match:
                raise Failure(f"cannot read the git source {source!r} of {package['name']}")
            checkouts.add((fetch_url(match.group(1)), match.group(2)))
        elif source.startswith(("registry+", "sparse+")) and source != CRATES_IO_SOURCE:
            registry_sources.add(source)

    git = []
    for url, rev in sorted(checkouts):
        digest = previous_git.get((url, rev))
        if digest is None:
            print(f"cargo purify: hashing {url} at {rev}", file=sys.stderr)
            digest = git_hash(url, rev)
        git.append({
            "path": f"git/{rev}",
            # cargo reads a checkout's files and never its .git directory.
            "git": {"url": url, "rev": rev, "submodules": True, "leaveDotGit": False, "commitObject": None},
            "hash": digest,
        })

    config = CargoConfig(root)
    registries = {}
    for source in sorted(registry_sources):
        print(f"cargo purify: reading the index configuration of {source}", file=sys.stderr)
        try:
            dl = index_config(source, config)["dl"]
        except (Failure, OSError, subprocess.CalledProcessError, KeyError, ValueError):
            if source not in previous_registries:
                raise
            print(f"cargo purify: keeping the recorded configuration of {source}", file=sys.stderr)
            dl = previous_registries[source]["dl"]
        registries[source] = {"dl": dl}

    result = {
        "version": FORMAT,
        "cargoLock": sri_sha256(cargo_lock_bytes),
        "git": git,
        "registries": registries,
        "packages": packages,
    }
    lock_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"cargo purify: wrote {lock_path}", file=sys.stderr)


def version_req(requirement):
    """A requirement as cargo sends it: a bare version means a caret
    requirement."""
    parts = []
    for part in requirement.split(","):
        part = part.strip()
        parts.append("^" + part if part[:1].isdigit() else part)
    return ", ".join(parts)


def member_text(archive, member):
    """A regular file of a tar archive, as text; KeyError when it is
    missing or not a regular file."""
    file = archive.extractfile(member)
    if file is None:
        raise KeyError(member)
    return file.read().decode()


def crate_contents(crate_bytes):
    with tarfile.open(fileobj=io.BytesIO(crate_bytes), mode="r:gz") as archive:
        manifests = [m for m in archive.getmembers() if m.name.count("/") == 1 and m.name.endswith("/Cargo.toml")]
        if len(manifests) != 1:
            raise Failure("the crate has no Cargo.toml at its top level")
        top = manifests[0].name.split("/")[0]
        manifest = tomllib.loads(member_text(archive, manifests[0]))
        readme = manifest.get("package", {}).get("readme")
        readme_text = None
        if isinstance(readme, str):
            try:
                readme_text = member_text(archive, f"{top}/{readme}")
            except KeyError:
                readme_text = None
        return manifest, readme_text


def publish_metadata(manifest, readme_text, target_index):
    """The JSON part of a publish request, as cargo builds it from the
    crate's normalized Cargo.toml."""
    package = manifest["package"]
    deps = []

    def add(table, kind, target):
        for key, spec in (table or {}).items():
            if isinstance(spec, str):
                spec = {"version": spec}
            if "version" not in spec:
                continue
            index = spec.get("registry-index", CRATES_IO_INDEX)
            deps.append({
                "optional": spec.get("optional", False),
                "default_features": spec.get("default-features", True),
                "name": spec.get("package", key),
                "features": spec.get("features", []),
                "version_req": version_req(spec["version"]),
                "target": target,
                "kind": kind,
                "registry": None if index == target_index else index,
                "explicit_name_in_toml": key if "package" in spec else None,
            })

    for kind, key in (("normal", "dependencies"), ("dev", "dev-dependencies"), ("build", "build-dependencies")):
        add(manifest.get(key), kind, None)
        for target, tables in manifest.get("target", {}).items():
            add(tables.get(key), kind, target)

    readme = package.get("readme")
    return {
        "name": package["name"],
        "vers": package["version"],
        "deps": deps,
        "features": manifest.get("features", {}),
        "authors": package.get("authors", []),
        "description": package.get("description"),
        "documentation": package.get("documentation"),
        "homepage": package.get("homepage"),
        "readme": readme_text,
        "readme_file": readme if isinstance(readme, str) else None,
        "keywords": package.get("keywords", []),
        "categories": package.get("categories", []),
        "license": package.get("license"),
        "license_file": package.get("license-file"),
        "repository": package.get("repository"),
        "badges": {},
        "links": package.get("links"),
        "rust_version": package.get("rust-version"),
    }


def publish_body(metadata, crate_bytes):
    encoded = json.dumps(metadata).encode()
    return (
        len(encoded).to_bytes(4, "little") + encoded
        + len(crate_bytes).to_bytes(4, "little") + crate_bytes
    )


def nix_crate(root, package):
    """The .crate file Nix packages for a workspace package."""
    out = run([
        "nix-build", "--no-out-link", os.environ["CARGO_PURIFY_CRATE_EXPR"],
        "--arg", "nixpkgs", os.environ["CARGO_PURIFY_NIXPKGS"],
        "--argstr", "system", os.environ["CARGO_PURIFY_SYSTEM"],
        "--argstr", "root", str(root),
        "--argstr", "package", package,
    ]).strip()
    crates = list(Path(out).glob("*.crate"))
    if len(crates) != 1:
        raise Failure(f"{out} holds no single .crate file")
    return crates[0]


def publish(options):
    root, _ = workspace_root(options.manifest_path)
    config = CargoConfig(root)
    lock_data = json.loads((root / LOCK_NAME).read_text()) if (root / LOCK_NAME).exists() else None

    if options.crate:
        crate_path = Path(options.crate)
    else:
        if lock_data is None:
            raise Failure(f"{root / LOCK_NAME} is missing. Run `cargo purify` first.")
        package = options.package
        if package is None:
            names = sorted(lock_data["packages"])
            if len(names) != 1:
                raise Failure(f"the workspace has several packages ({', '.join(names)}); choose one with --package")
            package = names[0]
        print(f"cargo purify: packaging {package} with Nix", file=sys.stderr)
        crate_path = nix_crate(root, package)
    crate_bytes = crate_path.read_bytes()

    if options.registry:
        if options.registry not in config.indexes:
            raise Failure(f"no registry named {options.registry} is configured")
        index_url = config.indexes[options.registry]
        source = index_url if index_url.startswith("sparse+") else "registry+" + index_url
        api = index_config(source, config).get("api")
        if not api:
            raise Failure(f"the registry {options.registry} does not accept publishing")
        token = config.tokens.get(options.registry)
        target_index = index_url
    else:
        api = CRATES_IO_API
        token = config.tokens.get("crates-io")
        target_index = CRATES_IO_INDEX

    manifest, readme_text = crate_contents(crate_bytes)
    metadata = publish_metadata(manifest, readme_text, target_index)
    print(f"cargo purify: {crate_path} is {metadata['name']} {metadata['vers']}", file=sys.stderr)
    if options.dry_run:
        print(json.dumps(metadata, indent=2, sort_keys=True))
        return
    if not token:
        raise Failure("no token for the registry; run `cargo login`, or set CARGO_REGISTRY_TOKEN "
                      "or CARGO_REGISTRIES_<NAME>_TOKEN")

    request = urllib.request.Request(
        api.rstrip("/") + "/api/v1/crates/new",
        data=publish_body(metadata, crate_bytes),
        method="PUT",
        headers={"Authorization": token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request) as response:
            answer = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        try:
            details = "; ".join(e.get("detail", "") for e in json.loads(body).get("errors", []))
        except ValueError:
            details = body
        raise Failure(f"the registry refused the upload ({error.code}): {details}") from error
    for kind, items in (answer.get("warnings") or {}).items():
        for item in items:
            print(f"cargo purify: warning from the registry ({kind}): {item}", file=sys.stderr)
    print(f"cargo purify: published {metadata['name']} {metadata['vers']}", file=sys.stderr)


def main(argv):
    args = argv[1:]
    # cargo runs an external subcommand with the subcommand's name first.
    if args[:1] == ["purify"]:
        args = args[1:]
    parser = argparse.ArgumentParser(prog="cargo purify", description=__doc__.splitlines()[0])
    parser.add_argument("--manifest-path", help="a Cargo.toml of the workspace")
    commands = parser.add_subparsers(dest="command")
    publisher = commands.add_parser("publish", help="upload the .crate Nix packages for a workspace package")
    publisher.add_argument("--manifest-path", help="a Cargo.toml of the workspace")
    publisher.add_argument("-p", "--package", help="the workspace package to publish")
    publisher.add_argument("--registry", help="a registry configured in cargo's configuration; crates.io by default")
    publisher.add_argument("--crate", help="a .crate file to upload instead of the one Nix packages")
    publisher.add_argument("--dry-run", action="store_true", help="print the publish metadata and upload nothing")
    options = parser.parse_args(args)
    if options.command == "publish":
        publish(options)
    else:
        lock(options)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            sys.stderr.write(error.stderr)
        sys.exit(f"cargo purify: {' '.join(error.cmd)} failed")
    except Failure as error:
        sys.exit(f"cargo purify: {error}")
