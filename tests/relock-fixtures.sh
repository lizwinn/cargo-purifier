#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the test fixtures with this checkout's `cargo-purifier lock`.
#
# The workspace fixture is locked from its manifests. The registry and ssh
# fixtures have hand-written lockfiles, because the registry they name does
# not exist and the SSH host needs keys, so only their content hash is
# written again. Last, tests/fixtures/stale/Cargo.lock is the workspace's
# Cargo.lock with one extra line, which no purifier lockfile was made from.
#
# Run it from the repository root: tests/relock-fixtures.sh
set -euo pipefail

tools=$(nix build --no-link --print-out-paths '.#cargo-purifier')

"$tools/bin/cargo-purifier" lock --manifest-path tests/fixtures/workspace/Cargo.toml

python3 - tests/fixtures/registry/cargo-purifier.lock.json tests/fixtures/ssh/cargo-purifier.lock.json <<'EOF'
import json, sys
sys.path.insert(0, "pkgs/cargo-purifier")
import cargo_purifier
for path in sys.argv[1:]:
    with open(path) as file:
        lock = json.load(file)
    lock["contentHash"] = cargo_purifier.content_hash(lock)
    with open(path, "w") as file:
        file.write(json.dumps(lock, indent=2, sort_keys=True) + "\n")
EOF

mkdir -p tests/fixtures/stale
{
  cat tests/fixtures/workspace/Cargo.lock
  echo '# changed after cargo-purifier lock'
} >tests/fixtures/stale/Cargo.lock
