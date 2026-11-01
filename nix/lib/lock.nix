# SPDX-License-Identifier: MIT
#
# Reads a cargo-purifier lockfile together with the Cargo.lock it was made
# from. Cargo.lock pins every registry download by name, version and
# checksum; the purifier lockfile adds the hash of each git checkout, the
# download URL template of each registry other than crates.io, and the
# workspace's packages.
#
# Evaluation fails when the Cargo.lock beside the purifier lockfile is not
# the one `cargo purify` read, because the git hashes, the registries and
# the package list may no longer match it.
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

  sourced = lib.filter (package: package ? source) parsed.package;

  gitPackages = lib.filter (package: lib.hasPrefix "git+" package.source) sourced;

  # crates.io, which nixpkgs importCargoLock fetches from its CDN.
  cratesIo = "registry+https://github.com/rust-lang/crates.io-index";

  isRegistry = source: lib.hasPrefix "registry+" source || lib.hasPrefix "sparse+" source;

  # The workspace's own packages, and its path dependencies, have no source.
  localPackages = lib.filter (package: !(package ? source)) parsed.package;
in
{
  # The workspace's packages, by name: their manifest, binaries and whether
  # they have a library.
  inherit (checked) packages;

  # The `version` field of Cargo.lock, which lockfiles before format 3 lack.
  cargoLockVersion = parsed.version or null;

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

  # The commit a git package's source names.
  inherit revOf;

  # The URL a git checkout is fetched from: the URL in Cargo.lock, or its
  # HTTPS form for an ssh:// dependency.
  gitUrlOf =
    rev:
    (lib.findFirst (entry: entry.git.rev == rev)
      (throw "cargo-purifier: ${toString lockFile} has no entry for the git commit ${rev}. Run `cargo purify`.")
      checked.git
    ).git.url;

  # The packages from crates.io and from git, which importCargoLock vendors.
  importedPackages = lib.filter (
    package: package.source == cratesIo || !(isRegistry package.source)
  ) sourced;

  # The packages from every other registry, which the purifier vendors.
  registryPackages = lib.filter (
    package: isRegistry package.source && package.source != cratesIo
  ) sourced;

  # The checksum Cargo.lock records for a registry package: in the package
  # entry, or in the `metadata` table of a format 1 lockfile.
  checksumOf =
    package:
    package.checksum
      or parsed.metadata."checksum ${package.name} ${package.version} (${package.source})"
        or (throw "cargo-purifier: Cargo.lock has no checksum for ${package.name} ${package.version}.");

  # The index configuration of a registry other than crates.io, by its
  # source in Cargo.lock.
  registryOf =
    source:
    (checked.registries or { }).${source}
      or (throw "cargo-purifier: ${toString lockFile} has no entry for the registry ${source}. Run `cargo purify`.");

  # The version of a workspace package, which Cargo.lock records.
  versionOf =
    name:
    (lib.findFirst (package: package.name == name)
      (throw "cargo-purifier: Cargo.lock has no workspace package ${name}. Run `cargo purify`.")
      localPackages
    ).version;
}
