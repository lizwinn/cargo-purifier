# SPDX-License-Identifier: MIT
#
# The vendored sources of a workspace: every crate its Cargo.lock names,
# fetched by the hashes the two lockfiles record, in the layout of
# `cargo vendor`. Its `.cargo/config.toml` replaces crates.io and each git
# source with the directory `cargo-vendor-dir`, which the cargo wrapper
# rewrites to the store path.
{
  lib,
  rustPlatform,
  # cargo-purifier.lock.json.
  lockFile,
  # The workspace's Cargo.lock.
  cargoLock,
}:
let
  lock = import ./lock.nix { inherit lib lockFile cargoLock; };
in
rustPlatform.importCargoLock {
  lockFile = cargoLock;
  inherit (lock) outputHashes;
}
