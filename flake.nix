{
  description = "Reproducible native assets for Dart packages: a flake library and the build hook that uses it";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Official Rust releases, fetched by hash rather than built from source.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Official zig releases, same reasoning.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, zig-overlay }:
    let
      dnixLib = import ./nix/lib.nix { inherit nixpkgs rust-overlay zig-overlay; };
      # The fixture crate exercises the Rust driver in this repository's own
      # CI; its outputs are exposed under a `fixture-` prefix.
      fixture = dnixLib.package {
        src = ./fixtures/rust;
        config = ./fixtures/rust/dnix.json;
      };
      prefixed = outputs: nixpkgs.lib.mapAttrs (_system: attrs:
        nixpkgs.lib.mapAttrs' (name: value: nixpkgs.lib.nameValuePair "fixture-${name}" value) attrs) outputs;
    in {
      lib = dnixLib;
      packages = prefixed fixture.packages;
      devShells = prefixed fixture.devShells;
    };
}
