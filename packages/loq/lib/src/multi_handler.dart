import 'package:loq/loq.dart';

/// A handler that dispatches records to multiple sub-handlers.
///
/// ```dart
/// LogConfig.configure(
///   handlers: [
///     MultiHandler([
///       ConsoleHandler(minLevel: Level.debug),
///       JsonHandler(minLevel: Level.info),
///     ]),
///   ],
/// );
/// ```
class MultiHandler implements Handler {
  /// Creates a handler that dispatches to all [handlers].
  MultiHandler(this.handlers);

  /// The sub-handlers to dispatch to.
  final List<Handler> handlers;

  /// Returns `true` if any sub-handler is enabled at [level].
  @override
  bool isEnabled(Level level) => handlers.any((h) => h.isEnabled(level));

  @override
  void handle(Record record) {
    for (final handler in handlers) {
      if (handler.isEnabled(record.level)) {
        handler.handle(record);
      }
    }
  }

  /// Flushes all sub-handlers in parallel.
  @override
  Future<void> flush() => Future.wait(handlers.map((h) => h.flush()));

  /// Closes all sub-handlers in parallel.
  @override
  Future<void> close() => Future.wait(handlers.map((h) => h.close()));
}
