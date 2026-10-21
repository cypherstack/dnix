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
`windows`, `macos`, `ios`, or a target triple. Inside WSL2 it covers the
non-Apple platforms.

`writeLock`, also in `package:dnix/tools.dart`, writes a lock from
`SHA256SUMS` files. CI uses it; a package rarely needs a shim for it.

Both tools exit 1 with a one-line reason on any problem dnix can name:
a mistake in `dnix.json`, a missing or inconsistent lock, a platform the
package does not ship, or Nix missing from PATH.
