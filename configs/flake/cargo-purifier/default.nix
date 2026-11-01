# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope is the `default` entry of this flake's package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`. The `packages` output holds the derivations of
    # the scope below, because the scope also holds the builder, which is a
    # function.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/cargo-purifier -- <command>` runs the
  # `cargo-purifier` command: lock, prefetch or publish.
  perSystem =
    { config, pkgs, ... }:
    {
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.cargo-purifier // {
        default = config.packages.cargo-purifier;
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit ((pkgs.extend self.overlays.default).cargo-purifier) buildCargoProject;
              inherit (self.lib.cargo-purifier) readLock;
              inherit (self.packages.${system}) cargo-purifier;
              inherit (inputs) ripgrep;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
