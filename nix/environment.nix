# The per-target build environment: which compiler, archiver, and linker
# each target uses, the flags that keep their output host-independent, and
# the SDKs they need. Nothing here knows which build tool consumes it; the
# language drivers (rust.nix and later ones) read these attribute sets.
#
# Every target set has: cc, cxx, ar, ranlib, linker (names of wrappers that `tools`
# puts on PATH; see cc-wrapper.sh for why names rather than paths), cflags
# and ldflags (lists of host-independent flags), includeFlag and
# prefixMapFlag (how the compiler spells a system include directory and a
# path remap, since clang-cl spells them differently), tools
# (nativeBuildInputs), and prepare (bash run before the build, which may
# append to the arrays dnix_cflags, dnix_include_dirs, and dnix_lib_dirs).
# Linux targets add zigTarget, the zig triple with the glibc floor.
{ pkgs, zig, settings }:
let
  inherit (pkgs) lib stdenvNoCC;
  system = pkgs.stdenv.hostPlatform.system;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  toolchains = settings.toolchains;
  floors = settings.floors;

  linuxTargets = builtins.filter (lib.hasSuffix "-linux-gnu") settings.targets;
  androidTargets = builtins.filter (lib.hasInfix "-linux-android") settings.targets;
  windowsTargets = builtins.filter (lib.hasInfix "-windows-msvc") settings.targets;
  appleTargets = builtins.filter (lib.hasInfix "-apple-") settings.targets;
  # Google ships no NDK host binaries for aarch64 Linux.
  androidSupported = system != "aarch64-linux";
  pureTargets = linuxTargets ++ lib.optionals androidSupported androidTargets ++ windowsTargets;

  llvm = pkgs."llvmPackages_${toString toolchains.llvm}";

  # No debug info in the C objects: with it, the static libraries carry
  # compiler, include, and object paths that differ between hosts. No
  # compiler identification either: the NDK's clang stamps host-specific
  # build flags into it.
  baseCflags = [ "-g0" "-fno-ident" ];

  # Every compiler is a wrapper invoked by a bare name from a bin directory
  # on PATH, through cc-wrapper.sh. A build that records its compiler
  # (OpenSSL's build info, for one) then records a name that is the same on
  # every host, not a store path that differs per host system. The script
  # runs under the store's bash: the Linux sandbox has no /usr/bin/env for
  # its shebang to find.
  wrap = name: command: pkgs.writeShellScriptBin name ''
    exec ${pkgs.runtimeShell} ${./cc-wrapper.sh} ${command} -- "$@"
  '';
  # Archivers take no compiler flags, so they skip the wrapper's additions.
  wrapTool = name: command: pkgs.writeShellScriptBin name ''
    exec ${command} "$@"
  '';
  ccName = target: "dnix-cc-${target}";
  cxxName = target: "dnix-c++-${target}";
  # The name contains "llvm-ar" so the cc crate uses ar-style invocation,
  # which stores base names rather than paths. ranlib is the same tool's
  # `s` operation: left to be found on PATH, a build like OpenSSL's would
  # run the host's ranlib and rewrite the archive in the host's format.
  arName = target: "llvm-ar-dnix-${target}";
  ranlibName = target: "llvm-ranlib-dnix-${target}";

  # zig's clang takes its target from -target; the cc crate's --target with
  # the Rust spelling of the triple would be rejected, so it is dropped.
  wrapWithoutTarget = name: command: pkgs.writeShellScriptBin name ''
    args=()
    for arg in "$@"; do
      case "$arg" in --target=*) ;; *) args+=("$arg") ;; esac
    done
    exec ${pkgs.runtimeShell} ${./cc-wrapper.sh} ${command} -- "''${args[@]}"
  '';
  wrapZig = name: zigArgs: wrapWithoutTarget name "${zig}/bin/zig ${zigArgs}";

  # Linux: zig provides the C compiler, linker, and a glibc at the floor
  # version, so the result does not depend on the host's toolchain.
  zigTriple = target: "${builtins.replaceStrings [ "-unknown-linux-gnu" ] [ "-linux-gnu" ] target}.${floors.glibc}";
  zigCc = target: wrapZig (ccName target) "cc -target ${zigTriple target}";
  zigCxx = target: wrapZig (cxxName target) "c++ -target ${zigTriple target}";
  zigAr = target: wrapTool (arName target) "${zig}/bin/zig ar";
  zigRanlib = target: wrapTool (ranlibName target) "${zig}/bin/zig ar s";

  # Android: the pinned NDK's clang at the API floor.
  androidSdk = (pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
    ndkVersions = [ toolchains.ndk ];
  }).androidsdk;
  ndkHost = if isDarwin then "darwin-x86_64" else "linux-x86_64";
  ndkBin = "${androidSdk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/${ndkHost}/bin";
  # Google compiles each NDK host package's crtbegin objects with that
  # package's own clang, so the darwin and Linux packages ship different
  # bytes for them, and crtbegin_so.o is linked into every shared library.
  # Every host links the Linux package's objects instead. The checksum is
  # the one androidenv records for the same download.
  ndkLinuxZip = pkgs.fetchurl {
    url = toolchains.ndkLinux.url;
    sha256 = toolchains.ndkLinux.sha256;
  };
  androidCrt = pkgs.runCommand "android-ndk-crt-${toolchains.ndk}" {
    nativeBuildInputs = [ pkgs.unzip ];
  } ''
    unzip -q ${ndkLinuxZip} \
      'android-ndk-*/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/*/${toString floors.android}/crt*.o' \
      -d "$TMPDIR/ndk"
    cd "$TMPDIR"/ndk/android-ndk-*/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib
    for abi in *; do
      mkdir -p "$out/$abi"
      cp "$abi/${toString floors.android}"/crt*.o "$out/$abi/"
    done
  '';
  # Sysroot directory names differ from the Rust triples for 32-bit ARM.
  androidSysrootDir = target:
    builtins.replaceStrings [ "armv7-linux-androideabi" ] [ "arm-linux-androideabi" ] target;
  androidClang = target:
    "${ndkBin}/${builtins.replaceStrings [ "armv7-" ] [ "armv7a-" ] target}${toString floors.android}-clang";
  # The NDK's per-API driver sets --target with the API level; the cc
  # crate's own --target without one would come later and win, which
  # changes the API the headers assume. Drop the cc crate's.
  androidCc = target: wrapWithoutTarget (ccName target) (androidClang target);
  androidCxx = target: wrapWithoutTarget (cxxName target) "${androidClang target}++";
  # llvm-ar in GNU format.
  androidArchiver = target: wrapTool (arName target) "${llvm.llvm}/bin/llvm-ar --format=gnu";
  androidRanlib = target: wrapTool (ranlibName target) "${llvm.llvm}/bin/llvm-ar --format=gnu s";

  # Windows SDK and CRT, fetched by xwin from Microsoft's CDN. The Visual
  # Studio channel manifest is pinned by its content-addressed URL and names
  # every package with a hash, so the download set is fixed. Fixed-output:
  # the first build reports the hash to put into toolchains.xwin.splatHash.
  vsChannel = pkgs.fetchurl {
    url = toolchains.xwin.channelUrl;
    sha256 = toolchains.xwin.channelSha256;
  };
  xwinSdk = stdenvNoCC.mkDerivation {
    name = "xwin-sdk";
    nativeBuildInputs = [ pkgs.xwin ];
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash =
      if toolchains.xwin.splatHash == "" then lib.fakeHash else toolchains.xwin.splatHash;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    buildCommand = ''
      export HOME=$TMPDIR
      # xwin only adds its case-fixing symlinks on case-sensitive file
      # systems, which would make this output differ between hosts. Skip
      # them here; the Windows build generates its own view below. Copy
      # rather than move: the build directory and the store are usually on
      # different file systems, and a rename across them fails.
      xwin --accept-license --arch x86_64 --variant desktop \
        --manifest ${vsChannel} --cache-dir "$TMPDIR/xwin-cache" \
        splat --disable-symlinks --copy --output "$out"
    '';
  };
  # zig's clang in its cl driver mode. Build scripts that target the MSVC
  # ABI assume cl.exe's syntax (ring 0.16 passes /GS and names its output
  # with /Fo), and the cc crate drives a compiler called clang-cl that way
  # too, so the compiler has to take cl's flags as well as clang's; the
  # name tells the cc crate which driver it is. zig keeps clang's builtin
  # headers under lib/include, where a resource directory of lib has them.
  # C++ exceptions are on, as in a Visual Studio project: cl.exe compiles
  # a `throw` without them and warns, clang-cl refuses (bitcoinconsensus
  # throws). A flag from the build script comes later and wins.
  windowsCcName = target: "dnix-clang-cl-${target}";
  windowsCc = target: wrap (windowsCcName target)
    "${zig}/bin/zig clang --driver-mode=cl --target=x86_64-pc-windows-msvc -resource-dir ${zig}/lib /EHsc";
  # Two conventions reach the archiver: ar's (`cq archive objects`, from
  # the cc crate when the archiver's name says llvm-ar) and lib.exe's
  # (`-out:archive objects`, from cc crates before 1.0.9x on any MSVC
  # target, and from the old gcc crate, which runs whatever `lib.exe` is on
  # PATH, so the same script is installed under that name too). Both
  # produce a GNU-format archive of base names. The objects keep their
  # CodeView sections: the linker drops them without a PDB, and removing
  # them would renumber the symbols that the address-significance table
  # refers to, which the linker then rejects.
  windowsArchiver = target: windowsArchiverNamed (arName target);
  windowsLib = windowsArchiverNamed "lib.exe";
  windowsArchiverNamed = name: pkgs.writeShellScriptBin name ''
    lib=
    for arg in "$@"; do
      case "$arg" in -out:*|/out:*|-OUT:*|/OUT:*) lib=1 ;; esac
    done
    if [ -n "$lib" ]; then
      out=
      objects=()
      for arg in "$@"; do
        case "$arg" in
          -out:*|/out:*|-OUT:*|/OUT:*) out=''${arg#*:} ;;
          # lib.exe options (/nologo, CMake's /machine:x64) look like
          # absolute paths; an object is a path that exists.
          /[A-Za-z]*|-[A-Za-z]*) if [ -e "$arg" ]; then objects+=("$arg"); fi ;;
          *) objects+=("$arg") ;;
        esac
      done
      # lib.exe takes the archive it extends as an input; ar appends to it.
      inputs=()
      for arg in "''${objects[@]}"; do
        if [ "$arg" != "$out" ]; then inputs+=("$arg"); fi
      done
      set -- qcs "$out" "''${inputs[@]}"
    fi
    exec ${llvm.llvm}/bin/llvm-ar --format=gnu "$@"
  '';
  windowsRanlib = target: wrapTool (ranlibName target) "${llvm.llvm}/bin/llvm-ar --format=gnu s";
  windowsIncludeDirs = [ "crt/include" "sdk/include/ucrt" "sdk/include/um" "sdk/include/shared" ];
  windowsLibDirs = [ "crt/lib/x86_64" "sdk/lib/um/x86_64" "sdk/lib/ucrt/x86_64" ];
  # The SDK's headers and import libraries reference each other with
  # casings that differ from the file names, and rustc asks for lowercase
  # import libraries. On a case-sensitive file system that needs symlinks.
  # Build an overlay next to the SDK with every lowercase name plus every
  # casing an #include directive uses, and search both. The overlay is
  # derived purely from the SDK contents.
  windowsPrepare = target: ''
    sdk=${xwinSdk}
    overlay=$TMPDIR/xwin-overlay
    include_dirs="${toString windowsIncludeDirs}"
    lib_dirs="${toString windowsLibDirs}"
    for dir in $include_dirs $lib_dirs; do
      mkdir -p "$overlay/$dir"
      for file in "$sdk/$dir"/*; do
        printf 'file\t%s\t%s\n' "$dir" "''${file##*/}"
      done
    done > "$TMPDIR/xwin-files"
    grep -rhoE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"][^>"]+[>"]' \
      $(printf "$sdk/%s " $include_dirs) > "$TMPDIR/xwin-refs" || true
    # Emit "dir, link name, file name" for every lowercase alias and for
    # every casing an #include directive uses that differs from the file.
    awk -F'\t' -v dirs="$include_dirs" '
      BEGIN { n = split(dirs, include, " ") }
      $1 == "file" {
        name[$2 "/" tolower($3)] = $3
        if ($3 != tolower($3)) print $2 "\t" tolower($3) "\t" $3
      }
      /^[[:space:]]*#/ && match($0, /[<"][^>"]+[>"]/) {
        base = substr($0, RSTART + 1, RLENGTH - 2)
        sub(/.*\//, "", base)
        for (i = 1; i <= n; i++) {
          key = include[i] "/" tolower(base)
          if (key in name && name[key] != base) print include[i] "\t" base "\t" name[key]
        }
      }
    ' "$TMPDIR/xwin-files" "$TMPDIR/xwin-refs" | sort -u \
      | while IFS=$'\t' read -r dir link file; do
      [ -e "$overlay/$dir/$link" ] || ln -s "$sdk/$dir/$file" "$overlay/$dir/$link"
    done
    for dir in $include_dirs; do
      dnix_include_dirs+=("$sdk/$dir" "$overlay/$dir")
    done
    for dir in $lib_dirs; do
      dnix_lib_dirs+=("$sdk/$dir" "$overlay/$dir")
    done
    # CMake builds (the cmake crate) get a toolchain file naming the
    # platform, the same clang-cl, and LLVM's stand-ins for Microsoft's
    # tools, as cargo-zigbuild gives Linux builds one. Compile tests link
    # nothing, so no project has to find a C runtime on its own.
    export CMAKE_GENERATOR=Ninja
    export CMAKE_TOOLCHAIN_FILE=$TMPDIR/dnix-windows.cmake
    libpaths=
    for dir in "''${dnix_lib_dirs[@]}"; do libpaths="$libpaths /libpath:$dir"; done
    cat > "$CMAKE_TOOLCHAIN_FILE" <<EOF
    set(CMAKE_SYSTEM_NAME Windows)
    set(CMAKE_SYSTEM_PROCESSOR AMD64)
    set(CMAKE_C_COMPILER $(command -v ${windowsCcName target}))
    set(CMAKE_CXX_COMPILER $(command -v ${windowsCcName target}))
    set(CMAKE_ASM_MASM_COMPILER $(command -v llvm-ml))
    set(CMAKE_ASM_MASM_FLAGS_INIT -m64)
    set(CMAKE_RC_COMPILER $(command -v llvm-rc))
    set(CMAKE_MT $(command -v llvm-mt))
    set(CMAKE_AR $(command -v lib.exe))
    set(CMAKE_LINKER $(command -v lld-link))
    set(CMAKE_EXE_LINKER_FLAGS_INIT "$libpaths")
    set(CMAKE_SHARED_LINKER_FLAGS_INIT "$libpaths")
    set(CMAKE_MODULE_LINKER_FLAGS_INIT "$libpaths")
    set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
    EOF
  '';

  linuxTarget = target: {
    cc = ccName target;
    cxx = cxxName target;
    ar = arName target;
    ranlib = ranlibName target;
    linker = ccName target;
    cflags = baseCflags;
    ldflags = [ ];
    includeFlag = "-isystem";
    prefixMapFlag = "-ffile-prefix-map=";
    tools = [ zig (zigCc target) (zigCxx target) (zigAr target) (zigRanlib target) ];
    prepare = "";
    zigTarget = zigTriple target;
  };
  androidTarget = target: {
    cc = ccName target;
    cxx = cxxName target;
    ar = arName target;
    ranlib = ranlibName target;
    linker = ccName target;
    cflags = baseCflags;
    # -B makes clang take crtbegin_so.o and crtend_so.o from here first.
    ldflags = [ "-B${androidCrt}/${androidSysrootDir target}" ];
    includeFlag = "-isystem";
    prefixMapFlag = "-ffile-prefix-map=";
    tools = [ (androidCc target) (androidCxx target) (androidArchiver target) (androidRanlib target) ];
    # CMake-based build scripts find the NDK's toolchain file through these.
    prepare = ''
      export ANDROID_NDK_ROOT=${androidSdk}/libexec/android-sdk/ndk-bundle
      export ANDROID_NDK_HOME=$ANDROID_NDK_ROOT
    '';
  };
  windowsTarget = target: {
    cc = windowsCcName target;
    cxx = windowsCcName target;
    ar = arName target;
    ranlib = ranlibName target;
    linker = "lld-link";
    # No debug info is the cl driver's default (-g0 is not a cl flag). No
    # compiler identification, and no timestamp in the COFF objects: clang
    # stamps one for incremental linking unless told otherwise, which the
    # cc crate does with -Brepro but a build script may not.
    cflags = [ "-fno-ident" "-gno-codeview-command-line" "-mno-incremental-linker-compatible" ];
    # /Brepro derives the PE timestamp from the content. No PDB: its
    # content-derived GUID would otherwise land in the DLL.
    ldflags = [ "/Brepro" "/DEBUG:NONE" ];
    # clang-cl ignores -isystem and -ffile-prefix-map; these are its forms.
    includeFlag = "/imsvc";
    prefixMapFlag = "/clang:-ffile-prefix-map=";
    tools = [ zig llvm.lld llvm.llvm pkgs.ninja (windowsCc target) (windowsArchiver target) windowsLib (windowsRanlib target) ];
    prepare = windowsPrepare target;
  };
in
{
  inherit pureTargets appleTargets linuxTargets androidTargets windowsTargets xwinSdk;
  targets = lib.genAttrs pureTargets (target:
    if lib.elem target linuxTargets then linuxTarget target
    else if lib.elem target androidTargets then androidTarget target
    else windowsTarget target);
  # Bash every driver runs first: caches inside the sandbox, a fixed
  # timestamp for anything that stamps one.
  setup = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/cache
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
    export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
    export SOURCE_DATE_EPOCH=0
    dnix_cflags=()
    dnix_include_dirs=()
    dnix_lib_dirs=()
  '';
}
