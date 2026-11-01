# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cargo-purifier`: `.cargo-purifier`, the commands with the cargo
# wrapper and rust-analyzer, and `.cargo` and `.rust-analyzer` on their own.
# A consumer that lists this flake in `projects` holds it as
# `cargo-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cargo-purifier";
}
