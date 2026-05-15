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
  ///
  /// If [config] is omitted, the logger resolves [LogConfig.global] at
  /// every log call. This means `LogConfig.configure()` updates take
  /// effect immediately for all loggers that did not pin an explicit
  /// config. If [config] is supplied, that config wins for the lifetime
  /// of the logger.
  Logger(this.name, {LogConfig? config})
      : _context = const {},
        _explicitConfig = config;

  Logger._bound(this.name, this._context, this._explicitConfig);

  /// The logger name, used as a source/category identifier.
  final String? name;

  final Map<String, Object?> _context;

  /// Per-logger config override. `null` means "defer to [LogConfig.global]
  /// at log time."
  final LogConfig? _explicitConfig;

  /// Resolves the effective config: the explicit override if set,
  /// otherwise the current [LogConfig.global].
  LogConfig get _config => _explicitConfig ?? LogConfig.global;

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
  /// The original logger is not mutated. The new logger inherits the
  /// original's config-override decision: if the parent had an explicit
  /// config, the bound logger uses the same explicit config; otherwise
  /// the bound logger also resolves [LogConfig.global] lazily.
  Logger withFields(Map<String, Object?> fields) =>
      Logger._bound(name, {..._context, ...fields}, _explicitConfig);

  /// Returns a new [Logger] whose name has [suffix] appended with a
  /// dot. Inherits this logger's context and config-override decision.
  ///
  /// ```dart
  /// final db = Logger('app').named('db');           // 'app.db'
  /// final q  = db.named('queries');                  // 'app.db.queries'
  /// ```
  ///
  /// If this logger has no name, [suffix] becomes the new name.
  Logger named(String suffix) {
    final newName = name == null ? suffix : '$name.$suffix';
    return Logger._bound(newName, _context, _explicitConfig);
  }

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
    // Resolve config once per call so all reads within this log event
    // see a consistent snapshot.
    final config = _config;
    final interested = config.handlers.where((h) {
      try {
        return h.isEnabled(level);
        // Containment: a misbehaving handler must not break logging
        // for sibling handlers or the host.
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        config.onHandlerError(h, e, st);
        return false;
      }
    }).toList();
    if (interested.isEmpty) return;

    // Capture source before any other work so the frame offset is stable.
    // skipFrames: 0 = _log, 1 = info/error/log/etc, 2 = caller.
    final source = config.captureSourceLocation
        ? SourceLocation.parse(StackTrace.current, skipFrames: 2)
        : null;

    final zoneFields = config.zoneAccessor?.call(Zone.current);

    final merged = <String, Object?>{
      ...?zoneFields,
      ..._context,
      ...?callFields,
    };

    // Resolve Lazy values so handlers and isolate boundaries never see them.
    final allFields = merged.map(
      (k, v) => MapEntry(k, v is Lazy ? v.value : v),
    );

    final record = config.processors.fold<Record?>(
      Record(
        time: DateTime.now(),
        level: level,
        message: message,
        fields: allFields,
        loggerName: name,
        source: source,
        zone: Zone.current,
      ),
      (rec, processor) => rec != null ? processor(rec) : null,
    );
    if (record == null) return;

    for (final h in interested) {
      try {
        h.handle(record);
        // Same containment as the isEnabled check above.
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        config.onHandlerError(h, e, st);
      }
    }
  }
}
