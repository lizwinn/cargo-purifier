# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cargo-purifier` (`.cargo`, `.cargo-purify`), and the builder
# `pkgs.buildCargoProject` (nix/lib/build-cargo-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
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
      buildCargoProject = final.callPackage ../../nix/lib/build-cargo-project.nix { };
    };
}
