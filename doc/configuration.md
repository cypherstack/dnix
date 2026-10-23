# Configuration

## dnix.json

The facts about the package that both the hook and the Nix build read.

| Field | Meaning |
|---|---|
| `name` | The package name, used in messages and as the default path prefix. |
| `repository` | The GitHub repository URL. Prebuilt libraries download from its releases. A trailing `.git` is ignored. |
| `library` | The library's base name, without `lib` or an extension. `hrf_api` means `libhrf_api.so`, `libhrf_api.dylib`, `hrf_api.dll`. |
| `asset` | The code asset name the package's `@Native` bindings reference. |
| `rust.workspace` | Directory holding `Cargo.lock`, relative to the package root. `"."` for the root. |
| `rust.crate` | The cargo package to build. |
| `rust.manifest` | `Cargo.toml` to pass to cargo, relative to the workspace. Default `Cargo.toml`. |
| `rust.cflags` | Extra C and C++ flags per target, `{"<target>": ["-D…"]}`, appended to what dnix sets. For a `-sys` crate that needs a define on one platform. Every key must be a listed target, so flags do not go stale unnoticed when a target changes. |
| `rust.env` | Extra environment variables for the build, `{"NAME": "value"}`, set for every target. For example `CXXSTDLIB_aarch64_linux_android: "static:-bundle=c++"` links the NDK's C++ runtime statically instead of shipping `libc++_shared.so`. Not for `CFLAGS`, `CXXFLAGS`, or `RUSTFLAGS`, which dnix composes itself. |
| `rust.tools` | Extra tools build scripts run, as nixpkgs package names, like `["protobuf"]` for a crate that runs `protoc`. They are on `PATH` in the sandbox and in the Apple shell; `perl` and `make` are always there. Their output must not depend on the host, which holds for code generators. |
| `rust.outputHashes` | Normally empty: git dependencies are fetched at the revision `Cargo.lock` records. Only a lock that names a git source without a full revision needs hashes here, as nixpkgs' `importCargoLock` takes them: `{"<crate>-<version>": "sha256-…"}`. |
| `targets` | The target triples the package ships. See the list below. |
| `toolchains.rust` | The Rust version to build with, a stable release like `"1.99.1"`. Required. |
| `toolchains.xcode` | The Xcode version for Apple targets. Default `"27.0"`; must match the `macos-runner` the workflow uses. `toolchains.xcodeBuild` optionally pins the build number too, like `"27A266a"`, which tells a beta from the release. |
| `toolchains.*` | Overrides for the other pins: `zig`, `llvm`, `ndk`, `xwin`, `ndkLinux`. Defaults live in `nix/defaults.nix`. An MSVC Windows target fetches the SDK for x86_64 and arm64 together, whichever of the two it is for, so an `xwin` override gives the hash of a splat that holds both; the GNU Windows targets fetch no SDK. |
| `floors` | Lowest supported `macos`, `ios`, `android` (API level) as integers, and `glibc` as a string. Defaults: 12, 13, 24, `"2.28"`. iOS and macOS cannot go above 13: Flutter 3.47 asks native assets for iOS 13 and macOS 13, and writes 13.0 into each iOS framework as its minimum. |
| `paths` | Canonical path prefixes embedded instead of build directories: `workspace` (default `/<name>/<rust.workspace>`), `registry`, `registryIndex`. Defaults are fine. |

Supported targets: `aarch64-apple-darwin`, `x86_64-apple-darwin`,
`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`,
`aarch64-linux-android`, `armv7-linux-androideabi`, `i686-linux-android`,
`x86_64-linux-android`, `aarch64-unknown-linux-gnu`,
`x86_64-unknown-linux-gnu`, `x86_64-pc-windows-msvc`,
`x86_64-pc-windows-gnullvm`, `aarch64-pc-windows-msvc`,
`aarch64-pc-windows-gnullvm`. Anything else is rejected by both the hook
and the flake.

Windows comes in two ABIs per architecture. MSVC is what Rust and Flutter
default to; GNU is MinGW-w64 in Rust's `-gnullvm` flavour, built as the
LLVM toolchain builds it, which zig's is. (Rust's older
`x86_64-pc-windows-gnu` assumes GCC's runtime and unwinder, and links far
more of the standard library into a DLL.) List the one the package should
ship, for each architecture it supports: Flutter asks for
the arm64 triple when it builds for Windows on arm, and a package that
lists none for an architecture fails there. The hook serves a Windows
build from whichever ABI is listed, and from the MSVC one when both are.
Listing both builds and publishes both, though no hook then asks for the
GNU one; dnix's own fixture lists all four to prove them.

What decides the choice is the C and C++ in the dependency tree; a crate
without any takes MSVC, the default. On the MSVC targets C is compiled by
clang-cl, which takes cl.exe's flags, with the Windows SDK in scope; a
dependency that needs Microsoft's own compiler builds on neither ABI, and
MASM assembly is assembled only in CMake builds on x86_64, through
`llvm-ml` (the cc crate looks for `ml64.exe`, which is not there, and
LLVM has no MASM assembler for arm64; GNU-syntax `.S` sources are fine
everywhere). On the GNU targets C is compiled by zig's clang in its
GCC-style driver with zig's MinGW-w64 headers, so GCC-style flags and
MinGW conventions apply, `rust.cflags` for the target are spelled that
way, and nothing of the SDK is in scope. What ships differs too: an MSVC
DLL imports the Visual C++ runtime (`vcruntime140.dll`, and `msvcp140.dll`
for C++), the redistributable a Flutter Windows application needs anyway;
a GNU DLL links zig's runtime pieces statically and imports only system
DLLs, at the cost of a larger file. Both allocate from the Universal C
Runtime's heap, so an application loads either kind and may mix them
across packages.

The hook names the field for every mistake in the fields it reads, and
rejects unknown fields so a typo cannot fall back to a default. The Nix
side checks `toolchains`, `paths`, and the rest when it builds.

Every field except `asset` and `repository` is part of the bytes: `name`
and `rust.workspace` set the path prefix embedded in the libraries,
`library` names the file, and the toolchains and floors decide the code.
Changing any of them means a new lock and a new release.

## What the crate needs

- `crate-type` includes `cdylib`. The dynamic library is what ships and the
  only file a build keeps; a `staticlib` or import library the crate also
  builds is left behind.
- A release profile that does not depend on toolchain defaults, like the
  fixture in `fixtures/rust/Cargo.toml`:

  ```toml
  [profile.release]
  debug = false
  strip = "debuginfo"
  incremental = false
  ```

- A current `Cargo.lock` with every dependency: the build runs
  `cargo --locked --offline`. Git dependencies are fine; they are fetched
  at the locked revision.
- No `.cargo/config.toml` that changes codegen; the build sets its own
  flags and ignores configuration outside the workspace.
- Build scripts that configure a C library the classic way, such as
  `openssl-src`, work: `perl` and `make` are in the build, and the compiler
  is invoked by a bare name so what such a library records about its build
  is the same on every host.
- No crate that turns `env!("CARGO_MANIFEST_DIR")` or `env!("OUT_DIR")`
  into a string in the library. Remapping covers the paths the compiler
  records, not those; the build fails if a build directory reaches the
  output.

Build scripts and proc macros are fine. Paths inside the build are remapped
to `/build`, `paths.workspace`, and the cargo registry prefix, so generated
code carries no host paths, and C and C++ compiled by build scripts get the
same flags. On the MSVC Windows targets the compiler is clang-cl with C++
exceptions on, as in a Visual Studio project; it takes cl.exe's flags as
well as clang's, so a build script written for either works, and `lib.exe`
is on `PATH` for build scripts that run it by name. On the GNU Windows
targets it is zig's clang as on Linux, with zig's MinGW-w64 headers and
runtime, and C++ gets zig's libc++ whether a build script asks for `c++`
or `stdc++`. A CMake build on Windows (the `cmake` crate, with `cmake` in
`rust.tools`) uses Ninja and a toolchain file that names the same compiler,
`llvm-rc` for resources, and for MSVC LLVM's `llvm-ml` (x86_64 only) and
`lld-link`. On the GNU targets the cmake crate names the C compiler as the
resource compiler itself; the wrapper hands a resource script on to
`llvm-rc`, preprocessed with the target's headers in scope. bindgen is
told the clang spelling of the GNU triple through `BINDGEN_EXTRA_CLANG_ARGS`,
since clang rejects `-gnullvm`; a package that sets that variable itself
keeps the `--target` in it.
Build scripts see only the tools of the Nix build, or on a Mac Xcode's
tools plus the flake's shell, never Homebrew or `~/.cargo/bin`.

## dnix.lock

What the native source currently builds to. Written by
`dart tool/update_lock.dart`, committed with the change that affected it.

```json
{
  "release": "3f9a1c2b7d4e",
  "date": "2026-10-21",
  "files": {
    "aarch64-apple-darwin/libhrf_api.dylib": "8e04…",
    "x86_64-unknown-linux-gnu/libhrf_api.so": "73e8…"
  }
}
```

- `release` is derived from the hashes: the first twelve hex digits of the
  SHA-256 over the sorted `<file>  <hash>` lines. The GitHub release and tag
  are named `native-<release>`. It changes exactly when the bytes change,
  and a lock whose `release` does not match its hashes is rejected, so a
  mangled merge is caught before anything is downloaded.
- `date` is for people reading the file. Rewriting the lock with unchanged
  hashes keeps it, so the file stays byte-identical.
- `files` lists every dynamic library by `<target>/<file name>`.

The lock does not affect the bytes, so a commit that only adds the lock
builds to the same libraries as the commit before it.

## The flake

`dnix.lib.package { src, config }` returns the package's flake outputs.
`src` is the package directory, normally `self`; `config` is `dnix.json`.

Outputs, per supported host system (`x86_64-linux`, `aarch64-linux`,
`aarch64-darwin`): one package per non-Apple target this host can build,
`all` with a `SHA256SUMS`, `vendor`, the `default` shell, and on macOS the
`apple` shell whose `dnix-apple-build <out-dir> [target...]` builds the
Apple targets. Android targets are not built on `aarch64-linux`, which has
no NDK; Intel Macs are not supported hosts.

Nix reads a git checkout as a flake of its tracked files, so a new file is
invisible until `git add`. The consumer's `flake.lock` has one direct input,
`dnix`; nixpkgs and the Rust and zig overlays are nested under it and are
pinned there too. They decide the bytes as much as dnix does, so commit the
lock and change it on purpose (see the bump section of
[workflow.md](workflow.md)).

## Build modes

The hook's mode comes from a `.dnix-build` file in the package checkout,
then the package's `build` user define in the app's `pubspec.yaml`, then
defaults to `prebuilt`. Hooks receive almost no environment variables, so
none is consulted.

```sh
echo dev > .dnix-build      # while working on the package; add it to .gitignore
```

```yaml
hooks:
  user_defines:
    frostdart:
      build: source         # in an app's pubspec.yaml
```

| Mode | What happens | Needs |
|---|---|---|
| `prebuilt` | Downloads the library of the release `dnix.lock` names and verifies its hash. | Dart only. |
| `source` | Builds with Nix exactly as the release did and verifies the same hash. | Nix on Linux or an Apple Silicon Mac; the pinned Xcode for Apple targets. |
| `dev` | Builds with Nix, skipping the Xcode pin and the hash check. | Nix on Linux or an Apple Silicon Mac. |

On Windows and on Intel Macs the hook can only use prebuilt libraries. Nix
runs on Windows inside WSL2, where the tools work but the hook of a Windows
Dart process does not.

In `source` and `dev` mode the hook declares the flake files and the
workspace's files (the git-tracked ones in a checkout, which is what Nix
builds from) as inputs, so editing the native code rebuilds. The hook only
notices files that existed when it last ran: a `.dnix-build` created after
a build takes effect once something else reruns the hook, such as touching
`dnix.json`. Before the first lock exists every mode falls back to `dev`.
The hook refuses static linking and refuses builds whose deployment target
is below the floors, since those could not match the release. Flutter asks
for iOS 13 and macOS 13 whatever the application's own deployment target,
so floors above those make every Apple build fail.
