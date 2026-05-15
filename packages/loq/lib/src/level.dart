/// Log severity level.
///
/// A zero-cost int wrapper. The built-in levels use numeric gaps so that
/// custom levels can slot in between without modifying the package.
///
/// ```dart
/// // Built-in
/// log.info('hello');
///
/// // Custom levels — define anywhere, use everywhere
/// const notice = Level(10);   // between info(8) and warn(12)
/// const critical = Level(18); // between error(16) and fatal(20)
/// log.log(notice, 'disk usage high');
/// ```
///
/// OTel severity mapping: TRACE→1, DEBUG→5,
/// INFO→9, WARN→13, ERROR→17, FATAL→21.
extension type const Level(int value) {
  /// Fine-grained debugging events.
  static const trace = Level(0);

  /// Debugging information.
  static const debug = Level(4);

  /// Normal operational events.
  static const info = Level(8);

  /// Potentially harmful situations.
  static const warn = Level(12);

  /// Error events that might still allow the app to continue.
  static const error = Level(16);

  /// Severe errors that will likely cause the app to abort.
  static const fatal = Level(20);

  /// Whether this level is at or above [other].
  bool operator >=(Level other) => value >= other.value;

  /// Whether this level is below [other].
  bool operator <(Level other) => value < other.value;

  /// Compares this level to [other] by severity.
  ///
  /// Returns a negative value if this level is less severe than [other],
  /// zero if equal, and a positive value if more severe.
  int compareTo(Level other) => value.compareTo(other.value);

  /// Human-readable name for this level.
  ///
  /// Returns the standard name for built-in levels, or `'level($value)'`
  /// for custom levels.
  String get name => switch (this) {
        trace => 'trace',
        debug => 'debug',
        info => 'info',
        warn => 'warn',
        error => 'error',
        fatal => 'fatal',
        _ => 'level($value)',
      };

  /// Parses a standard level name (case-insensitive). Returns `null`
  /// for unknown input.
  ///
  /// Useful for reading log levels from env vars or config files:
  ///
  /// ```dart
  /// final level = Level.tryParse(Platform.environment['LOG_LEVEL'] ?? '');
  /// LogConfig.configure(handlers: [
  ///   ConsoleHandler(minLevel: level ?? Level.info),
  /// ]);
  /// ```
  ///
  /// Accepts the six built-in names and the alias `'warning'` for
  /// [warn]. Custom levels are not parsed.
  static Level? tryParse(String name) => switch (name.toLowerCase().trim()) {
        'trace' => trace,
        'debug' => debug,
        'info' => info,
        'warn' || 'warning' => warn,
        'error' => error,
        'fatal' => fatal,
        _ => null,
      };
}
