# SPDX-License-Identifier: MIT
#
# The vendored sources of a workspace: every crate its Cargo.lock names,
# fetched by the hashes the two lockfiles record, in the layout of
# `cargo vendor`. Its `.cargo/config.toml` replaces each registry and git
# source with the directory `cargo-vendor-dir`, which nixpkgs'
# cargoSetupHook and the cargo wrapper point at the store path.
#
# nixpkgs importCargoLock vendors the crates from crates.io and from git,
# given a Cargo.lock that names only those. The purifier vendors the crates
# from every other registry, from the download URL that the registry's
# `dl` template gives, since importCargoLock knows only templates without
# markers. The result holds the workspace's own Cargo.lock, which
# cargoSetupHook compares with the one in the build's source.
#
# A git checkout is fetched from the URL the purifier lockfile records,
# which is the HTTPS form of an ssh:// dependency's URL, and the source
# replacement still names the source as Cargo.lock does.
{
  lib,
  rustPlatform,
  fetchurl,
  fetchgit,
  runCommand,
  # cargo-purifier.lock.json.
  lockFile,
  # The workspace's Cargo.lock.
  cargoLock,
}:
let
  lock = import ./lock.nix { inherit lib lockFile cargoLock; };
  registry = import ./registry.nix { inherit lib; };

  inherit (builtins) toJSON;

  isGit = package: lib.hasPrefix "git+" package.source;

  # The URL in a git source: git+<url>[?…]#<commit>.
  sourceUrlOf = package: lib.head (builtins.match "git\\+([^?#]+).*" package.source);

  # Git sources whose checkout comes from another URL, as
  # { original, fetched } pairs.
  rewrites = lib.unique (
    lib.concatMap (
      package:
      let
        original = sourceUrlOf package;
        fetched = lock.gitUrlOf package;
      in
      lib.optional (original != fetched) { inherit original fetched; }
    ) (lib.filter isGit lock.importedPackages)
  );

  # A package's source as importCargoLock sees it: with the URL a git
  # checkout is fetched from.
  importedSource =
    package:
    if isGit package then
      let
        original = sourceUrlOf package;
      in
      "git+" + lock.gitUrlOf package + lib.removePrefix "git+${original}" package.source
    else
      package.source;

  # A Cargo.lock with the fields importCargoLock reads, for the packages
  # it vendors. JSON strings are valid TOML basic strings. importCargoLock
  # needs the `package` key even when it vendors nothing.
  importedLock = lib.concatStrings (
    lib.optional (lock.cargoLockVersion != null) "version = ${toString lock.cargoLockVersion}\n"
    ++ lib.optional (lock.importedPackages == [ ]) "package = []\n"
    ++ map (
      package:
      ''

        [[package]]
        name = ${toJSON package.name}
        version = ${toJSON package.version}
        source = ${toJSON (importedSource package)}
      ''
      + lib.optionalString (lib.hasPrefix "registry+" package.source) ''
        checksum = ${toJSON (lock.checksumOf package)}
      ''
    ) lock.importedPackages
  );

  # A credentialed fetchgit reaches private repositories.
  imported = (rustPlatform.importCargoLock.override { inherit fetchgit; }) {
    lockFileContents = importedLock;
    inherit (lock) outputHashes;
  };

  importedNames = map (package: "${package.name}-${package.version}") lock.importedPackages;

  # A registry crate's directory: `<name>-<version>`, or with the source's
  # hash appended when a crate from crates.io or git has that name.
  dirName =
    package:
    let
      plain = "${package.name}-${package.version}";
    in
    if lib.elem plain importedNames then
      "${plain}-${builtins.substring 0 8 (builtins.hashString "sha256" package.source)}"
    else
      plain;

  registryCrate =
    package:
    let
      checksum = lock.checksumOf package;
      tarball = fetchurl {
        name = "crate-${package.name}-${package.version}.tar.gz";
        url = registry.downloadUrl {
          inherit (lock.registryOf package.source) dl;
          inherit (package) name version;
          inherit checksum;
        };
        sha256 = checksum;
      };
    in
    runCommand "${package.name}-${package.version}" { } ''
      mkdir $out
      tar xf ${tarball} -C $out --strip-components=1
      printf '{"files":{},"package":"%s"}' ${checksum} >$out/.cargo-checksum.json
    '';

  registrySources = lib.unique (map (package: package.source) lock.registryPackages);

  # The `registry` value of a source replacement: the index URL, which
  # keeps the `sparse+` prefix and drops `registry+`.
  indexOf = lib.removePrefix "registry+";
in
runCommand "cargo-vendor-dir" { } ''
  mkdir -p $out/.cargo
  for entry in ${imported}/*; do
    ln -s "$entry" "$out/$(basename "$entry")"
  done
  rm $out/Cargo.lock
  ln -s ${cargoLock} $out/Cargo.lock
  cp ${imported}/.cargo/config.toml $out/.cargo/config.toml
  chmod u+w $out/.cargo/config.toml

  ${lib.concatMapStrings (rewrite: ''
    substituteInPlace $out/.cargo/config.toml \
      --replace-fail ${lib.escapeShellArg "\"git+${rewrite.fetched}"} ${lib.escapeShellArg "\"git+${rewrite.original}"} \
      --replace-fail ${lib.escapeShellArg "git = \"${rewrite.fetched}\""} ${lib.escapeShellArg "git = \"${rewrite.original}\""}
  '') rewrites}

  ${lib.concatMapStrings (package: ''
    ln -s ${registryCrate package} $out/${dirName package}
  '') lock.registryPackages}

  ${lib.concatMapStrings (source: ''
    cat >>$out/.cargo/config.toml <<'EOF'

    [source.${toJSON source}]
    registry = ${toJSON (indexOf source)}
    replace-with = "vendored-sources"
    EOF
  '') registrySources}
''
