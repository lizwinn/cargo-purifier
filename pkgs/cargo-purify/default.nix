# SPDX-License-Identifier: MIT
#
# `cargo purify`, which writes cargo-purifier.lock.json. It runs the cargo
# on the PATH, so a workspace locks with the cargo it builds with, and falls
# back to the package set's cargo.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  # nixpkgs' cargo, taken from `pkgs`: in this package scope `cargo` names
  # the purifier's wrapper.
  pkgs,
  nix-prefetch-git,
}:
let
  inherit (pkgs) cargo;
in
stdenvNoCC.mkDerivation {
  pname = "cargo-purify";
  version = "0.1.0";
  src = ./cargo_purify.py;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    install -Dm644 $src $out/libexec/cargo-purify/cargo_purify.py
    makeWrapper ${lib.getExe python3} $out/bin/cargo-purify \
      --add-flags $out/libexec/cargo-purify/cargo_purify.py \
      --prefix PATH : ${lib.makeBinPath [ nix-prefetch-git ]} \
      --suffix PATH : ${lib.makeBinPath [ cargo ]}
    runHook postInstall
  '';
  meta.mainProgram = "cargo-purify";
}
