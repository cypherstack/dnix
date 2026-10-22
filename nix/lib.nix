# The flake library consumers call from their own flake.nix:
#
#   outputs = { self, dnix, ... }: dnix.lib.package {
#     src = self;
#     config = ./dnix.json;
#   };
#
# It returns `packages` and `devShells` for every supported system: one
# package per non-Apple target, `all` with a SHA256SUMS, `vendor`, and the
# `apple` shell whose `dnix-apple-build` command builds the Apple targets.
{ nixpkgs, rust-overlay, zig-overlay }:
let
  lib = nixpkgs.lib;
  defaults = import ./defaults.nix;
  # nixpkgs unstable no longer supports x86_64-darwin as a host. The x86_64
  # macOS target is still built, from an Apple Silicon host.
  systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
  # The same list as supportedTargets in lib/src/targets.dart.
  supportedTargets = [
    "aarch64-apple-darwin"
    "x86_64-apple-darwin"
    "aarch64-apple-ios"
    "aarch64-apple-ios-sim"
    "x86_64-apple-ios"
    "aarch64-linux-android"
    "armv7-linux-androideabi"
    "i686-linux-android"
    "x86_64-linux-android"
    "aarch64-unknown-linux-gnu"
    "x86_64-unknown-linux-gnu"
    "x86_64-pc-windows-msvc"
    "x86_64-pc-windows-gnullvm"
    "aarch64-pc-windows-msvc"
    "aarch64-pc-windows-gnullvm"
  ];

  # dnix.json on top of the defaults.
  resolveSettings = config:
    let
      user = builtins.fromJSON (builtins.readFile config);
      merged = lib.recursiveUpdate defaults user;
      rust = { manifest = "Cargo.toml"; outputHashes = { }; cflags = { }; env = { }; tools = [ ]; } // (user.rust or { });
      rustExtrasOk = builtins.isAttrs rust.cflags
        && builtins.all (target: builtins.elem target user.targets) (builtins.attrNames rust.cflags)
        && builtins.all (flags: builtins.isList flags && builtins.all builtins.isString flags) (builtins.attrValues rust.cflags)
        && builtins.isAttrs rust.env
        && builtins.all builtins.isString (builtins.attrValues rust.env)
        && builtins.isList rust.tools
        && builtins.all builtins.isString rust.tools;
      # Normalised the same way as the hook: no trailing slashes, no leading
      # ./, "." for the root; nothing absolute and nothing escaping the
      # package.
      given = rust.workspace or ".";
      trimmed = let m = builtins.match "(.*[^/])/*" given; in if m == null then "" else builtins.head m;
      stripped = lib.removePrefix "./" trimmed;
      workspace = if stripped == "" then "." else stripped;
      workspaceOk = !(lib.hasPrefix "/" given)
        && !(builtins.any (s: s == ".." || s == "") (lib.splitString "/" workspace))
        && builtins.match ".*[#?\\\\].*" workspace == null;
      unknown = lib.subtractLists supportedTargets user.targets;
    in
    assert lib.assertMsg (user ? name && user ? library && user ? targets)
      "dnix.json needs name, library, and targets";
    assert lib.assertMsg (unknown == [ ])
      "dnix.json lists targets dnix cannot build: ${toString unknown}";
    assert lib.assertMsg (user ? rust && rust ? workspace && rust ? crate)
      "dnix.json needs rust.workspace (the directory holding Cargo.lock) and rust.crate (the cargo package to build)";
    assert lib.assertMsg workspaceOk
      "dnix.json: rust.workspace must be a directory inside the package, relative to its root, like src/native or \".\", not \"${given}\"";
    assert lib.assertMsg rustExtrasOk
      "dnix.json: rust.cflags must map a listed target to a list of strings, rust.env a variable to a string, and rust.tools must list nixpkgs package names";
    assert lib.assertMsg (merged.toolchains ? rust)
      "dnix.json needs toolchains.rust, the Rust version to build with";
    merged // {
      rust = rust // { inherit workspace; };
      paths = {
        workspace = if workspace == "." then "/${merged.name}" else "/${merged.name}/${workspace}";
      } // merged.paths;
    };

  pkgsFor = system: import nixpkgs {
    inherit system;
    overlays = [ rust-overlay.overlays.default ];
    config = {
      # The Android NDK carries Google's SDK license.
      allowUnfree = true;
      android_sdk.accept_license = true;
    };
  };
in
{
  inherit systems defaults supportedTargets;

  package = { src, config }:
    let
      settings = resolveSettings config;
      perSystem = f: lib.genAttrs systems (system:
        let
          pkgs = pkgsFor system;
          zig = zig-overlay.packages.${system}.${settings.toolchains.zig};
          env = import ./environment.nix { inherit pkgs zig settings; };
        in f (import ./rust.nix {
          inherit pkgs zig env settings src;
          rust = settings.rust;
          name = settings.name;
        }));
    in {
      packages = perSystem (r: r.packages);
      devShells = perSystem (r: r.devShells);
    };
}
