# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  cargo-purify = callPackage ./cargo-purify { };
in
{
  # The command that writes cargo-purifier.lock.json. cargo runs it as
  # `cargo purify`.
  inherit cargo-purify;
  # cargo with the purifier: `cargo purify`, and every other command on the
  # locked sources.
  cargo = callPackage ./cargo { inherit cargo-purify; };
}
