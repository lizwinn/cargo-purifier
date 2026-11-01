# SPDX-License-Identifier: MIT
#
# The `cargo-purifier` library namespace, which holds what the purifier
# contract asks of every purifier:
#
#   lib.cargo-purifier.readLock { src, lockFile ? ... }
#   lib.cargo-purifier.buildCargoProject { pkgs, src, fetchers ? { }, ... }
#
# nix/lib/read-lock.nix and nix/lib/build-cargo-project.nix document them.
# The builder uses `lib.purifier`, which this flake's library holds because
# it lists the purifier flake in its projects.
{ ... }:
{

  overlay = final: prev: {
    cargo-purifier = {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
      buildCargoProject = import ../../nix/lib/build-cargo-project.nix { lib = final; };
    };
  };

}
