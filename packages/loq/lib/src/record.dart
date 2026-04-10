import 'dart:async';

import 'package:loq/src/handler.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/logger.dart';
import 'package:loq/src/source_location.dart';

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
    this.source,
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

  /// The call-site source location, if captured.
  final SourceLocation? source;

  /// The [Zone] at the time of the log call.
  final Zone zone;

  /// Returns a copy with additional or overridden fields.
  Record withFields(Map<String, Object?> extra) => copyWith(
        fields: {...fields, ...extra},
      );

  /// Returns a copy with the given [source] location.
  Record withSource(SourceLocation source) => copyWith(source: source);

  /// Returns a copy with the specified fields replaced.
  Record copyWith({
    DateTime? time,
    Level? level,
    String? message,
    Map<String, Object?>? fields,
    String? loggerName,
    SourceLocation? source,
    Zone? zone,
  }) =>
      Record(
        time: time ?? this.time,
        level: level ?? this.level,
        message: message ?? this.message,
        fields: fields ?? this.fields,
        loggerName: loggerName ?? this.loggerName,
        source: source ?? this.source,
        zone: zone ?? this.zone,
      );
}
