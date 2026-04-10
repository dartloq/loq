import 'dart:convert';

import 'package:loq/src/field_group.dart';
import 'package:loq/src/handler.dart';
import 'package:loq/src/lazy.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/record.dart';

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
      if (record.source != null) 'source': record.source.toString(),
      for (final e in record.fields.entries) e.key: _normalize(e.value),
    };
    _write(jsonEncode(map));
  }

  Object? _normalize(Object? v) {
    if (v is Lazy) return _normalize(v.value);
    if (v is FieldGroup) {
      return v.fields.map((k, v) => MapEntry(k, _normalize(v)));
    }
    if (v == null || v is String || v is num || v is bool) return v;
    if (v is List) return v.map(_normalize).toList();
    if (v is Map) {
      return v.map((k, v) => MapEntry(k.toString(), _normalize(v)));
    }
    return v.toString();
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
