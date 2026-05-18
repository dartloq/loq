## 0.1.0

- Initial release.
- `LoqDriftInterceptor`: a `QueryInterceptor` that writes a structured
  log record for each SQL query, batch, transaction step, and database
  open/close.
- Default fields aligned with OpenTelemetry database semantic
  conventions: `db.system.name`, `db.namespace`, `db.operation.name`,
  `db.query.summary`, `db.query.text`, `db.collection.name`,
  `db.response.returned_rows`, `db.operation.batch.size`. Plus
  `duration_ms` and two loq-native extensions in their own `loq.*`
  namespace:
  - `loq.db.affected_rows`: row count returned by `runUpdate` /
    `runDelete` on every dialect, and by `runInsert` on non-sqlite
    dialects. OTel doesn't standardize an "affected rows" attribute,
    so we keep this out of the `db.*` namespace.
  - `loq.db.last_insert_rowid`: for `runInsert` on sqlite, where
    Drift's executor gives back the auto-increment row id (not an
    affected count). The split keeps the names honest.
- `db.operation.batch.size` is left out when the batch holds a
  single operation, per the OTel spec. The field is only useful for
  telling real multi-operation batches apart from single-statement
  calls.
- `db.response.returned_rows` is OTel-spec but in **Development /
  Opt-In** status. The attribute name is settled but the spec hasn't
  promoted it to Stable. Future minor versions could narrow what it
  means. Documented in the README.
- `db.response.status_code` (OTel-spec Stable, set on error) is not
  emitted on its own. The value lives in dialect-specific exception
  types (`SqliteException`, `PgException`, `MySQLClientException`)
  that `loq_drift` doesn't import. README has per-dialect recipes
  for surfacing it through the existing `errorFields:` hook.
- `db.query.summary` derived as `<OP> <table?>` for single queries
  and `BATCH <OP> <table?>` for batches whose statements share a
  single operation (the common drift case: same statement repeated
  with different args). Mixed-op or empty batches fall back to
  plain `BATCH`. Transaction lifecycle events don't emit a summary
  since they aren't queries in OTel's sense, and dashboards keying
  off `db.query.summary` shouldn't pick up lifecycle noise.
- `fields` / `errorFields` are the one transformation point for
  their respective logs. Each gets a typed `DriftLogEvent`, one of
  `DriftQueryEvent`, `DriftBatchEvent`, `DriftTransactionEvent`,
  or `DriftLifecycleEvent`. Pattern-match with `switch` to branch
  on event shape; spread `...event.defaults` to keep the defaults;
  return a different map to replace. `DriftQueryEvent.args` is
  always populated, so hooks can read bind parameters without
  turning on `captureArgs` globally.
- `defaultDbSystemName` is public. Maps Drift's `SqlDialect`
  (sqlite, postgres, mariadb) to the OTel canonical
  `db.system.name`. Falls back to `other_sql` (the Stable OTel
  catch-all) for any other dialect. Users who want a specific name
  for an unregistered dialect (e.g. `duckdb`) override through
  `dbSystemResolver`.
- `extractOperationName` is public. Pulls out the leading SQL
  keyword (used for `runCustom` operation detection). Skips leading
  whitespace and `--` line comments. Returns `null` for empty,
  whitespace-only, or non-alphabetic statements.
- `namespace` constructor parameter emits OTel-spec `db.namespace`
  (Stable) on every event when non-null. One value per interceptor.
  Users with dynamic namespaces (multi-tenant routing etc.) either
  spin up one interceptor per database or emit `db.namespace`
  through the `fields:` hook or `withLogContext`.
- `tableResolver` populates `db.collection.name`. No built-in
  default. Wire it to your own table-extraction strategy to keep
  per-statement cardinality from blowing up dashboards. README
  notes that SQL-regex extraction is the OTel spec's *non-preferred*
  path: the spec wants the value from query metadata, not from
  parsing query text. Drift's `QueryInterceptor` doesn't expose the
  AST, so the spec's preferred path isn't reachable from inside the
  interceptor. README describes an alternative: bind
  `db.collection.name` through `withLogContext` at the call site.
- `dbSystemResolver` overrides the dialect-to-system mapping.
  Returning `null` falls back to `defaultDbSystemName`.
- `levelResolver`: one hook that overrides level for any event.
  Gets the typed `DriftLogEvent` and any caught error. Returning
  `null` falls back to `queryLevel` (queries / batches),
  `transactionLevel` (transactions), or `Level.error` (error path).
  `slowQueryThreshold`'s warn-bump still stacks on top.
- `skipLog` predicate to drop logs for high-frequency statements
  (`PRAGMA`, health pings). The query still runs. Batches and
  transactions always log; raise the handler's `minLevel` above
  `transactionLevel` / `queryLevel` to silence those. The `Log`
  suffix flags that `skipLog` is narrower than `loq_shelf`'s
  `skip:`, which bypasses the entire middleware (no zone context
  binding either). `loq_drift` can't bypass the query itself.
- `slowQueryThreshold` to flag and bump up queries / batches that
  cross a duration: adds `slow: true` and makes sure the level is at
  least `warn`. The `slow: true` flag goes on both success and
  error paths for queries and batches; the warn-bump itself only
  applies on success (the error path is already at `Level.error` or
  higher).
- `captureArgs` opt-in to emit bound parameters in the OTel-spec
  indexed shape: `db.query.parameter.<n>` (0-based, one attribute
  per position). Status is **Development / Opt-In** in the spec,
  so what it means could narrow in future minor versions. Off by
  default since parameters often carry user-identifying values.
  The spec also says don't emit parameter attributes for batches,
  and we follow that: batches never carry them regardless of
  `captureArgs`. No built-in arg redactor since positional bind
  args carry no schema signal, so the interceptor can't know which
  positions are sensitive. Two documented strategies:
  - Coarse: leave `captureArgs: false` in production (no parameter
    fields at all). For "args present but masked", strip
    `db.query.parameter.*` keys from the `fields:` hook.
  - Fine-grained: override individual `db.query.parameter.<n>` keys
    from the `fields:` hook by pattern-matching on `DriftQueryEvent`.
    Direct per-position override, no list rebuilding. `event.args`
    (the raw list) is always available on the event regardless of
    `captureArgs`.
- `queryLevel`, `transactionLevel`, and `lifecycleLevel` defaults
  for the three event categories (`Level.debug` for queries/batches;
  `Level.trace` for transactions and database lifecycle).
- Eleven message overrides, one per event variant
  (`queryCompleteMessage`, `queryErrorMessage`,
  `batchCompleteMessage`, `batchErrorMessage`,
  `transactionBeginMessage`, `transactionCommitMessage`,
  `transactionRollbackMessage`, `transactionErrorMessage`,
  `databaseOpenMessage`, `databaseCloseMessage`,
  `databaseLifecycleErrorMessage`).
- README notes that `loq_drift` doesn't bind anything to the zone
  on its own (unlike `loq_shelf`'s middleware). Drift dispatches
  transaction bodies and queries from above the interceptor's call
  frame, so there's no callback we can wrap. Users who want
  per-transaction correlation wrap the block themselves with
  `withLogContext` (recipe in README).
- Database lifecycle instrumentation: the first successful
  `ensureOpen` per interceptor emits a `database opened` record;
  every `close` emits a `database closed` record. Errors on either
  path emit a separate `database lifecycle failed` record at
  `Level.error`. New event type `DriftLifecycleEvent` joins the
  sealed `DriftLogEvent` family (with `operation: 'OPEN' | 'CLOSE'`).
  Default level `Level.trace` (set through `lifecycleLevel`);
  message overrides through `databaseOpenMessage`,
  `databaseCloseMessage`, `databaseLifecycleErrorMessage`.
- Tracing integration through chained `QueryInterceptor`: README
  has the pattern (a custom `TracingInterceptor` wrapping
  `LoqDriftInterceptor` through Drift's `interceptWith` chain),
  plus a runnable example at `example/tracing_example.dart`. Trace
  context flows from the outer tracing layer into log records
  through `withLogContext`. No API surface needed in `loq_drift`
  itself, no coupling to a specific tracer SDK.
- Test suite in three layers:
  - Unit tests against a `_FakeExecutor` (100% line coverage on
    `lib/src/`). Fast; runs in the default `dart test`.
  - SQLite integration suite at
    `test/integration/real_sqlite_test.dart` running against real
    in-memory SQLite through `NativeDatabase.memory()`. Catches
    behavior the synthetic fake can't model: real exception types,
    row counts returned by sqlite, batch internals, lifecycle
    open/close. Runs in the default `dart test`.
  - Postgres smoke suite at
    `test/integration/postgres_test.dart` running against real
    postgres through `drift_postgres`. Confirms that drift's
    postgres adapter dispatches through `QueryInterceptor` the same
    way sqlite's does, and that the dialect-specific branch
    (`loq.db.affected_rows` instead of `loq.db.last_insert_rowid`
    on INSERT) holds against the real adapter. Tagged
    `@Tags(['postgres'])` and skipped by default (through
    `dart_test.yaml`) so local devs without postgres don't see
    failures. CI runs them as a separate step with a `postgres:16`
    service container.
