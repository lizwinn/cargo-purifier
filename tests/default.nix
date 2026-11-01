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

  # Every fixture builds the way a consumer's package does: through
  # buildCargoProject of a package set the overlay applies to.
  inherit (pkgs.extend overlay) buildCargoProject;

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
