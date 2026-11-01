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
  # ripgrep's source, pinned in tests/dependencies.
  ripgrep,
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

  # The workspace fixture with its purifier lockfile changed by `change`.
  withLock =
    change:
    buildCargoProject {
      src = ./fixtures/workspace;
      lockFile = builtins.toFile "cargo-purifier.lock.json" (
        builtins.toJSON (change (lib.importJSON ./fixtures/workspace/cargo-purifier.lock.json))
      );
    };

  # Lockfiles that must fail evaluation. A malformed file and a tampered
  # hash fail in ways tryEval cannot observe, so tests/negative.sh covers
  # them.
  rejected = {
    stale = stale;
    missing-git-entry = withLock (lock: lock // { git = [ ]; });
    missing-field = withLock (lock: removeAttrs lock [ "packages" ]);
    wrong-format = withLock (lock: lock // { version = 2; });
    not-a-lockfile = withLock (_: [ ]);
    missing-registry-entry = buildCargoProject {
      src = ./fixtures/registry;
      lockFile = builtins.toFile "cargo-purifier.lock.json" (
        builtins.toJSON (
          lib.importJSON ./fixtures/registry/cargo-purifier.lock.json // { registries = { }; }
        )
      );
    };
  };

  evaluates =
    project:
    (builtins.tryEval (
      lib.concatMapStrings (package: package.drvPath) (lib.attrValues project.packages)
    )).success;

  realWorld = import ./projects/ripgrep.nix {
    inherit pkgs buildCargoProject cargo;
    src = ripgrep;
  };
in
realWorld
// {
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
    tar tzf ${workspace.crates.greet.crate} | grep -qx 'greet-0.1.0/src/lib.rs'
    touch $out
  '';

  # The workspace packages with a binary, or with a library cargo writes as
  # a file to install, have a package; greet has neither.
  packages =
    if
      lib.attrNames workspace.packages == [
        "ffi"
        "hello"
      ]
    then
      pass "packages"
    else
      throw "packages: ${toString (lib.attrNames workspace.packages)}";

  # Every output the lockfile names, at the path evaluation gives it. hello
  # has a crate attribute too, but `cargo package` refuses its git
  # dependency, which has no version.
  outputs =
    let
      inherit (workspace.packages) ffi hello;
      named = {
        "hello.bins.hello" = hello.bins.hello;
        "ffi.libs.libffi.so" = ffi.libs."libffi${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
        "ffi.libs.libffi.a" = ffi.libs."libffi.a";
        "crates.ffi.crate" = workspace.crates.ffi.crate;
        "crates.greet.crate" = workspace.crates.greet.crate;
      };
    in
    assert lib.attrNames hello.bins == [ "hello" ];
    assert lib.attrNames ffi.bins == [ ];
    assert lib.length (lib.attrNames ffi.libs) == 2;
    assert
      lib.attrNames workspace.crates == [
        "ffi"
        "greet"
        "hello"
      ];
    pkgs.runCommand "outputs" { } ''
      ${lib.concatStrings (
        lib.mapAttrsToList (name: file: ''
          test -f ${file} || { echo "${name} is missing: ${file}" >&2; exit 1; }
        '') named
      )}
      test -x ${hello.bins.hello}
      touch $out
    '';

  # The parsing, URL and publish logic of `cargo purify`.
  unit = pkgs.runCommand "unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp ${./test_cargo_purify.py} test_cargo_purify.py
    PYTHONPATH=${../pkgs/cargo-purify} python3 -m unittest -v test_cargo_purify
    touch $out
  '';

  inherit cargo;
}
// lib.mapAttrs' (
  name: project:
  lib.nameValuePair "rejects-${name}" (
    if evaluates project then
      throw "rejects-${name}: the lockfile evaluated, and buildCargoProject should have refused it"
    else
      pass "rejects-${name}"
  )
) rejected
