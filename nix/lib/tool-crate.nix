# SPDX-License-Identifier: MIT
#
# What `cargo purify publish` builds: the .crate of one workspace package,
# from the nixpkgs the command was built with.
#
#   nix-build tool-crate.nix --arg nixpkgs <path> --argstr system <system> \
#     --argstr root <workspace root> --argstr package <package>
{
  nixpkgs,
  system,
  root,
  package,
}:
let
  pkgs = import nixpkgs { inherit system; };
  project = pkgs.callPackage ./build-cargo-project.nix { } { src = /. + root; };
in
project.crates.${package}
