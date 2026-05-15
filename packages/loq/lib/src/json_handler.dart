import 'dart:convert';

import 'package:loq/src/field_group.dart';
import 'package:loq/src/handler.dart';
import 'package:loq/src/lazy.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/record.dart';

String _defaultDateTimeFormat(DateTime dt) => dt.toIso8601String();

/// Writes one JSON object per line. Intended for production log pipelines.
class JsonHandler implements Handler {
  /// Creates a JSON handler.
  ///
  /// [writer] defaults to [print]. Provide a custom writer for file or
  /// network output.
  ///
  /// [dateTimeFormatter] customizes how [Record.time] and any
  /// DateTime field value is rendered. Defaults to
  /// [DateTime.toIso8601String]. Examples:
  ///
  /// ```dart
  /// // Epoch milliseconds
  /// JsonHandler(
  ///   dateTimeFormatter: (dt) => dt.millisecondsSinceEpoch.toString(),
  /// )
  ///
  /// // RFC3339 without sub-seconds
  /// JsonHandler(
  ///   dateTimeFormatter: (dt) =>
  ///       '${dt.toIso8601String().substring(0, 19)}Z',
  /// )
  /// ```
  JsonHandler({
    this.minLevel = Level.info,
    void Function(String)? writer,
    String Function(DateTime)? dateTimeFormatter,
  })  : _write = writer ?? print,
        _dateTimeFormatter = dateTimeFormatter ?? _defaultDateTimeFormat;

  /// Minimum level to export.
  final Level minLevel;

  final void Function(String line) _write;

  final String Function(DateTime) _dateTimeFormatter;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) {
    final map = <String, Object?>{
      'time': _dateTimeFormatter(record.time),
      'level': record.level.name,
      'msg': record.message,
      if (record.loggerName != null) 'logger': record.loggerName,
      if (record.source != null) 'source': record.source.toString(),
      for (final e in record.fields.entries) e.key: _normalize(e.value),
    };
    _write(jsonEncode(map));
  }

  Object? _normalize(Object? v) => switch (v) {
        Lazy() => _normalize(v.value),
        FieldGroup() => v.fields.map((k, v) => MapEntry(k, _normalize(v))),
        null || String() || num() || bool() => v,
        DateTime() => _dateTimeFormatter(v),
        Duration() => v.inMilliseconds,
        Uri() => v.toString(),
        List() => v.map(_normalize).toList(),
        Map() => v.map((k, v) => MapEntry(k.toString(), _normalize(v))),
        _ => v.toString(),
      };

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
