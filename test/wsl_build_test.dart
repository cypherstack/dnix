import 'dart:io';

import 'package:dnix/src/exception.dart';
import 'package:dnix/src/lock.dart';
import 'package:dnix/src/wsl_build.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File destination;
  const target = 'x86_64-pc-windows-gnullvm';
  const library = 'wallet.dll';
  const packagePath = r"C:\Users\Alice Smith\dart's cache & $(touch injected)";
  const bytes = [0, 10, 13, 127, 128, 255];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dnix wsl ');
    destination = File('${root.path}/output # & cache/$target/$library');
  });
  tearDown(() => root.delete(recursive: true));

  Future<File> build({
    String buildTarget = target,
    Object? distribution,
    required WslCommandRunner run,
  }) => buildWithWsl(
    packagePath: packagePath,
    target: buildTarget,
    fileName: library,
    destination: destination,
    distribution: distribution,
    runCommand: run,
  );

  test('uses the default distribution and passes paths as arguments', () async {
    final built = await build(
      run: (executable, arguments) async {
        expect(executable, 'wsl.exe');
        expect(arguments.take(5), ['--cd', '/', '--exec', '/bin/sh', '-c']);
        expect(arguments[5], isNot(contains(packagePath)));
        expect(arguments.skip(6), [
          'dnix-wsl',
          packagePath,
          destination.absolute.path,
          target,
          library,
        ]);
        destination.writeAsBytesSync(bytes);
        return 0;
      },
    );
    expect(built.path, destination.path);
    verifyHash(
      bytes: built.readAsBytesSync(),
      expected: sha256Hex(bytes),
      what: 'WSL output',
    );
  });

  test('selects a distribution without shell interpolation', () async {
    await build(
      distribution: ' Ubuntu Development ',
      run: (executable, arguments) async {
        expect(arguments.take(2), ['--distribution', 'Ubuntu Development']);
        destination.writeAsBytesSync(bytes);
        return 0;
      },
    );
  });

  test('rejects malformed distribution settings before starting WSL', () async {
    expect(parseWslDistribution(null), isNull);
    for (final value in [true, 42, '', '  ', 'Ubuntu\u0000']) {
      await expectLater(
        build(
          distribution: value,
          run: (_, _) async =>
              fail('WSL must not start for an invalid setting'),
        ),
        throwsA(isA<DnixException>()),
      );
    }
  });

  test('does not try to build Apple targets through WSL', () async {
    await expectLater(
      build(
        buildTarget: 'aarch64-apple-ios',
        run: (_, _) async => fail('WSL must not start for Apple targets'),
      ),
      throwsA(
        isA<DnixException>().having(
          (error) => error.message,
          'message',
          contains('only be built on macOS'),
        ),
      ),
    );
  });

  test('explains how to proceed when WSL cannot start', () async {
    await expectLater(
      build(
        run: (executable, arguments) async =>
            throw ProcessException(executable, arguments, 'not found'),
      ),
      throwsA(
        isA<DnixException>()
            .having((error) => error.infrastructure, 'infrastructure', isTrue)
            .having(
              (error) => error.message,
              'message',
              contains('Install WSL2'),
            ),
      ),
    );
  });

  test('a failed build never returns a previous output', () async {
    destination.parent.createSync(recursive: true);
    destination.writeAsBytesSync(bytes);
    await expectLater(
      build(run: (_, _) async => 1),
      throwsA(
        isA<DnixException>()
            .having((error) => error.infrastructure, 'infrastructure', isFalse)
            .having(
              (error) => error.message,
              'message',
              contains('exit code 1'),
            ),
      ),
    );
  });

  test('a missing WSL tool is an infrastructure failure', () async {
    await expectLater(
      build(distribution: 'Ubuntu', run: (_, _) async => 127),
      throwsA(
        isA<DnixException>()
            .having((error) => error.infrastructure, 'infrastructure', isTrue)
            .having(
              (error) => error.message,
              'message',
              contains('distribution "Ubuntu"'),
            ),
      ),
    );
  });

  for (final code in [-1, 0xffffffff]) {
    test(
      'a WSL startup failure ($code) is an infrastructure failure',
      () async {
        await expectLater(
          build(run: (_, _) async => code),
          throwsA(
            isA<DnixException>()
                .having(
                  (error) => error.infrastructure,
                  'infrastructure',
                  isTrue,
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('wsl.exe --set-default'),
                ),
          ),
        );
      },
    );
  }

  test('reports a missing output even if WSL exits successfully', () async {
    await expectLater(
      build(run: (_, _) async => 0),
      throwsA(
        isA<DnixException>().having(
          (error) => error.message,
          'message',
          contains('without writing'),
        ),
      ),
    );
  });

  group(
    'WSL shell script',
    () {
      const windowsOutputPath = r'D:\Build Output # &\wallet.dll';
      late Directory bin;
      late Directory package;
      late Directory store;
      late Map<String, String> environment;
      late ProcessResult result;

      void executable(String name, String script) {
        final file = File('${bin.path}/$name')..writeAsStringSync(script);
        final chmod = Process.runSync('chmod', ['+x', file.path]);
        expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
      }

      setUp(() {
        bin = Directory('${root.path}/bin')..createSync();
        package = Directory("${root.path}/package's # & directory")
          ..createSync();
        store = Directory('${root.path}/store')..createSync();
        final built = File('${store.path}/lib/$library');
        built.parent.createSync();
        built.writeAsBytesSync(bytes);
        environment = {
          // Keep a real /usr/bin/wslpath from masking the missing-tool
          // case when these tests themselves run inside WSL.
          'PATH': bin.path,
          'DNIX_TEST_PACKAGE_WINDOWS': packagePath,
          'DNIX_TEST_PACKAGE_UNIX': package.path,
          'DNIX_TEST_OUTPUT_WINDOWS': windowsOutputPath,
          'DNIX_TEST_OUTPUT_UNIX': destination.absolute.path,
          'DNIX_TEST_STORE': store.path,
          'DNIX_TEST_ARGS': '${root.path}/nix-arguments',
          'DNIX_TEST_CWD': '${root.path}/nix-working-directory',
          'DNIX_TEST_NIX_EXIT': '0',
        };
        // Expose only the host commands the fixture needs. Resolve them
        // through PATH so this also works with NixOS's filesystem layout.
        for (final name in ['cat', 'touch', 'mktemp', 'mv', 'rm']) {
          final command = Platform.environment['PATH']!
              .split(':')
              .map((path) => File('$path/$name'))
              .firstWhere((file) => file.existsSync());
          Link('${bin.path}/$name').createSync(command.absolute.path);
        }
        executable('wslpath', r'''#!/bin/sh
set -eu
test "$1" = -a
test "$2" = -u
case "$3" in
  "$DNIX_TEST_PACKAGE_WINDOWS") printf '%s\n' "$DNIX_TEST_PACKAGE_UNIX" ;;
  "$DNIX_TEST_OUTPUT_WINDOWS") printf '%s\n' "$DNIX_TEST_OUTPUT_UNIX" ;;
  *) exit 3 ;;
esac
''');
        executable('nix', r'''#!/bin/sh
set -eu
printf '%s\n' "$@" > "$DNIX_TEST_ARGS"
pwd > "$DNIX_TEST_CWD"
test "$DNIX_TEST_NIX_EXIT" = 0 || exit "$DNIX_TEST_NIX_EXIT"
printf '%s\n' "$DNIX_TEST_STORE"
''');
      });

      Future<int> runScript(String executable, List<String> arguments) async {
        expect(executable, 'wsl.exe');
        final shellIndex = arguments.indexOf('/bin/sh');
        final shellArguments = arguments.sublist(shellIndex + 1);
        // Emulate the Windows-side output spelling on this POSIX host.
        // Writing to the untranslated argument must not reach destination.
        shellArguments[shellArguments.indexOf(destination.absolute.path)] =
            windowsOutputPath;
        result = await Process.run(
          '/bin/sh',
          shellArguments,
          environment: environment,
          workingDirectory: root.path,
        );
        return result.exitCode;
      }

      test(
        'translates paths, keeps the Windows target, and copies bytes',
        () async {
          final built = await build(run: runScript);
          expect(built.readAsBytesSync(), bytes);
          expect(File('${root.path}/nix-arguments').readAsLinesSync(), [
            '--extra-experimental-features',
            'nix-command flakes',
            'build',
            '.#$target',
            '--no-link',
            '--print-out-paths',
          ]);
          final cwd = File('${root.path}/nix-working-directory')
              .readAsStringSync()
              .trim();
          expect(
            Directory(cwd).resolveSymbolicLinksSync(),
            package.resolveSymbolicLinksSync(),
          );
          expect(File('${root.path}/injected').existsSync(), isFalse);
          expect(File('${package.path}/injected').existsSync(), isFalse);
          // Repeated builds can overwrite the copied file; it is not read-only.
          built.writeAsBytesSync([1]);
          await build(run: runScript);
          expect(built.readAsBytesSync(), bytes);
        },
      );

      test('a Nix failure stops before copying any library', () async {
        environment['DNIX_TEST_NIX_EXIT'] = '42';
        await expectLater(build(run: runScript), throwsA(isA<DnixException>()));
        expect(result.exitCode, 42);
        expect(destination.existsSync(), isFalse);
      });

      test('a path conversion failure stops before Nix', () async {
        environment['DNIX_TEST_PACKAGE_WINDOWS'] = 'another path';
        await expectLater(build(run: runScript), throwsA(isA<DnixException>()));
        expect(result.exitCode, 3);
        expect(File('${root.path}/nix-arguments').existsSync(), isFalse);
      });

      test('reports a missing wslpath before trying a build', () async {
        File('${bin.path}/wslpath').deleteSync();
        await expectLater(build(run: runScript), throwsA(isA<DnixException>()));
        expect(result.exitCode, 127);
        expect(result.stderr, contains('wslpath is missing'));
        expect(File('${root.path}/nix-arguments').existsSync(), isFalse);
      });

      test(
        'a missing library fails instead of returning an empty file',
        () async {
          File('${store.path}/lib/$library').deleteSync();
          await expectLater(
            build(run: runScript),
            throwsA(isA<DnixException>()),
          );
          expect(result.exitCode, isNot(0));
          expect(destination.existsSync(), isFalse);
          expect(destination.parent.listSync(), isEmpty);
        },
      );

      test('a failed copy preserves the previous library', () async {
        destination.parent.createSync(recursive: true);
        destination.writeAsBytesSync([42]);
        File('${store.path}/lib/$library').deleteSync();
        await expectLater(build(run: runScript), throwsA(isA<DnixException>()));
        expect(destination.readAsBytesSync(), [42]);
        expect(destination.parent.listSync().map((file) => file.path), [
          destination.path,
        ]);
      });
    },
    skip: Platform.isWindows
        ? 'Runs the WSL shell with POSIX test tools.'
        : false,
  );
}
