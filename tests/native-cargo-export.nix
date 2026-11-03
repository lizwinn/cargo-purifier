# SPDX-License-Identifier: MIT
{ pkgs, project }:
pkgs.runCommand "cargo-native-export-consumer"
  {
    nativeBuildInputs = [
      pkgs.cargo
      pkgs.rustc
      pkgs.stdenv.cc
      pkgs.jq
    ];
    passthru.repository = project.projections.cargo;
  }
  ''
    export HOME="$TMPDIR/home" CARGO_HOME="$TMPDIR/cargo-home"
    mkdir -p consumer/src consumer/.cargo
    cd consumer
    version=$(jq -r '.packages[] | select(.name == "greet") | .version' \
      ${project.projections.cargo.catalog})
    printf '[package]\nname="consumer"\nversion="1.0.0"\nedition="2021"\n[dependencies]\ngreet="=%s"\n' \
      "$version" > Cargo.toml
    printf '[source.crates-io]\nreplace-with="nix"\n[source.nix]\nlocal-registry="%s"\n' \
      ${project.projections.cargo} > .cargo/config.toml
    printf 'fn main(){println!("{}",greet::greeting(42))}\n' > src/main.rs
    cargo run --offline --quiet > actual
    grep -Fx "hello from 42 crates" actual
    touch "$out"
  ''
