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
];

/// The Rust-style target triple for a build target. These are the names the
/// Nix side, the release assets, and `dnix.lock` use.
String targetTriple(OS os, Architecture architecture, {IOSSdk? iOSSdk}) =>
    switch ((os, architecture)) {
      (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
      (OS.android, Architecture.arm64) => 'aarch64-linux-android',
      (OS.android, Architecture.ia32) => 'i686-linux-android',
      (OS.android, Architecture.x64) => 'x86_64-linux-android',
      (OS.iOS, Architecture.arm64) when iOSSdk == IOSSdk.iPhoneSimulator =>
        'aarch64-apple-ios-sim',
      (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
      (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
      _ => throw UnsupportedError('Unsupported target: $os/$architecture'),
    };

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
