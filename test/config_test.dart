import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dnix/dnix.dart';
import 'package:dnix/src/targets.dart';
import 'package:dnix/src/verify_release.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dnix-config-');
  });
  tearDown(() => root.delete(recursive: true));

  DnixConfig write(String json) {
    File('${root.path}/dnix.json').writeAsStringSync(json);
    return DnixConfig.load(root.uri);
  }

  Matcher complains(String about) => throwsA(
    isA<DnixException>().having((e) => e.message, 'message', contains(about)),
  );

  test('dnix.json provides the package facts, with default floors', () {
    final config = write('''
{
  "name": "example",
  "repository": "https://github.com/example/example",
  "library": "example_ffi",
  "asset": "example_bindings_generated.dart",
  "rust": {"workspace": "src/native/", "crate": "example-ffi"},
  "targets": ["x86_64-unknown-linux-gnu"],
  "floors": {"android": 26}
}
''');
    expect(config.name, 'example');
    expect(config.repository, 'https://github.com/example/example');
    expect(config.library, 'example_ffi');
    expect(config.asset, 'example_bindings_generated.dart');
    expect(config.rustWorkspace, 'src/native');
    expect(config.rustCrate, 'example-ffi');
    expect(config.sourceDirectories, ['src/native']);
    expect(config.targets, ['x86_64-unknown-linux-gnu']);
    expect(config.androidApiFloor, 26);
    expect(config.macOSFloor, 12);
    expect(config.iOSFloor, 15);
  });

  test('the repository URL is normalized', () {
    expect(
      write('{"repository": "https://github.com/o/r.git"}').repository,
      'https://github.com/o/r',
    );
    expect(
      write('{"repository": "https://github.com/o/r/"}').repository,
      'https://github.com/o/r',
    );
  });

  test('every mistake names the field', () {
    expect(() => write('{').name, complains('not valid JSON'));
    expect(() => write('[]').name, complains('JSON object'));
    expect(() => write('{}').name, complains('"name" must be'));
    expect(() => write('{"name": ""}').name, complains('"name" must be'));
    expect(() => write('{}').repository, complains('"repository" must be'));
    expect(
      () => write('{"repository": "github.com/o/r"}').repository,
      complains('"repository" must be'),
    );
    expect(() => write('{}').targets, complains('"targets" must be'));
    expect(
      () => write('{"targets": "x86_64-unknown-linux-gnu"}').targets,
      complains('"targets" must be'),
    );
    expect(
      () => write('{"targets": ["aarch64-apple-darwin", "..."]}').targets,
      complains('"..."'),
    );
    expect(() => write('{}').rustWorkspace, complains('"rust.workspace"'));
    expect(
      () => write('{"rust": {"workspace": "."}}').rustCrate,
      complains('"rust.crate"'),
    );
    expect(
      () => write('{"rust": "."}').rustWorkspace,
      complains('"rust" must be an object'),
    );
    expect(
      () => write('{"floors": {"macos": "12"}}').macOSFloor,
      complains('"floors.macos"'),
    );
    expect(() => write('{"floor": {}}'), complains('unknown field "floor"'));
    expect(
      () => write('{"floors": {"macOS": 12}}'),
      complains('unknown field "floors.macOS"'),
    );
    expect(
      () => write('{"rust": {"workspce": "."}}'),
      complains('unknown field "rust.workspce"'),
    );
    for (final workspace in ['/', '..', '../x', '/abs', 'src/a#b', 'a//b']) {
      expect(
        () => write('{"rust": {"workspace": "$workspace"}}').rustWorkspace,
        complains('"rust.workspace" must be'),
        reason: workspace,
      );
    }
    expect(write('{"rust": {"workspace": "./"}}').rustWorkspace, '.');
    expect(
      write(
        '{"rust": {"workspace": ".", "crate": "x", "cflags": {}, "env": {}}}',
      ).rustCrate,
      'x',
    );
    expect(write('{"rust": {"workspace": "./src/x/"}}').rustWorkspace, 'src/x');
    expect(
      () => write('{"library": "a/b"}').library,
      complains('"library" must be a file name stem'),
    );
  });

  test('the package root is found from a subdirectory', () async {
    await File('${root.path}/dnix.json').writeAsString('{}');
    final nested = await Directory('${root.path}/a/b').create(recursive: true);
    expect(
      DnixConfig.findRoot(nested).toFilePath(),
      Directory(root.path).absolute.uri.toFilePath(),
    );
  });

  test('targets map to the triples the release assets use', () {
    expect(targetTriples(OS.android, Architecture.arm), [
      'armv7-linux-androideabi',
    ]);
    expect(targetTriples(OS.android, Architecture.ia32), [
      'i686-linux-android',
    ]);
    expect(targetTriples(OS.android, Architecture.x64), [
      'x86_64-linux-android',
    ]);
    expect(
      targetTriples(OS.iOS, Architecture.arm64, iOSSdk: IOSSdk.iPhoneSimulator),
      ['aarch64-apple-ios-sim'],
    );
    expect(targetTriples(OS.iOS, Architecture.arm64), ['aarch64-apple-ios']);
    expect(targetTriples(OS.iOS, Architecture.x64), ['x86_64-apple-ios']);
    expect(targetTriples(OS.macOS, Architecture.x64), ['x86_64-apple-darwin']);
    expect(targetTriples(OS.linux, Architecture.arm64), [
      'aarch64-unknown-linux-gnu',
    ]);
    // Windows has two ABIs per architecture, MSVC preferred.
    expect(targetTriples(OS.windows, Architecture.x64), [
      'x86_64-pc-windows-msvc',
      'x86_64-pc-windows-gnullvm',
    ]);
    expect(targetTriples(OS.windows, Architecture.arm64), [
      'aarch64-pc-windows-msvc',
      'aarch64-pc-windows-gnullvm',
    ]);
    expect(
      () => targetTriples(OS.fuchsia, Architecture.x64),
      throwsUnsupportedError,
    );
    expect(isAppleTarget('aarch64-apple-ios-sim'), isTrue);
    expect(isAppleTarget('aarch64-linux-android'), isFalse);
    expect(libraryFileName('x', 'x86_64-pc-windows-msvc'), 'x.dll');
    expect(libraryFileName('x', 'x86_64-pc-windows-gnullvm'), 'x.dll');
    expect(libraryFileName('x', 'aarch64-pc-windows-gnullvm'), 'x.dll');
    expect(libraryFileName('x', 'aarch64-apple-ios'), 'libx.dylib');
    expect(libraryFileName('x', 'aarch64-linux-android'), 'libx.so');
    for (final target in supportedTargets) {
      expect(target.split('-').length, greaterThanOrEqualTo(3));
    }
  });

  test('the hook serves the triple the package lists, MSVC when both', () {
    String? choose(OS os, Architecture architecture, List<String> targets) =>
        targetTriple(os, architecture, targets: targets);
    const gnu = ['x86_64-pc-windows-gnullvm', 'aarch64-pc-windows-gnullvm'];
    expect(
      choose(OS.linux, Architecture.x64, ['x86_64-unknown-linux-gnu', ...gnu]),
      'x86_64-unknown-linux-gnu',
    );
    expect(
      choose(OS.linux, Architecture.x64, ['aarch64-unknown-linux-gnu']),
      isNull,
    );
    expect(
      choose(OS.windows, Architecture.x64, ['x86_64-pc-windows-msvc']),
      'x86_64-pc-windows-msvc',
    );
    expect(
      choose(OS.windows, Architecture.x64, gnu),
      'x86_64-pc-windows-gnullvm',
    );
    expect(
      choose(OS.windows, Architecture.arm64, gnu),
      'aarch64-pc-windows-gnullvm',
    );
    expect(
      choose(OS.windows, Architecture.x64, [...gnu, 'x86_64-pc-windows-msvc']),
      'x86_64-pc-windows-msvc',
    );
    expect(
      choose(OS.windows, Architecture.arm64, [
        ...gnu,
        'aarch64-pc-windows-msvc',
      ]),
      'aarch64-pc-windows-msvc',
    );
    // The other architecture's GNU triple says nothing about this one.
    expect(
      choose(OS.windows, Architecture.arm64, ['x86_64-pc-windows-gnullvm']),
      isNull,
    );
    expect(choose(OS.windows, Architecture.x64, ['aarch64-apple-ios']), isNull);
    expect(choose(OS.windows, Architecture.x64, []), isNull);
    expect(
      () =>
          targetTriple(OS.fuchsia, Architecture.x64, targets: supportedTargets),
      throwsUnsupportedError,
    );
  });

  test('every triple belongs to exactly one platform name', () {
    const platforms = ['linux', 'android', 'windows', 'macos', 'ios'];
    for (final target in supportedTargets) {
      expect(
        platforms.where((platform) => belongsTo(target, platform)),
        hasLength(1),
        reason: target,
      );
      expect(belongsTo(target, target), isTrue);
    }
    expect(supportedTargets.where((t) => belongsTo(t, 'windows')), [
      'x86_64-pc-windows-msvc',
      'x86_64-pc-windows-gnullvm',
      'aarch64-pc-windows-msvc',
      'aarch64-pc-windows-gnullvm',
    ]);
    expect(belongsTo('x86_64-pc-windows-gnullvm', 'linux'), isFalse);
    expect(
      belongsTo('x86_64-pc-windows-gnullvm', 'x86_64-pc-windows-msvc'),
      isFalse,
    );
  });

  test('the flake supports the same targets as the hook', () {
    final nix = File('nix/lib.nix').readAsStringSync();
    final start = nix.indexOf('supportedTargets = [');
    final block = nix.substring(start, nix.indexOf('];', start));
    final listed = RegExp(r'"([^"]+)"')
        .allMatches(block)
        .map((match) => match.group(1))
        .toList();
    expect(listed, supportedTargets);
  });
}
