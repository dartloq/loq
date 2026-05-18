// Showcase database exercising every loq_drift capability:
//
//   namespace                  : emit db.namespace on every event
//   skipLog                    : silence PRAGMA / health-check chatter
//   slowQueryThreshold         : flag and bump up slow queries
//   captureArgs                : include bound parameters (PII-aware)
//   fields                     : tag every successful event
//   errorFields                : mark retry-worthiness on failures
//   tableResolver              : populate db.collection.name
//   levelResolver              : custom per-event level logic
//   transaction lifecycle      : begin / commit / rollback at trace
//   database lifecycle         : open / close at trace
//
// Run with: `dart run example/example.dart`
//
// Requires the system sqlite3 library (most macOS/Linux distros ship it).
//
// Drives the raw `QueryExecutor` API so the example compiles without
// running `build_runner`. In a real app you'd hand the wrapped executor
// to your generated `GeneratedDatabase` subclass:
//
// ```dart
// final db = AppDatabase(
//   NativeDatabase.memory().interceptWith(LoqDriftInterceptor()),
// );
// ```

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:loq/loq.dart';
import 'package:loq_drift/loq_drift.dart';

/// Minimal `QueryExecutorUser` so the example can open the executor
/// without a generated database class.
class _NoSchema extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

/// Pull the primary table out of common Drift-generated SQL patterns.
String? _resolveTable(String sql) {
  final m = RegExp(
    r'\b(?:from|into|update)\s+"?(\w+)"?',
    caseSensitive: false,
  ).firstMatch(sql);
  return m?.group(1);
}

Future<void> main() async {
  // Swap ConsoleHandler for JsonHandler() to get one structured JSON
  // object per line (what you'd ship to Datadog/Elastic/Grafana).
  LogConfig.configure(
    handlers: [ConsoleHandler(minLevel: Level.trace)],
  );

  final interceptor = LoqDriftInterceptor(
    // ---- Setup ----
    logger: Logger('db'),
    namespace: ':memory:',

    // ---- Behavior ----
    skipLog: (sql) => sql.startsWith('PRAGMA'),
    slowQueryThreshold: const Duration(milliseconds: 50),

    // captureArgs leaks user-bound values into logs. Safe for dev; in
    // production combine with loq's redact() processor or leave off.
    captureArgs: true,

    // ---- Field hooks ----
    //
    // One hook for every success-path event. Pattern-match on `event`
    // to branch (DriftQueryEvent / DriftBatchEvent /
    // DriftTransactionEvent). Here we just tag every event the same.
    fields: (event) => {
      ...event.defaults,
      'tenant_id': 'acme',
    },
    errorFields: (event, error, stack) => {
      ...event.defaults,
      'db.error.retryable': error.toString().contains('locked'),
    },

    // ---- Resolvers ----
    tableResolver: _resolveTable,

    // Bump SELECTs that touch `users` to info for this demo.
    levelResolver: (event, error) {
      if (error == null &&
          event is DriftQueryEvent &&
          event.operation == 'SELECT' &&
          event.defaults['db.collection.name'] == 'users') {
        return Level.info;
      }
      return null;
    },
  );

  final executor = NativeDatabase.memory().interceptWith(interceptor);
  await executor.ensureOpen(_NoSchema());

  // Skipped by the skip predicate, so no log.
  await executor.runCustom('PRAGMA foreign_keys = ON');

  // Schema bootstrap. Logged as CREATE.
  await executor.runCustom(
    'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)',
  );

  // Single-row insert. sqlite reports the new row id via
  // `loq.db.last_insert_rowid` (`loq.db.affected_rows` on other dialects).
  await executor.runInsert(
    'INSERT INTO users (name, email) VALUES (?, ?)',
    ['Tibor', 'tibor@example.com'],
  );

  // Batch insert: one prepared statement, two argument groups.
  await executor.runBatched(
    BatchedStatements(
      const ['INSERT INTO users (name, email) VALUES (?, ?)'],
      [
        ArgumentsForBatchedStatement(0, ['Ada', 'ada@example.com']),
        ArgumentsForBatchedStatement(0, ['Grace', 'grace@example.com']),
      ],
    ),
  );

  // Read: bumped to info by levelResolver.
  await executor.runSelect('SELECT * FROM users', const []);

  // Transaction: begin, two updates, commit. Lifecycle events at trace;
  // inner queries at debug.
  final tx = executor.beginTransaction();
  await tx.ensureOpen(_NoSchema());
  await tx.runUpdate(
    'UPDATE users SET email = ? WHERE name = ?',
    ['tibor@scandit.com', 'Tibor'],
  );
  await tx.runUpdate(
    'UPDATE users SET email = ? WHERE name = ?',
    ['ada+oss@example.com', 'Ada'],
  );
  await tx.send();

  // Failing query: error log includes error.type, error.message,
  // stackTrace, plus the errorFields-supplied db.error.retryable.
  try {
    await executor.runSelect('SELECT * FROM does_not_exist', const []);
  } on Object catch (_) {
    // swallowed for the demo
  }

  await executor.close();
}
