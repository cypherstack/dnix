import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dnix/src/exception.dart';
import 'package:dnix/src/targets.dart';

/// The package's `dnix.lock`: the hashes of every library the package's
/// current native source builds to, and the name of the release that
/// carries those bytes.
///
/// The lock is a source file. Whoever changes the native code rebuilds and
/// rewrites it in the same change, and CI fails when the source no longer
/// builds to what the lock says. The release name is derived from the
/// hashes, so it changes exactly when the bytes change.
///
/// `files` maps `<target triple>/<library file name>` to a SHA-256 hex
/// digest, the same keys as the SHA256SUMS the builds produce.
class DnixLock {
  /// A lock holding [files] for [release], written on [date].
  DnixLock({required this.release, required this.date, required this.files});

  /// The file name in the package root.
  static const fileName = 'dnix.lock';

  /// Content-derived name of the release holding these bytes, without the
  /// `native-` prefix.
  final String release;

  /// The day the lock was written, for people reading the file.
  final String date;

  /// SHA-256 hex digest by `<target triple>/<library file name>`.
  final Map<String, String> files;

  /// The committed lock, or null before the first one is written. A lock
  /// that is unreadable, or whose release does not match its hashes, is a
  /// [DnixException].
  static DnixLock? load(Uri packageRoot) {
    final file = File.fromUri(packageRoot.resolve(fileName));
    if (!file.existsSync()) return null;
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw DnixException('${file.path} is not valid JSON: ${error.message}');
    }
    if (json is! Map<String, Object?> ||
        json['release'] is! String ||
        json['date'] is! String ||
        json['files'] is! Map<String, Object?>) {
      throw DnixException(
        '${file.path} is not a dnix lock: it needs release, date, and files. '
        'Regenerate it with update_lock.',
      );
    }
    final files = <String, String>{};
    for (final MapEntry(:key, :value)
        in (json['files'] as Map<String, Object?>).entries) {
      final parts = key.split('/');
      if (parts.length != 2 ||
          !supportedTargets.contains(parts[0]) ||
          parts[1].isEmpty) {
        throw DnixException(
          '${file.path}: "$key" is not <target triple>/<library file>.',
        );
      }
      if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
        throw DnixException(
          '${file.path}: the hash of $key is not a SHA-256 hex digest.',
        );
      }
      files[key] = value;
    }
    final release = json['release'] as String;
    if (release != releaseFor(files)) {
      throw DnixException(
        '${file.path}: release $release does not match its hashes, which '
        'name ${releaseFor(files)}. Regenerate it with update_lock.',
      );
    }
    return DnixLock(
      release: release,
      date: json['date'] as String,
      files: files,
    );
  }

  /// The release name for a set of hashes: the first twelve hex digits of
  /// the SHA-256 over the sorted `<key>  <hash>` lines.
  static String releaseFor(Map<String, String> files) {
    final keys = files.keys.toList()..sort();
    final lines = keys.map((key) => '$key  ${files[key]}\n').join();
    return sha256.convert(utf8.encode(lines)).toString().substring(0, 12);
  }

  /// The git tag and GitHub release name.
  String get tag => 'native-$release';

  /// The pinned hash for a library, or null when the package does not build
  /// it.
  String? hashFor(String target, String fileName) => files['$target/$fileName'];

  /// Release assets are flat, so the target triple prefixes the file name.
  static String assetName(String target, String fileName) =>
      '$target-$fileName';

  /// Where a library of this release is downloaded from, given the package
  /// repository's URL as [DnixConfig.repository] normalizes it.
  Uri assetUrl(String repository, String target, String fileName) => Uri.parse(
    '${repository.replaceAll(RegExp(r'/+$'), '')}'
    '/releases/download/$tag/${assetName(target, fileName)}',
  );

  /// The file contents, with the files in a stable order.
  String encode() {
    final keys = files.keys.toList()..sort();
    final json = const JsonEncoder.withIndent('  ').convert({
      'release': release,
      'date': date,
      'files': {for (final key in keys) key: files[key]!},
    });
    return '$json\n';
  }

  /// Writes the lock, keeping the existing date when the hashes are
  /// unchanged so a rewrite is byte-identical.
  static DnixLock write(Uri packageRoot, Map<String, String> files) {
    final release = releaseFor(files);
    DnixLock? existing;
    try {
      existing = load(packageRoot);
    } on DnixException {
      existing = null; // An old or broken lock is simply replaced.
    }
    final date = existing != null && existing.release == release
        ? existing.date
        : DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final lock = DnixLock(release: release, date: date, files: files);
    File.fromUri(packageRoot.resolve(fileName))
        .writeAsStringSync(lock.encode());
    return lock;
  }
}

const _dynamicLibrarySuffixes = ['.so', '.dylib', '.dll'];

/// The dynamic libraries listed in `sha256sum` output, keyed by path without
/// a leading `./` or the binary-mode `*` marker, so
/// `./x86_64-unknown-linux-gnu/libhrf_api.so` becomes
/// `x86_64-unknown-linux-gnu/libhrf_api.so`.
Map<String, String> dynamicLibraryHashes(Iterable<String> sha256sumLines) {
  final files = <String, String>{};
  for (final line in sha256sumLines) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    final digest = parts[0];
    var name = parts[1];
    if (name.startsWith('*')) name = name.substring(1);
    if (name.startsWith('./')) name = name.substring(2);
    if (_dynamicLibrarySuffixes.any(name.endsWith)) files[name] = digest;
  }
  return files;
}

/// The SHA-256 of [bytes] as lowercase hex.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Fails unless [bytes] hash to [expected].
void verifyHash({
  required List<int> bytes,
  required String expected,
  required String what,
}) {
  final actual = sha256Hex(bytes);
  if (actual != expected) {
    throw DnixException(
      'Hash mismatch for $what.\n'
      '  expected $expected\n'
      '  actual   $actual\n'
      'The file is not the one dnix.lock records. Build mode "dev" skips '
      'this check for local development.',
    );
  }
}

/// A response with a status other than 200.
class HttpStatusException extends HttpException {
  /// An exception for [statusCode] received from [uri].
  HttpStatusException(this.statusCode, Uri uri)
    : super('HTTP $statusCode from $uri', uri: uri);

  /// The status the server sent.
  final int statusCode;
}

bool _isLoopback(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);

/// No response or no progress for this long fails the download, so a
/// stalled connection cannot hang the build.
const _stall = Duration(seconds: 60);

/// Downloads [url] and returns its bytes, following redirects. A status
/// other than 200 is an [HttpStatusException].
Future<Uint8List> download(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  // Loopback never goes through a proxy; everything else follows the
  // environment, which hooks receive.
  client.findProxy = (uri) => _isLoopback(uri.host)
      ? 'DIRECT'
      : HttpClient.findProxyFromEnvironment(uri);
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(_stall);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpStatusException(response.statusCode, url);
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(_stall)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// Returns the cached copy of a verified library, downloading it when the
/// cache has no copy with the pinned hash. The cache is keyed by hash, so a
/// new release never reuses an old file.
Future<File> fetchPrebuilt({
  required Uri url,
  required String fileName,
  required String expectedHash,
  required Uri cacheDirectory,
  required String packageName,
}) async {
  // A prefix of the hash keeps the path short for Windows; the content is
  // verified in full on every use.
  final cached = File.fromUri(
    cacheDirectory.resolve(
      'prebuilt/${expectedHash.substring(0, 16)}/$fileName',
    ),
  );
  if (cached.existsSync() &&
      sha256Hex(cached.readAsBytesSync()) == expectedHash) {
    return cached;
  }
  stderr.writeln('$packageName: downloading $url');
  const locally =
      'Build mode "source" or "dev" builds the library locally instead.';
  final Uint8List bytes;
  try {
    bytes = await download(url);
  } on HttpStatusException catch (error) {
    if (error.statusCode == HttpStatus.notFound) {
      throw DnixException(
        '$url does not exist.\n'
        'Either the release is not published yet (that happens when a '
        "dnix.lock naming it reaches the repository's default branch), the "
        '"repository" in dnix.json is wrong or private, or the release was '
        'deleted. $locally',
      );
    }
    throw DnixException.infrastructure(
      'Downloading failed: ${error.message}. Retry later. $locally',
    );
  } on IOException catch (error) {
    throw DnixException.infrastructure(
      'Downloading $url failed: $error. Check the network and retry. $locally',
    );
  } on TimeoutException {
    throw DnixException.infrastructure(
      'Downloading $url stalled for ${_stall.inSeconds} seconds. Check the '
      'network and retry. $locally',
    );
  }
  verifyHash(bytes: bytes, expected: expectedHash, what: url.toString());
  cached.parent.createSync(recursive: true);
  final temporary = File('${cached.path}.part');
  temporary.writeAsBytesSync(bytes, flush: true);
  temporary.renameSync(cached.path);
  return cached;
}
