import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dnix/src/config.dart';
import 'package:dnix/src/exception.dart';
import 'package:dnix/src/lock.dart';
import 'package:dnix/src/modes.dart';
import 'package:dnix/src/nix_build.dart';
import 'package:dnix/src/targets.dart';
import 'package:hooks/hooks.dart';

/// The whole build hook of a package that uses dnix. Call it from
/// `hook/build.dart`:
///
/// ```dart
/// void main(List<String> args) => buildNativeLibrary(args);
/// ```
///
/// The mode comes from a `.dnix-build` file in the package checkout, then
/// the package's `build` user define, then defaults to `prebuilt`. Before
/// the first `dnix.lock` is written every mode falls back to `dev`.
Future<void> buildNativeLibrary(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    try {
      await _build(input, output);
    } on DnixException catch (error) {
      if (error.infrastructure) throw InfraError(message: error.message);
      throw BuildError(message: error.message);
    }
  });
}

Future<void> _build(BuildInput input, BuildOutputBuilder output) async {
  final root = input.packageRoot;
  // Only files that exist can be declared: hooks_runner treats a declared
  // file that is missing as modified just now and reruns every build. So a
  // `.dnix-build` created after a build is noticed once something else
  // reruns the hook, as doc/configuration.md says.
  final declared = existingFiles(root, [
    DnixConfig.fileName,
    DnixLock.fileName,
    buildModeFileName,
  ]).toSet();
  output.dependencies.addAll(declared);
  final config = DnixConfig.load(root);
  final lock = DnixLock.load(root);

  final code = input.config.code;
  final String target;
  try {
    target = targetTriple(
      code.targetOS,
      code.targetArchitecture,
      iOSSdk: code.targetOS == OS.iOS ? code.iOS.targetSdk : null,
    );
  } on UnsupportedError {
    throw DnixException(
      '${config.name} does not provide a library for ${code.targetOS}/'
      '${code.targetArchitecture}.',
    );
  }
  if (!config.targets.contains(target)) {
    throw DnixException(
      '${config.name} does not provide a library for $target.',
    );
  }
  // Only dynamic libraries are published and built; the reference set is
  // the one Flutter links.
  if (code.linkModePreference == LinkModePreference.static) {
    throw DnixException('${config.name} provides dynamic libraries only.');
  }
  final linkMode = DynamicLoadingBundled();
  final fileName = code.targetOS.libraryFileName(config.library, linkMode);

  var mode = resolveBuildMode(root, input.userDefines['build']);
  if (mode != BuildMode.dev && lock == null) {
    // Only while developing the package itself, before the first lock.
    stderr.writeln('${config.name}: no dnix.lock yet; building in dev mode.');
    mode = BuildMode.dev;
  }
  checkFloors(code, config);

  final File file;
  switch (mode) {
    case BuildMode.prebuilt:
      final expected = pinnedHash(lock!, target, fileName);
      file = await fetchPrebuilt(
        url: lock.assetUrl(config.repository, target, fileName),
        fileName: fileName,
        expectedHash: expected,
        cacheDirectory: input.outputDirectoryShared,
        packageName: config.name,
      );
    case BuildMode.source:
      final expected = pinnedHash(lock!, target, fileName);
      file = await buildWithNix(
        packageRoot: root,
        target: target,
        fileName: fileName,
        outputDirectory: input.outputDirectory,
        anyXcode: false,
      );
      verifyHash(
        bytes: file.readAsBytesSync(),
        expected: expected,
        what: '$target/$fileName built with Nix',
      );
      output.dependencies.addAll(sourceFiles(root, config).where(declared.add));
    case BuildMode.dev:
      file = await buildWithNix(
        packageRoot: root,
        target: target,
        fileName: fileName,
        outputDirectory: input.outputDirectory,
        anyXcode: true,
      );
      output.dependencies.addAll(sourceFiles(root, config).where(declared.add));
  }
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: config.asset,
      linkMode: linkMode,
      file: file.uri,
    ),
  );
}

/// The hash the lock records for one library.
String pinnedHash(DnixLock lock, String target, String fileName) {
  final expected = lock.hashFor(target, fileName);
  if (expected == null) {
    throw DnixException(
      'dnix.lock has no $fileName for $target. Build mode "dev" builds it '
      'locally without a pinned hash.',
    );
  }
  return expected;
}

/// Fails when the consumer's deployment target is below the floor the
/// libraries are built for, since such a build could not match the release.
void checkFloors(CodeConfig code, DnixConfig config) {
  final (String, num, int)? check = switch (code.targetOS) {
    OS.macOS => ('macOS', code.macOS.targetVersion, config.macOSFloor),
    OS.iOS => ('iOS', code.iOS.targetVersion, config.iOSFloor),
    OS.android => (
      'Android API',
      code.android.targetNdkApi,
      config.androidApiFloor,
    ),
    _ => null,
  };
  if (check == null) return;
  final (platform, actual, floor) = check;
  if (actual < floor) {
    throw DnixException(
      '${config.name} libraries support $platform $floor and later; this '
      'build targets $platform $actual. Raise the deployment target.',
    );
  }
}

/// Every file a build from source reads: `flake.nix`, `flake.lock`, and
/// the files under each source directory of [config]. The hook declares
/// them after building, so editing the native code reruns the build and a
/// `flake.lock` Nix just wrote is included.
///
/// In a git checkout these are the tracked files, which is what Nix builds
/// from; elsewhere every file, skipping build output (`target` at the
/// workspace root, Nix result links) and the git store. Only files that
/// exist are declared, since hooks_runner treats a declared missing file
/// as modified.
Iterable<Uri> sourceFiles(Uri packageRoot, DnixConfig config) sync* {
  yield* existingFiles(packageRoot, ['flake.nix', 'flake.lock']);
  final rootPath = Directory.fromUri(packageRoot).path
      .replaceAll(RegExp(r'/+$'), '');
  for (final directory in config.sourceDirectories) {
    final base = Directory(
      directory == '.' ? rootPath : '$rootPath/$directory',
    );
    if (!base.existsSync()) continue;
    yield* gitTrackedFiles(base) ?? _files(base, root: base);
  }
}

/// The files git tracks under [directory] and that exist, or null when
/// [directory] is not inside a git work tree or git is not installed.
List<Uri>? gitTrackedFiles(Directory directory) {
  final ProcessResult result;
  try {
    result = Process.runSync(
      'git',
      ['-C', directory.path, 'ls-files', '-z', '--cached', '--', '.'],
      stdoutEncoding: systemEncoding,
      stderrEncoding: systemEncoding,
    );
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) return null;
  // Dart's own tool directory is written during a build, so even if it is
  // tracked it must not be an input.
  return [
    for (final name in (result.stdout as String).split('\u0000'))
      if (name.isNotEmpty &&
          !name.startsWith('.dart_tool/') &&
          File('${directory.path}/$name').existsSync())
        File('${directory.path}/$name').uri,
  ];
}

Iterable<Uri> _files(Directory directory, {required Directory root}) sync* {
  for (final entry in directory.listSync(followLinks: false)) {
    final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (entry is Directory) {
      if (name == '.git' || name == '.dart_tool') continue;
      if (directory.path == root.path &&
          (name == 'target' || name.startsWith('result'))) {
        continue;
      }
      yield* _files(entry, root: root);
    } else if (entry is File) {
      yield entry.uri;
    }
  }
}

/// The files among [names] under [root] that exist.
Iterable<Uri> existingFiles(Uri root, List<String> names) sync* {
  for (final name in names) {
    final uri = root.resolve(name);
    if (File.fromUri(uri).existsSync()) yield uri;
  }
}
