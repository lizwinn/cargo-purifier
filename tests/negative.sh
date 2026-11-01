#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Lockfiles a build must refuse, and the error each one gives. Each case is
# a copy of the workspace fixture with one thing wrong, built with
# `nix build`: a malformed file and a tampered hash fail where the flake's
# checks cannot observe them (a JSON parse error, and a fixed-output hash
# mismatch).
#
# Run it from the repository root: tests/negative.sh
#
# The expected messages quote commands in backquotes, literally.
# shellcheck disable=SC2016
set -euo pipefail

repo=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0

# expect_failure <case> <text the error must contain>
expect_failure() {
  local case=$1 expected=$2
  local expression="
    let
      flake = builtins.getFlake \"git+file://$repo\";
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ flake.overlays.default ];
      };
    in
    (pkgs.buildCargoProject { src = $work/$case; }).packages.hello"
  if nix build --impure --no-link --expr "$expression" 2>"$work/$case.log"; then
    echo "FAIL $case: the build succeeded" >&2
    failures=$((failures + 1))
  elif ! grep -qF -- "$expected" "$work/$case.log"; then
    echo "FAIL $case: the error does not say: $expected" >&2
    cat "$work/$case.log" >&2
    failures=$((failures + 1))
  else
    echo "ok   $case: $(grep -F -- "$expected" "$work/$case.log" | head -n 1 | sed 's/^ *//')"
  fi
}

# new_case <case>: a fresh copy of the workspace fixture.
new_case() {
  cp -r "$repo/tests/fixtures/workspace" "$work/$1"
  chmod -R u+w "$work/$1"
}

# sri <file>: the SRI SHA-256 of a file.
sri() {
  echo "sha256-$(sha256sum "$1" | cut -d ' ' -f 1 | xxd -r -p | base64)"
}

new_case malformed
echo '{ "version": 1, ' >"$work/malformed/cargo-purifier.lock.json"
expect_failure malformed 'run `cargo purify` to write it again'

new_case stale
echo '# edited' >>"$work/stale/Cargo.lock"
expect_failure stale 'was made from a different Cargo.lock. Run `cargo purify`'

new_case missing-git-entry
python3 - "$work/missing-git-entry/cargo-purifier.lock.json" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
lock["git"] = []
json.dump(lock, open(sys.argv[1], "w"))
EOF
expect_failure missing-git-entry 'has no hash for the git dependency ryu. Run `cargo purify`'

new_case tampered-git-hash
sed -i 's|"hash": "sha256-[^"]*"|"hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="|' \
  "$work/tampered-git-hash/cargo-purifier.lock.json"
expect_failure tampered-git-hash 'hash mismatch'

# A checksum changed in Cargo.lock, with the purifier lockfile updated to
# match, so only the download's hash is wrong.
new_case tampered-checksum
sed -i 's/^checksum = "8f/checksum = "00/' "$work/tampered-checksum/Cargo.lock"
python3 - "$work/tampered-checksum/cargo-purifier.lock.json" "$(sri "$work/tampered-checksum/Cargo.lock")" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
lock["cargoLock"] = sys.argv[2]
json.dump(lock, open(sys.argv[1], "w"))
EOF
expect_failure tampered-checksum 'hash mismatch'

if [ "$failures" -ne 0 ]; then
  echo "$failures case(s) failed" >&2
  exit 1
fi
