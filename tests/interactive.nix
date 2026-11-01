# SPDX-License-Identifier: MIT
#
# The cargo wrapper in a workspace with lockfiles. The sandbox has no Nix
# daemon, so a stand-in nix-build answers the wrapper's call: first with
# the vendored sources the wrapper's own expression builds, then with the
# error Nix reports for a Cargo.lock that changed since `cargo purify`.
{
  pkgs,
  # The cargo wrapper.
  cargo,
  # The vendored sources of the workspace fixture.
  vendor,
}:
pkgs.runCommand "interactive" { nativeBuildInputs = [ cargo ]; } ''
  export HOME=$PWD/home CARGO_HOME=$PWD/cargo-home
  cp -r ${./fixtures/workspace} workspace
  chmod -R u+w workspace
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

  cd workspace
  output=$(cargo run --quiet --package hello)
  if [ "$output" != "hello from 2 crates and 1.5" ]; then
    echo "hello printed: $output" >&2
    exit 1
  fi
  grep -q "directory = \"${vendor}\"" target/cargo-purifier/config.toml

  # A second run reuses the vendored sources without calling nix-build.
  rm ../bin/nix-build
  cargo build --quiet --package hello

  cat >../bin/nix-build <<'EOF'
  #!${pkgs.runtimeShell}
  echo "error: cargo-purifier: cargo-purifier.lock.json was made from a different Cargo.lock. Run \`cargo purify\` and commit both files." >&2
  exit 1
  EOF
  chmod +x ../bin/nix-build
  echo '# changed after cargo purify' >>Cargo.lock
  if cargo build --package hello 2>../stderr; then
    echo "cargo built offline from a Cargo.lock the lockfile does not match" >&2
    exit 1
  fi
  grep -q 'the locked sources did not build, so cargo resolves the usual way' ../stderr
  grep -q 'made from a different Cargo.lock' ../stderr

  # Commands that do not read sources run plain cargo.
  cargo --version | grep -q '^cargo '
  touch $out
''
