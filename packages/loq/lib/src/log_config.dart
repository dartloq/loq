import 'dart:async';

import 'package:loq/src/console_handler.dart';
import 'package:loq/src/handler.dart';
import 'package:loq/src/source_location.dart';

/// Default reporter for handler errors. Prints a `loq:` -prefixed
/// diagnostic via [print] so logging failures don't break the host.
void _defaultOnHandlerError(
  Handler handler,
  Object error,
  StackTrace stackTrace,
) {
  // Print is the only pure-Dart sink available. Users wanting stderr
  // or a custom destination should override LogConfig.onHandlerError.
  // ignore: avoid_print
  print('loq: ${handler.runtimeType} threw: $error\n$stackTrace');
}

/// Global and per-logger configuration.
class LogConfig {
  /// Creates a configuration.
  const LogConfig({
    this.processors = const [],
    this.handlers = const [],
    this.zoneAccessor,
    this.captureSourceLocation = false,
    this.onHandlerError = _defaultOnHandlerError,
  });

  /// The processor chain applied to every record.
  final List<Processor> processors;

  /// The handlers that receive processed records.
  final List<Handler> handlers;

  /// Extracts ambient fields from the current [Zone].
  final Map<String, Object?>? Function(Zone zone)? zoneAccessor;

  /// Whether to capture the call-site [SourceLocation] for each record.
  ///
  /// Disabled by default because capturing a [StackTrace] on every log
  /// call has a non-trivial performance cost. Enable in development or
  /// when you need source info in production logs.
  final bool captureSourceLocation;

  /// Called when a [Handler]'s `isEnabled` or `handle` throws. The
  /// default prints a diagnostic to stdout so logging failures stay
  /// visible without crashing the host. Override to redirect to your
  /// own monitoring (Sentry, stderr, a fallback handler, etc.).
  final void Function(
    Handler handler,
    Object error,
    StackTrace stackTrace,
  ) onHandlerError;

  /// The global default configuration.
  static LogConfig global = LogConfig(handlers: [ConsoleHandler()]);

  /// Configure the global defaults. Call once at app startup.
  static void configure({
    List<Processor>? processors,
    List<Handler>? handlers,
    Map<String, Object?>? Function(Zone zone)? zoneAccessor,
    bool? captureSourceLocation,
    void Function(Handler handler, Object error, StackTrace stackTrace)?
        onHandlerError,
  }) {
    global = LogConfig(
      processors: processors ?? global.processors,
      handlers: handlers ?? global.handlers,
      zoneAccessor: zoneAccessor ?? global.zoneAccessor,
      captureSourceLocation:
          captureSourceLocation ?? global.captureSourceLocation,
      onHandlerError: onHandlerError ?? global.onHandlerError,
    );
  }

  /// Returns a copy of this config with the given fields replaced.
  ///
  /// Useful for deriving a per-logger config that overrides only some
  /// settings while inheriting the rest from another config:
  ///
  /// ```dart
  /// final hot = Logger('hot', config: LogConfig.global.copyWith(
  ///   processors: [sample(10)],
  /// ));
  /// // `hot` keeps the global's handlers, zoneAccessor, and
  /// // captureSourceLocation; overrides only processors.
  /// ```
  ///
  /// Passing `null` for a field (or omitting it) preserves the current
  /// value. There is no way to clear [zoneAccessor] back to `null`
  /// through this method — same limitation as [configure].
  LogConfig copyWith({
    List<Processor>? processors,
    List<Handler>? handlers,
    Map<String, Object?>? Function(Zone zone)? zoneAccessor,
    bool? captureSourceLocation,
    void Function(Handler handler, Object error, StackTrace stackTrace)?
        onHandlerError,
  }) {
    return LogConfig(
      processors: processors ?? this.processors,
      handlers: handlers ?? this.handlers,
      zoneAccessor: zoneAccessor ?? this.zoneAccessor,
      captureSourceLocation:
          captureSourceLocation ?? this.captureSourceLocation,
      onHandlerError: onHandlerError ?? this.onHandlerError,
    );
  }

  /// Reset global config to defaults.
  static void reset() {
    global = LogConfig(handlers: [ConsoleHandler()]);
  }

  /// Closes every handler in the current global config in parallel.
  ///
  /// Call at app shutdown to flush buffered records and release
  /// handler resources. Handlers inside a `MultiHandler` are closed
  /// transitively; per-logger configs (passed via `Logger('x',
  /// config: ...)`) are *not* affected — callers must close those
  /// themselves.
  static Future<void> shutdown() =>
      Future.wait(global.handlers.map((h) => h.close()));
}
