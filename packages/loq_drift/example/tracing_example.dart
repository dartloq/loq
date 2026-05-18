// Tracing example: chain a `TracingInterceptor` with `LoqDriftInterceptor`
// so each DB operation produces both a structured log record (via loq)
// and a tracing span (via your tracer of choice), correlated by
// `trace.id` / `span.id` carried through the loq zone context.
//
// In a real app the `Tracer` would be e.g. `dartastic_opentelemetry`'s
// `Tracer`. Here we use a tiny console-printing stub so the example
// runs without extra dependencies.
//
// Run with: `dart run example/tracing_example.dart`

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:loq/loq.dart';
import 'package:loq_drift/loq_drift.dart';

// --- A tiny stand-in for an OTel-style Tracer ----------------------------

/// Stub span. Real OTel spans carry trace state, attributes, and ship
/// to a collector. This one just prints to stdout so the lifecycle
/// shows up in the example output.
class ExampleSpan {
  ExampleSpan(this.name, this.traceId, this.spanId) {
    // Stub tracer prints to stdout to make span lifecycle visible.
    // ignore: avoid_print
    print('  → span start  name=$name traceId=$traceId spanId=$spanId');
  }
  final String name;
  final String traceId;
  final String spanId;
  final _attrs = <String, Object?>{};

  void setAttribute(String key, Object? value) {
    _attrs[key] = value;
  }

  void recordException(Object error) {
    _attrs['exception.type'] = error.runtimeType.toString();
    _attrs['exception.message'] = error.toString();
  }

  void end() {
    // Stub tracer prints to stdout.
    // ignore: avoid_print
    print('  ← span end    name=$name attrs=$_attrs');
  }
}

class ExampleTracer {
  var _counter = 0;
  String _hex() {
    final n = _counter++;
    return n.toRadixString(16).padLeft(8, '0');
  }

  ExampleSpan startSpan(String name) => ExampleSpan(name, _hex(), _hex());
}

// --- The TracingInterceptor ----------------------------------------------

/// Wraps every Drift operation with an OTel-style span. Binds the span's
/// `trace.id` and `span.id` into the loq zone context so any log record
/// emitted inside (including by [LoqDriftInterceptor]) inherits them.
///
/// Chain order matters: this interceptor must be applied **after**
/// `LoqDriftInterceptor` so it sits on the outside and its zone
/// context is active when the inner logger emits.
class TracingInterceptor extends QueryInterceptor {
  TracingInterceptor(this._tracer);
  final ExampleTracer _tracer;

  Future<T> _withSpan<T>(
    String name,
    String? statement,
    Future<T> Function() body,
  ) {
    final span = _tracer.startSpan(name);
    if (statement != null) span.setAttribute('db.query.text', statement);
    return withLogContext({
      'trace.id': span.traceId,
      'span.id': span.spanId,
    }, () async {
      try {
        return await body();
      } catch (e) {
        span.recordException(e);
        rethrow;
      } finally {
        span.end();
      }
    });
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _withSpan(
        'db.select',
        statement,
        () => super.runSelect(executor, statement, args),
      );

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _withSpan(
        'db.insert',
        statement,
        () => super.runInsert(executor, statement, args),
      );

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _withSpan(
        'db.update',
        statement,
        () => super.runUpdate(executor, statement, args),
      );

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _withSpan(
        'db.delete',
        statement,
        () => super.runDelete(executor, statement, args),
      );

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) =>
      _withSpan(
        'db.custom',
        statement,
        () => super.runCustom(executor, statement, args),
      );

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) =>
      _withSpan(
        'db.batch',
        statements.statements.join('; '),
        () => super.runBatched(executor, statements),
      );

  @override
  Future<void> commitTransaction(TransactionExecutor inner) => _withSpan(
        'db.tx.commit',
        null,
        () => super.commitTransaction(inner),
      );

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) => _withSpan(
        'db.tx.rollback',
        null,
        () => super.rollbackTransaction(inner),
      );

  // beginTransaction is sync, so there's no async work to wrap. A real
  // OTel adapter might still write a zero-duration "tx.begin" span;
  // here we let the default pass-through handle it.
}

class _NoSchema extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

// --- Main ----------------------------------------------------------------

Future<void> main() async {
  // zoneAccessor is required for the trace.id / span.id bound by
  // TracingInterceptor's withLogContext to land in log records.
  LogConfig.configure(
    handlers: [ConsoleHandler(minLevel: Level.trace)],
    zoneAccessor: defaultZoneAccessor,
  );

  final tracer = ExampleTracer();

  // Chain order: LoqDriftInterceptor INNER, TracingInterceptor OUTER.
  // The outer interceptor sees each call first and binds trace context
  // before delegating to the inner one. The inner one emits log records
  // which inherit the bound trace.id / span.id from the zone.
  final executor = NativeDatabase.memory()
      .interceptWith(LoqDriftInterceptor())
      .interceptWith(TracingInterceptor(tracer));

  await executor.ensureOpen(_NoSchema());

  await executor.runCustom(
    'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
  );

  await executor.runInsert(
    'INSERT INTO users (name) VALUES (?)',
    ['Tibor'],
  );

  await executor.runSelect('SELECT * FROM users', const []);

  final tx = executor.beginTransaction();
  await tx.ensureOpen(_NoSchema());
  await tx.runUpdate(
    'UPDATE users SET name = ? WHERE id = 1',
    ['Tibor M.'],
  );
  await tx.send();

  await executor.close();
}
