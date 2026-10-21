import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dnix/dnix.dart';
import 'package:dnix/src/targets.dart';
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
    expect(
      targetTriple(OS.android, Architecture.arm),
      'armv7-linux-androideabi',
    );
    expect(targetTriple(OS.android, Architecture.ia32), 'i686-linux-android');
    expect(targetTriple(OS.android, Architecture.x64), 'x86_64-linux-android');
    expect(
      targetTriple(OS.iOS, Architecture.arm64, iOSSdk: IOSSdk.iPhoneSimulator),
      'aarch64-apple-ios-sim',
    );
    expect(targetTriple(OS.iOS, Architecture.arm64), 'aarch64-apple-ios');
    expect(targetTriple(OS.iOS, Architecture.x64), 'x86_64-apple-ios');
    expect(targetTriple(OS.macOS, Architecture.x64), 'x86_64-apple-darwin');
    expect(
      targetTriple(OS.windows, Architecture.x64),
      'x86_64-pc-windows-msvc',
    );
    expect(
      targetTriple(OS.windows, Architecture.arm64),
      'aarch64-pc-windows-msvc',
    );
    expect(
      () => targetTriple(OS.fuchsia, Architecture.x64),
      throwsUnsupportedError,
    );
    expect(isAppleTarget('aarch64-apple-ios-sim'), isTrue);
    expect(isAppleTarget('aarch64-linux-android'), isFalse);
    expect(libraryFileName('x', 'x86_64-pc-windows-msvc'), 'x.dll');
    expect(libraryFileName('x', 'aarch64-apple-ios'), 'libx.dylib');
    expect(libraryFileName('x', 'aarch64-linux-android'), 'libx.so');
    for (final target in supportedTargets) {
      expect(target.split('-').length, greaterThanOrEqualTo(3));
    }
  });
}
