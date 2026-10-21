import 'dart:io';

import 'package:dnix/dnix.dart';
import 'package:dnix/src/hook.dart';
import 'package:test/test.dart';

void main() {
  test('a build from source depends on the flake and the workspace', () async {
    final root = await Directory.systemTemp.createTemp('dnix-hook-');
    addTearDown(() => root.delete(recursive: true));
    File(
      '${root.path}/dnix.json',
    ).writeAsStringSync('{"rust": {"workspace": "src/native", "crate": "x"}}');
    for (final path in [
      'flake.nix',
      'src/native/Cargo.toml',
      'src/native/Cargo.lock',
      'src/native/src/lib.rs',
      'src/native/src/target/mod.rs',
      'src/native/target/release/libx.so',
      'src/native/result/libx.so',
      'src/native/.git/HEAD',
      'lib/x.dart',
    ]) {
      File('${root.path}/$path').createSync(recursive: true);
    }
    final files = sourceFiles(
      root.uri,
      DnixConfig.load(root.uri),
    ).map((uri) => uri.path.substring(root.uri.path.length)).toSet();
    expect(files, {
      'flake.nix',
      'src/native/Cargo.toml',
      'src/native/Cargo.lock',
      'src/native/src/lib.rs',
      'src/native/src/target/mod.rs',
    });
  });

  test(
    'a workspace at the package root skips the Dart tool directory',
    () async {
      final root = await Directory.systemTemp.createTemp('dnix-hook-');
      addTearDown(() => root.delete(recursive: true));
      File('${root.path}/dnix.json')
          .writeAsStringSync('{"rust": {"workspace": ".", "crate": "x"}}');
      for (final path in [
        'flake.nix',
        'flake.lock',
        'Cargo.toml',
        '.dart_tool/package_config.json',
      ]) {
        File('${root.path}/$path').createSync(recursive: true);
      }
      final files = sourceFiles(
        root.uri,
        DnixConfig.load(root.uri),
      ).map((uri) => uri.path.substring(root.uri.path.length)).toSet();
      expect(files, {'flake.nix', 'flake.lock', 'Cargo.toml', 'dnix.json'});
    },
  );
  gitTests();
}

void gitTests() {
  test(
    'in a git checkout only tracked files that exist are declared',
    () async {
      final root = await Directory.systemTemp.createTemp('dnix-hook-git-');
      addTearDown(() => root.delete(recursive: true));
      File('${root.path}/dnix.json')
          .writeAsStringSync('{"rust": {"workspace": "native", "crate": "x"}}');
      for (final path in [
        'native/Cargo.toml',
        'native/src/lib.rs',
        'native/src/gone.rs',
        'native/untracked.rs',
        'native/target/debug/libx.so',
      ]) {
        File('${root.path}/$path').createSync(recursive: true);
      }
      Future<void> git(List<String> args) async {
        final result = await Process.run('git', ['-C', root.path, ...args]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      }

      await git(['init', '-q']);
      await git(['add', 'native/Cargo.toml', 'native/src', 'dnix.json']);
      File('${root.path}/native/src/gone.rs').deleteSync();
      final files = sourceFiles(
        root.uri,
        DnixConfig.load(root.uri),
      ).map((uri) => uri.path.substring(root.uri.path.length)).toSet();
      expect(files, {'native/Cargo.toml', 'native/src/lib.rs'});
    },
  );
}
