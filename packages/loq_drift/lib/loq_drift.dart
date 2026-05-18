/// Structured query logging interceptor for Drift, powered by loq.
///
/// Provides [LoqDriftInterceptor], a Drift `QueryInterceptor` that
/// writes a structured log record for each SQL query, batch,
/// transaction step, and database open/close. Fields follow the
/// OpenTelemetry database semantic conventions.
///
/// ```dart
/// import 'package:drift/drift.dart';
/// import 'package:drift/native.dart';
/// import 'package:loq_drift/loq_drift.dart';
///
/// final database = MyDatabase(
///   NativeDatabase.memory().interceptWith(LoqDriftInterceptor()),
/// );
/// ```
library;

// This import is consumed by dartdoc to resolve [LoqDriftInterceptor]
// in the library docstring above. Without it, the analyzer raises
// `comment_references`. Exports alone aren't enough.
import 'package:loq_drift/src/loq_drift_interceptor.dart';

export 'src/drift_log_event.dart';
export 'src/loq_drift_interceptor.dart';
export 'src/sql_helpers.dart';
