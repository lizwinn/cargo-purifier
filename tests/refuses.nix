# SPDX-License-Identifier: MIT
#
# refuses <name> { lockFile, cargoLock, expected }: a check that evaluation
# of the two lockfiles fails, with an error that contains `expected`. The
# check runs nix-instantiate in the sandbox, on a dummy store, because a
# parse error is one that builtins.tryEval cannot observe, and because the
# message is what a developer reads.
{ pkgs }:
name:
{
  lockFile,
  cargoLock,
  expected,
}:
pkgs.runCommand name { nativeBuildInputs = [ pkgs.nix ]; } ''
  export HOME=$PWD NIX_STATE_DIR=$PWD/state NIX_LOG_DIR=$PWD/log NIX_CONF_DIR=$PWD
  expression='
    let
      lib = import ${pkgs.path}/lib;
      lock = import ${../nix/lib/lock.nix} {
        inherit lib;
        lockFile = ${lockFile};
        cargoLock = ${cargoLock};
      };
    in
    builtins.deepSeq [
      lock.packages
      lock.outputHashes
      lock.gitEntries
      (map (package: lock.registryOf package.source) lock.registryPackages)
    ] true'
  if nix-instantiate --eval --strict --readonly-mode --store dummy:// --expr "$expression" 2>stderr; then
    echo "${name}: evaluation accepted the lockfile" >&2
    exit 1
  fi
  if ! grep -qF -- ${pkgs.lib.escapeShellArg expected} stderr; then
    echo "${name}: the error does not say: "${pkgs.lib.escapeShellArg expected} >&2
    cat stderr >&2
    exit 1
  fi
  touch $out
''
