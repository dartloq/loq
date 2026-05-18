// Integration tests against real in-memory SQLite via
// `NativeDatabase.memory()`. These exercise the actual drift dispatch
// path (not the synthetic `_FakeExecutor` used by the unit tests) and
// catch behavior that depends on real query execution: row counts
// returned by sqlite, real exception types, batch internals, etc.
//
// Slower than the unit suite but covers a different shape of risk.
// Requires the system sqlite3 library at runtime (most macOS/Linux
// distros ship it; on Windows CI you'd vendor a `sqlite3.dll`).

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:loq/loq.dart' as loq;
import 'package:loq_drift/loq_drift.dart';
import 'package:test/test.dart';

import '../test_helpers.dart';

Future<QueryExecutor> _openDb(loq.Logger logger) async {
  final executor = NativeDatabase.memory()
      .interceptWith(LoqDriftInterceptor(logger: logger));
  await executor.ensureOpen(TestSchemaUser());
  await executor.runCustom(
    'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)',
  );
  return executor;
}

void main() {
  late TestLogHandler handler;
  late loq.LogConfig config;

  setUp(() {
    handler = TestLogHandler();
    config = loq.LogConfig(handlers: [handler]);
  });

  loq.Logger newLogger() => loq.Logger('db', config: config);

  test('INSERT through real sqlite emits loq.db.last_insert_rowid', () async {
    final db = await _openDb(newLogger());

    final result = await db.runInsert(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ['Tibor', 'tibor@example.com'],
    );

    expect(result, 1);
    final insertLog = handler.records.firstWhere(
      (r) => r.fields['db.operation.name'] == 'INSERT',
    );
    expect(insertLog.fields['loq.db.last_insert_rowid'], 1);
    expect(insertLog.fields['db.system.name'], 'sqlite');
    await db.close();
  });

  test('UPDATE on real sqlite reports affected row count', () async {
    final db = await _openDb(newLogger());
    await db.runInsert(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ['Tibor', 'a@b.c'],
    );
    handler.records.clear();

    final affected = await db.runUpdate(
      'UPDATE users SET email = ? WHERE name = ?',
      ['new@x.y', 'Tibor'],
    );

    expect(affected, 1);
    expect(
      handler.records.single.fields['loq.db.affected_rows'],
      1,
    );
    await db.close();
  });

  test('SELECT through real sqlite emits db.response.returned_rows', () async {
    final db = await _openDb(newLogger());
    await db.runInsert(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ['Ada', 'a@b.c'],
    );
    await db.runInsert(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ['Grace', 'g@b.c'],
    );
    handler.records.clear();

    final rows = await db.runSelect('SELECT * FROM users', const []);

    expect(rows, hasLength(2));
    expect(
      handler.records.single.fields['db.response.returned_rows'],
      2,
    );
    await db.close();
  });

  test('batch INSERT through real sqlite reports batch.size', () async {
    final db = await _openDb(newLogger());
    handler.records.clear();

    await db.runBatched(
      BatchedStatements(
        ['INSERT INTO users (name, email) VALUES (?, ?)'],
        [
          ArgumentsForBatchedStatement(0, ['Ada', 'a@b.c']),
          ArgumentsForBatchedStatement(0, ['Grace', 'g@b.c']),
          ArgumentsForBatchedStatement(0, ['Linus', 'l@b.c']),
        ],
      ),
    );

    final batchLog =
        handler.records.firstWhere((r) => r.message == 'batch completed');
    expect(batchLog.fields['db.operation.name'], 'BATCH');
    expect(batchLog.fields['db.operation.batch.size'], 3);
    await db.close();
  });

  test('failing SELECT through real sqlite surfaces SqliteException', () async {
    final db = await _openDb(newLogger());
    handler.records.clear();

    await expectLater(
      db.runSelect('SELECT * FROM does_not_exist', const []),
      throwsA(isA<Exception>()),
    );

    final errLog = handler.records.single;
    expect(errLog.message, 'query failed');
    expect(errLog.level, loq.Level.error);
    expect(errLog.fields['error.type'], isA<String>());
    // sqlite3's exception type name should mention "Sqlite".
    expect(
      (errLog.fields['error.type']! as String).toLowerCase(),
      contains('sqlite'),
    );
    await db.close();
  });

  test('lifecycle: open then close emits both records', () async {
    final executor = NativeDatabase.memory()
        .interceptWith(LoqDriftInterceptor(logger: newLogger()));

    await executor.ensureOpen(TestSchemaUser());
    expect(
      handler.records.where((r) => r.message == 'database opened'),
      hasLength(1),
    );

    await executor.close();
    expect(
      handler.records.where((r) => r.message == 'database closed'),
      hasLength(1),
    );
  });

  test('transaction commit through real sqlite emits begin + commit', () async {
    final db = await _openDb(newLogger());
    handler.records.clear();

    final tx = db.beginTransaction();
    await tx.ensureOpen(TestSchemaUser());
    await tx.runInsert(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ['Tibor', 'a@b.c'],
    );
    await tx.send();

    final messages = handler.records.map((r) => r.message).toList();
    expect(messages, contains('transaction begin'));
    expect(messages, contains('transaction commit'));
    expect(messages, contains('query completed'));
    await db.close();
  });
}
