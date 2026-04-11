import 'dart:async';

import 'package:loq/src/console_handler.dart';
import 'package:loq/src/handler.dart';
import 'package:loq/src/source_location.dart';

/// Global and per-logger configuration.
class LogConfig {
  /// Creates a configuration.
  const LogConfig({
    this.processors = const [],
    this.handlers = const [],
    this.zoneAccessor,
    this.captureSourceLocation = false,
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

  /// The global default configuration.
  static LogConfig global = LogConfig(handlers: [ConsoleHandler()]);

  /// Configure the global defaults. Call once at app startup.
  static void configure({
    List<Processor>? processors,
    List<Handler>? handlers,
    Map<String, Object?>? Function(Zone zone)? zoneAccessor,
    bool? captureSourceLocation,
  }) {
    global = LogConfig(
      processors: processors ?? global.processors,
      handlers: handlers ?? global.handlers,
      zoneAccessor: zoneAccessor ?? global.zoneAccessor,
      captureSourceLocation:
          captureSourceLocation ?? global.captureSourceLocation,
    );
  }

  /// Reset global config to defaults.
  static void reset() {
    global = LogConfig(handlers: [ConsoleHandler()]);
  }
}
