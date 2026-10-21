import 'dart:convert';
import 'dart:io';

import 'package:dnix/src/exception.dart';
import 'package:dnix/src/targets.dart';

/// The package's `dnix.json`: what the native library is called, which
/// targets it ships for, where its source is, and the deployment floors it
/// is built at. The Nix side reads the same file, so both build paths
/// agree.
///
/// Every mistake in the fields the hook reads is reported as a
/// [DnixException] naming the field; unknown fields are rejected so a typo
/// cannot silently fall back to a default.
class DnixConfig {
  DnixConfig._(this._json);

  final Map<String, Object?> _json;

  /// The file name in the package root.
  static const fileName = 'dnix.json';

  static const _knownFields = {
    'name',
    'repository',
    'library',
    'asset',
    'rust',
    'toolchains',
    'floors',
    'paths',
    'targets',
  };
  static const _knownRustFields = {
    'workspace',
    'crate',
    'manifest',
    'outputHashes',
  };
  static const _knownFloors = {'macos', 'ios', 'android', 'glibc'};

  /// Reads `dnix.json` from [packageRoot].
  static DnixConfig load(Uri packageRoot) {
    final file = File.fromUri(packageRoot.resolve(fileName));
    if (!file.existsSync()) {
      throw DnixException('${file.path} is missing; dnix needs it.');
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw DnixException('$fileName is not valid JSON: ${error.message}');
    }
    if (json is! Map<String, Object?>) {
      throw DnixException('$fileName must hold a JSON object.');
    }
    final config = DnixConfig._(json);
    config._rejectUnknown(json.keys, _knownFields, '');
    config._rejectUnknown(
      config._section('rust').keys,
      _knownRustFields,
      'rust.',
    );
    config._rejectUnknown(
      config._section('floors').keys,
      _knownFloors,
      'floors.',
    );
    return config;
  }

  /// Finds the package root by walking up from [start] until `dnix.json`
  /// appears. For tools run from inside a checkout.
  static Uri findRoot([Directory? start]) {
    var directory = (start ?? Directory.current).absolute;
    while (true) {
      if (File('${directory.path}/$fileName').existsSync()) {
        return directory.uri;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        throw DnixException(
          'No $fileName found above ${Directory.current.path}.',
        );
      }
      directory = parent;
    }
  }

  void _rejectUnknown(Iterable<String> keys, Set<String> known, String prefix) {
    for (final key in keys) {
      if (!known.contains(key)) {
        throw DnixException(
          '$fileName: unknown field "$prefix$key". Known: '
          '${known.map((k) => '$prefix$k').join(', ')}',
        );
      }
    }
  }

  String _string(Map<String, Object?> json, String key, {String? section}) {
    final value = json[key];
    if (value is String && value.isNotEmpty) return value;
    final field = section == null ? key : '$section.$key';
    throw DnixException('$fileName: "$field" must be a non-empty string.');
  }

  Map<String, Object?> _section(String key) {
    final value = _json[key];
    if (value == null) return const {};
    if (value is Map<String, Object?>) return value;
    throw DnixException('$fileName: "$key" must be an object.');
  }

  int _floor(String key, int fallback) {
    final value = _section('floors')[key];
    if (value == null) return fallback;
    if (value is int) return value;
    throw DnixException('$fileName: "floors.$key" must be an integer.');
  }

  /// The package name, used in messages.
  String get name => _string(_json, 'name');

  /// The package's GitHub repository URL, without a trailing slash or
  /// `.git`. Prebuilt libraries are downloaded from its releases.
  String get repository {
    final value = _json['repository'];
    final url = value is String ? Uri.tryParse(value) : null;
    if (url == null ||
        !url.isAbsolute ||
        (url.scheme != 'https' && url.scheme != 'http') ||
        url.host.isEmpty) {
      throw DnixException(
        '$fileName: "repository" must be the package\'s GitHub URL, like '
        'https://github.com/owner/name; prebuilt libraries are downloaded '
        'from its releases.',
      );
    }
    var path = url.path.replaceAll(RegExp(r'/+$'), '');
    if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
    return url.replace(path: path, query: null, fragment: null).toString();
  }

  /// The library base name, without `lib` prefix or extension.
  String get library {
    final value = _string(_json, 'library');
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$').hasMatch(value)) {
      throw DnixException(
        '$fileName: "library" must be a file name stem like hrf_api, '
        'not "$value".',
      );
    }
    return value;
  }

  /// The name of the code asset the hook emits, which the package's
  /// `@Native` bindings reference.
  String get asset => _string(_json, 'asset');

  /// Target triples the package ships libraries for.
  List<String> get targets {
    final value = _json['targets'];
    if (value is! List<Object?> || value.isEmpty) {
      throw DnixException('$fileName: "targets" must be a non-empty list.');
    }
    final targets = <String>[];
    for (final target in value) {
      if (target is! String || !supportedTargets.contains(target)) {
        throw DnixException(
          '$fileName: "targets" has "$target", which dnix cannot build. '
          'Supported: ${supportedTargets.join(', ')}',
        );
      }
      targets.add(target);
    }
    return targets;
  }

  /// The Rust workspace directory, relative to the package root; `.` is
  /// the root itself. From `rust.workspace`.
  String get rustWorkspace {
    final given = _string(_section('rust'), 'workspace', section: 'rust');
    var value = given.replaceAll(RegExp(r'/+$'), '');
    if (value.startsWith('./')) value = value.substring(2);
    if (value.isEmpty) value = '.';
    final segments = value.split('/');
    if (given.startsWith('/') ||
        segments.any((s) => s.isEmpty || s == '..') ||
        value.contains(RegExp(r'[#?\\]'))) {
      throw DnixException(
        '$fileName: "rust.workspace" must be a directory inside the package, '
        'relative to its root, like src/native or ".", not "$given".',
      );
    }
    return value;
  }

  /// The cargo package to build, from `rust.crate`.
  String get rustCrate => _string(_section('rust'), 'crate', section: 'rust');

  /// The directories holding the native source, relative to the package
  /// root. Builds read them, so the hook declares their files as inputs.
  List<String> get sourceDirectories => [rustWorkspace];

  /// Lowest macOS major version the libraries support.
  int get macOSFloor => _floor('macos', 12);

  /// Lowest iOS major version the libraries support.
  int get iOSFloor => _floor('ios', 15);

  /// Lowest Android API level the libraries support.
  int get androidApiFloor => _floor('android', 24);
}
