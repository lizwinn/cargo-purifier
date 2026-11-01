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

import cargo_purify


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


if __name__ == "__main__":
    unittest.main()
