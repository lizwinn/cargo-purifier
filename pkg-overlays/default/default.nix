# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.cargo-purifier`, made with lib.makeScope, which holds the
# packages of pkgs/. `.buildCargoProject` is the builder, `.cargo-purifier`
# is the command with the cargo wrapper and rust-analyzer, and `.cargo` and
# `.rust-analyzer` are the wrappers on their own. A consumer that lists
# this flake in `projects` holds the overlay as `cargo-purifier/default`,
# which its package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cargo-purifier";
}
