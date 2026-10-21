import 'dart:io';

import 'package:dnix/dnix.dart';
import 'package:dnix/src/lock.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Directory cache;
  final library = List<int>.generate(1000, (i) => i % 251);
  final hash = sha256Hex(library);
  var requests = 0;
  late void Function(HttpRequest) handler;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('dnix-cache-');
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      requests++;
      handler(request);
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await cache.delete(recursive: true);
  });

  Uri url(String path) =>
      Uri.parse('http://127.0.0.1:${server.port}/releases/download/$path');

  Future<File> fetch(String path) => fetchPrebuilt(
    url: url(path),
    fileName: 'libx.so',
    expectedHash: hash,
    cacheDirectory: cache.uri,
    packageName: 'x',
  );

  Matcher fails({required bool infrastructure, required String saying}) =>
      throwsA(
        isA<DnixException>()
            .having((e) => e.infrastructure, 'infrastructure', infrastructure)
            .having((e) => e.message, 'message', contains(saying)),
      );

  test('a verified download is cached and served from the cache', () async {
    handler = (request) {
      request.response
        ..add(library)
        ..close();
    };
    final file = await fetch('native-abc/libx.so');
    expect(file.readAsBytesSync(), library);
    expect(file.path, startsWith(cache.path));
    expect(Directory(file.parent.path).listSync(), hasLength(1));
    await fetch('native-abc/libx.so');
    expect(requests, 1);
  });

  test('a corrupt cache entry is replaced', () async {
    handler = (request) {
      request.response
        ..add(library)
        ..close();
    };
    final file = await fetch('native-abc/libx.so');
    file.writeAsBytesSync([0]);
    expect((await fetch('native-abc/libx.so')).readAsBytesSync(), library);
    expect(requests, 2);
  });

  test('wrong bytes leave nothing in the cache', () async {
    handler = (request) {
      request.response
        ..add([...library, 0])
        ..close();
    };
    await expectLater(
      fetch('native-abc/libx.so'),
      fails(infrastructure: false, saying: 'Hash mismatch'),
    );
    expect(Directory('${cache.path}/prebuilt').existsSync(), isFalse);
  });

  test('a missing release explains how releases appear', () async {
    handler = (request) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    };
    await expectLater(
      fetch('native-abc/libx.so'),
      fails(infrastructure: false, saying: 'default branch'),
    );
  });

  test('server and network failures are infrastructure', () async {
    handler = (request) {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..close();
    };
    await expectLater(
      fetch('native-abc/libx.so'),
      fails(infrastructure: true, saying: 'HTTP 503'),
    );
    handler = (request) async {
      // Promise the whole file, send a piece, then drop every connection.
      request.response.contentLength = library.length;
      request.response.add(library.sublist(0, 10));
      await request.response.flush();
      await server.close(force: true);
    };
    await expectLater(
      fetch('native-abc/libx.so'),
      fails(infrastructure: true, saying: 'Check the network'),
    );
  });
}
