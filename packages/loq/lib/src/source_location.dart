/// A parsed source location from a Dart stack trace.
///
/// Captures the file path, line number, and optionally the column and
/// member (function/method) name of a call site.
class SourceLocation {
  /// Creates a source location.
  const SourceLocation({
    required this.file,
    required this.line,
    this.column,
    this.member,
  });

  /// Parses a source location from a [stackTrace].
  ///
  /// Skips [skipFrames] frames from the top before reading.
  /// Returns `null` if the frame cannot be parsed or is out of range.
  static SourceLocation? parse(
    StackTrace stackTrace, {
    int skipFrames = 0,
  }) {
    final frames = stackTrace.toString().split('\n');
    if (skipFrames >= frames.length) return null;
    final match = _framePattern.firstMatch(frames[skipFrames]);
    if (match == null) return null;
    return SourceLocation(
      member: match.group(1),
      file: match.group(2)!,
      line: int.parse(match.group(3)!),
      column: match.group(4) != null ? int.parse(match.group(4)!) : null,
    );
  }

  // Matches Dart VM format: #N  member (file:line:column)
  static final _framePattern = RegExp(
    r'#\d+\s+(.+?)\s+\((.+?):(\d+)(?::(\d+))?\)',
  );

  /// The source file path or URI.
  final String file;

  /// The line number.
  final int line;

  /// The column number, if available.
  final int? column;

  /// The function or method name, if available.
  final String? member;

  @override
  String toString() => '$file:$line';
}
