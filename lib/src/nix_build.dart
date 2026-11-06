import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:dnix/src/exception.dart';
import 'package:dnix/src/targets.dart';
import 'package:dnix/src/wsl_build.dart';

/// Builds [fileName] for [target] with the package's Nix flake and returns
/// a writable copy at `<outputDirectory>/<target>/<fileName>`.
///
/// Non-Apple targets are pure derivations of the flake. Apple targets need
/// the host's Xcode, so they are built by the `dnix-apple-build` command of
/// the flake's `apple` shell; [anyXcode] skips its pinned-version check.
/// Windows invokes Nix in WSL2, optionally selecting [wslDistribution].
/// Only Windows validates and consumes that raw hook configuration value.
Future<File> buildWithNix({
  required Uri packageRoot,
  required String target,
  required String fileName,
  required Uri outputDirectory,
  required bool anyXcode,
  Object? wslDistribution,
}) async {
  final destination = File.fromUri(
    outputDirectory.resolve('$target/$fileName'),
  );
  if (Platform.isWindows) {
    return buildWithWsl(
      packagePath: packageRoot.toFilePath(),
      target: target,
      fileName: fileName,
      destination: destination,
      distribution: wslDistribution,
    );
  }
  if (Platform.isMacOS && Abi.current() == Abi.macosX64) {
    throw DnixException(
      'Building from source needs an Apple Silicon Mac or Linux; nixpkgs no '
      'longer supports Intel Macs as hosts. Use the prebuilt library.',
    );
  }
  // Run inside the package so characters such as '#' in its parent path
  // cannot be interpreted as part of the flake reference. Nix still sees
  // tracked files in a git checkout, or all files in a plain directory.
  final packageDirectory = packageRoot.toFilePath();
  destination.parent.createSync(recursive: true);

  if (isAppleTarget(target)) {
    final built = Directory.fromUri(outputDirectory.resolve('apple/'));
    await runNix(
      [
        'develop',
        '.#apple',
        '--command',
        'dnix-apple-build',
        built.path,
        target,
      ],
      environment: {if (anyXcode) 'DNIX_ANY_XCODE': '1'},
      workingDirectory: packageDirectory,
    );
    return copyOut(File('${built.path}/$target/$fileName'), destination);
  }

  final storePath = await runNix([
    'build',
    '.#$target',
    '--no-link',
    '--print-out-paths',
  ], workingDirectory: packageDirectory);
  return copyOut(File('${storePath.trim()}/lib/$fileName'), destination);
}

/// Copies [from] to [to] as a regular writable file. A plain copy of a Nix
/// store file keeps its read-only mode, and on Linux the next copy onto it
/// is then refused.
File copyOut(File from, File to) {
  to.writeAsBytesSync(from.readAsBytesSync(), flush: true);
  return to;
}

/// Enables flakes for every Nix call, including those the Apple build makes
/// itself, without touching the user's nix.conf.
String nixConfig() {
  const flakes = 'extra-experimental-features = nix-command flakes';
  final existing = Platform.environment['NIX_CONFIG'];
  return existing == null || existing.isEmpty ? flakes : '$existing\n$flakes';
}

/// Runs `nix` with [arguments], streaming its progress to stderr, and
/// returns what it printed to stdout.
Future<String> runNix(
  List<String> arguments, {
  Map<String, String> environment = const {},
  String? workingDirectory,
}) async {
  final Process process;
  try {
    process = await Process.start(
      'nix',
      arguments,
      workingDirectory: workingDirectory,
      environment: {...environment, 'NIX_CONFIG': nixConfig()},
    );
  } on ProcessException {
    throw DnixException.infrastructure(
      'Building from source needs Nix on PATH: https://nixos.org/download. '
      'Use the prebuilt library if you do not want to build.',
    );
  }
  final stdoutBuffer = StringBuffer();
  await Future.wait([
    process.stdout.forEach(
      (bytes) => stdoutBuffer.write(String.fromCharCodes(bytes)),
    ),
    process.stderr.forEach(stderr.add),
  ]);
  final code = await process.exitCode;
  if (code != 0) {
    throw DnixException(
      'nix ${arguments.take(2).join(' ')} failed with exit code $code; its '
      'output is above.',
    );
  }
  return stdoutBuffer.toString();
}
