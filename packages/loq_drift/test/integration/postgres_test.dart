// Postgres smoke tests. Verifies that `LoqDriftInterceptor` behaves
// correctly against drift's real postgres adapter, i.e. that drift
// dispatches through `QueryInterceptor` the way our sqlite-derived
// expectations assume.
//
// Tagged `@Tags(['postgres'])` so the default `dart test` run skips
// them (see `dart_test.yaml`). Run locally with a postgres available:
//
//   docker run --rm -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:16
//   dart test --tags postgres
//
// In CI, a `postgres` service container provides the database; the
// `Test (loq_drift)` job runs `dart test --tags postgres` as a
// separate step.
//
// Connection params honor env vars (`POSTGRES_HOST`, `POSTGRES_PORT`,
// `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) with sensible
// defaults for the docker-compose command above.
@Tags(['postgres'])
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_postgres/drift_postgres.dart';
import 'package:loq/loq.dart' as loq;
import 'package:loq_drift/loq_drift.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import '../test_helpers.dart';

Endpoint _endpoint() => Endpoint(
      host: Platform.environment['POSTGRES_HOST'] ?? 'localhost',
      port: int.parse(Platform.environment['POSTGRES_PORT'] ?? '5432'),
      database: Platform.environment['POSTGRES_DB'] ?? 'postgres',
      username: Platform.environment['POSTGRES_USER'] ?? 'postgres',
      password: Platform.environment['POSTGRES_PASSWORD'] ?? 'postgres',
    );

void main() {
  late TestLogHandler handler;
  late loq.LogConfig config;
  late QueryExecutor executor;

  setUp(() async {
    handler = TestLogHandler();
    config = loq.LogConfig(handlers: [handler]);
    final logger = loq.Logger('db', config: config);
    // PgDatabase extends DelegatedDatabase which IS a QueryExecutor,
    // so we wrap it with the interceptor the same way we'd wrap
    // NativeDatabase.
    executor = PgDatabase(
      endpoint: _endpoint(),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    ).interceptWith(LoqDriftInterceptor(logger: logger));
    await executor.ensureOpen(TestSchemaUser());
    // Each test gets a fresh table to avoid cross-test pollution.
    await executor.runCustom(
      'CREATE TEMP TABLE loq_users '
      '(id SERIAL PRIMARY KEY, name TEXT, email TEXT)',
    );
    // Drop the lifecycle "opened" + CREATE records.
    handler.records.clear();
  });

  tearDown(() async {
    await executor.close();
  });

  test('postgres dialect resolves to db.system.name=postgresql', () async {
    await executor.runSelect('SELECT 1', const []);

    final r = handler.records.firstWhere(
      (r) => r.fields['db.operation.name'] == 'SELECT',
    );
    expect(r.fields['db.system.name'], 'postgresql');
  });

  test('INSERT on postgres uses loq.db.affected_rows (not row id)', () async {
    final affected = await executor.runInsert(
      r'INSERT INTO loq_users (name, email) VALUES ($1, $2)',
      ['Tibor', 'tibor@example.com'],
    );

    expect(affected, greaterThanOrEqualTo(0));
    final r = handler.records.firstWhere(
      (r) => r.fields['db.operation.name'] == 'INSERT',
    );
    // sqlite emits loq.db.last_insert_rowid; postgres should not.
    expect(r.fields.containsKey('loq.db.last_insert_rowid'), isFalse);
    expect(r.fields['loq.db.affected_rows'], affected);
  });

  test('SELECT through real postgres reports returned_rows', () async {
    await executor.runInsert(
      r'INSERT INTO loq_users (name, email) VALUES ($1, $2)',
      ['Ada', 'a@b.c'],
    );
    await executor.runInsert(
      r'INSERT INTO loq_users (name, email) VALUES ($1, $2)',
      ['Grace', 'g@b.c'],
    );
    handler.records.clear();

    final rows = await executor.runSelect(
      'SELECT * FROM loq_users',
      const [],
    );

    expect(rows, hasLength(2));
    expect(
      handler.records.single.fields['db.response.returned_rows'],
      2,
    );
  });

  test('failing SELECT surfaces a real postgres exception', () async {
    handler.records.clear();

    await expectLater(
      executor.runSelect(
        'SELECT * FROM definitely_not_a_real_table',
        const [],
      ),
      throwsA(isA<Exception>()),
    );

    final err = handler.records.single;
    expect(err.message, 'query failed');
    expect(err.level, loq.Level.error);
    // We claim error.type = error.runtimeType.toString(). Just verify
    // it's a non-empty string from the postgres exception family.
    final errorType = err.fields['error.type']! as String;
    expect(errorType, isNotEmpty);
    expect(
      errorType.toLowerCase(),
      anyOf(contains('postgres'), contains('pg'), contains('server')),
    );
  });
}
