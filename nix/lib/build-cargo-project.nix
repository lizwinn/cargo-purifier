# SPDX-License-Identifier: MIT
#
# buildCargoProject: the packages of a cargo workspace, built in the
# sandbox from its Cargo.lock and the cargo-purifier.lock.json that
# `cargo purify` wrote beside it. The workspace needs no Nix files of its
# own.
#
#   (buildCargoProject { src = ./.; }).packages.<package>
#
# Every workspace package with at least one binary has a package here,
# built with `cargo build --package <package>`. All of them share one
# derivation of vendored sources.
{
  lib,
  rustPlatform,
}:
{
  # The workspace root: the directory of the workspace's Cargo.toml.
  src,
  # cargo-purifier.lock.json.
  lockFile ? src + "/cargo-purifier.lock.json",
  # The workspace's Cargo.lock.
  cargoLock ? src + "/Cargo.lock",
  # Runs `cargo test --package <package>` in each package's build.
  doCheck ? false,
  # Which files of a path `src` the builds see. The default leaves out
  # cargo's target directory and Nix result links.
  srcFilter ? (
    path: type:
    let
      name = baseNameOf path;
    in
    !(type == "directory" && name == "target") && !(lib.hasPrefix "result" name)
  ),
}:
let
  lock = import ./lock.nix { inherit lib lockFile cargoLock; };

  vendor = import ./vendor.nix {
    inherit
      lib
      rustPlatform
      lockFile
      cargoLock
      ;
  };

  filteredSrc =
    if builtins.isPath src then
      lib.cleanSourceWith {
        inherit src;
        filter = srcFilter;
      }
    else
      src;

  mkPackage =
    name: info:
    rustPlatform.buildRustPackage {
      pname = name;
      version = lock.versionOf name;
      src = filteredSrc;
      cargoDeps = vendor;
      inherit doCheck;
      cargoBuildFlags = [
        "--package"
        name
      ];
      cargoTestFlags = [
        "--package"
        name
      ];
      meta = lib.optionalAttrs (lib.length info.bins == 1) {
        mainProgram = lib.head info.bins;
      };
    };
in
{
  packages = lib.mapAttrs mkPackage (lib.filterAttrs (_: info: info.bins != [ ]) lock.packages);

  # The vendored sources, which every package's build reads.
  inherit vendor;
}
