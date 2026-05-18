import 'package:drift/drift.dart';

/// Base class for events emitted by `LoqDriftInterceptor`.
///
/// Hooks receive one of the concrete subclasses ([DriftQueryEvent],
/// [DriftBatchEvent], [DriftTransactionEvent], [DriftLifecycleEvent])
/// and can branch on it with an exhaustive `switch`:
///
/// ```dart
/// fields: (event) => switch (event) {
///   DriftQueryEvent(:final operation) =>
///       {...event.defaults, 'kind': operation},
///   DriftBatchEvent() =>
///       {...event.defaults, 'kind': 'batch'},
///   DriftTransactionEvent(:final operation) =>
///       {...event.defaults, 'kind': operation},
///   DriftLifecycleEvent(:final operation) =>
///       {...event.defaults, 'kind': operation},
/// },
/// ```
sealed class DriftLogEvent {
  const DriftLogEvent();

  /// The fields the interceptor would emit without any user
  /// transformation. The hook can spread these (`...event.defaults`)
  /// to compose, return a different map to replace, or filter to drop
  /// individual fields.
  Map<String, Object?> get defaults;

  /// Elapsed wall-clock time for the underlying operation, or `null`
  /// for synchronous events that have no measurable duration. Right
  /// now that's just `BEGIN` and `BEGIN EXCLUSIVE`, which finish
  /// without an async send call.
  Duration? get elapsed;
}

/// A single-query event: one of `runSelect`, `runInsert`, `runUpdate`,
/// `runDelete`, or `runCustom`.
final class DriftQueryEvent extends DriftLogEvent {
  /// Creates a query event. Constructed by `LoqDriftInterceptor`; users
  /// receive instances in hook callbacks.
  const DriftQueryEvent({
    required this.statement,
    required this.args,
    required this.operation,
    required Duration elapsed,
    required Map<String, Object?> defaults,
  })  : _elapsed = elapsed,
        _defaults = defaults;

  /// The SQL passed to Drift, with `?` (or dialect-specific) placeholders.
  final String statement;

  /// Bound parameters as Drift passed them. Always populated;
  /// independent of `captureArgs`. The hook can read these to decide
  /// whether to show, summarize, or mask them in the final fields.
  final List<Object?> args;

  /// `SELECT` / `INSERT` / `UPDATE` / `DELETE` for the typed Drift
  /// methods. For `runCustom`, the leading SQL keyword (uppercased), or
  /// `CUSTOM` when unparseable.
  final String operation;

  final Duration _elapsed;
  @override
  Duration get elapsed => _elapsed;

  final Map<String, Object?> _defaults;
  @override
  Map<String, Object?> get defaults => _defaults;
}

/// A batched-execution event from `runBatched`.
final class DriftBatchEvent extends DriftLogEvent {
  /// Creates a batch event. Constructed by `LoqDriftInterceptor`; users
  /// receive instances in hook callbacks.
  const DriftBatchEvent({
    required this.statements,
    required Duration elapsed,
    required Map<String, Object?> defaults,
  })  : _elapsed = elapsed,
        _defaults = defaults;

  /// The Drift batch payload: prepared statements plus the per-execution
  /// argument groups.
  final BatchedStatements statements;

  final Duration _elapsed;
  @override
  Duration get elapsed => _elapsed;

  final Map<String, Object?> _defaults;
  @override
  Map<String, Object?> get defaults => _defaults;
}

/// A transaction lifecycle event: `BEGIN`, `BEGIN EXCLUSIVE`, `COMMIT`,
/// or `ROLLBACK`.
final class DriftTransactionEvent extends DriftLogEvent {
  /// Creates a transaction event. Constructed by `LoqDriftInterceptor`;
  /// users receive instances in hook callbacks.
  const DriftTransactionEvent({
    required this.operation,
    required Duration? elapsed,
    required Map<String, Object?> defaults,
  })  : _elapsed = elapsed,
        _defaults = defaults;

  /// One of `BEGIN`, `BEGIN EXCLUSIVE`, `COMMIT`, `ROLLBACK`.
  final String operation;

  /// `null` for `BEGIN` / `BEGIN EXCLUSIVE` (synchronous, no underlying
  /// async call to time); non-null for `COMMIT` / `ROLLBACK`, where it
  /// measures the time the driver's `send()` / `rollback()` took.
  final Duration? _elapsed;
  @override
  Duration? get elapsed => _elapsed;

  final Map<String, Object?> _defaults;
  @override
  Map<String, Object?> get defaults => _defaults;
}

/// A database lifecycle event: `OPEN` (first successful `ensureOpen`)
/// or `CLOSE` (the executor's `close` call).
final class DriftLifecycleEvent extends DriftLogEvent {
  /// Creates a lifecycle event. Constructed by `LoqDriftInterceptor`;
  /// users receive instances in hook callbacks.
  const DriftLifecycleEvent({
    required this.operation,
    required Duration elapsed,
    required Map<String, Object?> defaults,
  })  : _elapsed = elapsed,
        _defaults = defaults;

  /// `OPEN` or `CLOSE`.
  final String operation;

  /// Elapsed time of the underlying `ensureOpen` / `close` call.
  final Duration _elapsed;
  @override
  Duration get elapsed => _elapsed;

  final Map<String, Object?> _defaults;
  @override
  Map<String, Object?> get defaults => _defaults;
}
