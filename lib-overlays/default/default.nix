# SPDX-License-Identifier: MIT
#
# The `cargo-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildCargoProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    cargo-purifier = prev.cargo-purifier or { };
  };

}
