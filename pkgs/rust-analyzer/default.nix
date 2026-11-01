# SPDX-License-Identifier: MIT
#
# rust-analyzer for an editor in a purified workspace. It runs cargo through
# the purifier's wrapper, so it loads the workspace and its dependencies
# from the vendored sources, offline, and it reads the standard library's
# sources from the package set's rust-src.
{
  lib,
  runCommand,
  makeWrapper,
  # nixpkgs' rust-analyzer and Rust toolchain, taken from `pkgs`: in this
  # package scope `rust-analyzer` names this wrapper.
  pkgs,
  # The cargo wrapper.
  cargo,
}:
runCommand "rust-analyzer"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "rust-analyzer";
  }
  ''
    makeWrapper ${lib.getExe pkgs.rust-analyzer} $out/bin/rust-analyzer \
      --prefix PATH : ${lib.makeBinPath [ cargo ]} \
      --set-default RUST_SRC_PATH ${pkgs.rustPlatform.rustLibSrc}
  ''
