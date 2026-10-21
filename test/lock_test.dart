import 'dart:io';

import 'package:dnix/dnix.dart';
import 'package:dnix/src/lock.dart';
import 'package:dnix/src/modes.dart';
import 'package:dnix/tools.dart';
import 'package:test/test.dart';

void main() {
  const hash1 =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const hash2 =
      '2222222222222222222222222222222222222222222222222222222222222222';
  const hash3 =
      '3333333333333333333333333333333333333333333333333333333333333333';
  const files = {
    'x86_64-unknown-linux-gnu/libx.so': hash1,
    'aarch64-apple-darwin/libx.dylib': hash2,
  };

  test('the release name depends only on the hashes', () {
    final release = DnixLock.releaseFor(files);
    expect(release, hasLength(12));
    expect(
      DnixLock.releaseFor(Map.fromEntries(files.entries.toList().reversed)),
      release,
    );
    expect(DnixLock.releaseFor({...files, 'a/libx.so': hash3}), isNot(release));
  });

  test('a written lock loads back, names its assets, and keeps its date', () async {
    final root = await Directory.systemTemp.createTemp('dnix-lock-');
    addTearDown(() => root.delete(recursive: true));
    expect(DnixLock.load(root.uri), isNull);

    final first = DnixLock.write(root.uri, files);
    final loaded = DnixLock.load(root.uri)!;
    expect(loaded.release, first.release);
    expect(loaded.tag, 'native-${first.release}');
    expect(loaded.hashFor('x86_64-unknown-linux-gnu', 'libx.so'), hash1);
    expect(loaded.hashFor('x86_64-pc-windows-msvc', 'x.dll'), isNull);
    expect(
      loaded
          .assetUrl(
            'https://github.com/o/r/',
            'x86_64-unknown-linux-gnu',
            'libx.so',
          )
          .toString(),
      'https://github.com/o/r/releases/download/native-${first.release}/x86_64-unknown-linux-gnu-libx.so',
    );

    // Same hashes: byte-identical file, date untouched.
    final before = File('${root.path}/dnix.lock').readAsStringSync();
    final again = DnixLock(
      release: first.release,
      date: '2000-01-01',
      files: files,
    ).encode();
    File('${root.path}/dnix.lock').writeAsStringSync(again);
    DnixLock.write(root.uri, files);
    expect(File('${root.path}/dnix.lock').readAsStringSync(), again);
    expect(before, contains('"release": "${first.release}"'));
  });

  test(
    'write_lock keeps only dynamic libraries from SHA256SUMS files',
    () async {
      final root = await Directory.systemTemp.createTemp('dnix-lock-');
      addTearDown(() => root.delete(recursive: true));
      final sums = File('${root.path}/SHA256SUMS')
        ..writeAsStringSync(
          '$hash1  ./x86_64-unknown-linux-gnu/libx.so\n'
          '$hash2  ./x86_64-unknown-linux-gnu/libx.a\n'
          '$hash3  ./x86_64-pc-windows-msvc/x.dll\n'
          '$hash1  ./x86_64-pc-windows-msvc/x.dll.lib\n'
          '$hash2 *aarch64-apple-darwin/libx.dylib\n'
          'not a checksum line\n',
        );
      expect(writeLock([root.path, sums.path]), 0);
      expect(DnixLock.load(root.uri)!.files, {
        'x86_64-unknown-linux-gnu/libx.so': hash1,
        'x86_64-pc-windows-msvc/x.dll': hash3,
        'aarch64-apple-darwin/libx.dylib': hash2,
      });
    },
  );

  test(
    'an old-format or damaged lock is reported, and replaced on write',
    () async {
      final root = await Directory.systemTemp.createTemp('dnix-lock-');
      addTearDown(() => root.delete(recursive: true));
      final lock = File('${root.path}/dnix.lock');
      lock.writeAsStringSync(
        '{"nativeVersion": "0.0.1", "releaseUrl": "x", "files": {}}',
      );
      expect(
        () => DnixLock.load(root.uri),
        throwsA(
          isA<DnixException>().having(
            (e) => e.message,
            'message',
            contains('not a dnix lock'),
          ),
        ),
      );
      Matcher complains(String about) => throwsA(
        isA<DnixException>().having(
          (e) => e.message,
          'message',
          contains(about),
        ),
      );
      lock.writeAsStringSync(
        '{"release": "abc", "date": "2026-01-01", '
        '"files": {"x86_64-unknown-linux-gnu/libx.so": 7}}',
      );
      expect(() => DnixLock.load(root.uri), complains('not a SHA-256'));
      lock.writeAsStringSync(
        '{"release": "abc", "date": "2026-01-01", '
        '"files": {"nope/libx.so": "$hash1"}}',
      );
      expect(
        () => DnixLock.load(root.uri),
        complains('is not <target triple>/<library file>'),
      );
      // A release that does not name its own hashes, as a mangled merge
      // leaves behind.
      lock.writeAsStringSync(
        DnixLock(
          release: '000000000000',
          date: '2026-01-01',
          files: files,
        ).encode(),
      );
      expect(() => DnixLock.load(root.uri), complains('does not match its'));
      lock.writeAsStringSync('{');
      expect(() => DnixLock.load(root.uri), throwsA(isA<DnixException>()));
      DnixLock.write(root.uri, files);
      expect(DnixLock.load(root.uri)!.release, DnixLock.releaseFor(files));
    },
  );

  test('verification fails on a mismatch and passes on a match', () {
    final bytes = [1, 2, 3];
    final digest = sha256Hex(bytes);
    verifyHash(bytes: bytes, expected: digest, what: 'bytes');
    expect(
      () => verifyHash(bytes: bytes, expected: 'ff', what: 'bytes'),
      throwsA(isA<DnixException>()),
    );
  });

  test('the checkout file overrides the user define', () async {
    final root = await Directory.systemTemp.createTemp('dnix-mode-');
    addTearDown(() => root.delete(recursive: true));
    expect(resolveBuildMode(root.uri, null), BuildMode.prebuilt);
    expect(resolveBuildMode(root.uri, 'dev'), BuildMode.dev);
    File('${root.path}/.dnix-build').writeAsStringSync('source\n');
    expect(resolveBuildMode(root.uri, 'dev'), BuildMode.source);
  });

  test('build mode defaults to prebuilt and rejects unknown values', () {
    expect(BuildMode.parse(null), BuildMode.prebuilt);
    expect(BuildMode.parse('source'), BuildMode.source);
    expect(BuildMode.parse('dev'), BuildMode.dev);
    expect(() => BuildMode.parse('fast'), throwsA(isA<DnixException>()));
  });
}
