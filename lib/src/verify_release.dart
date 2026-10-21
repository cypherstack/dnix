import 'dart:io';

import 'package:dnix/src/config.dart';
import 'package:dnix/src/exception.dart';
import 'package:dnix/src/lock.dart';
import 'package:dnix/src/nix_build.dart';
import 'package:dnix/src/targets.dart';

/// Rebuilds the libraries of one platform with Nix and compares them with
/// the hashes in `dnix.lock`:
///
///     verify_release <platform>
///
/// `<platform>` is linux, android, windows, macos, ios, or one target
/// triple. Runs from anywhere inside the package checkout. Returns the
/// process exit code: non-zero on any mismatch.
Future<int> verifyRelease(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: verify_release <platform>');
    return 64;
  }
  try {
    return await _verify(args.single);
  } on DnixException catch (error) {
    stderr.writeln(error.message);
    return 1;
  }
}

const _platforms = ['linux', 'android', 'windows', 'macos', 'ios'];

Future<int> _verify(String platform) async {
  if (Platform.isWindows) {
    throw DnixException(
      'This needs Nix, which runs on Windows inside WSL2. Run it there.',
    );
  }
  final root = DnixConfig.findRoot();
  final config = DnixConfig.load(root);
  final lock = DnixLock.load(root);
  if (lock == null) {
    throw DnixException(
      '${root.toFilePath()} has no ${DnixLock.fileName} yet.',
    );
  }
  if (!_platforms.contains(platform) && !config.targets.contains(platform)) {
    throw DnixException(
      'Unknown platform "$platform". Use ${_platforms.join(', ')}, or one '
      'of: ${config.targets.join(', ')}',
    );
  }
  final wanted = {
    for (final MapEntry(:key, :value) in lock.files.entries)
      if (belongsTo(key.split('/').first, platform)) key: value,
  };
  if (wanted.isEmpty) {
    throw DnixException('${DnixLock.fileName} lists no $platform libraries.');
  }
  stdout.writeln(
    'Building ${libraries(wanted.length)} to compare with ${lock.tag}...',
  );
  if (wanted.keys.any(isAppleTarget) && !Platform.isMacOS) {
    throw DnixException('Apple libraries can only be built on macOS.');
  }

  var mismatches = 0;
  for (final MapEntry(:key, value: expected) in wanted.entries) {
    final [target, fileName] = key.split('/');
    final built = await buildWithNix(
      packageRoot: root,
      target: target,
      fileName: fileName,
      outputDirectory: root.resolve('.dart_tool/dnix/'),
      anyXcode: false,
    );
    final actual = sha256Hex(built.readAsBytesSync());
    if (actual == expected) {
      stdout.writeln('  match     $key');
    } else {
      mismatches++;
      stdout.writeln(
        '  MISMATCH  $key\n'
        '            expected $expected\n'
        '            built    $actual',
      );
    }
  }
  if (mismatches == 0) {
    stdout.writeln('Every library matches ${lock.tag}.');
    return 0;
  }
  stderr.writeln(
    '${libraries(mismatches)} ${mismatches == 1 ? 'differs' : 'differ'} '
    'from ${lock.tag}.',
  );
  return 1;
}

/// Whether [target] belongs to [platform], a platform name or a triple.
bool belongsTo(String target, String platform) => switch (platform) {
  'linux' => target.endsWith('-linux-gnu'),
  'android' => target.contains('-linux-android'),
  'windows' => target.contains('-windows-'),
  'macos' => target.endsWith('-apple-darwin'),
  'ios' => target.contains('-apple-ios'),
  _ => target == platform,
};

/// "1 library" or "n libraries".
String libraries(int n) => n == 1 ? '1 library' : '$n libraries';
