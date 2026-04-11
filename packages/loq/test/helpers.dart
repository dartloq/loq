import 'dart:async';

import 'package:loq/loq.dart';

/// A handler that captures records for testing.
class TestHandler implements Handler {
  TestHandler({this.minLevel = Level.trace});

  final Level minLevel;
  final List<Record> records = [];

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

/// Creates a minimal Record for testing.
Record makeRecord(String message, {Level level = Level.info}) => Record(
      time: DateTime(2024),
      level: level,
      message: message,
      fields: {},
      zone: Zone.current,
    );
