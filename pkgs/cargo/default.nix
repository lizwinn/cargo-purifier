# SPDX-License-Identifier: MIT
#
# cargo with the purifier. In a workspace with a cargo-purifier.lock.json,
# the commands that read the dependencies' sources (build, check, run,
# test and the like) read them from the vendored sources Nix builds from
# the two lockfiles, offline. The vendored sources stay alive through a GC
# root at target/cargo-purifier/vendor, which `cargo clean` removes.
#
# Every other command runs plain cargo, and so does every command when the
# workspace has no purifier lockfile or CARGO_PURIFIER=0 is set. When the
# vendored sources do not build, typically because Cargo.lock changed since
# `cargo purify`, or when a manifest needs a dependency Cargo.lock lacks,
# the wrapper says so and cargo resolves the usual way.
{
  lib,
  path,
  stdenv,
  writeShellApplication,
  coreutils,
  gnused,
  gnugrep,
  # nixpkgs' cargo and rustc, taken from `pkgs`: in this package scope
  # `cargo` names this wrapper.
  pkgs,
  cargo-purify,
}:
let
  inherit (pkgs) cargo rustc;
in
writeShellApplication {
  name = "cargo";
  runtimeInputs = [
    coreutils
    gnused
    gnugrep
  ];
  text = ''
    real=${lib.getExe cargo}
    # `cargo purify` runs cargo-purify, and cargo needs rustc. rustc links
    # with `cc`, and the package set's C compiler comes last on the PATH, so
    # a `cc` the user already has comes first.
    export PATH="${
      lib.makeBinPath [
        cargo-purify
        rustc
      ]
    }:$PATH:${lib.makeBinPath [ stdenv.cc ]}"

    # The subcommand is the first argument that is neither an option nor
    # an option's value.
    sub=
    args=("$@")
    i=0
    while [ "$i" -lt "''${#args[@]}" ]; do
      case "''${args[$i]}" in
        --config | --color | -C | -Z | --explain) i=$((i + 2)) ;;
        -* | +*) i=$((i + 1)) ;;
        *)
          sub=''${args[$i]}
          break
          ;;
      esac
    done

    case "$sub" in
      build | b | check | c | run | r | test | t | bench | doc | d | clippy | rustc | rustdoc | tree | metadata | package | fix) ;;
      *) exec "$real" "$@" ;;
    esac

    if [ "''${CARGO_PURIFIER:-1}" = 0 ]; then
      exec "$real" "$@"
    fi

    manifest=$("$real" locate-project --workspace --message-format plain 2>/dev/null) || exec "$real" "$@"
    root=''${manifest%/Cargo.toml}
    lock=$root/cargo-purifier.lock.json
    if [ ! -f "$lock" ] || [ ! -f "$root/Cargo.lock" ]; then
      exec "$real" "$@"
    fi

    state=$root/target/cargo-purifier
    mkdir -p "$state"
    stamp=$(cat "$lock" "$root/Cargo.lock" | sha256sum)
    if [ -e "$state/vendor" ] && [ "$(cat "$state/stamp" 2>/dev/null)" = "$stamp" ]; then
      vendor=$(readlink -f "$state/vendor")
    elif vendor=$(nix-build ${../../nix/lib}/tool-vendor.nix \
      --arg nixpkgs ${path} \
      --argstr system ${stdenv.hostPlatform.system} \
      --arg lockFile "/. + \"$lock\"" \
      --arg cargoLock "/. + \"$root/Cargo.lock\"" \
      --out-link "$state/vendor" 2>"$state/nix-build.log"); then
      printf '%s\n' "$stamp" >"$state/stamp"
    else
      echo "cargo-purifier: the locked sources did not build, so cargo resolves the usual way. Run \`cargo purify\` if Cargo.lock changed; $state/nix-build.log has the details." >&2
      # Nix prints the error that ends evaluation last.
      grep 'error: ' "$state/nix-build.log" | tail -n 1 | sed 's/^ *//' >&2 || true
      exec "$real" "$@"
    fi

    sed "s|^directory = \"cargo-vendor-dir\"\$|directory = \"$vendor\"|" \
      "$vendor/.cargo/config.toml" >"$state/config.toml"

    # A manifest that needs a dependency Cargo.lock lacks cannot resolve
    # from the vendored sources: cargo finds no such package there, or wants
    # to update Cargo.lock.
    if ! "$real" --config "$state/config.toml" metadata --offline --locked --format-version 1 \
      >/dev/null 2>"$state/metadata.log" &&
      grep -q -e 'needs to be updated' -e 'no matching package named' "$state/metadata.log"; then
      echo "cargo-purifier: Cargo.toml needs dependencies that Cargo.lock lacks, so cargo resolves the usual way. Run \`cargo purify\` afterwards to lock them." >&2
      exec "$real" "$@"
    fi

    exec "$real" --config "$state/config.toml" --offline "$@"
  '';
}
