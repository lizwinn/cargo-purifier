# SPDX-License-Identifier: MIT
#
# What `cargo-purifier publish` builds: the release (the .crate) of one
# workspace package, from the nixpkgs the command was built with.
#
#   nix-build tool-release.nix --arg nixpkgs <path> --argstr system <system> \
#     --argstr root <workspace root> --arg lockFile <cargo-purifier.lock.json> \
#     --argstr package <package>
{
  nixpkgs,
  system,
  root,
  lockFile,
  package,
}:
let
  pkgs = import nixpkgs { inherit system; };
  project = import ./build-cargo-project.nix {
    inherit pkgs lockFile;
    src = /. + root;
  };
in
project.release.${package}
