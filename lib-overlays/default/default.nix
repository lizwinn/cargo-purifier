# SPDX-License-Identifier: MIT
#
# The `cargo-purifier` library namespace, which holds the builder of the
# purifier contract:
#
#   lib.cargo-purifier.buildCargoProject { pkgs, src, fetchers ? { }, ... }
#
# nix/lib/build-cargo-project.nix documents its arguments and result.
{ ... }:
{

  overlay = final: prev: {
    cargo-purifier = {
      buildCargoProject = import ../../nix/lib/build-cargo-project.nix;
    };
  };

}
