/// Entry points for the maintainer tools. Each package keeps a two-line
/// shim under `tool/` that calls one of these, run with plain `dart`
/// rather than `dart run`, which would first run the package's own hook:
///
/// ```dart
/// import 'dart:io';
/// import 'package:dnix/tools.dart';
/// void main(List<String> args) async => exit(await updateLock(args));
/// ```
library;

export 'src/update_lock.dart' show updateLock;
export 'src/verify_release.dart' show verifyRelease;
export 'src/write_lock.dart' show writeLock;
