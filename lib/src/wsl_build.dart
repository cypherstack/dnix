import 'dart:io';

import 'package:dnix/src/exception.dart';
import 'package:dnix/src/targets.dart';

/// Runs a command, forwarding its output, and returns its exit code.
typedef WslCommandRunner = Future<int> Function(
  String executable,
  List<String> arguments,
);

/// The optional distribution chosen by an application's hook configuration.
String? parseWslDistribution(Object? value) {
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty || value.contains('\u0000')) {
    throw DnixException('wsl_distribution must be a non-empty string.');
  }
  return value.trim();
}

/// Builds a non-Apple target through WSL and copies its library back to a
/// regular, writable Windows file. The caller still verifies its pinned hash.
///
/// [distribution] defaults to the user's default WSL distribution. The
/// package stays on the Windows filesystem; Nix builds in its Linux store.
Future<File> buildWithWsl({
  required String packagePath,
  required String target,
  required String fileName,
  required File destination,
  Object? distribution,
  WslCommandRunner runCommand = _runCommand,
}) async {
  if (isAppleTarget(target)) {
    throw DnixException('Apple libraries can only be built on macOS.');
  }
  final selectedDistribution = parseWslDistribution(distribution);
  destination.parent.createSync(recursive: true);

  final arguments = [
    if (selectedDistribution != null) ...[
      '--distribution',
      selectedDistribution,
    ],
    // Do not inherit a Windows working directory that this distribution
    // might not mount. The script changes to the translated package path.
    '--cd',
    '/',
    '--exec',
    '/bin/sh',
    '-c',
    _buildScript,
    'dnix-wsl',
    // These are positional arguments, never interpolated into shell code.
    packagePath,
    destination.absolute.path,
    target,
    fileName,
  ];
  final int code;
  try {
    code = await runCommand('wsl.exe', arguments);
  } on ProcessException {
    throw DnixException.infrastructure(
      'Building from source on Windows needs WSL2 and Nix in a Linux '
      'distribution. Could not start wsl.exe. Install WSL2, or use '
      'build: prebuilt.',
    );
  }
  if (code != 0) {
    final where = selectedDistribution == null
        ? 'the default distribution'
        : 'distribution "$selectedDistribution"';
    final message =
        'WSL build for $target in $where failed with exit code $code; '
        'its output is above.';
    // A Linux shell status is 0..255. WSL startup errors use a Windows
    // exit code (commonly -1 / 0xffffffff); 127 means a missing tool.
    if (code == 127 || code < 0 || code > 255) {
      throw DnixException.infrastructure(
        '$message Check that WSL2 and Nix are installed in $where. '
        'Use wsl.exe --list --verbose to inspect distributions and '
        'wsl.exe --set-default <name> to select the default. '
        'Build hooks also accept the wsl_distribution user define.',
      );
    }
    throw DnixException(message);
  }
  if (!destination.existsSync()) {
    throw DnixException(
      'WSL finished without writing ${destination.path}. '
      'Check that the output directory is accessible inside WSL.',
    );
  }
  return destination;
}

Future<int> _runCommand(String executable, List<String> arguments) async {
  final process = await Process.start(
    executable,
    arguments,
    // WSL's own diagnostics otherwise use UTF-16 when redirected, while
    // the Linux commands' output is UTF-8. Keep both streams readable.
    environment: const {'WSL_UTF8': '1'},
  );
  await Future.wait([
    process.stdout.forEach(stderr.add),
    process.stderr.forEach(stderr.add),
  ]);
  return process.exitCode;
}

// A non-login shell avoids profile output and arbitrary shell setup. Nix's
// usual profile locations cover installations whose PATH is set only at login.
// Preserve the distribution's Nix configuration and enable flakes explicitly.
const _buildScript = r'''
set -eu
if ! command -v nix >/dev/null 2>&1; then
  for profile in "$HOME/.nix-profile/bin" /nix/var/nix/profiles/default/bin /run/current-system/sw/bin; do
    if [ -x "$profile/nix" ]; then
      PATH="$profile:$PATH"
      export PATH
      break
    fi
  done
fi
if ! command -v nix >/dev/null 2>&1; then
  echo 'dnix: install Nix inside this WSL2 distribution before building from source.' >&2
  exit 127
fi
if ! command -v wslpath >/dev/null 2>&1; then
  echo 'dnix: wslpath is missing; select a WSL2 Linux distribution.' >&2
  exit 127
fi
package=$(wslpath -a -u "$1")
destination=$(wslpath -a -u "$2")
cd "$package"
store=$(nix --extra-experimental-features 'nix-command flakes' build ".#$3" --no-link --print-out-paths)
# Copy to a writable sibling first, then replace the output only on success.
# A failed read or write must not leave an empty or partial library behind.
temporary=$(mktemp "${destination}.dnix-XXXXXX")
trap 'rm -f -- "$temporary"' 0
cat -- "$store/lib/$4" > "$temporary"
mv -f -- "$temporary" "$destination"
''';
