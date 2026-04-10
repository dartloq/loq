import 'dart:async';

import 'package:loq/loq.dart';

/// A handler that serializes records and sends them via a callback.
///
/// Designed for cross-isolate logging where the callback is typically
/// `sendPort.send`, but any `void Function(Object?)` works — making
/// this usable on web with other messaging mechanisms.
///
/// ```dart
/// // In a worker isolate:
/// LogConfig.configure(
///   handlers: [IsolateHandler(sendPort.send)],
/// );
///
/// // In the main isolate, receive and reconstruct:
/// receivePort.listen((message) {
///   final record = IsolateHandler.deserialize(
///     message as Map<String, Object?>,
///   );
///   mainHandler.handle(record);
/// });
/// ```
class IsolateHandler implements Handler {
  /// Creates an isolate handler that sends serialized records via [_send].
  IsolateHandler(this._send, {this.minLevel = Level.info});

  final void Function(Object?) _send;

  /// Minimum level to send.
  final Level minLevel;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) => _send(_serialize(record));

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  /// Reconstructs a [Record] from a serialized map produced by this handler.
  static Record deserialize(Map<String, Object?> data) {
    return Record(
      time: DateTime.parse(data['time']! as String),
      level: Level(data['level']! as int),
      message: data['message']! as String,
      loggerName: data['loggerName'] as String?,
      fields: (data['fields'] as Map?)?.cast<String, Object?>() ?? const {},
      zone: Zone.current,
    );
  }

  Map<String, Object?> _serialize(Record record) {
    return {
      'time': record.time.toIso8601String(),
      'level': record.level.value,
      'message': record.message,
      'loggerName': record.loggerName,
      'fields': _coerceFields(record.fields),
    };
  }

  Map<String, Object?> _coerceFields(Map<String, Object?> fields) {
    return fields.map((k, v) => MapEntry(k, _coerce(v)));
  }

  Object? _coerce(Object? v) {
    if (v is Lazy) return _coerce(v.value);
    if (v is FieldGroup) return _coerceFields(v.fields);
    if (v == null || v is String || v is num || v is bool) return v;
    if (v is List) return v.map(_coerce).toList();
    if (v is Map) return v.map((k, v) => MapEntry(k.toString(), _coerce(v)));
    return v.toString();
  }
}
