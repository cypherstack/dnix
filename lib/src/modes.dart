import 'dart:io';

import 'package:dnix/src/exception.dart';

/// How the hook obtains the native library.
enum BuildMode {
  /// Download the library of the pinned native release and verify it
  /// against the pinned hash. The default.
  prebuilt,

  /// Build with Nix exactly as the release did and verify against the
  /// pinned hash.
  source,

  /// Build with Nix but skip the Xcode pin and the hash check. For working
  /// on the native code; the output is not expected to match the release.
  dev;

  /// The mode named by [value]; null means [prebuilt].
  static BuildMode parse(Object? value) => switch (value?.toString()) {
    null || 'prebuilt' => BuildMode.prebuilt,
    'source' => BuildMode.source,
    'dev' => BuildMode.dev,
    final other => throw DnixException(
      'Unknown build mode "$other"; use prebuilt, source, or dev.',
    ),
  };
}

/// The file in a package checkout that overrides the build mode for that
/// checkout, holding `prebuilt`, `source`, or `dev`. Meant for working on
/// the package itself and for CI; apps use the `build` user define.
const buildModeFileName = '.dnix-build';

/// The mode for a build: the checkout's `.dnix-build` file, then the
/// package's `build` user define, then `prebuilt`. Hooks receive almost no
/// environment variables, so none is consulted.
BuildMode resolveBuildMode(Uri packageRoot, Object? userDefine) {
  final file = File.fromUri(packageRoot.resolve(buildModeFileName));
  if (file.existsSync()) return BuildMode.parse(file.readAsStringSync().trim());
  return BuildMode.parse(userDefine);
}
