# The Rust driver: builds one cdylib crate for every target the environment
# supports, from vendored crates, with cargo. Apple targets are built by
# apple-rust.sh inside the `apple` shell, since they need the host's Xcode.
{ pkgs, zig, env, settings, rust, src, name }:
let
  inherit (pkgs) lib stdenvNoCC;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  library = settings.library;
  paths = settings.paths;
  floors = settings.floors;
  registryPath = "${paths.registry}/${paths.registryIndex}";

  workspaceRoot = if rust.workspace == "." then src else src + "/${rust.workspace}";
  workspaceSrc = lib.cleanSourceWith {
    name = "${name}-workspace";
    src = workspaceRoot;
    # Cargo's build directory at the workspace root and the git store are
    # not source; a module directory named target deeper down is.
    filter = path: _type:
      path != toString workspaceRoot + "/target" && baseNameOf path != ".git";
  };

  # Official Rust release with the standard library for every target.
  rustToolchain = pkgs.rust-bin.stable.${settings.toolchains.rust}.minimal.override {
    targets = env.pureTargets ++ lib.optionals isDarwin env.appleTargets;
  };
  # nixpkgs wraps cargo-zigbuild with its own zig on PATH; point it at the
  # pinned official binary instead so the pin actually takes effect.
  cargoZigbuild = pkgs.cargo-zigbuild.override { inherit zig; };

  # Every crate in Cargo.lock, fetched by the checksum recorded there, laid
  # out as <name>-<version> directories like a cargo registry.
  vendor = pkgs.rustPlatform.importCargoLock {
    lockFile = workspaceSrc + "/Cargo.lock";
    outputHashes = rust.outputHashes;
  };

  # Cargo mixes every dependency's metadata hash into a crate's own, and for
  # build scripts and proc macros, which are compiled for the host, that hash
  # includes rustc's `host:` line. Every crate downstream of one therefore
  # gets a host-dependent symbol hash, which also reorders the emitted code.
  # Cargo reads `rustc -vV` through RUSTC_WRAPPER, so this wrapper answers
  # that one query with a fixed host and is transparent otherwise. The fixed
  # name is a real triple that is never a build target here, so no target
  # configuration can be mistaken for host configuration.
  fixedHost = "x86_64-unknown-linux-musl";
  rustcWrapper = pkgs.writeShellScript "rustc-fixed-host" ''
    if [ "$#" -eq 2 ] && [ "$2" = "-vV" ]; then
      "$1" -vV | sed 's/^host: .*/host: ${fixedHost}/'
      exit "''${PIPESTATUS[0]}"
    fi
    exec "$@"
  '';

  targetVariable = target: builtins.replaceStrings [ "-" ] [ "_" ] target;

  # The dynamic library first; the rest are copied when the crate builds them.
  outputsFor = target:
    if lib.hasInfix "-windows-" target
    then [ "${library}.dll" "${library}.dll.lib" "${library}.lib" ]
    else [ "lib${library}.so" "lib${library}.a" ];

  # importCargoLock writes the cargo configuration that serves every crate
  # from the vendored set, including a replacement section per git source,
  # with a placeholder for the vendor directory.
  cargoConfig = ''
    sed "s|cargo-vendor-dir|$vendor|" "$vendor/.cargo/config.toml" > "$CARGO_HOME/config.toml"
  '';

  mkTarget = target:
    let
      t = env.targets.${target};
      v = targetVariable target;
      # Linux goes through cargo-zigbuild, which configures the compiler,
      # archiver, and linker from the same zig itself.
      viaZigbuild = t ? zigTarget;
      outputs = outputsFor target;
    in stdenvNoCC.mkDerivation ({
      name = "${name}-${target}";
      src = workspaceSrc;
      nativeBuildInputs = [ rustToolchain ] ++ t.tools ++ lib.optionals viaZigbuild [ cargoZigbuild ];
      dontConfigure = true;
      # Fixup would strip and patch the outputs, changing their bytes.
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        ${env.setup}
        export CARGO_HOME=$TMPDIR/cargo-home
        mkdir -p "$CARGO_HOME"
        export RUSTC_WRAPPER=${rustcWrapper}
        vendor=$TMPDIR/vendor
        cp -RL ${vendor} "$vendor"
        chmod -R u+w "$vendor"
        ${cargoConfig}
        ${t.prepare}

        # Source paths are remapped onto the canonical prefixes, so the
        # build directory never reaches the binaries. Computed at build time
        # because the sandbox directory differs between Linux and macOS. The
        # catch-all comes first: rustc and clang take the last matching
        # prefix. It covers cargo's target directory, whose path otherwise
        # reaches code that build scripts generate.
        remaps=("$TMPDIR=/build" "$PWD=${paths.workspace}" "$vendor=${registryPath}")
        rustflags=()
        cflags=()
        for remap in "''${remaps[@]}"; do
          rustflags+=("--remap-path-prefix=$remap")
          cflags+=("-ffile-prefix-map=$remap")
        done
        for arg in ${lib.escapeShellArgs t.ldflags}; do
          rustflags+=("-Clink-arg=$arg")
        done
        for dir in "''${dnix_lib_dirs[@]}"; do
          rustflags+=("-Lnative=$dir")
        done
        cflags+=(${lib.escapeShellArgs t.cflags} "''${dnix_cflags[@]}")
        for dir in "''${dnix_include_dirs[@]}"; do
          cflags+=(-isystem "$dir")
        done
        export CARGO_ENCODED_RUSTFLAGS=$(IFS=$'\x1f'; printf '%s' "''${rustflags[*]}")
        # The cc crate reads CXXFLAGS for C++ sources, not CFLAGS.
        export CFLAGS_${v}="''${cflags[*]}" CXXFLAGS_${v}="''${cflags[*]}"

        cargo ${if viaZigbuild then "zigbuild" else "build"} \
          --locked --offline --release --lib --package ${rust.crate} \
          --manifest-path "$PWD/${rust.manifest}" \
          --target ${if viaZigbuild then "${target}.${floors.glibc}" else target} \
          --target-dir "$TMPDIR/target"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib"
        cp "$TMPDIR/target/${target}/release/${builtins.head outputs}" "$out/lib/"
        for name in ${lib.escapeShellArgs (builtins.tail outputs)}; do
          [ -e "$TMPDIR/target/${target}/release/$name" ] && cp "$TMPDIR/target/${target}/release/$name" "$out/lib/"
        done
        # Remapping covers paths the compiler records, not strings a crate
        # makes from env!("CARGO_MANIFEST_DIR") or env!("OUT_DIR"); those
        # would differ per host, so fail here rather than drift.
        for file in "$out"/lib/*; do
          if grep -a -q -F -e "$PWD" -e "$TMPDIR/target" -e "$TMPDIR/vendor" "$file"; then
            echo "$file embeds the build directory; a crate turns its manifest or output directory into a string, which no remap can fix" >&2
            exit 1
          fi
        done
        runHook postInstall
      '';
    } // lib.optionalAttrs (!viaZigbuild) {
      "CC_${v}" = t.cc;
      "CXX_${v}" = t.cxx;
      "AR_${v}" = t.ar;
      "CARGO_TARGET_${lib.toUpper v}_LINKER" = t.linker;
    });

  targetPackages = lib.genAttrs env.pureTargets mkTarget;

  # Every pure target this host can build, plus a SHA256SUMS to diff against
  # another host's.
  all = pkgs.runCommand "${name}-all" { } ''
    ${lib.concatMapStringsSep "\n" (target: ''
      mkdir -p "$out/${target}"
      cp ${targetPackages.${target}}/lib/* "$out/${target}/"
    '') env.pureTargets}
    cd "$out"
    find . -type f ! -name SHA256SUMS | sort | xargs -r sha256sum > SHA256SUMS
  '';

  # What apple-rust.sh needs, resolved here so the script carries no
  # defaults of its own.
  settingsFile = pkgs.writeText "${name}-dnix-settings.json" (builtins.toJSON settings);
  rustFile = pkgs.writeText "${name}-dnix-rust.json" (builtins.toJSON {
    inherit (rust) crate manifest;
    inherit library;
  });
  appleBuild = pkgs.writeShellScriptBin "dnix-apple-build" ''
    exec ${./apple-rust.sh} "$@"
  '';
in
{
  packages = targetPackages // {
    inherit vendor all;
    default = all;
  };
  devShells = {
    default = pkgs.mkShellNoCC {
      packages = [ rustToolchain zig cargoZigbuild pkgs.jq ];
    };
  } // lib.optionalAttrs isDarwin {
    # No C compiler from nixpkgs: Apple targets must link with Xcode's.
    apple = pkgs.mkShellNoCC {
      packages = [ rustToolchain pkgs.jq appleBuild ];
      # The same fixed host as the pure derivations, so crate metadata does
      # not depend on the Mac that builds.
      RUSTC_WRAPPER = rustcWrapper;
      DNIX_SETTINGS = settingsFile;
      DNIX_RUST = rustFile;
      DNIX_SRC = workspaceSrc;
      DNIX_VENDOR = vendor;
    };
  };
}
