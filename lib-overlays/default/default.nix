# SPDX-License-Identifier: MIT
#
# The `cargo-purifier` library namespace, which holds the reader of the
# purifier contract:
#
#   lib.cargo-purifier.readLock { src, lockFile ? ... }
#
# nix/lib/read-lock.nix documents it. The builder, buildCargoProject, is a
# package, which the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    cargo-purifier = {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
    };
  };

}
