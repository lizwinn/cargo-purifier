# cargo-purifier

A command, a cargo wrapper and a Nix library that build cargo workspaces in
the Nix sandbox from their lockfiles. The workspace needs no Nix files of
its own.

cargo keeps planning and compiling the build. `Cargo.lock` already pins
every registry download by name, version and checksum, so cargo-purifier
reuses it, and writes `cargo-purifier.lock.json` beside it only for what
`Cargo.lock` cannot record. cargo-purifier is one of the
[nix-purifiers](https://nix-purifiers.github.io) and meets the
[purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md).

## Quickstart

At the workspace root, lock the workspace and commit both lockfiles:

```zsh
nix run github:nix-purifiers/cargo-purifier -- lock
git add Cargo.lock cargo-purifier.lock.json
```

Build it with Nix from a flake:

```nix
{
  inputs.cargo-purifier.url = "github:nix-purifiers/cargo-purifier";
  inputs.nixpkgs.follows = "cargo-purifier/nixpkgs";

  outputs = { nixpkgs, cargo-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = cargo-purifier.lib.cargo-purifier.buildCargoProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      packages.${system}.hello = project.packages.hello;
      checks.${system}.tests = project.tests;
    };
}
```

For the everyday loop and the editor, put the `cargo-purifier` package on
the `PATH`, for example in a development shell, and prefetch once:

```zsh
cargo-purifier prefetch
```

## Everyday loop

The `cargo-purifier` package holds the command, a `cargo` wrapper and a
`rust-analyzer` wrapper. In a workspace with a `cargo-purifier.lock.json`,
the wrapper's `cargo build`, `check`, `run`, `test`, `bench`, `doc`,
`clippy`, `rustc`, `rustdoc`, `tree`, `metadata`, `package` and `fix` read
every registry and git source from a vendored copy that Nix builds from
the two lockfiles, and run with `--offline`. Incremental compilation works
as usual. Every other command, such as `update`, `add` or `publish`, runs
plain cargo.

To add a dependency, run `cargo add`, then `cargo-purifier lock`. To
upgrade, run `cargo-purifier update`, which runs `cargo update` for every
package, or for the packages it names, and then locks the result. Commit
both lockfiles either way. `cargo-purifier lock` keeps cargo's resolution:
it runs `cargo fetch`, which brings `Cargo.lock` up to date with the
manifests and changes no more than it must. It then hashes each git
checkout with `nix-prefetch-git`, submodules included, and reads the index
configuration of each registry other than crates.io. A relock of an
unchanged workspace reproduces the lockfile byte for byte, and hashes only
the git checkouts that changed. A command that needs a download the
lockfiles do not record stops, and names `cargo-purifier lock`.
`CARGO_PURIFIER=0` runs plain cargo, which downloads what it needs.

### The Nix build

`lib.cargo-purifier.buildCargoProject { pkgs, src, fetchers ? { }, ... }`
returns:

| Attribute | What it is |
|---|---|
| `packages.<package>` | every workspace package with a binary or an installable library, built with `cargo build --package <package>` |
| `packages.<package>.bins.<binary>` | `$out/bin/<binary>` |
| `packages.<package>.libs."lib<name>.so"`, `."lib<name>.a"` | the libraries of `cdylib`, `dylib` and `staticlib` targets |
| `tests` | `cargo test --workspace`, in the sandbox |
| `release.<package>` | the .crate of `cargo package --package <package>`; `release.<package>.crate` is its path |
| `fetches` | every download: the entries of the lock in memory |
| `vendor` | the vendored sources every build reads |

Evaluation knows every attribute and path from the lockfiles, without
building anything or importing generated Nix code. A plain Rust library
(`rlib`) is only usable compiled into something, so it has a release and
no package.

### The lock in memory

`lib.cargo-purifier.readLock { src, workspace ? ".", lockFile ? … }` reads
both lockfiles into the shape every purifier shares: `purifier`,
`entries`, `outputs` and `problems`. `entries` are download entries of the
[purifier library](https://github.com/nix-purifiers/purifier): a file
entry per registry crate, from the checksum in `Cargo.lock`, and a git
entry per checkout. Each also carries `cargo = { source, name, version }`.
Cargo downloads are the same on every system, so no entry has `systems`.
`outputs` names every workspace package, with its binaries, library and
version, and `problems` holds the reasons the lockfiles cannot be used.
Reading never fails, except on a purifier lockfile that looks like a JSON
object and does not parse, which Nix cannot catch; that error still names
the file and the fix. The builder passes the lock to the library's
`checkLock`, and builds the entries `entriesFor` gives for the host
system.

`fetchers.fetchurl` and `fetchers.fetchgit` replace nixpkgs' fetchers for
every download, crates.io included, for a mirror or credentials.
`nix/lib/build-cargo-project.nix` documents the other arguments: `doCheck`
also runs each package's tests in its build, `srcFilter` chooses the files
of a path `src` the builds see, and `rustPlatform` is the Rust toolchain.

### A lockfile outside the source

A packaging flake can build a workspace its author does not change.
`lockFile` names a purifier lockfile outside `src`; `Cargo.lock` stays in
the workspace. Every command takes `--lockfile <path>`, and the cargo
wrapper reads the same path from `CARGO_PURIFIER_LOCKFILE`.

### Publish

```zsh
cargo-purifier publish --package greet
```

`cargo-purifier publish` has Nix build `release.<package>` from the
workspace, and uploads that .crate file to crates.io, or to the registry
`--registry <name>` names in cargo's configuration. The upload is a request
to the registry's publish API, of the kind `cargo publish` sends, with the
metadata read from the normalized `Cargo.toml` inside the crate. The token
comes from where cargo keeps it: `CARGO_REGISTRY_TOKEN` or
`CARGO_REGISTRIES_<NAME>_TOKEN`, or `credentials.toml` as `cargo login`
writes it. `--dry-run` prints the metadata and uploads nothing.

### Decisions

- Each package builds with its own `cargo build --package`, so a package's
  build does not depend on its siblings. They share the vendored sources,
  not compiled crates.
- `doCheck` is off by default, so a test suite that needs the network does
  not break a package's build; `tests` runs the whole suite.
- `cargo-purifier publish` uploads through the registry API itself,
  because `cargo publish` always packages the crate again before
  uploading.
- The vendoring of crates.io and git sources is nixpkgs'
  `importCargoLock`, which places each crate of a checkout by name and
  resolves `workspace = true` inheritance in vendored manifests.

## Offline work

`cargo-purifier prefetch` builds, in the Nix store, everything the
everyday loop and the editor need: the vendored sources, the
`cargo-purifier` package with its cargo, rustc, C compiler and
rust-analyzer, and the standard library's sources. It keeps them alive with
a garbage-collector root at `target/cargo-purifier/prefetch`, and records
the vendored sources for the wrapper, which then needs no Nix call. After a
prefetch, `cargo build`, `run`, `test` and rust-analyzer work with the
network cut off.

`cargo clean` removes the root with the rest of `target`, so prefetch
again before the next stretch of offline work.

## Editor

Point the editor at the `rust-analyzer` of the `cargo-purifier` package,
for example `target/cargo-purifier/prefetch/tools/bin/rust-analyzer` after
a prefetch. It runs `cargo metadata` and `cargo check` through the cargo
wrapper, so it loads the workspace and its dependencies from the vendored
sources, and it reads the standard library's sources from the package
set's rust-src. On ripgrep it loads 18 crates and about 900,000 lines of
dependency code in about four seconds.

## Errors and fixes

| Mistake | What happens |
|---|---|
| `Cargo.lock` changed since the lock (an upgrade, or a hand edit) | "… was made from a different Cargo.lock. Run `cargo-purifier lock` and commit both files." The wrapper stops with the same reason. |
| A dependency added to `Cargo.toml` but not locked | The wrapper stops: "Cargo.toml needs dependencies that Cargo.lock lacks. Run `cargo-purifier lock` to lock them." |
| The purifier lockfile edited by hand | "… was changed after `cargo-purifier lock` wrote it. Run `cargo-purifier lock` to write it again." |
| A git dependency missing from the purifier lockfile | "… has no hash for the git dependency <name>. Run `cargo-purifier lock`." |
| A registry missing from the purifier lockfile | "… has no entry for the registry <source>. Run `cargo-purifier lock`." |
| A malformed or incomplete purifier lockfile | The error names the file, with "run `cargo-purifier lock` to write it again". |
| Offline, with sources never prefetched | The wrapper stops with Nix's reason, and says to run `cargo-purifier prefetch` while online. |
| A hash that does not match the download | Nix reports a hash mismatch for the crate or checkout. The upstream changed what it serves under that version or commit; `cargo-purifier lock` records what it serves now. |

## Sources supported and refused

| Source in Cargo.lock | How the build gets it |
|---|---|
| crates.io | nixpkgs `importCargoLock`, by the checksum in `Cargo.lock` |
| Another registry, git or sparse index | the URL its `dl` template gives, with all of cargo's markers, by the checksum in `Cargo.lock` |
| git, over HTTPS or any URL Nix can fetch | `fetchgit` with submodules, by the hash in the purifier lockfile |
| git over `ssh://` | the same repository over HTTPS from the same host, since the sandbox holds no SSH keys; a private repository needs a credentialed `fetchers.fetchgit` |
| path | the build's `src` |

A path dependency outside the workspace root builds when `src` is a
directory that holds both, and `workspace` names the workspace inside it,
as in `{ src = ./.; workspace = "app"; }`. The builds use the package set's
Rust toolchain, and do not read `rust-toolchain.toml`.

### What the purifier lockfile holds

Each field of `cargo-purifier.lock.json` is something Nix cannot get from
`Cargo.lock` or `Cargo.toml` at evaluation time. crates.io crates appear
only in `Cargo.lock`.

| Field | Why `Cargo.lock` cannot supply it |
|---|---|
| `version` | the purifier lockfile's own format |
| `contentHash` | the hash of the file's own content, which shows a hand edit |
| `cargoLock` | the hash of the `Cargo.lock` it was made from; a `Cargo.lock` cannot vouch that it is unchanged |
| `git[]` | `Cargo.lock` records a git dependency's commit, but a fixed-output fetch needs the checkout's NAR hash, with submodules |
| `registries.<source>.dl` | a registry's download URL template is in its index's `config.json`, which evaluation cannot fetch without import-from-derivation |
| `packages.<package>.bins`, `.lib` | the outputs: cargo finds binaries in `src/main.rs` and `src/bin/` without manifest entries, members may be globs, and the library's name and crate types decide its file names |

## Real-world projects

- [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1, commit
  `4649aa9700619f94cf9c66876e9549d83420e16c`, is a workspace of ten
  packages and 61 locked crates, with its purifier lockfile kept outside
  its source in `tests/projects/ripgrep/`. CI builds `rg` in the sandbox,
  and runs the developer loop through the wrapper offline: `cargo build`,
  `cargo run`, `cargo test --package grep-cli`, rust-analyzer, and a
  dependency added without a relock. CI also runs the quickstart's lock on
  it with the pushed commit, in 3 to 4 seconds with an empty cargo cache,
  and compares the lockfile byte for byte. The `grep-cli` tests and
  rust-analyzer also passed on a developer's machine.

Working through ripgrep made the wrapper name a dependency missing from
`Cargo.lock`, which used to end in cargo's offline resolution error.

### Tests

CI runs the suite on x86_64-linux and aarch64-linux.

- The flake holds the contract's checks for stale, tampered, missing and
  malformed lockfiles, for offline work after a prefetch, and for a
  lockfile kept outside the source. CI runs the relock, update and rebuild
  checks of the contract as jobs, because they need the network or a Nix
  daemon. The `read-lock` check covers the shape of the lock in memory.
- `refuses-*` checks give evaluation more lockfiles it must refuse, and
  check each message.
- Unit tests in `tests/test_cargo_purifier.py` cover the lockfile checks,
  the parsing of `Cargo.lock` sources, `ssh://` URLs, cargo's configuration
  and credentials, and the publish request.
- Each source kind has a fixture: `workspace` (crates.io, git with
  submodules, path), `registry`, `ssh`, and `outside` (a path dependency
  outside the workspace root).
- `local-registry` runs the lock and the publish against a registry and a
  git repository it sets up itself, and relocks from scratch byte for byte.
- `tests/negative.sh` covers downloads whose recorded hash is wrong.

## Credits

cargo-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), formerly
sbt-nix-backend: the build tool records what it downloads in a lockfile,
and Nix builds from it with no generated Nix files.

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), a fork of cargo that
builds every crate as its own Nix derivation. cargo-purifier runs stock
cargo instead, with its own incremental compiler, and gives Nix the
dependencies' sources, the release builds and the published crates.

nixpkgs `rustPlatform.importCargoLock` vendors the crates.io and git
dependencies. [crane](https://github.com/ipetkov/crane) and
[naersk](https://github.com/nix-community/naersk) build cargo projects
from `Cargo.lock` too.
