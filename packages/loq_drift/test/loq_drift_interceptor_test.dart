import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:loq/loq.dart' as loq;
import 'package:loq_drift/loq_drift.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// A test double for [QueryExecutor] that records calls and lets the
/// test specify return values and failures.
class _FakeExecutor extends QueryExecutor {
  _FakeExecutor({
    this.dialect = SqlDialect.sqlite,
    this.selectRows = const [],
    this.insertRowId = 1,
    this.updateRows = 0,
    this.deleteRows = 0,
    this.throwOn,
    this.beforeRun,
  });

  @override
  final SqlDialect dialect;

  /// Rows returned from runSelect.
  List<Map<String, Object?>> selectRows;

  /// Row id returned from runInsert.
  int insertRowId;

  /// Affected rows from runUpdate.
  int updateRows;

  /// Affected rows from runDelete.
  int deleteRows;

  /// When non-null, runX throws this. Applies to all run* calls.
  Object? throwOn;

  /// Optional async work to perform before each run* call (delays,
  /// schedule additional logs from the inner zone, etc.).
  Future<void> Function()? beforeRun;

  /// Log of every method called against this executor.
  final List<String> calls = [];

  Future<void> _maybeThrow() async {
    if (beforeRun != null) await beforeRun!();
    final t = throwOn;
    if (t != null) {
      // Test fake forwards whatever the caller supplied as a throwable.
      // ignore: only_throw_errors
      throw t;
    }
  }

  /// When true, [ensureOpen] throws a [StateError].
  bool openThrows = false;

  /// When true, [close] throws a [StateError].
  bool closeThrows = false;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    calls.add('ensureOpen');
    if (openThrows) throw StateError('open failed');
    return true;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async {
    calls.add('runSelect:$statement');
    await _maybeThrow();
    return selectRows;
  }

  @override
  Future<int> runInsert(String statement, List<Object?> args) async {
    calls.add('runInsert:$statement');
    await _maybeThrow();
    return insertRowId;
  }

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async {
    calls.add('runUpdate:$statement');
    await _maybeThrow();
    return updateRows;
  }

  @override
  Future<int> runDelete(String statement, List<Object?> args) async {
    calls.add('runDelete:$statement');
    await _maybeThrow();
    return deleteRows;
  }

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async {
    calls.add('runCustom:$statement');
    await _maybeThrow();
  }

  @override
  Future<void> runBatched(BatchedStatements statements) async {
    calls.add('runBatched:${statements.statements.join("|")}');
    await _maybeThrow();
  }

  /// When true, the [TransactionExecutor] returned by [beginTransaction]
  /// throws on `send()`.
  bool txCommitThrows = false;

  /// When true, the [TransactionExecutor] returned by [beginTransaction]
  /// throws on `rollback()`.
  bool txRollbackThrows = false;

  @override
  TransactionExecutor beginTransaction() {
    final tx = _FakeTransactionExecutor(this)
      ..sendThrows = txCommitThrows
      ..rollbackThrows = txRollbackThrows;
    return tx;
  }

  @override
  QueryExecutor beginExclusive() => this;

  @override
  Future<void> close() async {
    calls.add('close');
    if (closeThrows) throw StateError('close failed');
  }
}

class _FakeTransactionExecutor extends _FakeExecutor
    implements TransactionExecutor {
  _FakeTransactionExecutor(_FakeExecutor parent)
      : super(dialect: parent.dialect);

  bool sendThrows = false;
  bool rollbackThrows = false;

  @override
  Future<void> send() async {
    calls.add('send');
    if (sendThrows) throw StateError('commit failed');
  }

  @override
  Future<void> rollback() async {
    calls.add('rollback');
    if (rollbackThrows) throw StateError('rollback failed');
  }

  @override
  bool get supportsNestedTransactions => false;
}

void main() {
  late TestLogHandler logHandler;
  late loq.LogConfig config;

  setUp(() {
    logHandler = TestLogHandler();
    config = loq.LogConfig(handlers: [logHandler]);
  });

  loq.Logger newLogger() => loq.Logger('db', config: config);

  // ---------------------------------------------------------------------------
  // Single-query path
  // ---------------------------------------------------------------------------

  group('single queries', () {
    test('runSelect logs operation, query, duration, returned rows', () async {
      final executor = _FakeExecutor(
        selectRows: [
          {'a': 1},
          {'a': 2},
          {'a': 3},
        ],
      ).interceptWith(LoqDriftInterceptor(logger: newLogger()));

      final rows = await executor.runSelect('SELECT * FROM users', const []);

      expect(rows, hasLength(3));
      expect(logHandler.records, hasLength(1));
      final r = logHandler.records.single;
      expect(r.message, 'query completed');
      expect(r.fields['db.system.name'], 'sqlite');
      expect(r.fields['db.operation.name'], 'SELECT');
      expect(r.fields['db.query.text'], 'SELECT * FROM users');
      expect(r.fields['db.query.summary'], 'SELECT');
      expect(r.fields['db.response.returned_rows'], 3);
      expect(r.fields['duration_ms'], isA<int>());
    });

    test('db.query.summary includes collection when tableResolver set',
        () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          tableResolver: (_) => 'users',
        ),
      );

      await executor.runSelect('SELECT * FROM users', const []);

      expect(
        logHandler.records.single.fields['db.query.summary'],
        'SELECT users',
      );
    });

    test('runInsert on sqlite logs loq.db.last_insert_rowid', () async {
      final executor = _FakeExecutor(insertRowId: 42)
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runInsert('INSERT INTO users (name) VALUES (?)', ['x']);

      final r = logHandler.records.single;
      expect(r.fields['db.operation.name'], 'INSERT');
      expect(r.fields['loq.db.last_insert_rowid'], 42);
      // Affected-rows naming is reserved for the non-row-id semantics.
      expect(r.fields.containsKey('loq.db.affected_rows'), isFalse);
    });

    test('runInsert on non-sqlite logs loq.db.affected_rows', () async {
      final executor = _FakeExecutor(
        dialect: SqlDialect.postgres,
        insertRowId: 3,
      ).interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runInsert('INSERT INTO users (name) VALUES (?)', ['x']);

      final r = logHandler.records.single;
      expect(r.fields['db.operation.name'], 'INSERT');
      expect(r.fields['loq.db.affected_rows'], 3);
      expect(r.fields.containsKey('loq.db.last_insert_rowid'), isFalse);
    });

    test('runUpdate logs loq.db.affected_rows', () async {
      final executor = _FakeExecutor(updateRows: 7)
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runUpdate('UPDATE users SET name = ?', ['x']);

      final r = logHandler.records.single;
      expect(r.fields['db.operation.name'], 'UPDATE');
      expect(r.fields['loq.db.affected_rows'], 7);
    });

    test('runDelete logs loq.db.affected_rows', () async {
      final executor = _FakeExecutor(deleteRows: 2)
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runDelete('DELETE FROM users', const []);

      final r = logHandler.records.single;
      expect(r.fields['db.operation.name'], 'DELETE');
      expect(r.fields['loq.db.affected_rows'], 2);
    });

    test('runCustom extracts operation name from first SQL keyword', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runCustom('CREATE TABLE foo (id INTEGER PRIMARY KEY)');

      final r = logHandler.records.single;
      expect(r.fields['db.operation.name'], 'CREATE');
    });

    test('runCustom falls back to CUSTOM when SQL has no keyword', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runCustom('   ');

      final r = logHandler.records.single;
      expect(r.fields['db.operation.name'], 'CUSTOM');
    });

    test('uses Level.debug by default for query completion', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.level, loq.Level.debug);
    });

    test('uses Logger("db") when no logger is supplied', () async {
      // Install a global config so the default Logger('db') has somewhere
      // to send records. Restored in addTearDown.
      final captured = TestLogHandler();
      final previous = loq.LogConfig.global;
      loq.LogConfig.configure(handlers: [captured]);
      addTearDown(
        () => loq.LogConfig.configure(
          handlers: previous.handlers,
          processors: previous.processors,
          zoneAccessor: previous.zoneAccessor,
          captureSourceLocation: previous.captureSourceLocation,
        ),
      );

      final executor = _FakeExecutor().interceptWith(LoqDriftInterceptor());
      await executor.runSelect('SELECT 1', const []);

      expect(captured.records, hasLength(1));
      expect(captured.records.single.loggerName, 'db');
    });

    test('queryLevel override applies', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          queryLevel: loq.Level.info,
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.level, loq.Level.info);
    });

    test('custom queryCompleteMessage applies', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          queryCompleteMessage: 'db.query.end',
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.message, 'db.query.end');
    });
  });

  // ---------------------------------------------------------------------------
  // Error path
  // ---------------------------------------------------------------------------

  group('query errors', () {
    test('logs error with error.type and error.message', () async {
      final boom = StateError('connection lost');
      final executor = _FakeExecutor(throwOn: boom)
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await expectLater(
        executor.runSelect('SELECT 1', const []),
        throwsA(same(boom)),
      );

      expect(logHandler.records, hasLength(1));
      final r = logHandler.records.single;
      expect(r.message, 'query failed');
      expect(r.level, loq.Level.error);
      expect(r.fields['error.type'], 'StateError');
      expect(
        r.fields['error.message'],
        contains('connection lost'),
      );
      // loq's Logger.error injects error + stackTrace.
      expect(r.fields['error'], same(boom));
      expect(r.fields['stackTrace'], isA<StackTrace>());
    });

    test('custom queryErrorMessage applies', () async {
      final executor = _FakeExecutor(throwOn: StateError('x')).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          queryErrorMessage: 'db.query.error',
        ),
      );

      await expectLater(
        executor.runSelect('SELECT 1', const []),
        throwsStateError,
      );

      expect(logHandler.records.single.message, 'db.query.error');
    });
  });

  // ---------------------------------------------------------------------------
  // Slow query
  // ---------------------------------------------------------------------------

  group('slow query threshold', () {
    test('adds slow: true and bumps level to warn', () async {
      final executor = _FakeExecutor(
        beforeRun: () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        },
      ).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          slowQueryThreshold: const Duration(milliseconds: 5),
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      final r = logHandler.records.single;
      expect(r.fields['slow'], true);
      expect(r.level, loq.Level.warn);
    });

    test('error-path slow request still adds slow: true', () async {
      final executor = _FakeExecutor(
        throwOn: StateError('boom'),
        beforeRun: () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        },
      ).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          slowQueryThreshold: const Duration(milliseconds: 5),
        ),
      );

      await expectLater(
        executor.runSelect('SELECT 1', const []),
        throwsStateError,
      );

      expect(logHandler.records.single.fields['slow'], true);
    });

    test('does not bump level above error/fatal from levelResolver', () async {
      final executor = _FakeExecutor(
        beforeRun: () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        },
      ).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          slowQueryThreshold: const Duration(milliseconds: 5),
          levelResolver: (event, error) => loq.Level.error,
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.level, loq.Level.error);
    });
  });

  // ---------------------------------------------------------------------------
  // Namespace
  // ---------------------------------------------------------------------------

  group('namespace', () {
    test('emits db.namespace on every success-path event type', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(logger: newLogger(), namespace: 'myapp_prod'),
      );

      await executor.runSelect('SELECT 1', const []);

      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      await executor.runBatched(batch);

      final tx = executor.beginTransaction();
      await tx.send();

      for (final r in logHandler.records) {
        expect(r.fields['db.namespace'], 'myapp_prod', reason: r.message);
      }
      // Sanity: covered query, batch, tx begin, tx commit.
      expect(logHandler.records, hasLength(4));
    });

    test('emits db.namespace on every error-path event type', () async {
      // Query error.
      final qFail = _FakeExecutor(throwOn: StateError('q'));
      final qExec = qFail.interceptWith(
        LoqDriftInterceptor(logger: newLogger(), namespace: 'ns'),
      );
      await expectLater(
        qExec.runSelect('SELECT 1', const []),
        throwsStateError,
      );

      // Batch error.
      final bFail = _FakeExecutor(throwOn: StateError('b'));
      final bExec = bFail.interceptWith(
        LoqDriftInterceptor(logger: newLogger(), namespace: 'ns'),
      );
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      await expectLater(bExec.runBatched(batch), throwsStateError);

      // Transaction commit error.
      final tFake = _FakeExecutor()..txCommitThrows = true;
      final tExec = tFake.interceptWith(
        LoqDriftInterceptor(logger: newLogger(), namespace: 'ns'),
      );
      final tx = tExec.beginTransaction();
      await expectLater(tx.send(), throwsStateError);

      // All three error logs should carry the namespace.
      final errorLogs = logHandler.records
          .where((r) => r.fields['error.type'] != null)
          .toList();
      expect(errorLogs, hasLength(3));
      for (final r in errorLogs) {
        expect(r.fields['db.namespace'], 'ns', reason: r.message);
      }
    });

    test('namespace omitted when null on every event type', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runSelect('SELECT 1', const []);
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      await executor.runBatched(batch);
      final tx = executor.beginTransaction();
      await tx.send();

      for (final r in logHandler.records) {
        expect(
          r.fields.containsKey('db.namespace'),
          isFalse,
          reason: r.message,
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Skip + capture + redaction
  // ---------------------------------------------------------------------------

  group('skip and capture', () {
    test('skipLog predicate suppresses logging but still runs query', () async {
      final fake = _FakeExecutor();
      final executor = fake.interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          skipLog: (stmt) => stmt.startsWith('PRAGMA'),
        ),
      );

      await executor.runCustom('PRAGMA foreign_keys = ON');

      expect(fake.calls, contains('runCustom:PRAGMA foreign_keys = ON'));
      expect(logHandler.records, isEmpty);
    });

    test('captureArgs emits indexed db.query.parameter.<n> when enabled',
        () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(logger: newLogger(), captureArgs: true),
      );

      await executor.runSelect(
        'SELECT * FROM users WHERE id = ? AND tenant = ?',
        [42, 'acme'],
      );

      final r = logHandler.records.single;
      expect(r.fields['db.query.parameter.0'], 42);
      expect(r.fields['db.query.parameter.1'], 'acme');
      // No list-form leftover.
      expect(r.fields.containsKey('db.query.parameters'), isFalse);
    });

    test('captureArgs with zero args emits no parameter fields', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(logger: newLogger(), captureArgs: true),
      );

      await executor.runSelect('SELECT * FROM users', const []);

      final keys = logHandler.records.single.fields.keys;
      expect(keys.any((k) => k.startsWith('db.query.parameter.')), isFalse);
    });

    test('captureArgs off omits all db.query.parameter.* keys', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runSelect('SELECT * FROM users WHERE id = ?', [42]);

      final keys = logHandler.records.single.fields.keys;
      expect(keys.any((k) => k.startsWith('db.query.parameter.')), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Field hooks
  // ---------------------------------------------------------------------------

  group('field hooks', () {
    test('fields hook composes with defaults', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          fields: (event) => {...event.defaults, 'tenant': 'acme'},
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      final r = logHandler.records.single;
      expect(r.fields['tenant'], 'acme');
      expect(r.fields['db.query.text'], 'SELECT 1');
    });

    test('fields hook can fully replace defaults', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          fields: (_) => {'only': 'this'},
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.fields, {'only': 'this'});
    });

    test('fields hook can read args without captureArgs', () async {
      // captureArgs is off, so no db.query.parameter.* keys are in
      // defaults — but the hook can still inspect the raw args via the
      // event and emit a derived field (e.g., the count) instead. Also
      // asserts event.elapsed is the typed Duration form.
      DriftLogEvent? seen;
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          fields: (event) {
            seen = event;
            return switch (event) {
              DriftQueryEvent(:final args) => {
                  ...event.defaults,
                  'loq.db.query.parameter.count': args.length,
                },
              _ => event.defaults,
            };
          },
        ),
      );

      await executor.runSelect('SELECT * FROM users WHERE id = ?', [42]);

      final r = logHandler.records.single;
      expect(r.fields['loq.db.query.parameter.count'], 1);
      expect(
        r.fields.keys.any((k) => k.startsWith('db.query.parameter.')),
        isFalse,
      );
      expect(seen, isA<DriftQueryEvent>());
      expect((seen! as DriftQueryEvent).elapsed, isA<Duration>());
    });

    test('fields hook receives DriftBatchEvent for batches', () async {
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
          ArgumentsForBatchedStatement(0, [2]),
        ],
      );
      DriftLogEvent? seen;
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          fields: (event) {
            seen = event;
            return event.defaults;
          },
        ),
      );

      await executor.runBatched(batch);

      expect(seen, isA<DriftBatchEvent>());
      expect((seen! as DriftBatchEvent).statements.arguments, hasLength(2));
      expect((seen! as DriftBatchEvent).elapsed, isA<Duration>());
    });

    test('fields hook receives DriftTransactionEvent for tx lifecycle',
        () async {
      final seen = <DriftLogEvent>[];
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          fields: (event) {
            seen.add(event);
            return event.defaults;
          },
        ),
      );
      final tx = executor.beginTransaction();
      await tx.send();

      expect(seen, hasLength(2));
      expect(seen[0], isA<DriftTransactionEvent>());
      expect((seen[0] as DriftTransactionEvent).operation, 'BEGIN');
      // BEGIN has no measurable elapsed.
      expect((seen[0] as DriftTransactionEvent).elapsed, isNull);
      expect((seen[1] as DriftTransactionEvent).operation, 'COMMIT');
      expect((seen[1] as DriftTransactionEvent).elapsed, isNotNull);
    });

    test('errorFields hook applies on the error path', () async {
      final fake = _FakeExecutor(throwOn: ArgumentError('bad'));
      final executor = fake.interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          errorFields: (event, error, stack) => {
            ...event.defaults,
            'retryable': error is StateError,
          },
        ),
      );

      await expectLater(
        executor.runUpdate('UPDATE x SET y=?', [1]),
        throwsArgumentError,
      );

      final r = logHandler.records.single;
      expect(r.fields['retryable'], false);
      expect(r.fields['error.type'], 'ArgumentError');
    });
  });

  // ---------------------------------------------------------------------------
  // Resolvers
  // ---------------------------------------------------------------------------

  group('resolvers', () {
    test('tableResolver populates db.collection.name', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          tableResolver: (stmt) => 'users',
        ),
      );

      await executor.runSelect('SELECT * FROM users', const []);

      expect(logHandler.records.single.fields['db.collection.name'], 'users');
    });

    test('tableResolver returning null omits db.collection.name', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          tableResolver: (stmt) => null,
        ),
      );

      await executor.runSelect('SELECT * FROM users', const []);

      expect(
        logHandler.records.single.fields.containsKey('db.collection.name'),
        isFalse,
      );
    });

    test('dbSystemResolver maps postgres to postgresql by default', () async {
      final executor =
          _FakeExecutor(dialect: SqlDialect.postgres).interceptWith(
        LoqDriftInterceptor(logger: newLogger()),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.fields['db.system.name'], 'postgresql');
    });

    test('dbSystemResolver maps mariadb to mariadb by default', () async {
      final executor = _FakeExecutor(dialect: SqlDialect.mariadb).interceptWith(
        LoqDriftInterceptor(logger: newLogger()),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.fields['db.system.name'], 'mariadb');
    });

    test('dbSystemResolver falls back to other_sql for unknown dialects',
        () async {
      // OTel spec: `other_sql` is the Stable catch-all for SQL systems
      // without a registered canonical value.
      final executor = _FakeExecutor(dialect: SqlDialect.duckdb).interceptWith(
        LoqDriftInterceptor(logger: newLogger()),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(
        logHandler.records.single.fields['db.system.name'],
        'other_sql',
      );
    });

    test('custom dbSystemResolver overrides the default', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          dbSystemResolver: (_) => 'custom',
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.fields['db.system.name'], 'custom');
    });

    test('custom dbSystemResolver returning null falls back to default',
        () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          dbSystemResolver: (_) => null,
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.fields['db.system.name'], 'sqlite');
    });

    test('levelResolver overrides default level on success', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          levelResolver: (event, error) {
            if (event is DriftQueryEvent && event.operation == 'SELECT') {
              return loq.Level.info;
            }
            return null;
          },
        ),
      );

      await executor.runSelect('SELECT 1', const []);

      expect(logHandler.records.single.level, loq.Level.info);
    });

    test('levelResolver overrides default level on error', () async {
      final executor = _FakeExecutor(throwOn: StateError('x')).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          levelResolver: (event, error) =>
              error != null ? loq.Level.fatal : null,
        ),
      );

      await expectLater(
        executor.runSelect('SELECT 1', const []),
        throwsStateError,
      );

      expect(logHandler.records.single.level, loq.Level.fatal);
    });
  });

  // ---------------------------------------------------------------------------
  // Batches
  // ---------------------------------------------------------------------------

  group('batches', () {
    test('runBatched logs operation=BATCH, batch.size, joined statements',
        () async {
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)', 'UPDATE b SET x=?'],
        [
          ArgumentsForBatchedStatement(0, [1]),
          ArgumentsForBatchedStatement(0, [2]),
          ArgumentsForBatchedStatement(1, [3]),
        ],
      );
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runBatched(batch);

      final r = logHandler.records.single;
      expect(r.message, 'batch completed');
      expect(r.fields['db.operation.name'], 'BATCH');
      expect(r.fields['db.operation.batch.size'], 3);
      expect(
        r.fields['db.query.text'],
        'INSERT INTO a VALUES (?); UPDATE b SET x=?',
      );
      // Mixed-op batch falls back to plain 'BATCH'.
      expect(r.fields['db.query.summary'], 'BATCH');
    });

    test('runBatched with shared op derives BATCH <OP> summary', () async {
      final batch = BatchedStatements(
        ['INSERT INTO users VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
          ArgumentsForBatchedStatement(0, [2]),
        ],
      );
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runBatched(batch);

      expect(
        logHandler.records.single.fields['db.query.summary'],
        'BATCH INSERT',
      );
    });

    test('runBatched with shared op + tableResolver derives full summary',
        () async {
      final batch = BatchedStatements(
        ['INSERT INTO users VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          tableResolver: (_) => 'users',
        ),
      );

      await executor.runBatched(batch);

      expect(
        logHandler.records.single.fields['db.query.summary'],
        'BATCH INSERT users',
      );
    });

    test('runBatched of size 1 omits db.operation.batch.size', () async {
      final batch = BatchedStatements(
        ['INSERT INTO users VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runBatched(batch);

      final r = logHandler.records.single;
      expect(r.fields.containsKey('db.operation.batch.size'), isFalse);
    });

    test('runBatched with empty statements falls back to BATCH', () async {
      final batch = BatchedStatements(const [], const []);
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.runBatched(batch);

      expect(logHandler.records.single.fields['db.query.summary'], 'BATCH');
    });

    test('runBatched error logs at error level with error.type', () async {
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
          ArgumentsForBatchedStatement(0, [2]),
        ],
      );
      final executor = _FakeExecutor(throwOn: StateError('boom')).interceptWith(
        LoqDriftInterceptor(logger: newLogger()),
      );

      await expectLater(executor.runBatched(batch), throwsStateError);

      final r = logHandler.records.single;
      expect(r.message, 'batch failed');
      expect(r.level, loq.Level.error);
      expect(r.fields['error.type'], 'StateError');
      // batch.size is preserved on the error path when > 1.
      expect(r.fields['db.operation.batch.size'], 2);
    });

    test('errorFields hook applies on batch error path', () async {
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      final executor = _FakeExecutor(throwOn: StateError('boom')).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          errorFields: (event, error, stack) =>
              {...event.defaults, 'retryable': true},
        ),
      );

      await expectLater(executor.runBatched(batch), throwsStateError);

      expect(logHandler.records.single.fields['retryable'], true);
    });

    test('batch slow request bumps level to warn', () async {
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      final executor = _FakeExecutor(
        beforeRun: () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        },
      ).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          slowQueryThreshold: const Duration(milliseconds: 5),
        ),
      );

      await executor.runBatched(batch);

      final r = logHandler.records.single;
      expect(r.fields['slow'], true);
      expect(r.level, loq.Level.warn);
    });

    test('error-path slow batch still adds slow: true', () async {
      // Matches the symmetric behavior on the query error path.
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );
      final executor = _FakeExecutor(
        throwOn: StateError('boom'),
        beforeRun: () async {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        },
      ).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          slowQueryThreshold: const Duration(milliseconds: 5),
        ),
      );

      await expectLater(executor.runBatched(batch), throwsStateError);

      expect(logHandler.records.single.fields['slow'], true);
    });

    test('custom batch messages apply', () async {
      final batch = BatchedStatements(
        ['INSERT INTO a VALUES (?)'],
        [
          ArgumentsForBatchedStatement(0, [1]),
        ],
      );

      // Success path.
      final ok = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          batchCompleteMessage: 'db.batch.end',
        ),
      );
      await ok.runBatched(batch);
      expect(logHandler.records.single.message, 'db.batch.end');
      logHandler.records.clear();

      // Error path.
      final fail = _FakeExecutor(throwOn: StateError('boom')).interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          batchErrorMessage: 'db.batch.error',
        ),
      );
      await expectLater(fail.runBatched(batch), throwsStateError);
      expect(logHandler.records.single.message, 'db.batch.error');
    });
  });

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------

  group('transactions', () {
    test('beginTransaction logs at trace by default', () async {
      _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()))
          .beginTransaction();

      expect(logHandler.records, hasLength(1));
      final r = logHandler.records.single;
      expect(r.message, 'transaction begin');
      expect(r.level, loq.Level.trace);
      expect(r.fields['db.operation.name'], 'BEGIN');
      // Transaction events don't carry a db.query.summary — they're
      // lifecycle events, not queries.
      expect(r.fields.containsKey('db.query.summary'), isFalse);
    });

    test('beginExclusive logs BEGIN EXCLUSIVE', () async {
      _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()))
          .beginExclusive();

      final r = logHandler.records.single;
      expect(r.message, 'transaction begin');
      expect(r.fields['db.operation.name'], 'BEGIN EXCLUSIVE');
    });

    test('commit logs success with duration_ms', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));
      final tx = executor.beginTransaction();

      await tx.send();

      final commit = logHandler.records.last;
      expect(commit.message, 'transaction commit');
      expect(commit.fields['db.operation.name'], 'COMMIT');
      expect(commit.fields['duration_ms'], isA<int>());
    });

    test('rollback logs success with duration_ms', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));
      final tx = executor.beginTransaction();

      await tx.rollback();

      final rb = logHandler.records.last;
      expect(rb.message, 'transaction rollback');
      expect(rb.fields['db.operation.name'], 'ROLLBACK');
    });

    test('commit error logs at error with error.type', () async {
      final fake = _FakeExecutor()..txCommitThrows = true;
      final executor =
          fake.interceptWith(LoqDriftInterceptor(logger: newLogger()));
      final tx = executor.beginTransaction();

      await expectLater(tx.send(), throwsStateError);

      final r = logHandler.records.last;
      expect(r.message, 'transaction failed');
      expect(r.level, loq.Level.error);
      expect(r.fields['error.type'], 'StateError');
      expect(r.fields['db.operation.name'], 'COMMIT');
    });

    test('rollback error logs at error with error.type', () async {
      final fake = _FakeExecutor()..txRollbackThrows = true;
      final executor =
          fake.interceptWith(LoqDriftInterceptor(logger: newLogger()));
      final tx = executor.beginTransaction();

      await expectLater(tx.rollback(), throwsStateError);

      final r = logHandler.records.last;
      expect(r.message, 'transaction failed');
      expect(r.fields['db.operation.name'], 'ROLLBACK');
    });

    test('errorFields hook applies on transaction error path', () async {
      final fake = _FakeExecutor()..txCommitThrows = true;
      final executor = fake.interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          errorFields: (event, error, stack) =>
              {...event.defaults, 'tx_phase': 'commit'},
        ),
      );
      final tx = executor.beginTransaction();

      await expectLater(tx.send(), throwsStateError);

      expect(logHandler.records.last.fields['tx_phase'], 'commit');
    });

    test('transactionLevel override applies', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          transactionLevel: loq.Level.info,
        ),
      );

      final tx = executor.beginTransaction();
      await tx.send();

      expect(logHandler.records.first.level, loq.Level.info);
      expect(logHandler.records.last.level, loq.Level.info);
    });

    test('custom transaction messages apply', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          transactionBeginMessage: 'tx.begin',
          transactionCommitMessage: 'tx.commit',
          transactionRollbackMessage: 'tx.rollback',
        ),
      );

      final tx = executor.beginTransaction();
      await tx.send();
      final tx2 = executor.beginTransaction();
      await tx2.rollback();

      final messages = logHandler.records.map((r) => r.message).toList();
      expect(messages, ['tx.begin', 'tx.commit', 'tx.begin', 'tx.rollback']);
    });

    test('custom transactionErrorMessage applies', () async {
      final fake = _FakeExecutor()..txCommitThrows = true;
      final executor = fake.interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          transactionErrorMessage: 'db.tx.error',
        ),
      );
      final tx = executor.beginTransaction();

      await expectLater(tx.send(), throwsStateError);

      expect(logHandler.records.last.message, 'db.tx.error');
    });
  });

  // ---------------------------------------------------------------------------
  // Database lifecycle (open / close)
  // ---------------------------------------------------------------------------

  group('lifecycle', () {
    test('first ensureOpen emits database opened at trace', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      final result = await executor.ensureOpen(TestSchemaUser());

      expect(result, isTrue);
      expect(logHandler.records, hasLength(1));
      final r = logHandler.records.single;
      expect(r.message, 'database opened');
      expect(r.level, loq.Level.trace);
      expect(r.fields['db.operation.name'], 'OPEN');
      expect(r.fields['duration_ms'], isA<int>());
    });

    test('subsequent ensureOpen calls are silent', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.ensureOpen(TestSchemaUser());
      await executor.ensureOpen(TestSchemaUser());
      await executor.ensureOpen(TestSchemaUser());

      // Only the first open emits a record; the rest pass through.
      expect(logHandler.records, hasLength(1));
    });

    test('ensureOpen error emits lifecycle error log', () async {
      final fake = _FakeExecutor()..openThrows = true;
      final executor =
          fake.interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await expectLater(
        executor.ensureOpen(TestSchemaUser()),
        throwsStateError,
      );

      final r = logHandler.records.single;
      expect(r.message, 'database lifecycle failed');
      expect(r.level, loq.Level.error);
      expect(r.fields['db.operation.name'], 'OPEN');
      expect(r.fields['error.type'], 'StateError');
    });

    test('ensureOpen retried after error still emits success', () async {
      // After a failed open, _isOpen should remain false so the next
      // (successful) open still fires.
      final fake = _FakeExecutor()..openThrows = true;
      final executor =
          fake.interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await expectLater(
        executor.ensureOpen(TestSchemaUser()),
        throwsStateError,
      );
      fake.openThrows = false;
      await executor.ensureOpen(TestSchemaUser());

      expect(logHandler.records, hasLength(2));
      expect(logHandler.records.last.message, 'database opened');
    });

    test('close emits database closed at trace', () async {
      final executor = _FakeExecutor()
          .interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await executor.close();

      final r = logHandler.records.single;
      expect(r.message, 'database closed');
      expect(r.level, loq.Level.trace);
      expect(r.fields['db.operation.name'], 'CLOSE');
    });

    test('close error emits lifecycle error log', () async {
      final fake = _FakeExecutor()..closeThrows = true;
      final executor =
          fake.interceptWith(LoqDriftInterceptor(logger: newLogger()));

      await expectLater(executor.close(), throwsStateError);

      final r = logHandler.records.single;
      expect(r.message, 'database lifecycle failed');
      expect(r.fields['db.operation.name'], 'CLOSE');
    });

    test('custom lifecycle messages apply', () async {
      final fake = _FakeExecutor()..closeThrows = true;
      final executor = fake.interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          databaseOpenMessage: 'db.open',
          databaseCloseMessage: 'db.close',
          databaseLifecycleErrorMessage: 'db.lifecycle.error',
        ),
      );

      await executor.ensureOpen(TestSchemaUser());
      await expectLater(executor.close(), throwsStateError);

      final messages = logHandler.records.map((r) => r.message).toList();
      expect(messages, ['db.open', 'db.lifecycle.error']);
    });

    test('lifecycleLevel override applies', () async {
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          lifecycleLevel: loq.Level.info,
        ),
      );

      await executor.ensureOpen(TestSchemaUser());
      await executor.close();

      expect(logHandler.records.first.level, loq.Level.info);
      expect(logHandler.records.last.level, loq.Level.info);
    });

    test('errorFields hook applies on lifecycle error path', () async {
      final fake = _FakeExecutor()..openThrows = true;
      final executor = fake.interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          errorFields: (event, error, stack) =>
              {...event.defaults, 'lifecycle.phase': 'open'},
        ),
      );

      await expectLater(
        executor.ensureOpen(TestSchemaUser()),
        throwsStateError,
      );

      expect(logHandler.records.single.fields['lifecycle.phase'], 'open');
    });

    test('fields hook receives DriftLifecycleEvent', () async {
      DriftLogEvent? seen;
      final executor = _FakeExecutor().interceptWith(
        LoqDriftInterceptor(
          logger: newLogger(),
          fields: (event) {
            seen = event;
            return event.defaults;
          },
        ),
      );

      await executor.ensureOpen(TestSchemaUser());

      expect(seen, isA<DriftLifecycleEvent>());
      expect((seen! as DriftLifecycleEvent).operation, 'OPEN');
      expect((seen! as DriftLifecycleEvent).elapsed, isA<Duration>());
    });
  });

  // ---------------------------------------------------------------------------
  // extractOperationName helper
  // ---------------------------------------------------------------------------

  group('extractOperationName', () {
    test('extracts uppercase first keyword', () {
      expect(extractOperationName('select 1'), 'SELECT');
      expect(extractOperationName('  CREATE TABLE x'), 'CREATE');
      expect(extractOperationName('PRAGMA foo'), 'PRAGMA');
    });

    test('skips leading -- line comments', () {
      expect(
        extractOperationName('-- comment\nSELECT 1'),
        'SELECT',
      );
    });

    test('returns null for empty or whitespace-only statements', () {
      expect(extractOperationName(''), isNull);
      expect(extractOperationName('   '), isNull);
    });

    test('returns null for unterminated comment with no following SQL', () {
      expect(extractOperationName('-- forever'), isNull);
    });

    test('returns null for statement starting with non-alpha', () {
      expect(extractOperationName('123 not sql'), isNull);
    });
  });
}
