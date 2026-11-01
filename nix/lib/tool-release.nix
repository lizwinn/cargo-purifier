# SPDX-License-Identifier: MIT
#
# What `cargo-purifier publish` builds: the release (the .crate) of one
# workspace package, from the nixpkgs the command was built with.
#
#   nix-build tool-release.nix --arg nixpkgs <path> --argstr system <system> \
#     --arg src <workspace root> --arg lockFile <cargo-purifier.lock.json> \
#     --argstr package <package>
{
  nixpkgs,
  system,
  src,
  lockFile,
  package,
}:
let
  pkgs = import nixpkgs { inherit system; };
  lock = import ./tool-lock.nix {
    inherit (pkgs) lib;
    inherit src lockFile;
  };
  project = import ./project.nix {
    inherit (pkgs)
      lib
      stdenv
      runCommand
      rustPlatform
      fetchurl
      fetchgit
      ;
    inherit src lock;
    inherit (lock) entries;
  };
in
project.release.${package}
