# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  command = callPackage ./cargo-purifier { };
  cargo = callPackage ./cargo { inherit command; };
  rust-analyzer = callPackage ./rust-analyzer { inherit cargo; };
in
{
  # cargo with the locked sources: the everyday loop.
  inherit cargo;
  # rust-analyzer on the locked sources: the editor.
  inherit rust-analyzer;
  # The `cargo-purifier` command, with the cargo wrapper and rust-analyzer
  # beside it. `cargo-purifier prefetch` keeps this package alive in the
  # project's GC root, through the store path it records here.
  cargo-purifier = callPackage (
    { symlinkJoin, makeWrapper }:
    symlinkJoin {
      name = "cargo-purifier";
      paths = [
        command
        cargo
        rust-analyzer
      ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/cargo-purifier --set CARGO_PURIFIER_TOOLS $out
      '';
      meta.mainProgram = "cargo-purifier";
    }
  ) { };
}
