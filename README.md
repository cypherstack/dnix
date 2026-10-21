# dnix

Native libraries for Dart packages that anyone can rebuild, byte for byte.

A package that ships a Rust library adds dnix and gets:

- a build hook that downloads the library for the exact release the package
  was published with and checks its hash, or builds it the same way;
- a Nix build whose Linux, Android, and Windows libraries are identical on
  every machine, and whose Apple libraries are identical on every Mac with
  the pinned Xcode;
- CI that rebuilds on four machines, fails if a byte differs, and publishes
  the releases.

## Setup

1. Depend on dnix in `pubspec.yaml` (from git until it is on pub.dev):

   ```yaml
   dependencies:
     dnix:
       git:
         url: https://github.com/cypherstack/dnix.git
         ref: <commit>
   ```

2. `hook/build.dart`:

   ```dart
   import 'package:dnix/dnix.dart';

   void main(List<String> args) => buildNativeLibrary(args);
   ```

3. `dnix.json` in the package root:

   ```json
   {
     "name": "frostdart",
     "repository": "https://github.com/cypherstack/frostdart",
     "library": "hrf_api",
     "asset": "frostdart_bindings_generated.dart",
     "rust": { "workspace": "src/serai", "crate": "hrf-api" },
     "toolchains": { "rust": "1.99.1" },
     "targets": ["aarch64-apple-darwin", "x86_64-unknown-linux-gnu"]
   }
   ```

   `library` is the crate's library name (`hrf-api` builds `hrf_api`), and
   the crate must build a `cdylib` with an explicit release profile (see
   [doc/configuration.md](doc/configuration.md)).

4. `flake.nix`:

   ```nix
   {
     inputs.dnix.url = "github:cypherstack/dnix";
     outputs = { self, dnix, ... }: dnix.lib.package {
       src = self;
       config = ./dnix.json;
     };
   }
   ```

   Then `git add dnix.json flake.nix && nix flake lock`, and commit
   `flake.lock`. Nix only sees files git knows about, so `git add` new
   files before building.

5. `.github/workflows/native.yml`, with `<commit>` the same commit as in
   `pubspec.yaml` and `main` your default branch:

   ```yaml
   on:
     push:
       branches: [main]
     pull_request:
   permissions:
     contents: write
   concurrency:
     group: native-${{ github.ref }}
     cancel-in-progress: ${{ github.ref != format('refs/heads/{0}', github.event.repository.default_branch) }}
   jobs:
     native:
       uses: cypherstack/dnix/.github/workflows/native.yml@<commit>
   ```

6. Two-line tools in `tool/`, run with plain `dart`:
   `update_lock.dart` and `verify_release.dart` (see
   [doc/tools.md](doc/tools.md)). Add `.dnix-build` to `.gitignore`.

7. The first lock: `dart pub get`, then `dart tool/update_lock.dart` on a
   Mac with Nix and Xcode 27.0, and commit `dnix.lock`. Without a Mac, push:
   the first CI run fails and prints the lock in its job summary; commit
   that. The first build downloads a few gigabytes of toolchains.

## Day to day

**Changed the native code?** Run `dart tool/update_lock.dart` on a Mac and
commit `dnix.lock` with the change. The lock lists the hash of every library
the source now builds to, and names the release that will hold them.

**Working on the native code?** `echo dev > .dnix-build` makes the hook
build locally without checking hashes. The hook sees the file from its next
run on, so touch `dnix.json` once after creating it.

**CI** builds on every push, fails if any host or the lock disagrees, and
publishes the release when the lock reaches the default branch. Nothing is
ever committed by CI.

**Users** of the package get the prebuilt library, checked against the lock.
Anyone can rebuild one platform and compare:

```
dart tool/verify_release.dart linux
```

## What builds where

| Host | Prebuilt (default) | Build from source |
|---|---|---|
| Linux x86_64 | yes | Linux, Android, and Windows targets |
| Linux aarch64 | yes | Linux and Windows targets |
| macOS on Apple Silicon | yes | every target; Apple ones need Xcode 27.0 |
| macOS on Intel | yes | no |
| Windows | yes | no; inside WSL2 `verify_release` covers Linux, Android, and Windows targets, and locks come from CI |

## More

- [doc/configuration.md](doc/configuration.md): every field of `dnix.json`
  and `dnix.lock`, what the crate needs, the build modes.
- [doc/workflow.md](doc/workflow.md): what CI does, how releases happen,
  how to work on a package, how to bump dnix, Rust, or nixpkgs.
- [doc/reproducibility.md](doc/reproducibility.md): how the bytes stay
  identical across hosts.
- [doc/tools.md](doc/tools.md): the maintainer tools.

MIT license. Rust today; Go and C++ drivers can share the same per-target
environment.
