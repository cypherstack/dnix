import 'dart:io';

import 'package:dnix/src/config.dart';
import 'package:dnix/src/exception.dart';
import 'package:dnix/src/lock.dart';
import 'package:dnix/src/nix_build.dart';
import 'package:dnix/src/targets.dart';

/// Builds every target the package ships, with Nix and the pinned Xcode,
/// and writes `dnix.lock` with the resulting hashes:
///
///     update_lock
///
/// Run it after changing the native code, from anywhere inside the package
/// checkout, and commit the lock with the change. Needs macOS when the
/// package ships Apple targets; elsewhere, CI prints the lock the source
/// builds to. Returns the process exit code.
Future<int> updateLock(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('usage: update_lock');
    return 64;
  }
  try {
    return await _update();
  } on DnixException catch (error) {
    stderr.writeln(error.message);
    return 1;
  }
}

Future<int> _update() async {
  if (Platform.isWindows) {
    throw DnixException(
      'This needs Nix, which runs on Windows inside WSL2. Run it there.',
    );
  }
  final root = DnixConfig.findRoot();
  final config = DnixConfig.load(root);
  if (config.targets.any(isAppleTarget) && !Platform.isMacOS) {
    throw DnixException(
      'The Apple targets need macOS with the pinned Xcode. Run this on a '
      'Mac, or push the change and copy the lock CI prints once every host '
      'is green.',
    );
  }
  stdout.writeln('Building ${config.targets.length} targets...');
  final files = <String, String>{};
  for (final target in config.targets) {
    final fileName = libraryFileName(config.library, target);
    final built = await buildWithNix(
      packageRoot: root,
      target: target,
      fileName: fileName,
      outputDirectory: root.resolve('.dart_tool/dnix/'),
      anyXcode: false,
    );
    files['$target/$fileName'] = sha256Hex(built.readAsBytesSync());
    stdout.writeln(
      '  ${files['$target/$fileName']!.substring(0, 16)}  $target',
    );
  }
  final lock = DnixLock.write(root, files);
  stdout.writeln(
    'Wrote ${DnixLock.fileName}: release ${lock.tag}. Commit it with the '
    'change; the release is published when it reaches the default branch.',
  );
  return 0;
}
