# SPDX-License-Identifier: MIT
#
# buildCargoProject, the builder of the purifier contract, as a package for
# callPackage: a cargo workspace, built in the sandbox from its Cargo.lock
# and the cargo-purifier.lock.json that `cargo-purifier lock` wrote. The
# flake's overlays.default adds it to a package set, so a package takes it
# by name:
#
#   { buildCargoProject }: (buildCargoProject { src = ./.; }).packages.<package>
#
# It takes the packages it builds with by name, so
# `buildCargoProject.override` replaces them: `rustPlatform` for another
# Rust toolchain, and the purifier library's functions. It reads the
# lockfiles with readLock (read-lock.nix), fails evaluation through the
# purifier library's checkLock when they cannot be used, and builds the
# downloads that entriesFor gives for the host system. project.nix
# documents the result.
{
  lib,
  stdenv,
  runCommand,
  rustPlatform,
  fetchurl,
  fetchgit,
  # lib.purifier, the purifier library: checkLock and entriesFor.
  purifier,
  # lib.cargo-purifier.readLock.
  readLock,
}:
{
  # The source tree.
  src,
  # The workspace root inside `src`: the directory of the workspace's
  # Cargo.toml and Cargo.lock, when `src` also holds path dependencies
  # outside the workspace.
  workspace ? ".",
  # cargo-purifier.lock.json. A file outside `src` lets a packaging flake
  # build a workspace its author does not change.
  lockFile ? (if workspace == "." then src else src + "/${workspace}") + "/cargo-purifier.lock.json",
  # Fetchers in place of nixpkgs' own, as the purifier library's fetchEntry
  # takes them: `fetchurl` for registry downloads behind a mirror or
  # credentials, and `fetchgit` for private git repositories.
  fetchers ? { },
  # Runs `cargo test --package <package>` in each package's build too.
  doCheck ? false,
  # Which files of a path `src` the builds see.
  srcFilter ? null,
}:
let
  lock = purifier.checkLock (readLock {
    inherit src workspace lockFile;
  });
in
import ./project.nix (
  {
    inherit
      lib
      stdenv
      runCommand
      rustPlatform
      src
      workspace
      lock
      doCheck
      ;
    fetchurl = fetchers.fetchurl or fetchurl;
    fetchgit = fetchers.fetchgit or fetchgit;
    entries = purifier.entriesFor stdenv.hostPlatform.system lock;
  }
  // lib.optionalAttrs (srcFilter != null) { inherit srcFilter; }
)
