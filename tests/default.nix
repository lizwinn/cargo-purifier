# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked crates and git checkouts.
{
  pkgs,
  # The flake's default package overlay, which adds buildCargoProject.
  overlay,
  # The cargo wrapper.
  cargo,
}:
let
  inherit (pkgs) lib;

  withOverlay = pkgs.extend overlay;

  # Every fixture builds the way a consumer's package does: through
  # buildCargoProject of a package set the overlay applies to.
  inherit (withOverlay) buildCargoProject;

  registryUrls = import ../nix/lib/registry.nix { inherit lib; };

  # A binary with a crate from a registry other than crates.io, whose
  # download template has markers. Its lockfiles are written by hand: the
  # registry's index does not exist, and the build never reads it.
  registry = buildCargoProject { src = ./fixtures/registry; };

  # A binary with an ssh:// git dependency. Its lockfiles are written by
  # hand, with the dependency recorded under its HTTPS URL as `cargo purify`
  # records it.
  ssh = buildCargoProject { src = ./fixtures/ssh; };

  # A workspace with a library from crates.io and a binary with a git
  # dependency, locked by tests/relock-fixtures.sh.
  workspace = buildCargoProject { src = ./fixtures/workspace; };

  # The same workspace with `cargo test` in its builds.
  checked = buildCargoProject {
    src = ./fixtures/workspace;
    doCheck = true;
  };

  # The workspace's purifier lockfile beside a Cargo.lock it was not made
  # from.
  stale = buildCargoProject {
    src = ./fixtures/workspace;
    cargoLock = ./fixtures/stale/Cargo.lock;
  };

  pass = name: pkgs.runCommand name { } "touch $out";
in
{
  # hello runs, with its crates.io and git dependencies.
  workspace = pkgs.runCommand "workspace" { } ''
    output=$(${lib.getExe workspace.packages.hello})
    if [ "$output" != "hello from 2 crates and 1.5" ]; then
      echo "hello printed: $output" >&2
      exit 1
    fi
    touch $out
  '';

  workspace-check = checked.packages.hello;

  # counter runs, with itoa from the fixture's own registry.
  registry = pkgs.runCommand "registry" { } ''
    output=$(${lib.getExe registry.packages.counter})
    if [ "$output" != "counted 42" ]; then
      echo "counter printed: $output" >&2
      exit 1
    fi
    touch $out
  '';

  # Download URLs follow cargo's rules for `dl` templates.
  registry-urls =
    let
      url =
        dl: name:
        registryUrls.downloadUrl {
          inherit dl name;
          version = "1.0.0";
          checksum = "abc";
        };
      cases = {
        "https://dl.example/crates/serde/1.0.0/download" = url "https://dl.example/crates" "serde";
        "https://dl.example/se/rd/serde/1.0.0" =
          url "https://dl.example/{prefix}/{crate}/{version}" "serde";
        "https://dl.example/1/a.crate" = url "https://dl.example/{prefix}/{crate}.crate" "a";
        "https://dl.example/2/ab" = url "https://dl.example/{prefix}/{crate}" "ab";
        "https://dl.example/3/a/abc" = url "https://dl.example/{lowerprefix}/{crate}" "abc";
        "https://dl.example/se/rd/Serde?abc" =
          url "https://dl.example/{lowerprefix}/{crate}?{sha256-checksum}" "Serde";
      };
      failures = lib.filterAttrs (expected: got: expected != got) cases;
    in
    if failures == { } then
      pass "registry-urls"
    else
      throw "registry-urls: ${builtins.toJSON failures}";

  # The wrapper on the workspace fixture, with the vendored sources its own
  # expression builds.
  interactive = import ./interactive.nix {
    inherit pkgs cargo;
    vendor = import ../nix/lib/tool-vendor.nix {
      nixpkgs = pkgs.path;
      inherit (pkgs.stdenv.hostPlatform) system;
      lockFile = ./fixtures/workspace/cargo-purifier.lock.json;
      cargoLock = ./fixtures/workspace/Cargo.lock;
    };
  };

  # The .crate that `cargo purify publish` has Nix build.
  publish-crate = import ../nix/lib/tool-crate.nix {
    nixpkgs = pkgs.path;
    inherit (pkgs.stdenv.hostPlatform) system;
    root = toString ./fixtures/workspace;
    package = "greet";
  };

  # tell runs, with ryu from an ssh:// git dependency fetched over HTTPS.
  ssh = pkgs.runCommand "ssh" { } ''
    output=$(${lib.getExe ssh.packages.tell})
    if [ "$output" != "told 2.5" ]; then
      echo "tell printed: $output" >&2
      exit 1
    fi
    touch $out
  '';

  # The lock run and the publish step against a registry of the check's own.
  local-registry = import ./local-registry.nix {
    inherit pkgs;
    inherit (withOverlay.cargo-purifier) cargo-purify;
    crate = workspace.crates.greet;
  };

  # greet packaged as a .crate, which `cargo package` also builds.
  crate = pkgs.runCommand "crate" { } ''
    tar tzf ${workspace.crates.greet}/greet-0.1.0.crate | grep -qx 'greet-0.1.0/src/lib.rs'
    touch $out
  '';

  # Only workspace packages with a binary have a package.
  packages =
    if lib.attrNames workspace.packages == [ "hello" ] then
      pass "packages"
    else
      throw "packages: ${toString (lib.attrNames workspace.packages)}";

  # A Cargo.lock that changed since `cargo purify` fails evaluation.
  stale-lock =
    if (builtins.tryEval stale.packages.hello.drvPath).success then
      throw "stale-lock: a purifier lockfile beside a different Cargo.lock evaluated"
    else
      pass "stale-lock";

  inherit cargo;
}
