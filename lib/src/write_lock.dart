import 'dart:io';

import 'package:dnix/src/lock.dart';

/// Writes a package's `dnix.lock` from SHA256SUMS files of its builds:
///
///     write_lock <package-dir> <SHA256SUMS>...
///
/// Only dynamic libraries are recorded. CI uses this to check that the
/// committed lock still matches what the source builds to. Returns the
/// process exit code.
int writeLock(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: write_lock <package-dir> <SHA256SUMS>...');
    return 64;
  }
  final [dir, ...sums] = args;
  final root = Directory(dir).absolute.uri;
  final files = <String, String>{};
  for (final path in sums) {
    files.addAll(dynamicLibraryHashes(File(path).readAsLinesSync()));
  }
  if (files.isEmpty) {
    stderr.writeln('No dynamic libraries listed in ${sums.join(', ')}.');
    return 1;
  }
  final lock = DnixLock.write(root, files);
  stdout.writeln(
    '${DnixLock.fileName}: ${files.length} libraries, release ${lock.tag}',
  );
  return 0;
}
