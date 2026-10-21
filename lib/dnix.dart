/// Reproducible native assets with Nix.
///
/// A package's `hook/build.dart` delegates to [buildNativeLibrary], which
/// fetches the library of the release named in `dnix.lock` and verifies its
/// hash, or runs the same Nix build that produced it. The `dnix.json` and
/// `dnix.lock` files it reads are described in `doc/configuration.md`.
library;

export 'src/config.dart' show DnixConfig;
export 'src/exception.dart' show DnixException;
export 'src/hook.dart' show buildNativeLibrary;
export 'src/lock.dart' show DnixLock;
export 'src/modes.dart' show BuildMode;
