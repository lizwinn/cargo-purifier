# SPDX-License-Identifier: MIT
#
# Reads a cargo-purifier lockfile together with the Cargo.lock it was made
# from. Cargo.lock pins every crates.io download by name, version and
# checksum; the purifier lockfile adds the hash of each git checkout and the
# workspace's packages.
#
# Evaluation fails when the Cargo.lock beside the purifier lockfile is not
# the one `cargo purify` read, because the git hashes and the package list
# may no longer match it.
{
  lib,
  # cargo-purifier.lock.json.
  lockFile,
  # The workspace's Cargo.lock.
  cargoLock,
}:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  cargoLockHash = builtins.convertHash {
    hash = builtins.hashFile "sha256" cargoLock;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };

  checked =
    if (lock.version or null) != 1 then
      throw "cargo-purifier: ${toString lockFile} has format ${
        toString (lock.version or "unknown")
      }, and this cargo-purifier reads format 1. Run `cargo purify` with this cargo-purifier."
    else if lock.cargoLock != cargoLockHash then
      throw "cargo-purifier: ${toString lockFile} was made from a different Cargo.lock. Run `cargo purify` and commit both files."
    else
      lock;

  parsed = builtins.fromTOML (builtins.readFile cargoLock);

  # A git source in Cargo.lock ends with `#<commit>`.
  revOf = package: lib.last (lib.splitString "#" package.source);

  hashByRev = lib.listToAttrs (map (entry: lib.nameValuePair entry.git.rev entry.hash) checked.git);

  gitPackages = lib.filter (package: lib.hasPrefix "git+" (package.source or "")) parsed.package;

  # The workspace's own packages, and its path dependencies, have no source.
  localPackages = lib.filter (package: !(package ? source)) parsed.package;
in
{
  # The workspace's packages, by name: their manifest, binaries and whether
  # they have a library.
  inherit (checked) packages;

  # The hashes of the git dependencies, in the form nixpkgs importCargoLock
  # takes them.
  outputHashes = lib.listToAttrs (
    map (
      package:
      lib.nameValuePair "${package.name}-${package.version}" (
        hashByRev.${revOf package}
        or (throw "cargo-purifier: ${toString lockFile} has no hash for the git dependency ${package.name}. Run `cargo purify`.")
      )
    ) gitPackages
  );

  # The version of a workspace package, which Cargo.lock records.
  versionOf =
    name:
    (lib.findFirst (package: package.name == name)
      (throw "cargo-purifier: Cargo.lock has no workspace package ${name}. Run `cargo purify`.")
      localPackages
    ).version;
}
