import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dnix/dnix.dart';
import 'package:dnix/src/hook.dart';
import 'package:hooks/hooks.dart';
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

  group('checkFloors', () {
    late Directory root;
    late DnixConfig config;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dnix-floors-');
      File('${root.path}/dnix.json').writeAsStringSync(
        '{"name": "demo", "rust": {"workspace": ".", "crate": "x"}, '
        '"floors": {"ios": 15, "macos": 14, "android": 26}}',
      );
      config = DnixConfig.load(root.uri);
    });
    tearDown(() => root.delete(recursive: true));

    CodeConfig code(OS os, int version) {
      final builder = BuildInputBuilder()
        ..setupShared(
          packageRoot: root.uri,
          packageName: 'demo',
          outputDirectoryShared: root.uri.resolve('shared/'),
          outputFile: root.uri.resolve('output.json'),
        )
        ..config.setupBuild(linkingEnabled: false)
        ..addExtension(
          CodeAssetExtension(
            targetArchitecture: Architecture.arm64,
            targetOS: os,
            linkModePreference: LinkModePreference.dynamic,
            iOS: os == OS.iOS
                ? IOSCodeConfig(
                    targetSdk: IOSSdk.iPhoneOS,
                    targetVersion: version,
                  )
                : null,
            macOS: os == OS.macOS
                ? MacOSCodeConfig(targetVersion: version)
                : null,
            android: os == OS.android
                ? AndroidCodeConfig(targetNdkApi: version)
                : null,
          ),
        );
      return builder.build().config.code;
    }

    test('lets a build at or above the floors through', () {
      checkFloors(code(OS.iOS, 15), config);
      checkFloors(code(OS.macOS, 15), config);
      checkFloors(code(OS.android, 26), config);
    });

    test('says what to change for each platform below its floor', () {
      void fails(CodeConfig code, String message) => expect(
        () => checkFloors(code, config),
        throwsA(
          isA<DnixException>().having(
            (error) => error.message,
            'message',
            contains(message),
          ),
        ),
      );
      fails(
        code(OS.iOS, 13),
        'demo libraries support iOS 15 and later; this build targets iOS 13.'
        ' This build asks every native asset for iOS 13, whatever the '
        'application targets, so demo must lower "floors.ios" in dnix.json.',
      );
      fails(code(OS.macOS, 13), 'demo must lower "floors.macos" in dnix.json.');
      fails(
        code(OS.android, 24),
        'this build targets Android API 24. '
        "Raise the application's minSdkVersion.",
      );
    });

    test('the default floors admit what Flutter 3.47 asks for', () {
      File('${root.path}/dnix.json').writeAsStringSync(
        '{"name": "demo", "rust": {"workspace": ".", "crate": "x"}}',
      );
      final defaults = DnixConfig.load(root.uri);
      checkFloors(code(OS.iOS, 13), defaults);
      checkFloors(code(OS.macOS, 13), defaults);
    });
  });
}
