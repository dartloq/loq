# loq_drift

Structured query logging interceptor for [Drift](https://pub.dev/packages/drift), powered by [loq](https://pub.dev/packages/loq).

Wraps any Drift `QueryExecutor` and writes a structured log record for each SQL query, batch, transaction step, and database open/close. Fields follow the [OpenTelemetry database semantic conventions](https://opentelemetry.io/docs/specs/semconv/database/).

## Quick start

```dart
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:loq_drift/loq_drift.dart';

final database = AppDatabase(
  NativeDatabase.memory().interceptWith(LoqDriftInterceptor()),
);
```

Sample output (ConsoleHandler):

```
12:34:56.788 [TRACE] db: database opened | db.system.name=sqlite, db.operation.name=OPEN, duration_ms=0
12:34:56.789 [DEBUG] db: query completed | db.system.name=sqlite, db.operation.name=INSERT, db.query.summary=INSERT, db.query.text=INSERT INTO users (name, email) VALUES (?, ?), duration_ms=1, loq.db.last_insert_rowid=1
12:34:56.790 [DEBUG] db: batch completed | db.system.name=sqlite, db.operation.name=BATCH, db.query.summary=BATCH INSERT, db.query.text=INSERT INTO users (name, email) VALUES (?, ?), db.operation.batch.size=2, duration_ms=0
12:34:56.791 [DEBUG] db: query completed | db.system.name=sqlite, db.operation.name=SELECT, db.query.summary=SELECT, db.query.text=SELECT * FROM users, duration_ms=1, db.response.returned_rows=3
12:34:56.792 [TRACE] db: transaction begin | db.system.name=sqlite, db.operation.name=BEGIN
12:34:56.793 [TRACE] db: transaction commit | db.system.name=sqlite, db.operation.name=COMMIT, duration_ms=0
12:34:56.794 [ERROR] db: query failed | db.system.name=sqlite, db.operation.name=SELECT, db.query.summary=SELECT, db.query.text=SELECT * FROM does_not_exist, duration_ms=1, error.type=SqliteException, error.message=no such table: does_not_exist
12:34:56.795 [TRACE] db: database closed | db.system.name=sqlite, db.operation.name=CLOSE, duration_ms=0
```

## Zone context (manual)

Unlike `loq_shelf`'s middleware, `loq_drift` doesn't bind anything to the zone for you. Drift runs the transaction body and queries from above the interceptor's call frame, so there's no callback we can wrap with `withLogContext`. It's a shape limit of `QueryInterceptor`, not a missing feature.

To tag a transaction (or any block) so logs inside pick up a shared field, wrap the body yourself with `withLogContext`:

```dart
import 'package:loq/loq.dart';
import 'package:nanoid/nanoid.dart' as nanoid;

final txId = nanoid.nanoid();
await database.transaction(() => withLogContext({'tx.id': txId}, () async {
  await db.users.insertOne(...);
  log.info('did the thing');  // record carries tx.id
}));
```

The same pattern wraps a single statement, a batch, or any user code. `withLogContext` is the building block. Pick whatever ID style fits the rest of your tracing (UUID, nanoid, snowflake, an OTel span ID, etc.).

> **Important:** zone fields only land in records when `LogConfig.zoneAccessor` is set:
>
> ```dart
> LogConfig.configure(
>   handlers: [...],
>   zoneAccessor: defaultZoneAccessor,  // reads withLogContext bindings
> );
> ```
>
> Without `zoneAccessor`, `withLogContext` does nothing for log records.

## Tracing (OTel spans alongside logs)

`loq_drift` doesn't pick a tracer for you. Drift's `QueryInterceptor` API allows **chained** interceptors, so the suggested shape is to wrap a small tracing interceptor outside `LoqDriftInterceptor`. The two signals stay separate but tied together through `withLogContext`.

```dart
final executor = NativeDatabase.memory()
    .interceptWith(LoqDriftInterceptor())        // inner: emits logs
    .interceptWith(TracingInterceptor(tracer));  // outer: binds trace context
```

**Chain order matters.** The outer interceptor sees each call first. By the time the inner `LoqDriftInterceptor` writes its log record, the outer's `withLogContext` zone is active, so `trace.id` / `span.id` land in the record on their own:

```text
23:14:45 [DEBUG] db: query completed | trace.id=00000000, span.id=00000001, db.system.name=sqlite, db.operation.name=INSERT, …
```

### A complete `TracingInterceptor`

```dart
import 'package:drift/drift.dart';
import 'package:loq/loq.dart';

class TracingInterceptor extends QueryInterceptor {
  TracingInterceptor(this.tracer);
  final Tracer tracer;  // your tracer of choice; e.g. dartastic_opentelemetry

  Future<T> _withSpan<T>(
    String name,
    String? statement,
    Future<T> Function() body,
  ) {
    final span = tracer.startSpan(name);
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
  Future<List<Map<String, Object?>>> runSelect(executor, statement, args) =>
      _withSpan('db.select', statement,
          () => super.runSelect(executor, statement, args));

  @override
  Future<int> runInsert(executor, statement, args) =>
      _withSpan('db.insert', statement,
          () => super.runInsert(executor, statement, args));

  // ... same shape for runUpdate / runDelete / runCustom / runBatched
  // ... and commitTransaction / rollbackTransaction (statement = null)

  // beginTransaction / beginExclusive are synchronous in Drift's
  // interceptor; they have no async work to wrap. A real OTel adapter
  // can still emit a zero-duration "tx.begin" span here if you want.
}
```

A runnable end-to-end example with a stub tracer is in [`example/tracing_example.dart`](example/tracing_example.dart). It uses real in-memory SQLite and prints span lifecycle alongside the log records.

### Where each signal lands

| | Logs (via `LoqDriftInterceptor`) | Spans (via `TracingInterceptor`) |
|---|---|---|
| Carries | OTel-aligned structured fields plus `trace.id` / `span.id`¹ | OTel span attributes plus lifecycle (start, end, exception) |
| Sink | loq `Handler`s: console, JSON, etc. | your tracer's exporter (OTLP, Jaeger, Zipkin, ...) |
| Pivot direction | "this slow query log → the trace" via the IDs | "this span → the underlying query" via attributes |

¹ `trace.id` / `span.id` only land in records when `LogConfig.zoneAccessor` is set (see [Zone context (manual)](#zone-context-manual)). Without it, the `withLogContext` bindings from `TracingInterceptor` get dropped at log time. Spans still emit fine, but the link to logs is gone.

Two signals, one operation. The interceptors stack because `QueryInterceptor` was built for chaining. `loq_drift` doesn't need to know anything about tracing, and your tracing layer doesn't need to know anything about logging.

## Events and fields

Each log event is one of four sealed types:

- **`DriftQueryEvent`** for `runSelect`/`runInsert`/`runUpdate`/`runDelete`/`runCustom`. Carries `statement`, `args`, `operation`, `elapsed`, and the `defaults` field map.
- **`DriftBatchEvent`** for `runBatched`. Carries `statements` (the Drift `BatchedStatements`), `elapsed`, `defaults`.
- **`DriftTransactionEvent`** for `BEGIN` / `BEGIN EXCLUSIVE` / `COMMIT` / `ROLLBACK`. Carries `operation`, `elapsed` (null on `BEGIN`/`BEGIN EXCLUSIVE`), `defaults`.
- **`DriftLifecycleEvent`** for the first successful `ensureOpen` (`OPEN`) and every `close` (`CLOSE`). Carries `operation`, `elapsed`, `defaults`.

The `fields:` hook receives one of these and returns the final field map. Spread `...event.defaults` to keep the defaults; return a different map to replace. Branch on event type with `switch`:

```dart
fields: (event) => switch (event) {
  DriftQueryEvent(:final operation) =>
      {...event.defaults, 'kind': operation.toLowerCase()},
  DriftBatchEvent() =>
      {...event.defaults, 'kind': 'batch'},
  DriftTransactionEvent() =>
      {...event.defaults, 'kind': 'tx'},
  DriftLifecycleEvent() =>
      {...event.defaults, 'kind': 'lifecycle'},
},
```

The `errorFields:` hook has the same shape plus the caught error and stack trace. The `defaults` map below is what each event carries with no user transformation.

### Query log defaults

For `runSelect`, `runInsert`, `runUpdate`, `runDelete`, `runCustom`:

| Field | Source |
|-------|--------|
| `db.system.name` | `dbSystemResolver` or [`defaultDbSystemName`](#supported-dialects) |
| `db.namespace` | from `namespace:` constructor parameter, when set |
| `db.operation.name` | from the Drift method (`SELECT`/`INSERT`/`UPDATE`/`DELETE`); for `runCustom`, parsed first SQL keyword (or `CUSTOM` if unparseable) |
| `db.query.summary` | `<OP> <table?>` low-cardinality string for dashboard grouping |
| `db.query.text` | the prepared statement |
| `duration_ms` | elapsed time in milliseconds |
| `db.collection.name` | `tableResolver(statement)`, when set |
| `db.query.parameter.<n>` | one attribute per bound arg (0-based index), when `captureArgs: true`. OTel-spec indexed shape, **Development / Opt-In** status |
| `db.response.returned_rows` | for `runSelect`, `result.length`. OTel-spec, **Development / Opt-In** status. The name is settled but not yet promoted to Stable, so future minor versions of the spec could narrow what it means |
| `loq.db.affected_rows` | for `runUpdate`/`runDelete` (any dialect) and `runInsert` on non-sqlite dialects. Loq extension since OTel doesn't standardize an affected-rows attribute |
| `loq.db.last_insert_rowid` | for `runInsert` on sqlite. sqlite's `runInsert` gives back the auto-increment row id, not an affected count |
| `slow` | `true` when `slowQueryThreshold` is crossed |

### Batch log defaults

For `runBatched`:

| Field | Source |
|-------|--------|
| `db.system.name` | as above |
| `db.namespace` | as above |
| `db.operation.name` | `BATCH` |
| `db.query.summary` | `BATCH <OP> <table?>` when all statements share an operation; plain `BATCH` for mixed or empty batches |
| `db.query.text` | prepared statements joined with `; ` |
| `db.operation.batch.size` | total operations run; left out per OTel spec when the batch holds a single operation |
| `duration_ms` | elapsed time in milliseconds |
| `slow` | `true` when `slowQueryThreshold` is crossed |

### Transaction log defaults

For `beginTransaction`, `beginExclusive`, `commitTransaction`, `rollbackTransaction`:

| Field | Source |
|-------|--------|
| `db.system.name` | as above |
| `db.namespace` | as above |
| `db.operation.name` | `BEGIN` / `BEGIN EXCLUSIVE` / `COMMIT` / `ROLLBACK` |
| `duration_ms` | elapsed time on the underlying `send()`/`rollback()` call (commit / rollback only) |

### Lifecycle log defaults

For the first successful `ensureOpen` and any `close`:

| Field | Source |
|-------|--------|
| `db.system.name` | as above |
| `db.namespace` | as above |
| `db.operation.name` | `OPEN` / `CLOSE` |
| `duration_ms` | elapsed time on the underlying `ensureOpen` / `close` call |

The `OPEN` log fires only on the first successful `ensureOpen` per interceptor. Drift may call `ensureOpen` more than once per connection; only the first one writes a record. `CLOSE` fires on every `close` call. Errors on either path write a separate error record at `Level.error` with `error.type` / `error.message`.

### Error log defaults

Added to whichever map the failing event built:

| Field | Source |
|-------|--------|
| `error.type` | `error.runtimeType.toString()` |
| `error.message` | `error.toString()` |

loq's `Logger` always adds `error` (the caught `Object`) and `stackTrace` on a layer below `errorFields:`. Replacing the map with `errorFields: (_, __, ___) => {}` still includes them.

#### Adding `db.response.status_code` (per-dialect)

OTel's `db.response.status_code` is **Stable** and should be set on warning/error, but the value lives in dialect-specific exception types (`sqlite3`'s `SqliteException`, `postgres`'s `PgException`, `mysql_client`'s `MySQLClientException`). `loq_drift` doesn't import those packages. Adding the attribute is a one-line recipe in your own `errorFields:` hook:

```dart
import 'package:sqlite3/sqlite3.dart' show SqliteException;

LoqDriftInterceptor(
  errorFields: (event, error, stack) => {
    ...event.defaults,
    if (error is SqliteException)
      'db.response.status_code': error.extendedResultCode.toString(),
  },
)
```

Same shape for other dialects:

```dart
// postgres (package:postgres)
import 'package:postgres/postgres.dart' show PgException;

errorFields: (event, error, stack) => {
  ...event.defaults,
  if (error is PgException && error.code != null)
    'db.response.status_code': error.code!,
},

// mariadb / MySQL (package:mysql_client)
import 'package:mysql_client/mysql_client.dart' show MySQLClientException;

errorFields: (event, error, stack) => {
  ...event.defaults,
  if (error is MySQLClientException)
    'db.response.status_code': error.errno?.toString() ?? '',
},
```

Drift sometimes wraps these in `DriftRemoteException`. Pattern-match accordingly if you're running through the isolate / remote transport.

### Reading args without `captureArgs`

`captureArgs: false` (the default) keeps `db.query.parameter.*` keys out of the defaults. But `DriftQueryEvent.args` is always populated. The hook can read them and write a derived field instead:

```dart
LoqDriftInterceptor(
  // captureArgs left at false
  fields: (event) => switch (event) {
    DriftQueryEvent(:final args) => {
      ...event.defaults,
      'loq.db.query.parameter.count': args.length,
    },
    _ => event.defaults,
  },
)
```

> `duration_ms` uses snake_case (industry convention across Datadog, Elastic, Logstash, etc.) rather than loq's usual camelCase.

## Supported dialects

`defaultDbSystemName` maps Drift's [`SqlDialect`](https://pub.dev/documentation/drift/latest/drift/SqlDialect.html) to the OTel canonical `db.system.name`:

| `SqlDialect` | `db.system.name` |
|--------------|------------------|
| `sqlite` | `sqlite` |
| `postgres` | `postgresql` |
| `mariadb` | `mariadb` |
| anything else | `other_sql` (OTel-spec catch-all) |

The fallback is `other_sql` per the OTel spec. It's the Stable canonical value for SQL systems without a registered name. If you'd rather emit the actual Drift dialect name (e.g. `duckdb`), and you're OK with that name not being in the OTel registry, override with a custom `dbSystemResolver`:

```dart
LoqDriftInterceptor(
  dbSystemResolver: (d) => switch (d) {
    SqlDialect.duckdb => 'duckdb',
    _ => null,  // fall back to defaultDbSystemName
  },
)
```

## Configuration

### Skip noisy statement logs

`PRAGMA`, `SELECT 1` health pings, and other high-frequency calls usually aren't worth logging. The query still runs; only the log is dropped.

```dart
LoqDriftInterceptor(
  skipLog: (sql) => sql.startsWith('PRAGMA'),
)
```

Batches and transactions always log. To silence those, raise the handler's `minLevel` above `transactionLevel` (default `trace`) or `queryLevel` (default `debug`).

> **Note vs `loq_shelf`.** `loq_shelf`'s `skip:` bypasses the middleware *entirely* (no log **and** no `withLogContext` binding), so a skipped request loses downstream-log correlation too. `loq_drift`'s `skipLog:` only drops the log; it has to run the query either way. The `Log` suffix is the hint.

### Slow query threshold

Adds `slow: true` and bumps the completion level to at least `warn` (keeping `error`/`fatal`):

```dart
LoqDriftInterceptor(
  slowQueryThreshold: const Duration(milliseconds: 50),
)
```

### Levels

```dart
LoqDriftInterceptor(
  queryLevel: Level.debug,        // single-query and batch completion
  transactionLevel: Level.trace,  // begin / commit / rollback
)
```

`levelResolver` is the one hook that overrides level for any event. It gets the typed `DriftLogEvent` and any caught error (`null` on success). Return `null` to fall back to the per-event default. `slowQueryThreshold`'s warn-bump still stacks on top:

```dart
LoqDriftInterceptor(
  levelResolver: (event, error) => switch (event) {
    _ when error is TimeoutException => Level.warn,
    DriftQueryEvent(operation: 'SELECT', :final statement)
        when statement.contains('sessions') => Level.trace,
    DriftTransactionEvent(operation: 'ROLLBACK') => Level.warn,
    _ => null,
  },
)
```

### Tables

Drift doesn't expose the matched table name through `QueryInterceptor`. By the time a statement reaches the interceptor, Drift has already compiled it to SQL with no AST attached. The OTel spec is clear that `db.collection.name` *should* come from query metadata, not from parsing query text. Drift's `QueryInterceptor` puts the spec's preferred path out of reach inside the interceptor. The two strategies below are workarounds.

**Strategy 1: bind the table through zone context at the call site.** Closest to the spec's intent, since you're using the table name you already know from your code (not re-extracting it from SQL):

```dart
Future<User> getUser(int id) =>
    withLogContext({'db.collection.name': 'users'}, () =>
        database.userById(id).getSingle());
```

In this strategy, leave `tableResolver:` unset. With no resolver, the interceptor doesn't put `db.collection.name` in the call-time fields, so the zone-context value is the only source and wins. Cost: every Drift call that needs the field has to be wrapped (or a block of calls wrapped together).

**Strategy 2: SQL regex `tableResolver`.** Works in practice but is fragile. The spec calls this the *non-preferred* path. Fine for typical single-table Drift-generated statements; breaks on CTEs, joins to many tables, and subqueries:

```dart
LoqDriftInterceptor(
  tableResolver: (sql) {
    final m = RegExp(
      r'\b(?:from|into|update)\s+"?(\w+)"?',
      caseSensitive: false,
    ).firstMatch(sql);
    return m?.group(1);
  },
)
```

**Note on combining.** loq's field layering puts call-time fields *above* zone-context fields, so a non-null `tableResolver` return value overrides any `db.collection.name` you bound through `withLogContext`. Pick one strategy per `db.collection.name`; mixing them silently lets the resolver win.

### Database system override

```dart
LoqDriftInterceptor(
  // Pin a value no matter the dialect. Useful when proxying through
  // a connection that lies about its dialect, or to tag a custom DB.
  dbSystemResolver: (_) => 'cockroachdb',
)
```

Returning `null` falls back to `defaultDbSystemName(dialect)`.

### Database namespace

Set `namespace:` to emit OTel-spec `db.namespace` (Stable) on every event (query, batch, and transaction):

```dart
LoqDriftInterceptor(
  namespace: 'myapp_production',  // postgres database name, sqlite file, etc.
)
```

One value per interceptor. For dynamic namespaces (multi-tenant routing, per-request DB selection), either spin up one interceptor per database or emit `db.namespace` from the `fields:` hook or through `withLogContext`.

### Capture bound parameters

**Off by default**, since bound args often carry user-identifying values. When on, emits one OTel-spec attribute per bound parameter at `db.query.parameter.<n>` (0-based):

```dart
LoqDriftInterceptor(captureArgs: true)
```

A query like `SELECT * FROM users WHERE id = ? AND tenant = ?` with bind values `[42, 'acme']` emits `db.query.parameter.0=42` and `db.query.parameter.1=acme`.

> The attribute is **Development / Opt-In** in the OTel spec. The name is settled, but future minor spec versions could narrow what it means. The spec also says don't emit it for batches. We follow that: batches never carry parameter attributes regardless of `captureArgs`.

#### Redaction strategies

`loq_drift` ships no built-in arg redaction. Positional bind args carry no schema signal, so the interceptor doesn't know which positions are sensitive. Two strategies cover the realistic cases:

**1. Coarse: don't capture in production.** The cleanest option is to leave `captureArgs: false` in production (e.g. gate on an env var):

```dart
LoqDriftInterceptor(
  captureArgs: const bool.fromEnvironment('CAPTURE_DB_ARGS'),
)
```

If you do want "we know there were args, we won't show which" in production, strip the `db.query.parameter.*` keys from the `fields:` hook:

```dart
LoqDriftInterceptor(
  captureArgs: true,
  fields: (event) => Map.of(event.defaults)
    ..removeWhere((k, _) => k.startsWith('db.query.parameter.')),
)
```

(loq core's `redact()` works on whole field names, not glob patterns, so a `fields:`-side strip is the way to "redact all parameters" today. Other sensitive fields like `db.query.text` and `error.message` still compose with `redact()` directly.)

**2. Fine-grained: per-position redaction.** Override individual `db.query.parameter.<n>` keys from the `fields:` hook by pattern-matching on `DriftQueryEvent` and reading `event.args` / `event.statement`. The raw args are always available on the event, regardless of `captureArgs`:

```dart
LoqDriftInterceptor(
  captureArgs: true,
  fields: (event) => switch (event) {
    DriftQueryEvent(:final statement) when statement.contains('users') => {
      ...event.defaults,
      // mask positions 1 (name) and 2 (email); leave 0 (id) and the rest
      'db.query.parameter.1': '***',
      'db.query.parameter.2': '***',
    },
    _ => event.defaults,
  },
)
```

Direct key override is the strength of the indexed shape. No list rebuilding needed.

The fine-grained strategy needs schema knowledge. Only your code knows which position is the password and which is the user id. The coarse strategy is the safer default when in doubt.

### Customizing fields

`fields:` and `errorFields:` are the one transformation point for their event types. Each gets a typed `DriftLogEvent` and returns the final fields. Compose, filter, or fully replace:

```dart
// Add a tenant id on top of defaults
LoqDriftInterceptor(
  fields: (event) => {
    ...event.defaults,
    'tenant_id': currentTenantId(),
  },
)

// Drop default fields (here: strip all bound parameters)
LoqDriftInterceptor(
  fields: (event) => Map.of(event.defaults)
    ..removeWhere((k, _) => k.startsWith('db.query.parameter.')),
)

// Replace entirely (you opt out of OTel defaults)
LoqDriftInterceptor(
  fields: (event) => {
    'operation': event.defaults['db.operation.name'],
    if (event.elapsed != null) 'duration_ms': event.elapsed!.inMilliseconds,
  },
)

// Tag error logs based on the exception type
LoqDriftInterceptor(
  errorFields: (event, error, stack) => {
    ...event.defaults,
    'db.error.retryable': error.toString().contains('locked'),
  },
)

// Per-event-type shaping via switch
LoqDriftInterceptor(
  fields: (event) => switch (event) {
    DriftQueryEvent() => {...event.defaults, 'kind': 'query'},
    DriftBatchEvent() => {...event.defaults, 'kind': 'batch'},
    DriftTransactionEvent() => {...event.defaults, 'kind': 'tx'},
    DriftLifecycleEvent() => {...event.defaults, 'kind': 'lifecycle'},
  },
)
```

### Custom messages

Handy when downstream log pipelines key off specific event names:

```dart
LoqDriftInterceptor(
  queryCompleteMessage: 'db.query.end',
  queryErrorMessage: 'db.query.error',
  batchCompleteMessage: 'db.batch.end',
  batchErrorMessage: 'db.batch.error',
  transactionBeginMessage: 'db.tx.begin',
  transactionCommitMessage: 'db.tx.commit',
  transactionRollbackMessage: 'db.tx.rollback',
  transactionErrorMessage: 'db.tx.error',
)
```

### Custom logger

```dart
LoqDriftInterceptor(
  logger: Logger('db', config: LogConfig(
    handlers: [JsonHandler()],
    processors: [addTimestamp()],
  )),
)
```

## Design notes

A few things `loq_drift` doesn't do on purpose. Coming from another DB-logging library you might expect them, so here's why we don't.

### One log per query (no separate "started" log)

We write one log record per operation, at completion. No paired "started" record.

If what you want is **span lifetime** for distributed tracing (open something on start, close on end), that's `TracingInterceptor` territory, not log emission. See the [Tracing](#tracing-otel-spans-alongside-logs) section above. Spans and logs are separate signals, tied together by `trace.id` / `span.id`. Expressing span lifetime as a pair of log records gets you to the same place a worse way (twice the log volume, manual correlation in a custom Handler).

If what you want is per-operation "in-flight" visibility (e.g. to debug a hung query), the `TracingInterceptor` pattern also covers it. Your tracer can show in-flight spans without us writing logs at start time.

This matches TypeORM, Prisma, and sqlx; it differs from pgx, EF Core, ActiveRecord, and Knex, which emit paired start/end log events.

### One `fields:` hook (not per-event-type hooks)

A single `fields:` hook plus the sealed `DriftLogEvent` hierarchy lets users branch through `switch` instead of writing the same logic across multiple signatures:

```dart
// One hook, pattern-match on what you need
fields: (event) => switch (event) {
  DriftQueryEvent()       => {...event.defaults, 'kind': 'query'},
  DriftBatchEvent()       => {...event.defaults, 'kind': 'batch'},
  DriftTransactionEvent() => {...event.defaults, 'kind': 'tx'},
  DriftLifecycleEvent()   => {...event.defaults, 'kind': 'lifecycle'},
},
```

The dominant pattern (tag every log uniformly) is one line instead of four. Per-event-type tweaks stay clean through `switch`. Adding a fifth event type later is a new subclass, not a new constructor parameter.

### One log per batch (not per-execution)

pgx emits `BatchStart` plus one event per query inside the batch plus `BatchEnd`: a three-method tracer interface. For drift, a batch can be "INSERT 1000 rows," which would mean **1002 log records for one logical operation**. We write a single `batch completed` record with `db.operation.batch.size` carrying the count, plus the batch-level error fields on failure.

There are good reasons to want per-execution visibility: per-row timing variance, OTel per-statement spans, regulatory audit-per-row, or debugging which bind values are involved. None of those are well served by writing 1000+ log records by default. They all benefit from being explicit. If you need any of them, layer a custom `QueryInterceptor` on top of `LoqDriftInterceptor` and override `runBatched` to do the per-execution work you need (timing, span emission, etc.). Same chaining pattern as in the [Tracing](#tracing-otel-spans-alongside-logs) section.

## API reference

```dart
LoqDriftInterceptor({
  // Setup
  Logger? logger,
  String? namespace,
  // Behavior
  bool Function(String statement)? skipLog,
  Level queryLevel = Level.debug,
  Level transactionLevel = Level.trace,
  Level lifecycleLevel = Level.trace,
  Duration? slowQueryThreshold,
  // Field hooks
  Map<String, Object?> Function(DriftLogEvent event)? fields,
  Map<String, Object?> Function(DriftLogEvent event, Object error, StackTrace stack)? errorFields,
  // Resolvers
  String? Function(String statement)? tableResolver,
  String? Function(SqlDialect dialect)? dbSystemResolver,
  Level? Function(DriftLogEvent event, Object? error)? levelResolver,
  // Capture
  bool captureArgs = false,
  // Messages
  String queryCompleteMessage = 'query completed',
  String queryErrorMessage = 'query failed',
  String batchCompleteMessage = 'batch completed',
  String batchErrorMessage = 'batch failed',
  String transactionBeginMessage = 'transaction begin',
  String transactionCommitMessage = 'transaction commit',
  String transactionRollbackMessage = 'transaction rollback',
  String transactionErrorMessage = 'transaction failed',
  String databaseOpenMessage = 'database opened',
  String databaseCloseMessage = 'database closed',
  String databaseLifecycleErrorMessage = 'database lifecycle failed',
})
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| **Setup** | | |
| `logger` | `Logger('db')` | Logger instance for all interceptor logs |
| `namespace` | `null` | Emits OTel-spec `db.namespace` on every event when non-null |
| **Behavior** | | |
| `skipLog` | `null` | Drop the log when `true` (the query still runs); single queries only, batches and transactions always log. See note above on how this differs from `loq_shelf`'s `skip:` |
| `queryLevel` | `Level.debug` | Level for single-query and batch completion logs |
| `transactionLevel` | `Level.trace` | Level for transaction lifecycle logs (begin / commit / rollback) |
| `lifecycleLevel` | `Level.trace` | Level for database lifecycle logs (open / close) |
| `slowQueryThreshold` | `null` | Adds `slow: true` to defaults and bumps completion level to ≥ `warn` |
| **Field hooks** | | |
| `fields` | identity | Transforms success-path defaults across all event types (queries, batches, transactions, lifecycle) |
| `errorFields` | identity | Transforms error-path defaults across all event types (queries, batches, transactions, lifecycle); also gets the caught error and stack trace |
| **Resolvers** | | |
| `tableResolver` | `null` | Returns `db.collection.name` from the statement |
| `dbSystemResolver` | `defaultDbSystemName` | Returns the OTel `db.system.name` from the executor's dialect |
| `levelResolver` | `null` | Overrides level for any event (success or error) |
| **Capture** | | |
| `captureArgs` | `false` | Emit one `db.query.parameter.<n>` attribute per bound arg (OTel-spec indexed shape, Development/Opt-In) |
| **Messages** | | |
| `queryCompleteMessage` | `'query completed'` | Success log for single queries |
| `queryErrorMessage` | `'query failed'` | Error log for single queries |
| `batchCompleteMessage` | `'batch completed'` | Success log for `runBatched` |
| `batchErrorMessage` | `'batch failed'` | Error log for `runBatched` |
| `transactionBeginMessage` | `'transaction begin'` | Log for `beginTransaction` / `beginExclusive` |
| `transactionCommitMessage` | `'transaction commit'` | Log for `commitTransaction` |
| `transactionRollbackMessage` | `'transaction rollback'` | Log for `rollbackTransaction` |
| `transactionErrorMessage` | `'transaction failed'` | Error log for commit / rollback failure |
| `databaseOpenMessage` | `'database opened'` | Log for the first successful `ensureOpen` |
| `databaseCloseMessage` | `'database closed'` | Log for `close` |
| `databaseLifecycleErrorMessage` | `'database lifecycle failed'` | Error log for open / close failure |

## License

MIT. See [LICENSE](LICENSE).
