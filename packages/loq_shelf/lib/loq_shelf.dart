/// Structured request logging middleware for Shelf, powered by loq.
///
/// Provides [loqMiddleware], a drop-in replacement for Shelf's
/// `logRequests()` that emits structured log records with request fields,
/// zone context propagation, and configurable log levels.
///
/// ```dart
/// import 'package:loq_shelf/loq_shelf.dart';
///
/// final handler = Pipeline()
///     .addMiddleware(loqMiddleware())
///     .addHandler(router);
/// ```
library;

import 'package:loq_shelf/src/loq_middleware.dart';

export 'src/loq_middleware.dart';
