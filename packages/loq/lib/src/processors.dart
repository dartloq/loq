import 'package:loq/src/handler.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/log_config.dart';
import 'package:loq/src/record.dart';

/// Drops records below [minLevel].
Processor filterByLevel(Level minLevel) =>
    (record) => record.level >= minLevel ? record : null;

/// Keeps records whose level is at or above the threshold for their
/// [Record.loggerName]. The threshold comes from the rule whose key is
/// the longest prefix of the logger name; records below it are dropped.
///
/// Use the empty string `''` for a root catch-all. Records with a null
/// [Record.loggerName] fall back to [defaultLevel] — they do not hit
/// the `''` rule.
///
/// ```dart
/// LogConfig.configure(processors: [
///   levelByName({
///     'app.db.queries': Level.trace,
///     'app.db':         Level.warn,
///     'app':            Level.info,
///     '':               Level.error,
///   }),
/// ]);
///
/// // Logger('app.db.queries.select') → 'app.db.queries' → keep trace+
/// // Logger('app.db.connection')     → 'app.db'         → keep warn+
/// // Logger('payments')              → ''               → keep error+
/// // Logger(null)                    → defaultLevel     → keep trace+
/// ```
///
/// Walks the dotted name one step at a time. A rule key `'foo'` fits
/// `'foo'`, `'foo.bar'`, `'foo.bar.baz'`, but not `'foobar'`.
Processor levelByName(
  Map<String, Level> rules, {
  Level defaultLevel = Level.trace,
}) {
  Level threshold(String? name) {
    if (name == null) return defaultLevel;
    var current = name;
    while (true) {
      final rule = rules[current];
      if (rule != null) return rule;
      final dot = current.lastIndexOf('.');
      if (dot < 0) {
        // We tried `current` as a key above. If it was already '',
        // that was our root catch-all try. Otherwise try '' now.
        return current.isEmpty ? defaultLevel : (rules[''] ?? defaultLevel);
      }
      current = current.substring(0, dot);
    }
  }

  return (record) =>
      record.level >= threshold(record.loggerName) ? record : null;
}

/// Redacts field values by key.
Processor redact(Set<String> keys, {String replacement = '***'}) =>
    (record) => record.copyWith(
          fields: record.fields.map(
            (k, v) => MapEntry(k, keys.contains(k) ? replacement : v),
          ),
        );

/// Passes through approximately 1 in [n] records.
Processor sample(int n) {
  var count = 0;
  return (record) => ++count % n == 0 ? record : null;
}

/// Applies [processor] only when [condition] returns `true`.
///
/// Records that don't match the condition pass through unchanged.
Processor when(
  bool Function(Record) condition,
  Processor processor,
) =>
    (record) => condition(record) ? processor(record) : record;

/// Adds the record's timestamp as an ISO 8601 string field.
Processor addTimestamp({String key = 'timestamp'}) =>
    (record) => record.withFields({key: record.time.toIso8601String()});

/// Adds the record's level name as a field.
Processor addLevel({String key = 'level'}) =>
    (record) => record.withFields({key: record.level.name});

/// Adds the record's logger name as a field.
///
/// Skips records with no logger name.
Processor addLoggerName({String key = 'logger'}) => (record) {
      if (record.loggerName == null) return record;
      return record.withFields({key: record.loggerName});
    };

/// Adds the record's source location as a string field.
///
/// Requires [LogConfig.captureSourceLocation] to be enabled.
/// Skips records with no source location.
Processor addSource({String key = 'source'}) => (record) {
      if (record.source == null) return record;
      return record.withFields({key: record.source.toString()});
    };
