import 'package:flutter/foundation.dart';

/// Base class for error events emitted by `initLoq`'s error-capture
/// integrations.
///
/// Hooks receive one of the concrete subclasses
/// ([FlutterFrameworkErrorEvent], [PlatformDispatcherErrorEvent],
/// [ZoneGuardErrorEvent]) and can branch on it with an exhaustive
/// `switch`:
///
/// ```dart
/// errorFields: (event) => switch (event) {
///   FlutterFrameworkErrorEvent(:final details) =>
///       {...event.defaults, 'library': details.library},
///   PlatformDispatcherErrorEvent() ||
///   ZoneGuardErrorEvent() =>
///       event.defaults,
/// },
/// ```
sealed class ErrorEvent {
  const ErrorEvent();

  /// The thrown error or exception.
  Object get error;

  /// The captured stack trace.
  StackTrace get stackTrace;

  /// Whether some upstream handler already considers this error
  /// handled. For [FlutterFrameworkErrorEvent] this is always `false`
  /// (Flutter only fires `FlutterError.onError` for unhandled
  /// errors). For [PlatformDispatcherErrorEvent] this reflects the
  /// previously-installed `PlatformDispatcher.onError` callback's
  /// return value. For [ZoneGuardErrorEvent] this is always `true`
  /// (`runZonedGuarded` only fires for caught errors).
  bool get handled;

  /// The fields the integration would emit without any user
  /// transformation. The hook can spread these (`...event.defaults`)
  /// to compose, return a different map to replace, or filter to drop
  /// individual fields.
  Map<String, Object?> get defaults;
}

/// An error caught by `FlutterError.onError`. Usually widget build,
/// layout, or paint errors raised by the Flutter framework.
final class FlutterFrameworkErrorEvent extends ErrorEvent {
  /// Creates a Flutter framework error event. Constructed by
  /// `initLoq`'s integration; users receive instances in hook
  /// callbacks.
  const FlutterFrameworkErrorEvent({
    required this.details,
    required Map<String, Object?> defaults,
  }) : _defaults = defaults;

  /// The full Flutter error details, including `library`, `context`,
  /// `silent`, and `informationCollector`.
  final FlutterErrorDetails details;

  final Map<String, Object?> _defaults;

  @override
  Object get error => details.exception;

  @override
  StackTrace get stackTrace => details.stack ?? StackTrace.empty;

  @override
  bool get handled => false;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// An error caught by `PlatformDispatcher.instance.onError`: async
/// errors raised in the engine that don't go through `FlutterError`.
final class PlatformDispatcherErrorEvent extends ErrorEvent {
  /// Creates a platform-dispatcher error event. Constructed by
  /// `initLoq`'s integration; users receive instances in hook
  /// callbacks.
  const PlatformDispatcherErrorEvent({
    required Object error,
    required StackTrace stackTrace,
    required bool handled,
    required Map<String, Object?> defaults,
  })  : _error = error,
        _stackTrace = stackTrace,
        _handled = handled,
        _defaults = defaults;

  final Object _error;
  final StackTrace _stackTrace;
  final bool _handled;
  final Map<String, Object?> _defaults;

  @override
  Object get error => _error;

  @override
  StackTrace get stackTrace => _stackTrace;

  /// Reflects the previously-installed `PlatformDispatcher.onError`'s
  /// return value (if any). Defaults to `false` when no previous
  /// handler was installed.
  @override
  bool get handled => _handled;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// An error captured by the `runZonedGuarded` wrapper around the
/// user's `runApp` body.
final class ZoneGuardErrorEvent extends ErrorEvent {
  /// Creates a zone-guard error event. Constructed by `initLoq`'s
  /// integration; users receive instances in hook callbacks.
  const ZoneGuardErrorEvent({
    required Object error,
    required StackTrace stackTrace,
    required Map<String, Object?> defaults,
  })  : _error = error,
        _stackTrace = stackTrace,
        _defaults = defaults;

  final Object _error;
  final StackTrace _stackTrace;
  final Map<String, Object?> _defaults;

  @override
  Object get error => _error;

  @override
  StackTrace get stackTrace => _stackTrace;

  @override
  bool get handled => true;

  @override
  Map<String, Object?> get defaults => _defaults;
}
