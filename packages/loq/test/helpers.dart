import 'dart:async';

import 'package:loq/loq.dart';

/// Creates a Record for testing. Defaults give a minimal Record; pass
/// named params to vary [level], [loggerName], [fields], [time], or
/// [source].
Record makeRecord(
  String message, {
  Level level = Level.info,
  String? loggerName,
  Map<String, Object?> fields = const {},
  DateTime? time,
  SourceLocation? source,
}) =>
    Record(
      time: time ?? DateTime(2024),
      level: level,
      message: message,
      fields: fields,
      loggerName: loggerName,
      source: source,
      zone: Zone.current,
    );
