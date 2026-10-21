# Workflow

## The one rule

`dnix.lock` is a source file. It says what the native code builds to. CI
checks that it is true on every push, and publishes from it. No release is
ever cut first and recorded afterwards, and CI never commits.

## Changing native code

1. Change the Rust code, `dnix.json`, or `flake.lock`. Adding or removing
   a target is the same: edit `targets`.
2. Run `dart tool/update_lock.dart`. It builds every target, writes
   `dnix.lock`, and prints the new release name. On a Mac with Nix and the
   pinned Xcode this takes a few minutes once the toolchains are cached;
   the first run downloads a few gigabytes. Without a Mac, push the change:
   CI fails and prints the lock the source builds to, in the job summary.
   Paste it into `dnix.lock` once every host job is green; the check does
   not run while a host is missing.
3. Commit the lock with the change and open the pull request.

## What CI does on every push

The reusable workflow builds the library on four hosts: Linux x86_64, Linux
aarch64, macOS with the pinned Xcode, and Linux inside WSL2 on Windows. Each
host rebuilds every sandboxed target a second time from scratch and Nix
compares the two. The Apple targets, which have no sandbox, are built twice
on the macOS host and compared. Then one job compares every host's hashes
with every other host's, and with the committed `dnix.lock`. Any difference
fails the run.

What that proves: Linux and Windows libraries are identical across three
Nix systems (the WSL2 host runs the same x86_64 Linux derivations as the
first), Android across two (aarch64 Linux has no NDK), and Apple libraries
across two builds on one Mac. Apple bytes are proven across Macs only when
the lock was written on a different Mac than CI's, or when someone runs
`verify_release` elsewhere.

On a push to the default branch, if the lock names a release that does not
exist yet, a final job uploads the dynamic libraries from the artifacts the
hosts just agreed on, after checking each against its host's checksums, and
creates the GitHub release and tag `native-<release>` on that commit. The
tag's tree contains the lock that describes it. A manual `workflow_dispatch`
run never publishes; re-run the push's run instead.

Calling it from a package:

```yaml
on:
  push:
    branches: [main]   # your default branch
  pull_request:
permissions:
  contents: write
concurrency:
  group: native-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != format('refs/heads/{0}', github.event.repository.default_branch) }}
jobs:
  native:
    uses: cypherstack/dnix/.github/workflows/native.yml@<commit>
    with:
      macos-runner: xcode-27   # the default
```

Pin `<commit>` to the same dnix commit as `pubspec.yaml` and `flake.lock`:
the check job runs dnix's lock tools from that commit, and the workflow runs
with your repository's write token, so a moving `@main` would hand that
token to whoever can push to dnix.

Never cancel runs on the default branch: a release is created as a draft
and published last, and a cancelled publish would leave a draft behind that
is not downloadable. The workflow removes such a draft on its next run.

Inputs: `macos-runner` (the runner label; it decides which Xcode is
installed, so it goes with `toolchains.xcode`), `package-dir` (where
`dnix.json` lives, default `.`), `flake-dir` (default: the package dir; the
hook always uses the package dir, so keep the flake there unless only CI
builds), `attr-prefix` (for flakes that expose a package under a prefix),
`artifact-suffix` (give every call a distinct one when a run calls the
workflow more than once), `dart-sdk`. Do not upload other artifacts named
`sums-*` from the same run.

Old releases stay. A published pub version keeps downloading the release its
lock names, so never delete a `native-*` release.

## Testing the package before its first release

Until the first lock reaches the default branch there is no release to
download, so the package's own tests must build from source. Decide the
mode in the test workflow by asking GitHub whether the release exists:

```sh
repository=$(jq -r .repository dnix.json | sed 's/\.git$//; s#/$##')
tag=native-$(jq -r .release dnix.lock)
if curl -fsSLI -o /dev/null "$repository/releases/tag/$tag"; then
  echo prebuilt > .dnix-build
else
  echo source > .dnix-build
fi
```

Windows runners can only use `prebuilt`, so skip the tests there until the
release exists.

## Before publishing to pub.dev

The lock in the published package must name a release that exists, or
prebuilt mode fails for every user. Publish from the default branch after the
release workflow has run for the commit.

Users who choose `source` or `dev` mode build from the pub copy of the
package, so `dnix.json`, `dnix.lock`, `flake.nix`, `flake.lock`, and the
whole Rust workspace with its `Cargo.lock` must be in the archive. Do not
`.pubignore` the native source.

## Checking a release yourself

```
dart tool/verify_release.dart linux    # or android, windows, macos, ios, or a triple
```

Rebuilds that platform with Nix and compares each library with the lock.
The Apple targets use the Xcode bundle under `/Applications` that reports
the pinned version, whatever `xcode-select` points at. Inside WSL2 this
covers the Linux, Android, and Windows targets.

## Bumping dnix, Rust, or nixpkgs

The bytes depend on dnix's toolchain pins in `nix/defaults.nix`, on the
nixpkgs and overlay revisions in the package's `flake.lock`, and on
`dnix.json`: `toolchains.rust`, `toolchains.xcode`, the floors, and the
`name`, `rust.workspace`, and `library` that set embedded paths and file
names. Any of them changing means a new lock and a new release, even with
unchanged source. When the `xcode-27` runner image moves to a newer Xcode,
the macOS job fails until `toolchains.xcode` is bumped the same way.

The consumer's `flake.lock` has one direct input, `dnix`; nixpkgs and the
overlays are nested under it, so they are addressed as `dnix/<input>`:

- **dnix**: `nix flake update dnix`, which also re-locks the nested inputs
  to what dnix's own `flake.lock` pins. Set the same commit as `ref:` in
  `pubspec.yaml` and in the workflow's `uses:`.
- **Rust**: change `toolchains.rust`. The version must exist in the
  rust-overlay revision `flake.lock` pins; `nix flake update
  dnix/rust-overlay` brings newer ones. The Nix build ignores
  `rust-toolchain.toml`.
- **nixpkgs**: `nix flake update dnix/nixpkgs`, on purpose, since lld, the
  Android NDK packaging, and cargo-zigbuild come from it.

Then `dart tool/update_lock.dart` and commit the lock with the bump.
