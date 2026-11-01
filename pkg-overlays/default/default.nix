# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the builder `buildCargoProject`
# (nix/lib/build-cargo-project.nix), where nixpkgs keeps its own builders,
# and the packages of pkgs/ under `pkgs.cargo-purifier`: `.cargo-purifier`,
# the command with the cargo wrapper and rust-analyzer, and `.cargo` and
# `.rust-analyzer` on their own. A consumer that lists this flake in
# `projects` holds it as `cargo-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cargo-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildCargoProject = final.callPackage ../../nix/lib/build-cargo-project.nix {
        inherit (closure-lib) purifier;
        inherit (closure-lib.cargo-purifier) readLock;
      };
    };
}
