# SPDX-License-Identifier: MIT
#
# The `cargo-purifier` command: `lock` writes cargo-purifier.lock.json,
# `prefetch` builds what offline work needs, and `publish` uploads the
# .crate Nix packages. cargo also runs it as `cargo purifier <command>`. It
# runs the cargo on the PATH, so a workspace locks with the cargo it builds
# with, and falls back to the package set's cargo.
{
  lib,
  path,
  stdenv,
  stdenvNoCC,
  makeWrapper,
  python3,
  # nixpkgs' cargo, taken from `pkgs`: in this package scope `cargo` names
  # the purifier's wrapper.
  pkgs,
  git,
  nix-prefetch-git,
  cacert,
}:
let
  inherit (pkgs) cargo;
in
stdenvNoCC.mkDerivation {
  pname = "cargo-purifier-command";
  version = "0.1.0";
  src = ./cargo_purifier.py;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    install -Dm644 $src $out/libexec/cargo-purifier/cargo_purifier.py
    makeWrapper ${lib.getExe python3} $out/bin/cargo-purifier \
      --add-flags $out/libexec/cargo-purifier/cargo_purifier.py \
      --prefix PATH : ${
        lib.makeBinPath [
          nix-prefetch-git
          git
        ]
      } \
      --suffix PATH : ${lib.makeBinPath [ cargo ]} \
      --set CARGO_PURIFIER_NIX_LIB ${../../nix/lib} \
      --set CARGO_PURIFIER_NIXPKGS ${path} \
      --set CARGO_PURIFIER_SYSTEM ${stdenv.hostPlatform.system} \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt
    runHook postInstall
  '';
  meta.mainProgram = "cargo-purifier";
}
