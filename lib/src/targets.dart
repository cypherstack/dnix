import 'package:code_assets/code_assets.dart';

/// Every target triple dnix can build, as `dnix.json` lists them.
const supportedTargets = [
  'aarch64-apple-darwin',
  'x86_64-apple-darwin',
  'aarch64-apple-ios',
  'aarch64-apple-ios-sim',
  'x86_64-apple-ios',
  'aarch64-linux-android',
  'armv7-linux-androideabi',
  'i686-linux-android',
  'x86_64-linux-android',
  'aarch64-unknown-linux-gnu',
  'x86_64-unknown-linux-gnu',
  'x86_64-pc-windows-msvc',
  'x86_64-pc-windows-gnullvm',
  'aarch64-pc-windows-msvc',
  'aarch64-pc-windows-gnullvm',
];

/// The triples that can serve a build target, the preferred one first.
///
/// Windows has two ABIs per architecture: MSVC, the default of Rust and of
/// Flutter's own build, and GNU (MinGW-w64) in Rust's `-gnullvm` flavour,
/// `x86_64-pc-windows-gnullvm` and `aarch64-pc-windows-gnullvm`. Every
/// other platform has one triple.
List<String> targetTriples(
  OS os,
  Architecture architecture, {
  IOSSdk? iOSSdk,
}) => switch ((os, architecture)) {
  (OS.android, Architecture.arm) => ['armv7-linux-androideabi'],
  (OS.android, Architecture.arm64) => ['aarch64-linux-android'],
  (OS.android, Architecture.ia32) => ['i686-linux-android'],
  (OS.android, Architecture.x64) => ['x86_64-linux-android'],
  (OS.iOS, Architecture.arm64) when iOSSdk == IOSSdk.iPhoneSimulator => [
    'aarch64-apple-ios-sim',
  ],
  (OS.iOS, Architecture.arm64) => ['aarch64-apple-ios'],
  (OS.iOS, Architecture.x64) => ['x86_64-apple-ios'],
  (OS.macOS, Architecture.arm64) => ['aarch64-apple-darwin'],
  (OS.macOS, Architecture.x64) => ['x86_64-apple-darwin'],
  (OS.linux, Architecture.arm64) => ['aarch64-unknown-linux-gnu'],
  (OS.linux, Architecture.x64) => ['x86_64-unknown-linux-gnu'],
  (OS.windows, Architecture.arm64) => [
    'aarch64-pc-windows-msvc',
    'aarch64-pc-windows-gnullvm',
  ],
  (OS.windows, Architecture.x64) => [
    'x86_64-pc-windows-msvc',
    'x86_64-pc-windows-gnullvm',
  ],
  _ => throw UnsupportedError('Unsupported target: $os/$architecture'),
};

/// The triple the hook serves a build target from: the first of its
/// [targetTriples] that [targets], a package's `dnix.json` list, contains,
/// or null when it contains none. These are the names the Nix side, the
/// release assets, and `dnix.lock` use.
String? targetTriple(
  OS os,
  Architecture architecture, {
  IOSSdk? iOSSdk,
  required Iterable<String> targets,
}) {
  for (final candidate in targetTriples(os, architecture, iOSSdk: iOSSdk)) {
    if (targets.contains(candidate)) return candidate;
  }
  return null;
}

/// Whether [target] is one of the Apple triples, which are built with the
/// host's Xcode rather than in the Nix sandbox.
bool isAppleTarget(String target) => target.contains('-apple-');

/// The dynamic library file name for [library] on [target]'s platform.
String libraryFileName(String library, String target) =>
    target.contains('-windows-')
    ? '$library.dll'
    : isAppleTarget(target)
    ? 'lib$library.dylib'
    : 'lib$library.so';
