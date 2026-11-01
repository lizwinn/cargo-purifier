# SPDX-License-Identifier: MIT
#
# `cargo purify`, which writes cargo-purifier.lock.json, and
# `cargo purify publish`, which uploads the .crate Nix packages. It runs the
# cargo on the PATH, so a workspace locks with the cargo it builds with,
# and falls back to the package set's cargo.
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
      --prefix PATH : ${
        lib.makeBinPath [
          nix-prefetch-git
          git
        ]
      } \
      --suffix PATH : ${lib.makeBinPath [ cargo ]} \
      --set CARGO_PURIFY_CRATE_EXPR ${../../nix/lib}/tool-crate.nix \
      --set CARGO_PURIFY_NIXPKGS ${path} \
      --set CARGO_PURIFY_SYSTEM ${stdenv.hostPlatform.system} \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt
    runHook postInstall
  '';
  meta.mainProgram = "cargo-purify";
}
