import 'dart:async';

import 'package:loq/src/lazy.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/log_config.dart';
import 'package:loq/src/record.dart';
import 'package:loq/src/source_location.dart';

/// A structured logger.
///
/// ```dart
/// final log = Logger('payments');
/// log.info('processed', fields: {'orderId': 'abc', 'amount': 99.95});
///
/// final reqLog = log.withFields({'requestId': 'req-123'});
/// reqLog.info('handling request');
/// ```
class Logger {
  /// Creates a logger with the given [name].
  Logger(this.name, {LogConfig? config})
      : _context = const {},
        _config = config ?? LogConfig.global;

  Logger._bound(this.name, this._context, this._config);

  /// The logger name, used as a source/category identifier.
  final String? name;

  final Map<String, Object?> _context;
  final LogConfig _config;

  /// Whether any handler is interested in records at [level].
  ///
  /// Use this to guard expensive field computation that cannot be
  /// wrapped in a [Lazy]:
  ///
  /// ```dart
  /// if (log.isEnabled(Level.debug)) {
  ///   log.debug('state', fields: {'snapshot': computeExpensiveSnapshot()});
  /// }
  /// ```
  bool isEnabled(Level level) =>
      _config.handlers.any((h) => h.isEnabled(level));

  /// Returns a new [Logger] that includes [fields] in every record.
  ///
  /// The original logger is not mutated.
  Logger withFields(Map<String, Object?> fields) =>
      Logger._bound(name, {..._context, ...fields}, _config);

  /// Log at an arbitrary [level]. Use this for custom levels.
  ///
  /// ```dart
  /// const notice = Level(10);
  /// log.log(notice, 'disk usage high', fields: {'usage': 0.83});
  /// ```
  void log(
    Level level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? fields,
  }) {
    _log(level, message, {
      ...?fields,
      if (error != null) 'error': error,
      if (stackTrace != null) 'stackTrace': stackTrace,
    });
  }

  /// Log at [Level.trace].
  void trace(String message, {Map<String, Object?>? fields}) =>
      _log(Level.trace, message, fields);

  /// Log at [Level.debug].
  void debug(String message, {Map<String, Object?>? fields}) =>
      _log(Level.debug, message, fields);

  /// Log at [Level.info].
  void info(String message, {Map<String, Object?>? fields}) =>
      _log(Level.info, message, fields);

  /// Log at [Level.warn].
  void warn(String message, {Map<String, Object?>? fields}) =>
      _log(Level.warn, message, fields);

  /// Log at [Level.error].
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? fields,
  }) {
    _log(Level.error, message, {
      ...?fields,
      if (error != null) 'error': error,
      if (stackTrace != null) 'stackTrace': stackTrace,
    });
  }

  /// Log at [Level.fatal].
  void fatal(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? fields,
  }) {
    _log(Level.fatal, message, {
      ...?fields,
      if (error != null) 'error': error,
      if (stackTrace != null) 'stackTrace': stackTrace,
    });
  }

  void _log(Level level, String message, Map<String, Object?>? callFields) {
    if (!_config.handlers.any((h) => h.isEnabled(level))) return;

    // Capture source before any other work so the frame offset is stable.
    // skipFrames: 0 = _log, 1 = info/error/log/etc, 2 = caller.
    final source = _config.captureSourceLocation
        ? SourceLocation.parse(StackTrace.current, skipFrames: 2)
        : null;

    final zoneFields = _config.zoneAccessor?.call(Zone.current);

    final merged = <String, Object?>{
      ...?zoneFields,
      ..._context,
      ...?callFields,
    };

    // Resolve Lazy values so handlers and isolate boundaries never see them.
    final allFields = merged.map(
      (k, v) => MapEntry(k, v is Lazy ? v.value : v),
    );

    var record = Record(
      time: DateTime.now(),
      level: level,
      message: message,
      fields: allFields,
      loggerName: name,
      source: source,
      zone: Zone.current,
    );

    for (final processor in _config.processors) {
      final result = processor(record);
      if (result == null) return;
      record = result;
    }

    for (final handler in _config.handlers) {
      if (handler.isEnabled(level)) {
        handler.handle(record);
      }
    }
  }
}
