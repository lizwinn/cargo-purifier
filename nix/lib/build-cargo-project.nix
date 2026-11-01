# SPDX-License-Identifier: MIT
#
# lib.cargo-purifier.buildCargoProject, the builder of the purifier
# contract: a cargo workspace, built in the sandbox from its Cargo.lock and
# the cargo-purifier.lock.json that `cargo-purifier lock` wrote. The
# workspace needs no Nix files of its own.
#
#   lib.cargo-purifier.buildCargoProject { inherit pkgs; src = ./.; }
#
# The builder reads the lockfiles with readLock (read-lock.nix), fails
# evaluation through the purifier library's checkLock when they cannot be
# used, and builds the downloads entriesFor gives for the host system.
# project.nix documents the result and the other arguments: `fetchers`,
# `doCheck`, `srcFilter` and `rustPlatform`.
{
  # A library with the purifier library's namespace, `lib.purifier`.
  lib,
}:
{
  pkgs,
  # The source tree.
  src,
  # The workspace root inside `src`: the directory of the workspace's
  # Cargo.toml and Cargo.lock, when `src` also holds path dependencies
  # outside the workspace.
  workspace ? ".",
  # cargo-purifier.lock.json, when it is not in the workspace root. A file
  # outside `src` lets a packaging flake build a workspace its author does
  # not change.
  lockFile ? null,
  ...
}@args:
let
  lock = lib.purifier.checkLock (
    import ./read-lock.nix { inherit lib; } (
      { inherit src workspace; } // lib.optionalAttrs (lockFile != null) { inherit lockFile; }
    )
  );
in
import ./project.nix (
  removeAttrs args [ "lockFile" ]
  // {
    inherit lock;
    entries = lib.purifier.entriesFor pkgs.stdenv.hostPlatform.system lock;
  }
)
