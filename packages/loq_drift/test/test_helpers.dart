// Shared fixtures used by the unit and integration test suites.

import 'package:drift/drift.dart';
import 'package:loq/loq.dart' as loq;

/// A loq `Handler` that captures every record into an in-memory list.
/// Use with a per-test [loq.LogConfig] so the captured records are
/// scoped to one test:
///
/// ```dart
/// late TestLogHandler handler;
/// late loq.LogConfig config;
///
/// setUp(() {
///   handler = TestLogHandler();
///   config = loq.LogConfig(handlers: [handler]);
/// });
///
/// loq.Logger newLogger() => loq.Logger('db', config: config);
/// ```
class TestLogHandler implements loq.Handler {
  final List<loq.Record> records = [];

  @override
  bool isEnabled(loq.Level level) => true;
  @override
  void handle(loq.Record record) => records.add(record);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
}

/// Minimal [QueryExecutorUser] for tests that need to call
/// [QueryExecutor.ensureOpen] on the wrapped executor. Schema version
/// 1, no-op `beforeOpen`.
class TestSchemaUser extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}
