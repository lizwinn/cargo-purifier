# cargo-purifier

A cargo subcommand, a cargo wrapper and a Nix library that build cargo
workspaces in the Nix sandbox from their lockfiles. The workspace needs no
Nix files of its own.

cargo keeps planning and compiling the build. `Cargo.lock` already pins
every registry download by name, version and checksum, so cargo-purifier
reuses it. `cargo purify` writes `cargo-purifier.lock.json` beside it, with
what `Cargo.lock` leaves out: the hash of each git dependency's checkout,
the download URL template of each registry other than crates.io, and the
workspace's packages with their binaries.

- **Sandboxed builds.** `buildCargoProject`, which the flake's overlay adds
  to a package set, gives a package for every workspace package that has a
  binary or an installable library, and a .crate file for every workspace
  package. Evaluation knows every output by name from the lockfile.
- **Interactive cargo on the locked sources.** With the lockfiles present,
  the wrapper's `cargo build`, `run`, `test` and the like read the
  dependencies' sources from a vendored copy that Nix builds from the two
  lockfiles, offline. Incremental compilation works as usual.
- **Publishing what Nix packaged.** `cargo purify publish` uploads the
  .crate file that Nix built in the sandbox, so nothing published was
  packaged outside it.

## Lock

Run `cargo purify` at the workspace root through the flake's wrapper, and
commit `Cargo.lock` and `cargo-purifier.lock.json`:

```zsh
nix run github:nix-purifiers/cargo-purifier -- purify
```

`cargo purify` first runs `cargo fetch`, which brings `Cargo.lock` up to
date with the manifests and changes no more than it must. It then hashes
each git checkout with `nix-prefetch-git`, submodules included, and reads
the index configuration (`config.json`) of each registry other than
crates.io for its download URL template. A rerun reuses the hashes of
checkouts that did not change.

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

Each package runs `cargo build --package <package>`. Each crate,
`(buildCargoProject { … }).crates.<package>`, runs
`cargo package --package <package>`, which also builds the packaged crate.
All of them read one derivation of vendored sources,
`(buildCargoProject { … }).vendor`.

## Outputs

The lockfile names each workspace package with its binaries and its
library target, so evaluation knows every output and its path without
building anything or importing generated Nix code:

| Attribute | Output |
|---|---|
| `packages.<package>.bins.<binary>` | `$out/bin/<binary>` |
| `packages.<package>.libs."lib<name>.so"` | the shared library of a `cdylib` or `dylib` target |
| `packages.<package>.libs."lib<name>.a"` | the static library of a `staticlib` target |
| `crates.<package>.crate` | `$out/<package>-<version>.crate` |

A workspace package has a `packages` entry when it has a binary or one of
those library kinds. A plain Rust library (`rlib`) is only usable compiled
into something, so it has a crate and no package. The outputs come from
the lock run's `cargo metadata`, because `Cargo.toml` alone does not name
them: cargo finds binaries in `src/main.rs` and `src/bin/` without any
manifest entry, and workspace members may be globs.

`nix/lib/build-cargo-project.nix` documents the arguments: `doCheck` runs
`cargo test --package <package>`, `srcFilter` chooses the files of a path
`src` the builds see, and `lockFile` and `cargoLock` name the two lockfiles
when they are not at the workspace root. `buildCargoProject.override`
replaces what the builder takes from the package set: `rustPlatform` for
another Rust toolchain, `fetchurl` for registry downloads that need
credentials or a mirror, and `fetchgit` for private git repositories.

## Interactive mode

The wrapper is the flake's default package. In a workspace with a
`cargo-purifier.lock.json`, the commands that read the dependencies'
sources (`build`, `check`, `run`, `test`, `bench`, `doc`, `clippy`,
`rustc`, `rustdoc`, `tree`, `metadata`, `package` and `fix`) run with every
registry and git source replaced by the vendored copy, and with
`--offline`. The vendored copy stays alive through a GC root at
`target/cargo-purifier/vendor`, which `cargo clean` removes.

Every other command, such as `update`, `add` or `publish`, runs plain
cargo. So does every command in a workspace without a purifier lockfile, or
with `CARGO_PURIFIER=0` set. When the vendored copy does not build,
typically because `Cargo.lock` changed since `cargo purify`, the wrapper
prints the reason and cargo resolves the usual way.

The wrapper runs the package set's cargo and rustc. When no `cc` is on the
`PATH`, rustc links with the package set's C compiler.

## Publish

```zsh
nix run github:nix-purifiers/cargo-purifier -- purify publish --package greet
```

`cargo purify publish` has Nix build `crates.<package>` from the workspace,
and uploads that .crate file to crates.io, or to the registry
`--registry <name>` names in cargo's configuration. The upload is a request
to the registry's publish API, of the kind `cargo publish` sends, with the
metadata read from the normalized `Cargo.toml` inside the crate. The token
comes from where cargo keeps it: `CARGO_REGISTRY_TOKEN` or
`CARGO_REGISTRIES_<NAME>_TOKEN`, or `credentials.toml` as `cargo login`
writes it. `--dry-run` prints the metadata and uploads nothing, and
`--crate <file>` uploads a .crate file built some other way.

## Dependency sources

| Source in Cargo.lock | How the build gets it |
|---|---|
| crates.io | nixpkgs `importCargoLock`, from the checksum in `Cargo.lock` |
| Another registry, git or sparse index | the URL its `dl` template gives (all of cargo's markers), with the checksum in `Cargo.lock` |
| git, over HTTPS or any URL Nix can fetch | `fetchgit` with submodules, by the hash in the purifier lockfile |
| git over `ssh://` | the same repository over HTTPS from the same host, since the sandbox holds no SSH keys; a private repository needs a credentialed `fetchgit` |
| path | the build's `src` |

A path dependency outside the workspace root is not part of `src`, so the
sandbox cannot see it. Such a dependency builds when `src` is a directory
that contains both, with `lockFile` and `cargoLock` naming the lockfiles in
the workspace.

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
    "ffi": { "bins": [], "lib": { "kinds": ["cdylib", "staticlib"], "name": "ffi" }, "manifest": "ffi/Cargo.toml" },
    "hello": { "bins": ["hello"], "lib": null, "manifest": "hello/Cargo.toml" }
  },
  "registries": {
    "sparse+https://registry.example/index/": { "dl": "https://dl.example/{prefix}/{crate}-{version}.crate" }
  },
  "version": 1
}
```

`cargoLock` is the SRI hash of the `Cargo.lock` the file was made from.
Each `git` entry is one checkout: a commit of a repository, the URL it is
fetched from, and the NAR hash that nixpkgs `fetchgit` computes for it. One
checkout can provide several crates, and the vendoring step finds each
crate in it by name. `registries` maps each registry source in `Cargo.lock`
to the `dl` template of its index configuration. `packages` lists the
workspace's packages with their binaries, and with the name and crate
types of their library target. The file records no versions, so a version
bump changes only `Cargo.lock`, which then needs `cargo purify` again.

## Decisions

- Only packages with a binary or an installable library become Nix
  packages, because a plain Rust library is only usable compiled into
  something. Every package has a crate.
- Each package builds with its own `cargo build --package`, so a package's
  build does not depend on its siblings. They share the vendored sources,
  not compiled crates.
- `doCheck` is off by default, so a test suite that needs the network does
  not break a package's build.
- When the vendored copy does not build, the wrapper falls back to plain
  cargo instead of failing, so a stale lockfile does not stop local work.
- `cargo purify publish` uploads through the registry API itself, because
  `cargo publish` always packages the crate again before uploading.

## Limits

- The builds use the package set's Rust toolchain. They do not read
  `rust-toolchain.toml`.
- Downloads that need credentials go through the `fetchurl` and `fetchgit`
  a consumer passes to `buildCargoProject.override`, because the sandbox
  sees no credentials of its own.
- `cargo purify publish` sends the metadata fields cargo sends for stable
  features. It does not send artifact dependencies, an unstable cargo
  feature.
- The wrapper finds the subcommand as the first argument that is neither an
  option nor the value of `--config`, `--color`, `-C`, `-Z` or `--explain`.
  An alias defined in cargo's configuration runs plain cargo.

## Related work

cargo-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io).
It follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), formerly
sbt-nix-backend: the build tool records what it downloads in a lockfile,
and Nix builds from it with no generated Nix files.

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), a fork of cargo that
builds every crate as its own Nix derivation. cargo-purifier runs stock
cargo instead, with its own incremental compiler, and gives Nix the
dependencies' sources, the release builds and the published crates.

nixpkgs `rustPlatform.importCargoLock` vendors the crates.io and git
dependencies, and also builds from `Cargo.lock` alone when given the git
hashes by hand. [crane](https://github.com/ipetkov/crane) and
[naersk](https://github.com/nix-community/naersk) build cargo projects
from `Cargo.lock` too.
