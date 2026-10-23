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
  for. With the former default, 15, the hook refused every iOS build; the
  fixture's iOS libraries change bytes. The floor error now says what to
  change for each platform.
* The Windows host in CI loads every x64 Windows library before anything is
  released, and each host job may run for four hours instead of two.

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
