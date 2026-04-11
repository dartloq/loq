import 'package:loq/src/handler.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/log_config.dart';
import 'package:loq/src/record.dart';

/// Drops records below [minLevel].
Processor filterByLevel(Level minLevel) =>
    (record) => record.level >= minLevel ? record : null;

/// Redacts field values by key.
Processor redact(Set<String> keys, {String replacement = '***'}) => (record) {
      final redacted = Map<String, Object?>.of(record.fields);
      for (final key in keys) {
        if (redacted.containsKey(key)) redacted[key] = replacement;
      }
      return record.copyWith(fields: redacted);
    };

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
