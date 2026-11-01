# cargo-purifier

A cargo subcommand, a cargo wrapper and a Nix library that build cargo
workspaces in the Nix sandbox from their lockfiles. The workspace needs no
Nix files of its own.

cargo keeps planning and compiling the build. `Cargo.lock` already pins
every crates.io download by name, version and checksum, so cargo-purifier
reuses it. `cargo purify` writes `cargo-purifier.lock.json` beside it, with
what `Cargo.lock` leaves out: the hash of each git dependency's checkout,
and the workspace's packages with their binaries.

- **Sandboxed builds.** `buildCargoProject`, which the flake's overlay adds
  to a package set, gives a package for every workspace package that has a
  binary.
- **Interactive cargo on the locked sources.** With the lockfiles present,
  the wrapper's `cargo build`, `run`, `test` and the like read the
  dependencies' sources from a vendored copy that Nix builds from the two
  lockfiles, offline. Incremental compilation works as usual.

## Lock

Run `cargo purify` at the workspace root through the flake's wrapper, and
commit `Cargo.lock` and `cargo-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/cargo-purifier -- purify
```

`cargo purify` first runs `cargo fetch`, which brings `Cargo.lock` up to
date with the manifests and changes no more than it must. It then hashes
each git checkout with `nix-prefetch-git`, submodules included. A rerun
reuses the hashes of checkouts that did not change.

Run `cargo purify` again whenever `Cargo.lock` changes. The purifier
lockfile records the hash of the `Cargo.lock` it was made from, and a Nix
build of a different `Cargo.lock` fails with a message saying so.

## Build with Nix

The flake's `overlays.default` adds `buildCargoProject` to a package set,
and a package written for `callPackage` takes it by name:

```nix
# package.nix
{ buildCargoProject }:
(buildCargoProject { src = ./.; }).packages.hello
```

```nix
{
  inputs.cargo-purifier.url = "github:nix-purifiers/cargo-purifier";
  inputs.nixpkgs.follows = "cargo-purifier/nixpkgs";

  outputs = { nixpkgs, cargo-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          cargo-purifier.overlays.default
          (final: prev: { hello = final.callPackage ./package.nix { }; })
        ];
      };
    in
    {
      packages.${system}.hello = pkgs.hello;
    };
}
```

Each package runs `cargo build --package <package>`, and all of them read
one derivation of vendored sources, `(buildCargoProject { … }).vendor`.
`nix/lib/build-cargo-project.nix` documents the arguments: `doCheck` runs
`cargo test --package <package>`, `srcFilter` chooses the files of a path
`src` the builds see, and `lockFile` and `cargoLock` name the two lockfiles
when they are not at the workspace root. The builder takes `rustPlatform`
from the package set, so `buildCargoProject.override` replaces the Rust
toolchain.

## Interactive mode

The wrapper is the flake's default package. In a workspace with a
`cargo-purifier.lock.json`, the commands that read the dependencies'
sources (`build`, `check`, `run`, `test`, `bench`, `doc`, `clippy`,
`rustc`, `rustdoc`, `tree`, `metadata`, `package` and `fix`) run with
crates.io and every git source replaced by the vendored copy, and with
`--offline`. The vendored copy stays alive through a GC root at
`target/cargo-purifier/vendor`, which `cargo clean` removes.

Every other command, such as `update`, `add` or `publish`, runs plain
cargo. So does every command in a workspace without a purifier lockfile, or
with `CARGO_PURIFIER=0` set. When the vendored copy does not build,
typically because `Cargo.lock` changed since `cargo purify`, the wrapper
warns and cargo resolves the usual way.

The wrapper runs the package set's cargo and rustc. When no `cc` is on the
`PATH`, rustc links with the package set's C compiler.

## Lockfile

```json
{
  "cargoLock": "sha256-…",
  "git": [
    {
      "git": { "rev": "12746aa8…", "submodules": true, "url": "https://github.com/dtolnay/ryu" },
      "hash": "sha256-3sLJLjnNzF0WaWXzI8Re4m3JiZ+W3h4p8TKRsETIUTU=",
      "path": "git/12746aa8…"
    }
  ],
  "packages": {
    "hello": { "bins": ["hello"], "lib": false, "manifest": "hello/Cargo.toml" }
  },
  "version": 1
}
```

`cargoLock` is the SRI hash of the `Cargo.lock` the file was made from.
Each `git` entry is one checkout: a commit of a repository, with the NAR
hash that nixpkgs `fetchgit` computes for it. One checkout can provide
several crates, and the vendoring step finds each crate in it by name.
`packages` lists the workspace's packages. The file records no versions,
so a version bump changes only `Cargo.lock`, which then needs
`cargo purify` again.

## Limits

- Only crates.io and git sources work. A crate from another registry fails
  the vendoring step.
- The builds use the package set's Rust toolchain. They do not read
  `rust-toolchain.toml`.
- Only packages with a binary become Nix packages. Library crates build as
  part of the packages that depend on them.

## Related work

cargo-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).
The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), a fork of cargo that
builds every crate as its own Nix derivation. cargo-purifier runs stock
cargo instead, with its own incremental compiler, and gives Nix the
dependencies' sources and the release builds.

The vendoring itself is nixpkgs `rustPlatform.importCargoLock`, which also
builds from `Cargo.lock` alone when given the git hashes by hand.
[crane](https://github.com/ipetkov/crane) and
[naersk](https://github.com/nix-community/naersk) build cargo projects
from `Cargo.lock` too.
