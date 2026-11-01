# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked crates and git checkouts.
# conformance-relock and conformance-rebuild need the network or a Nix
# daemon, so they are CI jobs of those names (.github/workflows/check.yml).
{
  pkgs,
  # lib.cargo-purifier.buildCargoProject.
  buildCargoProject,
  # The cargo-purifier package: the command, the cargo wrapper and
  # rust-analyzer.
  cargo-purifier,
  # ripgrep's source, pinned in tests/dependencies.
  ripgrep,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  build = args: buildCargoProject ({ inherit pkgs; } // args);

  registryUrls = import ../nix/lib/registry.nix { inherit lib; };

  refuses = import ./refuses.nix { inherit pkgs; };

  # A workspace with a library from crates.io, a binary with a git
  # dependency, and a C library, locked by tests/relock-fixtures.sh.
  workspace = build { src = ./fixtures/workspace; };

  # The same workspace with `cargo test` in its package builds.
  checked = build {
    src = ./fixtures/workspace;
    doCheck = true;
  };

  # A binary with a crate from a registry other than crates.io, whose
  # download template has markers. Its lockfiles are written by hand: the
  # registry's index does not exist, and the build never reads it.
  registry = build { src = ./fixtures/registry; };

  # A binary with an ssh:// git dependency. Its lockfiles are written by
  # hand, with the dependency recorded under its HTTPS URL as
  # `cargo-purifier lock` records it.
  ssh = build { src = ./fixtures/ssh; };

  # The workspace fixture without either lockfile in its source, built from
  # the lockfiles beside it.
  external = build {
    src = builtins.path {
      name = "workspace-without-lockfiles";
      path = ./fixtures/workspace;
      filter =
        path: _:
        !(lib.elem (baseNameOf path) [
          "cargo-purifier.lock.json"
          "Cargo.lock"
        ]);
    };
    lockFile = ./fixtures/workspace/cargo-purifier.lock.json;
    cargoLock = ./fixtures/workspace/Cargo.lock;
  };

  workspaceLock = lib.importJSON ./fixtures/workspace/cargo-purifier.lock.json;

  sri =
    hex:
    builtins.convertHash {
      hash = hex;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # A lockfile changed by hand, with the content hash `cargo-purifier lock`
  # would have written for it, so that only the change itself is wrong.
  rehashed =
    lock:
    lock
    // {
      contentHash = sri (
        builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "contentHash" ]))
      );
    };

  lockText = value: builtins.toFile "cargo-purifier.lock.json" (builtins.toJSON value);

  workspaceRefuses =
    name: lockFile: expected:
    refuses name {
      inherit lockFile expected;
      cargoLock = ./fixtures/workspace/Cargo.lock;
    };

  pass = name: pkgs.runCommand name { } "touch $out";

  realWorld = import ./projects/ripgrep.nix {
    inherit pkgs cargo-purifier;
    buildCargoProject = buildCargoProject;
    src = ripgrep;
  };
in
realWorld
// {
  # The purifier contract.

  conformance-stale = refuses "conformance-stale" {
    lockFile = ./fixtures/workspace/cargo-purifier.lock.json;
    cargoLock = ./fixtures/stale/Cargo.lock;
    expected = "was made from a different Cargo.lock. Run `cargo-purifier lock`";
  };

  conformance-tampered = workspaceRefuses "conformance-tampered" (lockText (
    workspaceLock
    // {
      git = map (
        entry: entry // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
      ) workspaceLock.git;
    }
  )) "was changed after `cargo-purifier lock` wrote it";

  conformance-missing = workspaceRefuses "conformance-missing" (lockText (
    rehashed (workspaceLock // { git = [ ]; })
  )) "has no hash for the git dependency ryu. Run `cargo-purifier lock`";

  conformance-malformed =
    workspaceRefuses "conformance-malformed"
      (builtins.toFile "cargo-purifier.lock.json" ''{ "version": 1, '')
      "run `cargo-purifier lock` to write it again";

  conformance-offline = import ./conformance-offline.nix {
    inherit pkgs cargo-purifier;
    prefetched = import ../nix/lib/tool-prefetch.nix {
      nixpkgs = pkgs.path;
      inherit system;
      lockFile = ./fixtures/workspace/cargo-purifier.lock.json;
      cargoLock = ./fixtures/workspace/Cargo.lock;
      tools = cargo-purifier;
    };
  };

  conformance-external = pkgs.runCommand "conformance-external" { } ''
    test "$(${lib.getExe external.packages.hello})" = "hello from 2 crates and 1.5"
    touch $out
  '';

  # More lockfiles evaluation refuses, each with the command that fixes it.

  refuses-missing-field = workspaceRefuses "refuses-missing-field" (lockText (
    rehashed (removeAttrs workspaceLock [ "packages" ])
  )) "lacks packages. Run `cargo-purifier lock`";

  refuses-other-format = workspaceRefuses "refuses-other-format" (lockText (
    rehashed (workspaceLock // { version = 2; })
  )) "reads format 1. Run `cargo-purifier lock`";

  refuses-not-a-lockfile = workspaceRefuses "refuses-not-a-lockfile" (lockText [
  ]) "is not a cargo-purifier lockfile. Run `cargo-purifier lock`";

  refuses-missing-registry = refuses "refuses-missing-registry" {
    lockFile = lockText (
      rehashed (lib.importJSON ./fixtures/registry/cargo-purifier.lock.json // { registries = { }; })
    );
    cargoLock = ./fixtures/registry/Cargo.lock;
    expected = "has no entry for the registry sparse+https://registry.invalid/index/. Run `cargo-purifier lock`";
  };

  # The fixtures.

  # hello runs, with its crates.io and git dependencies.
  workspace = pkgs.runCommand "workspace" { } ''
    test "$(${lib.getExe workspace.packages.hello})" = "hello from 2 crates and 1.5"
    touch $out
  '';

  # hello with `cargo test` in its build, which conformance-rebuild also
  # builds twice.
  workspace-hello = checked.packages.hello;

  # The workspace test run in the sandbox.
  workspace-tests = workspace.tests;

  # counter runs, with itoa from the fixture's own registry.
  registry = pkgs.runCommand "registry" { } ''
    test "$(${lib.getExe registry.packages.counter})" = "counted 42"
    touch $out
  '';

  # tell runs, with ryu from an ssh:// git dependency fetched over HTTPS.
  ssh = pkgs.runCommand "ssh" { } ''
    test "$(${lib.getExe ssh.packages.tell})" = "told 2.5"
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
  # has a release attribute too, but `cargo package` refuses its git
  # dependency, which has no version.
  outputs =
    let
      inherit (workspace.packages) ffi hello;
      named = {
        "hello.bins.hello" = hello.bins.hello;
        "ffi.libs.libffi.so" = ffi.libs."libffi${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}";
        "ffi.libs.libffi.a" = ffi.libs."libffi.a";
        "release.ffi.crate" = workspace.release.ffi.crate;
        "release.greet.crate" = workspace.release.greet.crate;
      };
    in
    assert lib.attrNames hello.bins == [ "hello" ];
    assert lib.attrNames ffi.bins == [ ];
    assert lib.length (lib.attrNames ffi.libs) == 2;
    assert
      lib.attrNames workspace.release == [
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
      tar tzf ${workspace.release.greet.crate} | grep -qx 'greet-0.1.0/src/lib.rs'
      touch $out
    '';

  # `fetches` lists every download as a purifier library entry: the
  # crates.io crate itoa as a file entry, and the ryu checkout as a git
  # entry.
  fetches =
    let
      inherit (workspace) fetches;
      files = lib.filter (entry: entry ? url) fetches;
      gits = lib.filter (entry: entry ? git) fetches;
    in
    assert map (entry: entry.path) files == [ "itoa-1.0.18" ];
    assert lib.all (entry: entry.mirrors == [ ] && lib.hasPrefix "sha256-" entry.hash) files;
    assert map (entry: entry.git.url) gits == [ "https://github.com/dtolnay/ryu" ];
    assert lib.length fetches == 2;
    pass "fetches";

  # The release that `cargo-purifier publish` has Nix build.
  publish-release = import ../nix/lib/tool-release.nix {
    nixpkgs = pkgs.path;
    inherit system;
    root = toString ./fixtures/workspace;
    lockFile = ./fixtures/workspace/cargo-purifier.lock.json;
    package = "greet";
  };

  # The lock run and the publish step against a registry of the check's own.
  local-registry = import ./local-registry.nix {
    inherit pkgs cargo-purifier;
    crate = workspace.release.greet;
  };

  # The parsing, URL, lockfile and publish logic of `cargo-purifier`.
  unit = pkgs.runCommand "unit" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp ${./test_cargo_purifier.py} test_cargo_purifier.py
    PYTHONPATH=${../pkgs/cargo-purifier} python3 -m unittest -v test_cargo_purifier
    touch $out
  '';

  inherit cargo-purifier;
}
