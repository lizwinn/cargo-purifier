# SPDX-License-Identifier: MIT
#
# lib.cargo-purifier.buildCargoProject: a cargo workspace, built in the
# sandbox from its Cargo.lock and the cargo-purifier.lock.json that
# `cargo-purifier lock` wrote. The workspace needs no Nix files of its own.
#
#   lib.cargo-purifier.buildCargoProject { inherit pkgs; src = ./.; }
#
# The result follows the purifier contract:
#
#   packages.<package>   every workspace package that has a binary, or a
#                        library cargo writes as a file to install (a
#                        cdylib, a staticlib or a dylib), built with
#                        `cargo build --package <package>`
#   tests                `cargo test --workspace`, in the sandbox
#   release.<package>    the .crate that `cargo package --package <package>`
#                        makes, which `cargo-purifier publish` uploads
#   fetches              every download, as purifier library entries
#   vendor               the vendored sources every build reads
#
# The lockfile names every output, so evaluation knows each one's path
# without building anything:
#
#   packages.<package>.bins.<binary>    $out/bin/<binary>
#   packages.<package>.libs."<file>"    $out/lib/lib<name>.so or .a
#   release.<package>.crate             $out/<package>-<version>.crate
{
  pkgs,
  # The workspace root: the directory of the workspace's Cargo.toml.
  src,
  # Fetchers in place of nixpkgs' own, as the purifier library's fetchEntry
  # takes them: `fetchurl` for registry downloads behind a mirror or
  # credentials, and `fetchgit` for private git repositories.
  fetchers ? { },
  # cargo-purifier.lock.json. A file outside `src` lets a packaging flake
  # build a workspace its author does not change.
  lockFile ? src + "/cargo-purifier.lock.json",
  # The workspace's Cargo.lock. A file outside `src` replaces any copy in
  # it.
  cargoLock ? src + "/Cargo.lock",
  # Runs `cargo test --package <package>` in each package's build too.
  doCheck ? false,
  # Which files of a path `src` the builds see. The default leaves out
  # cargo's target directory and Nix result links.
  srcFilter ? (
    path: type:
    let
      name = baseNameOf path;
    in
    !(type == "directory" && name == "target") && !(pkgs.lib.hasPrefix "result" name)
  ),
  # The Rust toolchain.
  rustPlatform ? pkgs.rustPlatform,
}:
let
  inherit (pkgs) lib stdenv;

  lock = import ./lock.nix { inherit lib lockFile cargoLock; };

  vendored = import ./vendor.nix {
    inherit
      lib
      rustPlatform
      lockFile
      cargoLock
      ;
    inherit (pkgs) runCommand;
    fetchurl = fetchers.fetchurl or pkgs.fetchurl;
    fetchgit = fetchers.fetchgit or pkgs.fetchgit;
  };
  inherit (vendored) vendor;

  filteredSrc =
    if builtins.isPath src then
      lib.cleanSourceWith {
        inherit src;
        filter = srcFilter;
      }
    else
      src;

  # Every build works on the Cargo.lock this builder was given, which
  # nixpkgs' cargoSetupHook then compares with the vendored one.
  common = {
    src = filteredSrc;
    cargoDeps = vendor;
    prePatch = ''
      cp ${cargoLock} Cargo.lock
      chmod u+w Cargo.lock
    '';
  };

  # The files cargo writes for a library target and nixpkgs' install hook
  # copies to $out/lib.
  libFiles =
    info:
    let
      kinds = if info.lib == null then [ ] else info.lib.kinds;
      shared = stdenv.hostPlatform.extensions.sharedLibrary;
    in
    lib.optional (lib.elem "cdylib" kinds || lib.elem "dylib" kinds) "lib${info.lib.name}${shared}"
    ++ lib.optional (lib.elem "staticlib" kinds) "lib${info.lib.name}.a";

  hasOutputs = info: info.bins != [ ] || libFiles info != [ ];

  mkPackage =
    name: info:
    let
      drv = rustPlatform.buildRustPackage (
        common
        // {
          pname = name;
          version = lock.versionOf name;
          inherit doCheck;
          cargoBuildFlags = [
            "--package"
            name
          ];
          cargoTestFlags = [
            "--package"
            name
          ];
          meta = lib.optionalAttrs (lib.length info.bins == 1) {
            mainProgram = lib.head info.bins;
          };
        }
      );
    in
    drv
    // {
      bins = lib.genAttrs info.bins (bin: "${drv}/bin/${bin}");
      libs = lib.genAttrs (libFiles info) (file: "${drv}/lib/${file}");
    };

  # A derivation that runs cargo in the build's source, with the vendored
  # sources and the toolchain.
  cargoRun =
    attrs:
    stdenv.mkDerivation (
      common
      // {
        nativeBuildInputs = [
          rustPlatform.cargoSetupHook
          rustPlatform.rust.cargo
          rustPlatform.rust.rustc
        ];
      }
      // attrs
    );

  mkRelease =
    name: _:
    let
      version = lock.versionOf name;
      drv = cargoRun {
        pname = "${name}-crate";
        inherit version;
        # `cargo package` also builds the packaged crate, from its own
        # sources and the vendored ones.
        buildPhase = ''
          runHook preBuild
          cargo package --frozen --package ${lib.escapeShellArg name}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm644 target/package/${name}-${version}.crate $out/${name}-${version}.crate
          runHook postInstall
        '';
      };
    in
    drv // { crate = "${drv}/${name}-${version}.crate"; };
in
{
  packages = lib.mapAttrs mkPackage (lib.filterAttrs (_: hasOutputs) lock.packages);

  tests = cargoRun {
    name = "cargo-workspace-tests";
    buildPhase = ''
      runHook preBuild
      cargo test --frozen --workspace
      runHook postBuild
    '';
    installPhase = "touch $out";
  };

  release = lib.mapAttrs mkRelease lock.packages;

  inherit (vendored) fetches;
  inherit vendor;
}
