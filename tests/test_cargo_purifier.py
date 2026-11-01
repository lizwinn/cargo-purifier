# SPDX-License-Identifier: MIT
"""Unit tests of cargo_purify: the parsing of Cargo.lock sources, the URLs
git dependencies are fetched from, cargo's configuration, and the publish
request."""

import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cargo_purifier as cargo_purify


class GitSource(unittest.TestCase):
    def parse(self, source):
        match = cargo_purify.GIT_SOURCE.fullmatch(source)
        return match and (match.group(1), match.group(2))

    def test_reference_kinds(self):
        rev = "12746aa88cc51a6f1fc97f92b8d36d991c2d966e"
        for query in ("", "?tag=1.0.18", "?branch=main", "?rev=12746aa"):
            self.assertEqual(
                self.parse(f"git+https://github.com/dtolnay/ryu{query}#{rev}"),
                ("https://github.com/dtolnay/ryu", rev),
            )

    def test_not_git(self):
        self.assertIsNone(self.parse("registry+https://github.com/rust-lang/crates.io-index"))
        self.assertIsNone(self.parse("git+https://example.com/repo"))


class FetchUrl(unittest.TestCase):
    def test_https_unchanged(self):
        self.assertEqual(cargo_purify.fetch_url("https://github.com/a/b"), "https://github.com/a/b")
        self.assertEqual(cargo_purify.fetch_url("file:///tmp/repo"), "file:///tmp/repo")

    def test_ssh_becomes_https(self):
        self.assertEqual(cargo_purify.fetch_url("ssh://git@github.com/a/b"), "https://github.com/a/b")
        self.assertEqual(cargo_purify.fetch_url("ssh://git@example.com:2222/a/b.git"), "https://example.com/a/b.git")
        self.assertEqual(cargo_purify.fetch_url("ssh://example.com/a"), "https://example.com/a")


class VersionReq(unittest.TestCase):
    def test_bare_version_is_caret(self):
        self.assertEqual(cargo_purify.version_req("1"), "^1")
        self.assertEqual(cargo_purify.version_req("1.2.3"), "^1.2.3")

    def test_operators_kept(self):
        self.assertEqual(cargo_purify.version_req("=1.0.0"), "=1.0.0")
        self.assertEqual(cargo_purify.version_req(">=1, <2"), ">=1, <2")
        self.assertEqual(cargo_purify.version_req("~1.2"), "~1.2")
        self.assertEqual(cargo_purify.version_req("*"), "*")


class SriSha256(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(cargo_purify.sri_sha256(b""), "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")


def make_crate(files):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as archive:
        for name, text in files.items():
            encoded = text.encode()
            info = tarfile.TarInfo(name)
            info.size = len(encoded)
            archive.addfile(info, io.BytesIO(encoded))
    return data.getvalue()


MANIFEST = """
[package]
name = "greet"
version = "0.1.0"
description = "Greets"
license = "MIT"
readme = "README.md"
keywords = ["hello"]

[dependencies.itoa]
version = "1"

[dependencies.renamed]
version = "0.2"
package = "real-name"
optional = true
default-features = false
features = ["x"]

[dependencies.private]
version = "3"
registry-index = "sparse+https://registry.example/index/"

[dev-dependencies.tester]
version = "=2.0.0"

[target.'cfg(unix)'.dependencies.libc]
version = "0.2"

[features]
default = []
extra = ["renamed"]
"""


class PublishMetadata(unittest.TestCase):
    def setUp(self):
        crate = make_crate({"greet-0.1.0/Cargo.toml": MANIFEST, "greet-0.1.0/README.md": "# greet\n"})
        self.manifest, self.readme = cargo_purify.crate_contents(crate)

    def metadata(self, index=cargo_purify.CRATES_IO_INDEX):
        return cargo_purify.publish_metadata(self.manifest, self.readme, index)

    def dep(self, metadata, name):
        [dep] = [d for d in metadata["deps"] if d["name"] == name]
        return dep

    def test_package_fields(self):
        metadata = self.metadata()
        self.assertEqual((metadata["name"], metadata["vers"]), ("greet", "0.1.0"))
        self.assertEqual(metadata["readme"], "# greet\n")
        self.assertEqual(metadata["readme_file"], "README.md")
        self.assertEqual(metadata["keywords"], ["hello"])
        self.assertEqual(metadata["features"], {"default": [], "extra": ["renamed"]})

    def test_dependencies(self):
        metadata = self.metadata()
        itoa = self.dep(metadata, "itoa")
        self.assertEqual((itoa["version_req"], itoa["kind"], itoa["registry"]), ("^1", "normal", None))
        renamed = self.dep(metadata, "real-name")
        self.assertEqual(renamed["explicit_name_in_toml"], "renamed")
        self.assertTrue(renamed["optional"])
        self.assertFalse(renamed["default_features"])
        self.assertEqual(renamed["features"], ["x"])
        self.assertEqual(self.dep(metadata, "tester")["kind"], "dev")
        self.assertEqual(self.dep(metadata, "libc")["target"], "cfg(unix)")
        self.assertEqual(self.dep(metadata, "private")["registry"], "sparse+https://registry.example/index/")

    def test_registry_of_dependencies_for_another_registry(self):
        metadata = self.metadata("sparse+https://registry.example/index/")
        self.assertEqual(self.dep(metadata, "itoa")["registry"], cargo_purify.CRATES_IO_INDEX)
        self.assertIsNone(self.dep(metadata, "private")["registry"])

    def test_body(self):
        metadata = self.metadata()
        body = cargo_purify.publish_body(metadata, b"crate bytes")
        length = int.from_bytes(body[:4], "little")
        self.assertEqual(json.loads(body[4:4 + length]), metadata)
        self.assertEqual(int.from_bytes(body[4 + length:8 + length], "little"), 11)
        self.assertEqual(body[8 + length:], b"crate bytes")

    def test_crate_without_manifest(self):
        with self.assertRaises(cargo_purify.Failure):
            cargo_purify.crate_contents(make_crate({"greet-0.1.0/src/lib.rs": ""}))


class Config(unittest.TestCase):
    def test_registries_and_tokens(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "workspace"
            home = Path(directory) / "cargo-home"
            (root / ".cargo").mkdir(parents=True)
            home.mkdir()
            (root / ".cargo" / "config.toml").write_text(
                '[registries.local]\nindex = "sparse+https://local.example/index/"\n'
            )
            (home / "config.toml").write_text(
                '[registries.local]\nindex = "https://overridden.example"\n'
                '[registries.git-index]\nindex = "https://git.example/index"\n'
            )
            (home / "credentials.toml").write_text('[registries.git-index]\ntoken = "from-file"\n')
            environment = {"CARGO_HOME": str(home), "CARGO_REGISTRIES_LOCAL_TOKEN": "from-env"}
            with mock.patch.dict(os.environ, environment, clear=True):
                config = cargo_purify.CargoConfig(root)
        # The workspace configuration takes precedence over the one in
        # CARGO_HOME.
        self.assertEqual(config.indexes["local"], "sparse+https://local.example/index/")
        self.assertEqual(config.name_of_source("sparse+https://local.example/index/"), "local")
        self.assertEqual(config.name_of_source("registry+https://git.example/index"), "git-index")
        self.assertEqual(config.token_for_source("sparse+https://local.example/index/"), "from-env")
        self.assertEqual(config.tokens["git-index"], "from-file")
        self.assertIsNone(config.name_of_source("sparse+https://unknown.example/"))


class Lockfile(unittest.TestCase):
    def write(self, directory, lock, cargo_lock=b"version = 4\n"):
        root = Path(directory)
        (root / "Cargo.lock").write_bytes(cargo_lock)
        path = root / cargo_purify.LOCK_NAME
        path.write_text(lock if isinstance(lock, str) else json.dumps(lock))
        return root, path

    def lock(self):
        lock = {
            "version": 1,
            "cargoLock": cargo_purify.sri_sha256(b"version = 4\n"),
            "git": [],
            "registries": {},
            "packages": {"hello": {"bins": ["hello"], "lib": None}},
        }
        lock["contentHash"] = cargo_purify.content_hash(lock)
        return lock

    def test_content_hash_ignores_itself_and_key_order(self):
        lock = self.lock()
        reordered = dict(reversed(list(lock.items())))
        self.assertEqual(cargo_purify.content_hash(reordered), lock["contentHash"])
        self.assertNotEqual(cargo_purify.content_hash(lock | {"git": [{"path": "x"}]}), lock["contentHash"])

    def test_accepts_a_written_lockfile(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.write(directory, self.lock())
            self.assertEqual(cargo_purify.checked_lock(root / "Cargo.lock", path)["packages"]["hello"]["bins"], ["hello"])

    def refusal(self, lock, cargo_lock=b"version = 4\n"):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.write(directory, lock, cargo_lock)
            with self.assertRaises(cargo_purify.Failure) as raised:
                cargo_purify.checked_lock(root / "Cargo.lock", path)
            return str(raised.exception)

    def test_refusals_name_the_command(self):
        tampered = self.lock() | {"git": [{"path": "git/x"}]}
        cases = {
            "malformed": ('{ "version": 1, ', b"version = 4\n", "is not valid JSON"),
            "tampered": (tampered, b"version = 4\n", "was changed after `cargo-purifier lock` wrote it"),
            "stale": (self.lock(), b"version = 4\n# edited\n", "was made from a different Cargo.lock"),
            "other format": (self.lock() | {"version": 2}, b"version = 4\n", "is not a cargo-purifier lockfile"),
        }
        for name, (lock, cargo_lock, expected) in cases.items():
            with self.subTest(name):
                message = self.refusal(lock, cargo_lock)
                self.assertIn(expected, message)
                self.assertIn("`cargo-purifier lock`", message)



class OutsideCargoLock(unittest.TestCase):
    def test_writes_outside_and_keeps_the_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "tree"
            root.mkdir()
            (root / "Cargo.lock").write_bytes(b"tree\n")
            outside = Path(directory) / "outside" / "Cargo.lock"
            seen = []
            for result in (b"first\n", b"second\n"):
                with cargo_purify.cargo_lock_in_tree(root, outside):
                    seen.append((root / "Cargo.lock").read_bytes())
                    (root / "Cargo.lock").write_bytes(result)
                self.assertEqual(outside.read_bytes(), result)
                self.assertEqual((root / "Cargo.lock").read_bytes(), b"tree\n")
            # The first run starts from the tree's copy, and the second from
            # the outside copy the first one wrote.
            self.assertEqual(seen, [b"tree\n", b"first\n"])

    def test_a_tree_without_cargo_lock_stays_without(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "elsewhere.lock"
            with cargo_purify.cargo_lock_in_tree(root, outside):
                (root / "Cargo.lock").write_bytes(b"made\n")
            self.assertEqual(outside.read_bytes(), b"made\n")
            self.assertFalse((root / "Cargo.lock").exists())

    def test_a_failed_command_writes_nothing_outside(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Cargo.lock").write_bytes(b"tree\n")
            outside = root / "elsewhere.lock"
            with self.assertRaises(RuntimeError):
                with cargo_purify.cargo_lock_in_tree(root, outside):
                    (root / "Cargo.lock").write_bytes(b"half\n")
                    raise RuntimeError
            self.assertFalse(outside.exists())
            self.assertEqual((root / "Cargo.lock").read_bytes(), b"tree\n")


if __name__ == "__main__":
    unittest.main()
