#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the test fixtures with this checkout's `cargo purify`, then writes
# tests/fixtures/stale/Cargo.lock: the workspace's Cargo.lock with one
# extra line, which no purifier lockfile was made from.
#
# Run it from the repository root: tests/relock-fixtures.sh
set -euo pipefail

cargo=$(nix build --no-link --print-out-paths '.#cargo')/bin/cargo

"$cargo" purify --manifest-path tests/fixtures/workspace/Cargo.toml

mkdir -p tests/fixtures/stale
{
  cat tests/fixtures/workspace/Cargo.lock
  echo '# changed after cargo purify'
} >tests/fixtures/stale/Cargo.lock
