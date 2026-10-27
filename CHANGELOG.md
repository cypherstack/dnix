## Unreleased

* Three more Windows targets beside `x86_64-pc-windows-msvc`:
  `x86_64-pc-windows-gnullvm` and `aarch64-pc-windows-gnullvm` build with zig's
  MinGW-w64 toolchain, for C and C++ dependencies that need GCC-style flags,
  and `aarch64-pc-windows-msvc` with the SDK's arm64 libraries. A package
  lists the ABI it ships per architecture; the hook serves a Windows build
  from whichever is listed, and from the MSVC one when both are. The SDK is
  now fetched for both architectures, so a `toolchains.xwin` override needs
  the hash of such a splat.
* `rust.cflags` keys must be listed targets; flags for a target the package
  no longer builds are an error rather than silently ignored.
* A CMake build on a Windows target can compile resource scripts: the
  `llvm-rc` on its path has a clang for its preprocessing.
* zig compiles C without its debug-mode sanitizer. A library whose C was
  compiled with no optimisation level changes bytes; one compiled with
  `-O1` or higher does not.
* The default iOS floor is 13, the version Flutter 3.47 asks native assets
  for. With the former default, 15, the hook refused every iOS build. A
  package that kept the default gets new iOS bytes with this version: run
  `dart tool/update_lock.dart`, commit the lock, and the default branch
  publishes the new release. The floor error now says what to change.
* The Windows host in CI loads every x64 Windows library the package lists,
  resolving imports against Windows' own DLLs only, before anything is
  released; a library that fails to load fails the run with the reason.
  Each host job may run for four hours instead of two.
* The workflows pin every action to a commit, the publishing job's included.
* bindgen loads libclang from the pinned LLVM. A crate that generates
  bindings no longer fails to build on Linux, where the sandbox has no
  libclang, nor depends on the Mac's Xcode or Command Line Tools on macOS.
* A library built on macOS is now byte-identical to the same library built
  on Linux. Three things differed by build host, and each change below can
  alter a package's bytes once; run `dart tool/update_lock.dart` after
  updating dnix:
  * Cargo resolved build scripts' and proc macros' dependencies for the
    machine running the build, so a dependency that only one host's
    platform needs changed the symbol hashes of everything above it. A
    platform condition in a vendored manifest that holds on some build
    hosts and not on others now holds on all of them for build-time
    dependencies; what the library itself links is unchanged.
  * LLVM sorts some lists with the C library's `qsort`, and glibc and macOS
    order equal elements differently, which changed instruction order and
    the names of promoted symbols on ARM targets. rustc runs with a `qsort`
    that is glibc's merge sort on every host, and a build stops if rustc
    did not load it.
  * bindgen ran Xcode's clang on macOS, and none on Linux, to find header
    directories, so the same header gave different bindings. It now runs
    the clang that belongs to the pinned libclang, and Android builds hand
    it the NDK's sysroot.
* A target keeps only its dynamic library, the file the lock records and
  the hook ships. A static library or import library the crate also builds
  is no longer in the build output, the CI artifacts, or `SHA256SUMS`; its
  member names and debug info carry the build directory and toolchain
  paths, so it could not be compared across machines.

## 0.1.0

* Initial release, extracted from frostdart: the build hook with its
  prebuilt, source, and dev modes; the Nix environment and Rust driver; the
  Apple build through a pinned Xcode; the reusable workflow that verifies
  every push on four hosts and publishes releases; and the tools that
  update the lock and verify a platform.
* `dnix.lock` is a source file written by `update_lock`: it records what the
  native source builds to and names the release, derived from the hashes,
  that holds those bytes. CI fails when the source and the lock disagree and
  publishes the release from the default branch.
