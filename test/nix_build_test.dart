import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:code_assets/code_assets.dart';
import 'package:dnix/src/lock.dart';
import 'package:dnix/src/nix_build.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

void main() {
  group(
    'Nix runner (WSL on Windows)',
    () {
      late Directory root;
      const bytes = [0, 10, 13, 127, 128, 255];
      const gnuTarget = 'x86_64-pc-windows-gnullvm';

      setUp(() async {
        root = await Directory.systemTemp.createTemp("dnix runner's # & ");
        final library = File('${root.path}/native/lib/wallet.dll');
        library.parent.createSync(recursive: true);
        library.writeAsBytesSync(bytes);
        // A store path is a valid nix build output. This exercises the real
        // process and filesystem boundary without compiling native libraries
        // or downloading nixpkgs and a compiler toolchain.
        File('${root.path}/flake.nix').writeAsStringSync('''
{
  outputs = { self }: let
    library = builtins.path { path = ./native; name = "dnix-runner-smoke"; };
  in {
    packages = builtins.listToAttrs (map (system: {
      name = system;
      value.x86_64-pc-windows-msvc = library;
      value.$gnuTarget = library;
    }) [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]);
  };
}
''');
      });
      tearDown(() => root.delete(recursive: true));

      test('copies exact bytes and keeps the output writable', () async {
        final built = await buildWithNix(
          packageRoot: root.uri,
          target: 'x86_64-pc-windows-msvc',
          fileName: 'wallet.dll',
          outputDirectory: root.uri.resolve('output/'),
          anyXcode: false,
        );
        expect(built.readAsBytesSync(), bytes);
        verifyHash(
          bytes: built.readAsBytesSync(),
          expected: sha256Hex(bytes),
          what: 'Nix runner output',
        );
        built.writeAsBytesSync([1]); // The copied output remains writable.
      });

      test(
        'git sources include local edits and exclude untracked files',
        () async {
          for (final arguments in [
            ['init', '-q'],
            ['add', 'flake.nix', 'native'],
          ]) {
            final result = await Process.run(
              'git',
              arguments,
              workingDirectory: root.path,
            );
            expect(result.exitCode, 0, reason: '${result.stderr}');
          }
          final untracked = File('${root.path}/native/lib/untracked.dll')
            ..writeAsBytesSync([99]);
          // Nix must see the current worktree, including an unstaged edit.
          File('${root.path}/native/lib/wallet.dll').writeAsBytesSync([42]);
          Future<File> build(String name) => buildWithNix(
            packageRoot: root.uri,
            target: gnuTarget,
            fileName: name,
            outputDirectory: root.uri.resolve('output/'),
            anyXcode: false,
          );
          expect((await build('wallet.dll')).readAsBytesSync(), [42]);
          await expectLater(build('untracked.dll'), throwsA(isA<Exception>()));
          expect(untracked.existsSync(), isTrue);
        },
      );

      test('the hook verifies source output before registering an asset', () async {
        File('${root.path}/dnix.json').writeAsStringSync(
          jsonEncode({
            'name': 'demo',
            'repository': 'https://example.invalid/demo',
            'library': 'wallet',
            'asset': 'wallet.dart',
            'rust': {'workspace': 'native', 'crate': 'demo'},
            // The hook must keep the package's GNU target, even though MSVC is
            // the default for Windows and the flake offers both variants.
            'targets': [gnuTarget],
          }),
        );
        final hook = File('${root.path}/build.dart')
          ..writeAsStringSync('''
import 'package:dnix/dnix.dart';
Future<void> main(List<String> args) => buildNativeLibrary(args);
''');
        final output = File('${root.path}/output/build-output.json');
        output.parent.createSync(recursive: true);
        final packageConfig = (await Isolate.packageConfig)!.toFilePath();

        Future<ProcessResult> runHook(String mode) async {
          final input = BuildInputBuilder()
            ..setupShared(
              packageRoot: root.uri,
              packageName: 'demo',
              outputDirectoryShared: root.uri.resolve('shared/'),
              outputFile: output.uri,
              userDefines: PackageUserDefines(
                workspacePubspec: PackageUserDefinesSource(
                  defines: {
                    'build': mode,
                    // Only Windows consumes this define. Other hosts must
                    // not validate a setting they do not use.
                    if (!Platform.isWindows) 'wsl_distribution': 24.04,
                  },
                  basePath: root.uri,
                ),
              ),
            )
            ..config.setupBuild(linkingEnabled: false)
            ..addExtension(
              CodeAssetExtension(
                targetArchitecture: Architecture.x64,
                targetOS: OS.windows,
                linkModePreference: LinkModePreference.dynamic,
              ),
            );
          final inputFile = File('${root.path}/input.json')
            ..writeAsStringSync(jsonEncode(input.json));
          return Process.run(Platform.resolvedExecutable, [
            '--packages=$packageConfig',
            hook.uri.toString(),
            '--config',
            inputFile.path,
          ]);
        }

        Map<String, Object?> readOutput() =>
            jsonDecode(output.readAsStringSync()) as Map<String, Object?>;

        DnixLock.write(root.uri, {'$gnuTarget/wallet.dll': sha256Hex(bytes)});
        final verified = await runHook('source');
        expect(verified.exitCode, 0, reason: '${verified.stderr}');
        final asset = BuildOutput(readOutput()).assets.code.single;
        expect(asset.file!.path, contains('/$gnuTarget/wallet.dll'));
        expect(File.fromUri(asset.file!).readAsBytesSync(), bytes);

        // A valid lock for different bytes must fail even when a previous
        // successful build left a library at the destination.
        DnixLock.write(root.uri, {
          '$gnuTarget/wallet.dll': sha256Hex([99]),
        });
        final mismatch = await runHook('source');
        expect(mismatch.exitCode, isNot(0));
        expect(mismatch.stderr, contains('Hash mismatch'));
        expect(readOutput()['status'], 'failure');
        expect(readOutput()['assets'] ?? [], isEmpty);

        final development = await runHook('dev');
        expect(development.exitCode, 0, reason: '${development.stderr}');
        expect(BuildOutput(readOutput()).assets.code, hasLength(1));
      });
    },
    skip: Platform.environment['DNIX_TEST_NIX'] != '1'
        ? 'Set DNIX_TEST_NIX=1 with Nix installed (inside WSL2 on Windows).'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
