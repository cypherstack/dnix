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
| `rust.outputHashes` | Hashes for git dependencies in the lock file, as nixpkgs' `importCargoLock` takes them: `{"<crate>-<version>": "sha256-…"}`. Put a wrong hash in first; the build fails and prints the right one. |
| `targets` | The target triples the package ships. See the list below. |
| `toolchains.rust` | The Rust version to build with, a stable release like `"1.99.1"`. Required. |
| `toolchains.xcode` | The Xcode version for Apple targets. Default `"27.0"`; must match the `macos-runner` the workflow uses. `toolchains.xcodeBuild` optionally pins the build number too, like `"27A266a"`, which tells a beta from the release. |
| `toolchains.*` | Overrides for the other pins: `zig`, `llvm`, `ndk`, `xwin`, `ndkLinux`. Defaults live in `nix/defaults.nix`. |
| `floors` | Lowest supported `macos`, `ios`, `android` (API level) as integers, and `glibc` as a string. Defaults: 12, 15, 24, `"2.28"`. |
| `paths` | Canonical path prefixes embedded instead of build directories: `workspace` (default `/<name>/<rust.workspace>`), `registry`, `registryIndex`. Defaults are fine. |

Supported targets: `aarch64-apple-darwin`, `x86_64-apple-darwin`,
`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`,
`aarch64-linux-android`, `armv7-linux-androideabi`, `i686-linux-android`,
`x86_64-linux-android`, `aarch64-unknown-linux-gnu`,
`x86_64-unknown-linux-gnu`, `x86_64-pc-windows-msvc`. Anything else is
rejected by both the hook and the flake.

The hook names the field for every mistake in the fields it reads, and
rejects unknown fields so a typo cannot fall back to a default. The Nix
side checks `toolchains`, `paths`, and the rest when it builds.

Every field except `asset` and `repository` is part of the bytes: `name`
and `rust.workspace` set the path prefix embedded in the libraries,
`library` names the file, and the toolchains and floors decide the code.
Changing any of them means a new lock and a new release.

## What the crate needs

- `crate-type` includes `cdylib`. The dynamic library is what ships; a
  `staticlib` beside it is built and kept in CI artifacts but not released.
- A release profile that does not depend on toolchain defaults, like the
  fixture in `fixtures/rust/Cargo.toml`:

  ```toml
  [profile.release]
  debug = false
  strip = "debuginfo"
  incremental = false
  ```

- A current `Cargo.lock` with every dependency: the build runs
  `cargo --locked --offline`. Git dependencies need `rust.outputHashes`.
- No `.cargo/config.toml` that changes codegen; the build sets its own
  flags and ignores configuration outside the workspace.
- No crate that turns `env!("CARGO_MANIFEST_DIR")` or `env!("OUT_DIR")`
  into a string in the library. Remapping covers the paths the compiler
  records, not those; the build fails if a build directory reaches the
  output.

Build scripts and proc macros are fine. Paths inside the build are remapped
to `/build`, `paths.workspace`, and the cargo registry prefix, so generated
code carries no host paths, and C and C++ compiled by build scripts get the
same flags. Build scripts see only the tools of the Nix build, or on a Mac
Xcode's tools plus the flake's shell, never Homebrew or `~/.cargo/bin`.

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
is below the floors, since those could not match the release.
