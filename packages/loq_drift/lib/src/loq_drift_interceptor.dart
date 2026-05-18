import 'dart:async';

import 'package:drift/drift.dart';
import 'package:loq/loq.dart';
import 'package:loq_drift/src/drift_log_event.dart';
import 'package:loq_drift/src/sql_helpers.dart';

/// Hook for every success-path event. Gets the typed event (use
/// pattern matching to branch on shape) and returns the final fields.
/// Spread `...event.defaults` to keep the defaults; return a different
/// map to replace.
typedef DriftFieldsHook = Map<String, Object?> Function(DriftLogEvent event);

/// Hook for the error path. Gets the typed event describing what was
/// attempted, plus the caught error and stack trace.
typedef DriftErrorFieldsHook = Map<String, Object?> Function(
  DriftLogEvent event,
  Object error,
  StackTrace stackTrace,
);

/// Hook that overrides the level for any event. Returning `null`
/// falls back to the per-event default. The error is non-null on the
/// error path.
typedef DriftLevelResolver = Level? Function(
  DriftLogEvent event,
  Object? error,
);

/// Structured query logging interceptor for Drift.
///
/// Wraps every method on [QueryInterceptor] to write a log record for
/// each query, batch, transaction step, and database open/close. Fields
/// follow the OpenTelemetry database semantic conventions.
///
/// ```dart
/// final database = MyDatabase(
///   NativeDatabase.memory().interceptWith(LoqDriftInterceptor()),
/// );
/// ```
///
/// ## Default fields
///
/// Every event builds a `defaults` map with everything the interceptor
/// would write on its own. The `fields:` hook (or `errorFields:` for
/// the error path) gets the typed [DriftLogEvent] and returns the
/// final fields. Spread `...event.defaults` to keep the defaults;
/// return a different map to replace.
///
/// **Query defaults** (success path of `runSelect` / `runInsert` /
/// `runUpdate` / `runDelete` / `runCustom`):
///
/// - `db.system.name`: from `dbSystemResolver:` or [defaultDbSystemName]
/// - `db.namespace`: when [namespace] is set
/// - `db.operation.name`: `SELECT` / `INSERT` / `UPDATE` / `DELETE`, or
///   the parsed first keyword for `runCustom` (or `CUSTOM` if it
///   can't be parsed)
/// - `db.query.summary`: low-cardinality `<OP> <table?>` string for
///   dashboard grouping
/// - `db.query.text`: the statement
/// - `duration_ms`: elapsed time in milliseconds
/// - When `tableResolver:` is set: `db.collection.name`
/// - When [captureArgs] is `true`: `db.query.parameter.<n>` for each
///   bound argument, where `<n>` is the 0-based position (OTel-spec
///   indexed shape, Development / Opt-In status in the spec)
/// - For `runSelect`: `db.response.returned_rows` (OTel-spec, in
///   Development / Opt-In status in the spec, not yet stable; future
///   minor versions could narrow what it means)
/// - For `runUpdate` / `runDelete` (any dialect) and `runInsert` on
///   non-sqlite dialects: `loq.db.affected_rows`. The row count the
///   executor returned. Under the `loq.*` namespace since OTel
///   doesn't standardize an affected-rows attribute.
/// - For `runInsert` on sqlite: `loq.db.last_insert_rowid`. sqlite's
///   `runInsert` gives back the auto-increment row id, not an affected
///   count, so it's named accordingly.
/// - When [slowQueryThreshold] is crossed: `slow: true`
///
/// **Batch defaults** (success path of `runBatched`):
///
/// - `db.system.name`, `duration_ms`
/// - `db.namespace`: when [namespace] is set
/// - `db.operation.name`: `BATCH`
/// - `db.query.summary`: `BATCH <OP> <table?>` when all statements
///   share an operation; plain `BATCH` for mixed batches
/// - `db.operation.batch.size`: total operations run (left out per
///   OTel spec when the batch holds a single operation)
/// - `db.query.text`: prepared statements joined with `; `
/// - When [slowQueryThreshold] is crossed: `slow: true`
///
/// **Transaction defaults** (begin / commit / rollback / begin exclusive):
///
/// - `db.system.name`
/// - `db.namespace`: when [namespace] is set
/// - `db.operation.name`: `BEGIN` / `COMMIT` / `ROLLBACK` / `BEGIN EXCLUSIVE`
/// - For commit / rollback: `duration_ms` for the matching driver call
///
/// **Lifecycle defaults** (success path of `ensureOpen` first-call /
/// `close`):
///
/// - `db.system.name`, `duration_ms`
/// - `db.namespace`: when [namespace] is set
/// - `db.operation.name`: `OPEN` / `CLOSE`
///
/// **Error defaults** (added to whichever map the failing event built):
///
/// - `error.type`: `error.runtimeType.toString()`
/// - `error.message`: `error.toString()`
///
/// loq's [Logger] always adds `error` (the caught Object) and
/// `stackTrace` to the error log on a layer below `errorFields:`.
///
/// Note: `duration_ms` uses snake_case (industry convention across
/// Datadog, Elastic, Logstash, etc.) rather than loq's usual camelCase.
class LoqDriftInterceptor extends QueryInterceptor {
  /// Creates a structured query logging interceptor.
  ///
  /// ### Setup
  ///
  /// - [logger]: the [Logger] to use. Defaults to `Logger('db')`.
  /// - [namespace]: when non-null, emits `db.namespace` (OTel-spec
  ///   Stable) on every event. Set this to the database name your app
  ///   uses (e.g. `myapp_production` for postgres, a file path or
  ///   `:memory:` for sqlite). Default `null`, in which case the
  ///   field is left out.
  ///
  /// ### Behavior
  ///
  /// - [skipLog]: predicate run before logging single queries
  ///   (`runSelect` / `runInsert` / `runUpdate` / `runDelete` /
  ///   `runCustom`). Returning `true` drops the log; **the query
  ///   still runs**. Handy for high-frequency `PRAGMA`, `SELECT 1`
  ///   health pings, etc. Batches and transactions always log. To
  ///   silence those, raise the handler's `minLevel` above
  ///   [transactionLevel] / [queryLevel].
  ///
  ///   Note: this is narrower than `loq_shelf`'s `skip:`, which
  ///   bypasses the entire middleware (no logs **and** no zone
  ///   context binding). loq_drift can't skip running the query, so
  ///   it can only skip the log. Hence the `Log` suffix.
  /// - [queryLevel]: level for single-query and batch completion logs.
  ///   Default [Level.debug].
  /// - [transactionLevel]: level for transaction lifecycle logs
  ///   (begin / commit / rollback). Default [Level.trace].
  /// - [lifecycleLevel]: level for database lifecycle logs
  ///   (open / close). Default [Level.trace]. The `OPEN` log fires
  ///   only on the first successful `ensureOpen` per interceptor.
  ///   Drift may call `ensureOpen` more than once per connection;
  ///   the rest pass through silently.
  /// - [slowQueryThreshold]: when crossed, adds `slow: true` to the
  ///   defaults and bumps the completion level to at least [Level.warn]
  ///   (never lowers `error` or higher). Error-path level isn't
  ///   bumped.
  ///
  /// ### Field hooks
  ///
  /// Both take a [DriftLogEvent] and return the final map. Spread
  /// `...event.defaults` to keep the defaults; return a different map
  /// to replace.
  ///
  /// - [fields]: transforms the success-path defaults.
  /// - [errorFields]: transforms the error-path defaults; also gets
  ///   the caught error and stack trace.
  ///
  /// ### Resolvers
  ///
  /// Each returns `T?`. Returning `null` falls back to the built-in
  /// default.
  ///
  /// - [tableResolver]: returns the primary collection for
  ///   `db.collection.name`. No built-in default. Wire it to your
  ///   Drift table classes (e.g. by stripping the prefix Drift uses
  ///   on its generated SQL) to surface the table in dashboards.
  /// - [dbSystemResolver]: returns the OTel canonical system name for
  ///   the wrapped executor's [SqlDialect]. Defaults to
  ///   [defaultDbSystemName].
  /// - [levelResolver]: overrides the level for any event. Gets the
  ///   typed [DriftLogEvent] and any caught error (`null` on success).
  ///   Return `null` to fall back to [queryLevel] /
  ///   [transactionLevel] / [Level.error]. [slowQueryThreshold]'s
  ///   warn-bump still stacks on top.
  ///
  /// ### Capture
  ///
  /// - [captureArgs]: when `true`, writes one attribute per bound
  ///   parameter at `db.query.parameter.<n>` (0-based, OTel-spec
  ///   indexed shape). Default `false`. Turning this on without a
  ///   redaction strategy leaks any PII the query binds. Two
  ///   strategies are on offer:
  ///   - **Coarse:** leave `captureArgs: false` in production. That's
  ///     the no-emission default; no parameter fields ever land in
  ///     records. For "capture in dev, mask in prod" you can also
  ///     keep `captureArgs: true` and strip the
  ///     `db.query.parameter.*` keys from the [fields] hook.
  ///   - **Fine-grained (per-position):** override individual
  ///     `db.query.parameter.<n>` keys from the [fields] hook by
  ///     pattern-matching on [DriftQueryEvent] and reading
  ///     `event.args` / `event.statement`.
  ///
  ///   The raw args stay reachable through [DriftQueryEvent.args]
  ///   inside any hook regardless of this flag. The flag only
  ///   controls whether the indexed attributes land in `defaults`.
  ///
  /// ### Messages
  ///
  /// Log message text overrides:
  /// [queryCompleteMessage], [queryErrorMessage],
  /// [batchCompleteMessage], [batchErrorMessage],
  /// [transactionBeginMessage], [transactionCommitMessage],
  /// [transactionRollbackMessage], [transactionErrorMessage],
  /// [databaseOpenMessage], [databaseCloseMessage],
  /// [databaseLifecycleErrorMessage].
  LoqDriftInterceptor({
    // Setup
    Logger? logger,
    this.namespace,
    // Behavior
    bool Function(String statement)? skipLog,
    this.queryLevel = Level.debug,
    this.transactionLevel = Level.trace,
    this.lifecycleLevel = Level.trace,
    this.slowQueryThreshold,
    // Field hooks
    DriftFieldsHook? fields,
    DriftErrorFieldsHook? errorFields,
    // Resolvers
    String? Function(String statement)? tableResolver,
    String? Function(SqlDialect dialect)? dbSystemResolver,
    DriftLevelResolver? levelResolver,
    // Capture
    this.captureArgs = false,
    // Messages
    this.queryCompleteMessage = 'query completed',
    this.queryErrorMessage = 'query failed',
    this.batchCompleteMessage = 'batch completed',
    this.batchErrorMessage = 'batch failed',
    this.transactionBeginMessage = 'transaction begin',
    this.transactionCommitMessage = 'transaction commit',
    this.transactionRollbackMessage = 'transaction rollback',
    this.transactionErrorMessage = 'transaction failed',
    this.databaseOpenMessage = 'database opened',
    this.databaseCloseMessage = 'database closed',
    this.databaseLifecycleErrorMessage = 'database lifecycle failed',
  })  : _logger = logger ?? Logger('db'),
        _skipLog = skipLog,
        _fields = fields,
        _errorFields = errorFields,
        _tableResolver = tableResolver,
        _dbSystemResolver =
            ((d) => dbSystemResolver?.call(d) ?? defaultDbSystemName(d)),
        _levelResolver = levelResolver;

  /// The OTel `db.namespace` to emit on every event when non-null.
  ///
  /// Per the OTel database semantic conventions, this is the database
  /// name (e.g. `myapp_production` for postgres, a file path or
  /// `:memory:` for sqlite). One value per interceptor; set it once
  /// at construction. For dynamic namespaces (e.g. multi-tenant
  /// routing), either spin up one interceptor per database or emit
  /// `db.namespace` from the `fields:` hook or through
  /// `withLogContext`.
  final String? namespace;

  /// Level applied to query and batch completion logs.
  final Level queryLevel;

  /// Level applied to transaction lifecycle logs (begin / commit /
  /// rollback / begin exclusive).
  final Level transactionLevel;

  /// Level applied to database lifecycle logs (open / close).
  final Level lifecycleLevel;

  /// When set and exceeded, adds `slow: true` and bumps the level to at
  /// least [Level.warn] on the completion log.
  final Duration? slowQueryThreshold;

  /// When `true`, emits one attribute per bound parameter at
  /// `db.query.parameter.<n>` (0-based, OTel-spec indexed form).
  /// Default `false` because parameters often carry user-identifying
  /// values. The raw args remain reachable via [DriftQueryEvent.args]
  /// from inside hook callbacks regardless of this flag.
  final bool captureArgs;

  /// Message for the success-path query log.
  final String queryCompleteMessage;

  /// Message for the error-path query log.
  final String queryErrorMessage;

  /// Message for the success-path batch log.
  final String batchCompleteMessage;

  /// Message for the error-path batch log.
  final String batchErrorMessage;

  /// Message for the transaction `BEGIN` log.
  final String transactionBeginMessage;

  /// Message for the transaction `COMMIT` log.
  final String transactionCommitMessage;

  /// Message for the transaction `ROLLBACK` log.
  final String transactionRollbackMessage;

  /// Message for the transaction error-path log.
  final String transactionErrorMessage;

  /// Message for the database `OPEN` log.
  final String databaseOpenMessage;

  /// Message for the database `CLOSE` log.
  final String databaseCloseMessage;

  /// Message for the database open/close error-path log.
  final String databaseLifecycleErrorMessage;

  final Logger _logger;
  final bool Function(String statement)? _skipLog;
  final DriftFieldsHook? _fields;
  final DriftErrorFieldsHook? _errorFields;
  final String? Function(String statement)? _tableResolver;
  final String Function(SqlDialect dialect) _dbSystemResolver;
  final DriftLevelResolver? _levelResolver;

  Map<String, Object?> _queryDefaults({
    required SqlDialect dialect,
    required String operation,
    required String statement,
    required List<Object?> args,
  }) {
    final table = _tableResolver?.call(statement);
    final summary = table != null ? '$operation $table' : operation;
    return <String, Object?>{
      'db.system.name': _dbSystemResolver(dialect),
      if (namespace != null) 'db.namespace': namespace,
      'db.operation.name': operation,
      'db.query.summary': summary,
      'db.query.text': statement,
      if (table != null) 'db.collection.name': table,
      // OTel spec: emit one attribute per bound parameter at
      // `db.query.parameter.<n>` (0-based). Status is Development /
      // Opt-In in the spec; gated behind `captureArgs`.
      if (captureArgs)
        for (var i = 0; i < args.length; i++) 'db.query.parameter.$i': args[i],
    };
  }

  /// Computes the OTel `db.query.summary` for a batch. Returns
  /// `BATCH <OP> <table?>` when all statements share a single
  /// operation (the common drift case: same statement repeated with
  /// different args). Falls back to `BATCH` for empty or mixed-op
  /// batches.
  String _batchSummary(BatchedStatements statements) {
    if (statements.statements.isEmpty) return 'BATCH';
    final ops = statements.statements
        .map(extractOperationName)
        .whereType<String>()
        .toSet();
    if (ops.length != 1) return 'BATCH';
    final op = ops.first;
    final table = _tableResolver?.call(statements.statements.first);
    return table != null ? 'BATCH $op $table' : 'BATCH $op';
  }

  Future<T> _runQuery<T>({
    required QueryExecutor executor,
    required String operation,
    required String statement,
    required List<Object?> args,
    required Future<T> Function() exec,
    Map<String, Object?> Function(T result)? resultFields,
  }) async {
    if (_skipLog != null && _skipLog(statement)) {
      return exec();
    }

    final dialect = executor.dialect;
    final stopwatch = Stopwatch()..start();
    try {
      final result = await exec();
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final isSlow =
          slowQueryThreshold != null && elapsed > slowQueryThreshold!;

      final defaults = <String, Object?>{
        ..._queryDefaults(
          dialect: dialect,
          operation: operation,
          statement: statement,
          args: args,
        ),
        'duration_ms': elapsed.inMilliseconds,
        if (resultFields != null) ...resultFields(result),
        if (isSlow) 'slow': true,
      };
      final event = DriftQueryEvent(
        statement: statement,
        args: args,
        operation: operation,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _fields != null ? _fields(event) : defaults;

      var level = _levelResolver?.call(event, null) ?? queryLevel;
      if (isSlow && level < Level.warn) {
        level = Level.warn;
      }
      _logger.log(level, queryCompleteMessage, fields: finalFields);
      return result;
    } catch (error, stackTrace) {
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final isSlow =
          slowQueryThreshold != null && elapsed > slowQueryThreshold!;

      final defaults = <String, Object?>{
        ..._queryDefaults(
          dialect: dialect,
          operation: operation,
          statement: statement,
          args: args,
        ),
        'duration_ms': elapsed.inMilliseconds,
        'error.type': error.runtimeType.toString(),
        'error.message': error.toString(),
        if (isSlow) 'slow': true,
      };
      final event = DriftQueryEvent(
        statement: statement,
        args: args,
        operation: operation,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _errorFields != null
          ? _errorFields(event, error, stackTrace)
          : defaults;

      final level = _levelResolver?.call(event, error) ?? Level.error;

      _logger.log(
        level,
        queryErrorMessage,
        error: error,
        stackTrace: stackTrace,
        fields: finalFields,
      );
      rethrow;
    }
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runQuery(
      executor: executor,
      operation: 'SELECT',
      statement: statement,
      args: args,
      exec: () => executor.runSelect(statement, args),
      resultFields: (rows) => {'db.response.returned_rows': rows.length},
    );
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    // sqlite's runInsert returns lastInsertRowId, not an affected count.
    // Other dialects return a row count; surface them under the
    // semantically appropriate loq.* field.
    final isSqlite = executor.dialect == SqlDialect.sqlite;
    final fieldName =
        isSqlite ? 'loq.db.last_insert_rowid' : 'loq.db.affected_rows';
    return _runQuery(
      executor: executor,
      operation: 'INSERT',
      statement: statement,
      args: args,
      exec: () => executor.runInsert(statement, args),
      resultFields: (result) => {fieldName: result},
    );
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runQuery(
      executor: executor,
      operation: 'UPDATE',
      statement: statement,
      args: args,
      exec: () => executor.runUpdate(statement, args),
      resultFields: (rows) => {'loq.db.affected_rows': rows},
    );
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runQuery(
      executor: executor,
      operation: 'DELETE',
      statement: statement,
      args: args,
      exec: () => executor.runDelete(statement, args),
      resultFields: (rows) => {'loq.db.affected_rows': rows},
    );
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    return _runQuery(
      executor: executor,
      operation: extractOperationName(statement) ?? 'CUSTOM',
      statement: statement,
      args: args,
      exec: () => executor.runCustom(statement, args),
    );
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    final dialect = executor.dialect;
    final summary = _batchSummary(statements);
    final stopwatch = Stopwatch()..start();
    try {
      await executor.runBatched(statements);
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final isSlow =
          slowQueryThreshold != null && elapsed > slowQueryThreshold!;

      final defaults = <String, Object?>{
        'db.system.name': _dbSystemResolver(dialect),
        if (namespace != null) 'db.namespace': namespace,
        'db.operation.name': 'BATCH',
        'db.query.summary': summary,
        'db.query.text': statements.statements.join('; '),
        // OTel spec: omit when the batch contains a single operation.
        if (statements.arguments.length > 1)
          'db.operation.batch.size': statements.arguments.length,
        'duration_ms': elapsed.inMilliseconds,
        if (isSlow) 'slow': true,
      };
      final event = DriftBatchEvent(
        statements: statements,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _fields != null ? _fields(event) : defaults;

      var level = _levelResolver?.call(event, null) ?? queryLevel;
      if (isSlow && level < Level.warn) {
        level = Level.warn;
      }
      _logger.log(level, batchCompleteMessage, fields: finalFields);
    } catch (error, stackTrace) {
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final isSlow =
          slowQueryThreshold != null && elapsed > slowQueryThreshold!;

      final defaults = <String, Object?>{
        'db.system.name': _dbSystemResolver(dialect),
        if (namespace != null) 'db.namespace': namespace,
        'db.operation.name': 'BATCH',
        'db.query.summary': summary,
        'db.query.text': statements.statements.join('; '),
        // OTel spec: omit when the batch contains a single operation.
        if (statements.arguments.length > 1)
          'db.operation.batch.size': statements.arguments.length,
        'duration_ms': elapsed.inMilliseconds,
        'error.type': error.runtimeType.toString(),
        'error.message': error.toString(),
        if (isSlow) 'slow': true,
      };
      final event = DriftBatchEvent(
        statements: statements,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _errorFields != null
          ? _errorFields(event, error, stackTrace)
          : defaults;

      final level = _levelResolver?.call(event, error) ?? Level.error;

      _logger.log(
        level,
        batchErrorMessage,
        error: error,
        stackTrace: stackTrace,
        fields: finalFields,
      );
      rethrow;
    }
  }

  void _logTransactionBegin(QueryExecutor parent, String operationName) {
    final dialect = parent.dialect;
    final defaults = <String, Object?>{
      'db.system.name': _dbSystemResolver(dialect),
      if (namespace != null) 'db.namespace': namespace,
      'db.operation.name': operationName,
    };
    final event = DriftTransactionEvent(
      operation: operationName,
      elapsed: null,
      defaults: defaults,
    );
    final finalFields = _fields != null ? _fields(event) : defaults;
    final level = _levelResolver?.call(event, null) ?? transactionLevel;
    _logger.log(level, transactionBeginMessage, fields: finalFields);
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final tx = super.beginTransaction(parent);
    _logTransactionBegin(parent, 'BEGIN');
    return tx;
  }

  @override
  QueryExecutor beginExclusive(QueryExecutor parent) {
    final inner = super.beginExclusive(parent);
    _logTransactionBegin(parent, 'BEGIN EXCLUSIVE');
    return inner;
  }

  Future<void> _completeTransaction({
    required TransactionExecutor inner,
    required String operationName,
    required String successMessage,
    required Future<void> Function() send,
  }) async {
    final dialect = inner.dialect;
    final stopwatch = Stopwatch()..start();
    try {
      await send();
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final defaults = <String, Object?>{
        'db.system.name': _dbSystemResolver(dialect),
        if (namespace != null) 'db.namespace': namespace,
        'db.operation.name': operationName,
        'duration_ms': elapsed.inMilliseconds,
      };
      final event = DriftTransactionEvent(
        operation: operationName,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _fields != null ? _fields(event) : defaults;
      final level = _levelResolver?.call(event, null) ?? transactionLevel;
      _logger.log(level, successMessage, fields: finalFields);
    } catch (error, stackTrace) {
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final defaults = <String, Object?>{
        'db.system.name': _dbSystemResolver(dialect),
        if (namespace != null) 'db.namespace': namespace,
        'db.operation.name': operationName,
        'duration_ms': elapsed.inMilliseconds,
        'error.type': error.runtimeType.toString(),
        'error.message': error.toString(),
      };
      final event = DriftTransactionEvent(
        operation: operationName,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _errorFields != null
          ? _errorFields(event, error, stackTrace)
          : defaults;
      final level = _levelResolver?.call(event, error) ?? Level.error;
      _logger.log(
        level,
        transactionErrorMessage,
        error: error,
        stackTrace: stackTrace,
        fields: finalFields,
      );
      rethrow;
    }
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    return _completeTransaction(
      inner: inner,
      operationName: 'COMMIT',
      successMessage: transactionCommitMessage,
      send: () => super.commitTransaction(inner),
    );
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) {
    return _completeTransaction(
      inner: inner,
      operationName: 'ROLLBACK',
      successMessage: transactionRollbackMessage,
      send: () => super.rollbackTransaction(inner),
    );
  }

  // Gates the "database opened" log so it fires only on the first
  // successful `ensureOpen`. Subsequent calls (idempotent re-opens
  // by drift) pass through silently.
  bool _isOpen = false;

  Future<T> _runLifecycle<T>({
    required QueryExecutor executor,
    required String operationName,
    required String successMessage,
    required Future<T> Function() body,
    bool Function(T result)? shouldEmit,
  }) async {
    final dialect = executor.dialect;
    final stopwatch = Stopwatch()..start();
    try {
      final result = await body();
      stopwatch.stop();
      if (shouldEmit != null && !shouldEmit(result)) return result;
      final elapsed = stopwatch.elapsed;
      final defaults = <String, Object?>{
        'db.system.name': _dbSystemResolver(dialect),
        if (namespace != null) 'db.namespace': namespace,
        'db.operation.name': operationName,
        'duration_ms': elapsed.inMilliseconds,
      };
      final event = DriftLifecycleEvent(
        operation: operationName,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _fields != null ? _fields(event) : defaults;
      final level = _levelResolver?.call(event, null) ?? lifecycleLevel;
      _logger.log(level, successMessage, fields: finalFields);
      return result;
    } catch (error, stackTrace) {
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      final defaults = <String, Object?>{
        'db.system.name': _dbSystemResolver(dialect),
        if (namespace != null) 'db.namespace': namespace,
        'db.operation.name': operationName,
        'duration_ms': elapsed.inMilliseconds,
        'error.type': error.runtimeType.toString(),
        'error.message': error.toString(),
      };
      final event = DriftLifecycleEvent(
        operation: operationName,
        elapsed: elapsed,
        defaults: defaults,
      );
      final finalFields = _errorFields != null
          ? _errorFields(event, error, stackTrace)
          : defaults;
      final level = _levelResolver?.call(event, error) ?? Level.error;
      _logger.log(
        level,
        databaseLifecycleErrorMessage,
        error: error,
        stackTrace: stackTrace,
        fields: finalFields,
      );
      rethrow;
    }
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    return _runLifecycle(
      executor: executor,
      operationName: 'OPEN',
      successMessage: databaseOpenMessage,
      body: () => super.ensureOpen(executor, user),
      // Only emit the success log on the first open; drift may call
      // ensureOpen repeatedly per connection lifecycle. Errors always
      // emit (the catch branch isn't gated).
      shouldEmit: (_) {
        if (_isOpen) return false;
        _isOpen = true;
        return true;
      },
    );
  }

  @override
  Future<void> close(QueryExecutor inner) {
    return _runLifecycle(
      executor: inner,
      operationName: 'CLOSE',
      successMessage: databaseCloseMessage,
      body: () => super.close(inner),
    );
  }
}
