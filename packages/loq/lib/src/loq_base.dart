import 'dart:async';
import 'dart:convert';

// ---------------------------------------------------------------------------
// Level
// ---------------------------------------------------------------------------

/// Log severity levels.
///
/// Numeric values leave gaps for custom levels and clean OTel severity mapping.
enum Level implements Comparable<Level> {
  /// Fine-grained debugging events.
  trace(0),

  /// Debugging information.
  debug(4),

  /// Normal operational events.
  info(8),

  /// Potentially harmful situations.
  warn(12),

  /// Error events that might still allow the app to continue.
  error(16),

  /// Severe errors that will likely cause the app to abort.
  fatal(20);

  const Level(this.value);

  /// The numeric severity value.
  final int value;

  /// Whether this level is at or above [other].
  bool operator >=(Level other) => value >= other.value;

  /// Whether this level is below [other].
  bool operator <(Level other) => value < other.value;

  @override
  int compareTo(Level other) => value.compareTo(other.value);
}

// ---------------------------------------------------------------------------
// Record
// ---------------------------------------------------------------------------

/// An immutable log event.
///
/// Produced by a [Logger] and consumed by [Handler]s after passing
/// through the processor chain.
class Record {
  /// Creates a log record.
  const Record({
    required this.time,
    required this.level,
    required this.message,
    required this.fields,
    required this.zone,
    this.loggerName,
  });

  /// When the event occurred.
  final DateTime time;

  /// Severity of the event.
  final Level level;

  /// Human-readable log message.
  final String message;

  /// Structured key-value fields.
  final Map<String, Object?> fields;

  /// The logger name (source/category).
  final String? loggerName;

  /// The [Zone] at the time of the log call.
  final Zone zone;

  /// Returns a copy with additional or overridden fields.
  Record withFields(Map<String, Object?> extra) => Record(
        time: time,
        level: level,
        message: message,
        fields: {...fields, ...extra},
        loggerName: loggerName,
        zone: zone,
      );
}

// ---------------------------------------------------------------------------
// Processor
// ---------------------------------------------------------------------------

/// A function that transforms, enriches, or filters a [Record].
///
/// Return the record (possibly modified) to pass it along.
/// Return `null` to drop it.
typedef Processor = Record? Function(Record record);

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// A backend that writes processed [Record]s somewhere.
///
/// Implement this for custom sinks: files, network, OTel, Crashlytics, etc.
abstract interface class Handler {
  /// Whether this handler wants records at [level].
  ///
  /// Called before any allocation — if all handlers return `false`,
  /// the [Logger] skips building the [Record] entirely.
  bool isEnabled(Level level);

  /// Write a fully processed record.
  void handle(Record record);

  /// Flush any buffered output.
  Future<void> flush();

  /// Release resources.
  Future<void> close();
}

// ---------------------------------------------------------------------------
// LogConfig
// ---------------------------------------------------------------------------

/// Global and per-logger configuration.
class LogConfig {
  /// Creates a configuration.
  const LogConfig({
    this.processors = const [],
    this.handlers = const [],
    this.zoneAccessor,
  });

  /// The processor chain applied to every record.
  final List<Processor> processors;

  /// The handlers that receive processed records.
  final List<Handler> handlers;

  /// Extracts ambient fields from the current [Zone].
  final Map<String, Object?>? Function(Zone zone)? zoneAccessor;

  /// The global default configuration.
  static LogConfig global = LogConfig(handlers: [ConsoleHandler()]);

  /// Configure the global defaults. Call once at app startup.
  static void configure({
    List<Processor>? processors,
    List<Handler>? handlers,
    Map<String, Object?>? Function(Zone zone)? zoneAccessor,
  }) {
    global = LogConfig(
      processors: processors ?? global.processors,
      handlers: handlers ?? global.handlers,
      zoneAccessor: zoneAccessor ?? global.zoneAccessor,
    );
  }

  /// Reset global config to defaults.
  static void reset() {
    global = LogConfig(handlers: [ConsoleHandler()]);
  }
}

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

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

  /// Returns a new [Logger] that includes [fields] in every record.
  ///
  /// The original logger is not mutated.
  Logger withFields(Map<String, Object?> fields) =>
      Logger._bound(name, {..._context, ...fields}, _config);

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

    final zoneFields = _config.zoneAccessor?.call(Zone.current);

    final allFields = <String, Object?>{
      ...?zoneFields,
      ..._context,
      ...?callFields,
    };

    var record = Record(
      time: DateTime.now(),
      level: level,
      message: message,
      fields: allFields,
      loggerName: name,
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

// ---------------------------------------------------------------------------
// Zone context
// ---------------------------------------------------------------------------

final _loqContextKey = Object();

/// Run [body] with ambient log fields that flow through async calls.
///
/// ```dart
/// withLogContext({'requestId': id}, () async {
///   log.info('start');   // includes requestId
///   await doWork();
///   log.info('done');    // still includes requestId
/// });
/// ```
R withLogContext<R>(Map<String, Object?> fields, R Function() body) {
  final current = Zone.current[_loqContextKey] as Map<String, Object?>?;
  return runZoned(
    body,
    zoneValues: {
      _loqContextKey: {...?current, ...fields},
    },
  );
}

/// Default [LogConfig.zoneAccessor] that reads from [withLogContext].
Map<String, Object?>? defaultZoneAccessor(Zone zone) =>
    zone[_loqContextKey] as Map<String, Object?>?;

// ---------------------------------------------------------------------------
// Built-in processors
// ---------------------------------------------------------------------------

/// Drops records below [minLevel].
Processor filterByLevel(Level minLevel) =>
    (record) => record.level >= minLevel ? record : null;

/// Redacts field values by key.
Processor redact(Set<String> keys, {String replacement = '***'}) => (record) {
      final redacted = Map<String, Object?>.of(record.fields);
      for (final key in keys) {
        if (redacted.containsKey(key)) redacted[key] = replacement;
      }
      return Record(
        time: record.time,
        level: record.level,
        message: record.message,
        fields: redacted,
        loggerName: record.loggerName,
        zone: record.zone,
      );
    };

/// Passes through approximately 1 in [n] records.
Processor sample(int n) {
  var count = 0;
  return (record) => ++count % n == 0 ? record : null;
}

// ---------------------------------------------------------------------------
// Console handler
// ---------------------------------------------------------------------------

/// Prints human-readable log output. Intended for development.
class ConsoleHandler implements Handler {
  /// Creates a console handler.
  ConsoleHandler({this.minLevel = Level.info});

  /// Minimum level to display.
  final Level minLevel;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) {
    final time = record.time.toIso8601String().substring(11, 23);
    final lvl = record.level.name.toUpperCase().padRight(5);
    final src = record.loggerName != null ? ' ${record.loggerName}:' : '';

    final buf = StringBuffer('$time [$lvl]$src ${record.message}');

    final visible = record.fields.entries
        .where((e) => e.key != 'error' && e.key != 'stackTrace');
    if (visible.isNotEmpty) {
      buf.write(' | ${visible.map((e) => '${e.key}=${e.value}').join(', ')}');
    }

    // Since this is a console handler, print is acceptable here
    // ignore: avoid_print
    print(buf);

    final err = record.fields['error'];
    if (err != null) {
      // Since this is a console handler, print is acceptable here
      // ignore: avoid_print
      print('  error: $err');
    }
    final st = record.fields['stackTrace'];
    if (st != null) {
      // Since this is a console handler, print is acceptable here
      // ignore: avoid_print
      print('  $st');
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

// ---------------------------------------------------------------------------
// JSON handler
// ---------------------------------------------------------------------------

/// Writes one JSON object per line. Intended for production log pipelines.
class JsonHandler implements Handler {
  /// Creates a JSON handler.
  ///
  /// [writer] defaults to [print]. Provide a custom writer for file or
  /// network output.
  JsonHandler({this.minLevel = Level.info, void Function(String)? writer})
      : _write = writer ?? print;

  /// Minimum level to export.
  final Level minLevel;

  final void Function(String line) _write;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) {
    final map = <String, Object?>{
      'time': record.time.toIso8601String(),
      'level': record.level.name,
      'msg': record.message,
      if (record.loggerName != null) 'logger': record.loggerName,
      for (final e in record.fields.entries) e.key: _normalize(e.value),
    };
    _write(jsonEncode(map));
  }

  Object? _normalize(Object? v) {
    if (v == null || v is String || v is num || v is bool) return v;
    if (v is List) return v.map(_normalize).toList();
    if (v is Map) return v.map((k, v) => MapEntry(k.toString(), _normalize(v)));
    return v.toString();
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
