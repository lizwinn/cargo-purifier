# SPDX-License-Identifier: MIT
"""Checks what the local-registry check produced: the purifier lockfile
`cargo purify` wrote, and the publish request `cargo purify publish` sent.

Usage: check-local-registry.py <lockfile> <index url> <dl template>
           <git dependency url> <upload> <authorization> <crate>
"""

import json
import sys
from pathlib import Path

lockfile, index, dl, git_url, upload, authorization, crate = sys.argv[1:]

lock = json.loads(Path(lockfile).read_text())
source = "registry+" + index
assert lock["registries"] == {source: {"dl": dl}}, lock["registries"]
[git] = lock["git"]
assert git["git"]["url"] == git_url and git["git"]["submodules"] is True, git
assert git["hash"].startswith("sha256-") and git["path"] == "git/" + git["git"]["rev"], git
assert lock["packages"]["app"] == {"bins": ["app"], "lib": None, "manifest": "Cargo.toml"}, lock["packages"]

body = Path(upload).read_bytes()
length = int.from_bytes(body[:4], "little")
metadata = json.loads(body[4:4 + length])
rest = body[4 + length:]
crate_length = int.from_bytes(rest[:4], "little")
assert rest[4:4 + crate_length] == Path(crate).read_bytes(), "the upload is not the crate Nix packaged"
assert len(rest) == 4 + crate_length
assert (metadata["name"], metadata["vers"]) == ("greet", "0.1.0"), metadata
[dep] = metadata["deps"]
assert dep["name"] == "itoa" and dep["version_req"] == "^1" and dep["kind"] == "normal", dep
# A crates.io dependency of a crate published elsewhere names crates.io.
assert dep["registry"] == "https://github.com/rust-lang/crates.io-index", dep
assert Path(authorization).read_text() == "local-registry-token"
print("local registry: lockfile and upload as expected")
