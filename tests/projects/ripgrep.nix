# SPDX-License-Identifier: MIT
#
# ripgrep 14.1.1, a real workspace of ten packages and 61 locked crates,
# with the purifier lockfile `cargo purify` wrote for it
# (projects/ripgrep/cargo-purifier.lock.json). ripgrep's own Cargo.lock is
# the one in its source.
{
  pkgs,
  buildCargoProject,
  # The cargo wrapper.
  cargo,
  # ripgrep's source at 4649aa9700619f94cf9c66876e9549d83420e16c.
  src,
}:
let
  inherit (pkgs) lib;

  lockFile = ./ripgrep/cargo-purifier.lock.json;

  project = buildCargoProject { inherit src lockFile; };

  vendor = import ../../nix/lib/tool-vendor.nix {
    nixpkgs = pkgs.path;
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit lockFile;
    cargoLock = src + "/Cargo.lock";
  };
in
{
  # The release build of rg, from the sandbox.
  ripgrep = pkgs.runCommand "ripgrep" { } ''
    ${project.packages.ripgrep.bins.rg} --version | grep -q '^ripgrep 14.1.1'
    printf 'one\nneedle\nthree\n' >haystack
    test "$(${lib.getExe project.packages.ripgrep} --count needle haystack)" = 1
    touch $out
  '';

  # A developer's loop on ripgrep through the cargo wrapper, offline: build,
  # run, test, rust-analyzer, and a new dependency that Cargo.lock lacks. The
  # sandbox has no Nix daemon, so a stand-in nix-build answers the wrapper
  # with the vendored sources its own expression builds.
  ripgrep-develop =
    pkgs.runCommand "ripgrep-develop"
      {
        nativeBuildInputs = [
          cargo
          pkgs.rust-analyzer
        ];
        RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
      }
      ''
        export HOME=$PWD/home CARGO_HOME=$PWD/cargo-home
        cp -r ${src} ripgrep
        chmod -R u+w ripgrep
        cp ${lockFile} ripgrep/cargo-purifier.lock.json
        mkdir bin
        export PATH=$PWD/bin:$PATH
        cat >bin/nix-build <<'EOF'
        #!${pkgs.runtimeShell}
        while [ $# -gt 0 ]; do
          if [ "$1" = --out-link ]; then link=$2; fi
          shift
        done
        ln -sfn ${vendor} "$link"
        echo ${vendor}
        EOF
        chmod +x bin/nix-build
        cd ripgrep

        cargo build --quiet
        cargo run --quiet -- --version | grep -q '^ripgrep 14.1.1'
        cargo test --quiet --package grep-cli

        # rust-analyzer runs cargo metadata and cargo check through the
        # wrapper, so it loads the workspace from the vendored sources.
        rust-analyzer analysis-stats --skip-inference . >../analysis 2>&1 || {
          cat ../analysis >&2
          exit 1
        }
        # The dependencies' code is loaded only when cargo metadata resolved
        # them from the vendored sources.
        grep -q '^Database loaded:' ../analysis && grep -q 'dependency lines of code: [1-9]' ../analysis || {
          cat ../analysis >&2
          exit 1
        }

        # A dependency added to Cargo.toml but not yet locked.
        sed -i 's/^\[dependencies\]$/[dependencies]\nsmallvec = "1"/' Cargo.toml
        if cargo build --quiet 2>../stderr; then
          echo "cargo built offline with a dependency Cargo.lock lacks" >&2
          exit 1
        fi
        grep -q 'Cargo.toml needs dependencies that Cargo.lock lacks' ../stderr || {
          cat ../stderr >&2
          exit 1
        }
        touch $out
      '';
}
