# SPDX-License-Identifier: MIT
#
# What the cargo wrapper builds: the vendored sources of a workspace, from
# the nixpkgs the wrapper was built with.
#
#   nix-build tool-vendor.nix --arg nixpkgs <path> --argstr system <system> \
#     --arg src <workspace root> --arg lockFile <cargo-purifier.lock.json>
{
  nixpkgs,
  system,
  src,
  lockFile,
}:
let
  pkgs = import nixpkgs { inherit system; };
  lock = import ./tool-lock.nix {
    inherit (pkgs) lib;
    inherit src lockFile;
  };
in
import ./vendor.nix {
  inherit (pkgs)
    lib
    rustPlatform
    fetchurl
    fetchgit
    runCommand
    ;
  cargoLock = src + "/Cargo.lock";
  inherit (lock) entries;
}
