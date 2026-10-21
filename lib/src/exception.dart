/// A failure dnix reports to the person running the build, with a message
/// that says what to do about it. The hook turns it into the hooks
/// package's error types; the tools print the message and exit.
class DnixException implements Exception {
  /// A problem in the package or its inputs.
  DnixException(this.message) : infrastructure = false;

  /// A problem outside the package: the network, or a missing tool.
  DnixException.infrastructure(this.message) : infrastructure = true;

  /// What went wrong and what to do.
  final String message;

  /// Whether the cause is outside the package.
  final bool infrastructure;

  @override
  String toString() => message;
}
