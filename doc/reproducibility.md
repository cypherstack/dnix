# Reproducibility

Every non-Apple target is a Nix derivation built from toolchains pinned by
hash: the official Rust and zig releases, lld from nixpkgs for the MSVC
link, the Windows SDK fetched by xwin from a pinned Visual Studio channel
manifest, and the Android NDK. The pinned inputs carry the guarantee; the
Nix sandbox (on by default on Linux, `sandbox = true` in `nix.conf` on
macOS) additionally keeps the host out of the build.

Within a build, source paths are remapped onto canonical prefixes (the
build directory to `/build`, the workspace to `paths.workspace`, vendored
crates to the cargo registry prefix), C and C++ objects carry no debug info
or compiler identification, PE timestamps are fixed (lld-link derives them
from the content, zig's lld takes `SOURCE_DATE_EPOCH`), archives use the GNU
format with base names only, and deployment targets are fixed at the
floors. A library that still embeds a build directory, which happens when a
crate turns `env!("CARGO_MANIFEST_DIR")` into a string, fails the build
rather than differing per host.

Some C libraries record how they were built. OpenSSL keeps its compiler
command line and its install directories in `libcrypto`, which would carry
a store path that differs per host system and a build directory that
differs per machine. So every compiler, archiver, and ranlib is a wrapper
invoked by a bare name from `PATH`, the flags that name directories are
added inside the compiler wrapper rather than in `CFLAGS`, and a `-D` macro
whose value mentions the build directory is rewritten to `/build`, the name
the Linux sandbox gives it. What such a library records is then the same
everywhere, and no build can pick up the host's own `ranlib`, which on
macOS would rewrite an archive in Darwin format.

Three details make the output independent of the host that builds it:

- **Cargo's host triple.** Cargo mixes rustc's host triple into the metadata
  hash of build scripts and proc macros, and from there into the symbol hash
  of nearly every crate. Cargo reads `rustc -vV` through `RUSTC_WRAPPER`, so
  a wrapper answers that one query with a fixed host.
- **The C compiler.** nixpkgs' clang is a separate build per host platform
  and emitted different code on each. Linux and Windows targets compile C
  with zig's bundled clang instead, whose output is the same everywhere;
  for the MSVC ABI it runs as clang-cl, since build scripts that target it
  assume cl.exe's flag syntax, and for the GNU ABI it links with zig's
  MinGW-w64 runtime, the PE timestamp taken from `SOURCE_DATE_EPOCH` and
  no PDB. zig asks clang for CodeView on Windows, so each object names
  itself in a record even at `-g0`, which no prefix map reaches; the
  wrappers leave the name empty rather than the temporary under the build
  directory that zig compiled into. Android uses the NDK's clang with
  debug info and compiler identification off, which is where its host
  dependence lived.
- **The NDK's crt objects.** Google compiles each NDK host package's
  `crtbegin` objects with that package's own clang, and the darwin and Linux
  packages differ. Every host links the Linux package's objects.

Apple targets embed the SDK version, so they cannot be built in the sandbox.
They are built outside it with a pinned Xcode, inside the flake's `apple`
shell, with the same vendored crates, rustc wrapper, and path remaps, plus
the flags Mach-O needs (a location-independent install name with header
padding, no debug map from the linker, no post-link strip), under an
environment holding nothing from the caller's shell. The Xcode version is
pinned in `nix/defaults.nix` (`toolchains.xcode`, overridable in
`dnix.json`) and checked before building; `toolchains.xcodeBuild` pins the
build number as well, which tells a beta from the release.

## Environment and drivers

`nix/environment.nix` describes each target without reference to any build
tool: compiler, archiver, linker, flags, SDK directories, and a preparation
step. `nix/rust.nix` is the driver that reads those sets and runs cargo. A
Go or CMake driver would read the same sets and run its own tool; the parts
that took the effort to get right are shared.
