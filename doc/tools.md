# Tools

Each package keeps two-line shims under `tool/` and runs them with plain
`dart`, not `dart run`, because `dart run` would first run the package's own
build hook. Run `dart pub get` once first.

`tool/update_lock.dart`:

```dart
import 'dart:io';
import 'package:dnix/tools.dart';

void main(List<String> args) async => exit(await updateLock(args));
```

Builds every target and writes `dnix.lock`. Needs Nix, and an Apple Silicon
Mac with the pinned Xcode when the package ships Apple targets, which is
why a Windows or Linux contributor takes the lock from CI's job summary
instead. Builds land under `.dart_tool/dnix/` in the checkout.

`tool/verify_release.dart`:

```dart
import 'dart:io';
import 'package:dnix/tools.dart';

void main(List<String> args) async => exit(await verifyRelease(args));
```

Rebuilds one platform and compares with the lock: `linux`, `android`,
`windows`, `macos`, `ios`, or a target triple. Native Windows Dart invokes
Nix in the default WSL2 distribution for non-Apple platforms. Set that
distribution with `wsl.exe --set-default <name>`; the `wsl_distribution`
user define applies to build hooks, not these standalone tools.

`update_lock` also uses WSL2 when called from Windows for a package with
only non-Apple targets. A package shipping Apple targets still needs a
Mac to write its full lock, or the lock printed by CI.

`writeLock`, also in `package:dnix/tools.dart`, writes a lock from
`SHA256SUMS` files. CI uses it; a package rarely needs a shim for it.

Both tools exit 1 with a one-line reason on any problem dnix can name:
a mistake in `dnix.json`, a missing or inconsistent lock, a platform the
package does not ship, or Nix missing from PATH.

## Testing the build runner

`dart test` checks WSL argument handling and failures, and exercises the
shell script with stand-in tools on POSIX hosts. A separate opt-in smoke
test exercises the real Nix process and file copying with a tiny store
fixture. It also runs the build hook to check Windows target selection,
hash verification, and rejection of mismatched bytes before an asset is
registered. It requires no compiler toolchains or native-library rebuilds:

```sh
DNIX_TEST_NIX=1 dart test test/nix_build_test.dart
```

Run it from native Windows Dart to exercise the WSL handoff. In PowerShell,
with Nix installed in the default WSL2 distribution:

```powershell
$env:DNIX_TEST_NIX = '1'
dart test test/nix_build_test.dart
Remove-Item Env:DNIX_TEST_NIX
```
