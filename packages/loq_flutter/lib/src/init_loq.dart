import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/src/default_fields.dart';
import 'package:loq_flutter/src/error_event.dart';
import 'package:loq_flutter/src/loq_lifecycle_observer.dart';

/// One-call entry point for loq's Flutter setup.
///
/// Wires `FlutterError.onError`, `PlatformDispatcher.instance.onError`,
/// and `runZonedGuarded` so uncaught errors flow through loq. Uses
/// **chain-and-restore** semantics on the two global handler slots
/// (`FlutterError.onError`, `PlatformDispatcher.onError`) so the
/// wrapper lives alongside other packages that touch the same slots
/// (Crashlytics, Sentry, and so on).
///
/// A **bounded LRU hash queue** dedupes errors caught by more than
/// one path. For example, an exception flowing through both
/// `PlatformDispatcher.onError` and `runZonedGuarded` emits a single
/// record.
///
/// ```dart
/// final navObserver = LoqNavigatorObserver();
///
/// Future<void> main() async {
///   await initLoq(() {
///     WidgetsFlutterBinding.ensureInitialized();
///     LogConfig.configure(
///       processors: [navObserver.screenFieldsProcessor],
///       handlers: [JsonHandler()],
///     );
///     runApp(MyApp(navObserver: navObserver));
///   });
/// }
/// ```
///
/// **Install order matters when pairing with handler-replacing
/// packages.** Crashlytics's recommended setup replaces
/// `FlutterError.onError` and `PlatformDispatcher.onError` without
/// saving the previous handler. Call `initLoq()` *after* Firebase /
/// Crashlytics setup so its chain-and-restore can pick up
/// Crashlytics's handler as the chained "previous". Calling
/// `initLoq()` first means Crashlytics will overwrite our handler.
///
/// Returns a `Future<void>` that completes after [body] completes and
/// the lifecycle observer (if any) has been installed. Awaiting is
/// optional: `void main() => initLoq(...)` works for fire-and-forget.
Future<void> initLoq(
  FutureOr<void> Function() body, {
  // Setup.
  LogConfig? config,
  Logger? errorLogger,
  bool? captureSourceLocation,
  // Behavior.
  Level errorLevel = Level.fatal,
  bool wireFlutterErrors = true,
  bool wirePlatformDispatcher = true,
  bool wireZoneGuard = true,
  bool installLifecycleObserver = true,
  LoqLifecycleObserver? lifecycleObserver,
  bool reportSilentFlutterErrors = false,
  bool redirectFlutterDebugPrint = false,
  Logger? flutterDebugLogger,
  Level flutterDebugLevel = Level.debug,
  // Hooks.
  Map<String, Object?> Function(ErrorEvent event)? errorFields,
  String Function(ErrorEvent event)? message,
}) async {
  if (config != null) {
    LogConfig.configure(
      processors: config.processors,
      handlers: config.handlers,
      zoneAccessor: config.zoneAccessor,
      captureSourceLocation:
          captureSourceLocation ?? config.captureSourceLocation,
      onHandlerError: config.onHandlerError,
    );
  } else if (captureSourceLocation != null) {
    LogConfig.configure(captureSourceLocation: captureSourceLocation);
  }

  final state = LoqErrorState(
    logger: errorLogger ?? Logger('loq_flutter.error'),
    level: errorLevel,
    reportSilentFlutterErrors: reportSilentFlutterErrors,
    fields: errorFields,
    message: message,
  );

  if (wireFlutterErrors) state.installFlutterError();
  if (wirePlatformDispatcher) state.installPlatformDispatcher();
  if (redirectFlutterDebugPrint) {
    state.installDebugPrintRedirect(
      logger: flutterDebugLogger ?? Logger('loq_flutter.debug_print'),
      level: flutterDebugLevel,
    );
  }

  if (wireZoneGuard) {
    await _runGuarded(body, state);
  } else {
    await body();
  }

  if (installLifecycleObserver) {
    (lifecycleObserver ?? LoqLifecycleObserver()).install();
  }
}

Future<void> _runGuarded(
  FutureOr<void> Function() body,
  LoqErrorState state,
) {
  // A Completer is the only deterministic way to signal body completion
  // when body might throw: runZonedGuarded's zone-caught errors leave
  // the body's Future in a state that never satisfies an awaiting
  // listener. The inner try/catch routes body errors to dedup before
  // any escape; the outer zone handler still catches anything that
  // slips past (e.g. detached Futures created inside body that error
  // later). The dedup queue keeps both paths from double-emitting.
  final completer = Completer<void>();
  // The runZonedGuarded call below returns the body's Future; we
  // intentionally drop it because the Completer above is the
  // signalling path.
  // ignore: discarded_futures
  runZonedGuarded(
    () async {
      try {
        await body();
        // Containment: surface body errors to the dedup-aware handler.
        // ignore: avoid_catches_without_on_clauses
      } catch (e, st) {
        state.handleZoneGuard(e, st);
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    },
    state.handleZoneGuard,
  );
  return completer.future;
}

/// Visible-for-testing internal state shared across error
/// integrations. Public so tests can drive it without spinning up
/// `initLoq`; not exported from the package's public library.
@visibleForTesting
class LoqErrorState {
  /// Creates the shared state. Tests inject a logger; production code
  /// goes through `initLoq`.
  LoqErrorState({
    required this.logger,
    required this.level,
    required this.reportSilentFlutterErrors,
    Map<String, Object?> Function(ErrorEvent event)? fields,
    String Function(ErrorEvent event)? message,
  })  : _fields = fields,
        _message = message;

  /// Logger used for emitted error records.
  final Logger logger;

  /// Level used for emitted error records.
  final Level level;

  /// Whether to emit records for `FlutterErrorDetails.silent == true`.
  final bool reportSilentFlutterErrors;

  final Map<String, Object?> Function(ErrorEvent event)? _fields;
  final String Function(ErrorEvent event)? _message;

  /// Bounded LRU dedup queue keyed on
  /// `identityHashCode(error) ^ identityHashCode(stackTrace)`.
  /// Capacity is small on purpose. Multi-path captures usually fire
  /// within microseconds of each other.
  static const int _dedupCapacity = 16;
  final Queue<int> _dedupQueue = Queue<int>();
  final Set<int> _dedupSet = <int>{};

  FlutterExceptionHandler? _previousFlutterHandler;
  ErrorCallback? _previousPlatformHandler;
  DebugPrintCallback? _previousDebugPrint;
  Logger? _debugPrintLogger;
  Level? _debugPrintLevel;
  bool _flutterInstalled = false;
  bool _platformInstalled = false;
  bool _debugPrintInstalled = false;

  /// Process-wide reference to the [LoqErrorState] currently owning
  /// `FlutterError.onError`, or `null` if no instance has installed
  /// it. Used to unwind on hot reload: a second `initLoq` call
  /// disposes the prior owner first so we chain to the real
  /// original handler, not our own wrapper.
  static LoqErrorState? _currentFlutterErrorOwner;

  /// Same idea for `PlatformDispatcher.instance.onError`.
  static LoqErrorState? _currentPlatformOwner;

  /// Same idea for the global `debugPrint` function.
  static LoqErrorState? _currentDebugPrintOwner;

  /// Install [FlutterError.onError], chaining to any previous
  /// handler. Idempotent for the current instance; if a previous
  /// [LoqErrorState] instance already owns the slot (hot reload
  /// re-running `initLoq`), it is disposed first so the chain stays
  /// flat instead of growing one level per reload.
  void installFlutterError() {
    if (_flutterInstalled) return;
    final priorOwner = _currentFlutterErrorOwner;
    if (priorOwner != null && priorOwner != this) {
      priorOwner._disposeFlutterError();
    }
    _previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = _handleFlutterError;
    _flutterInstalled = true;
    _currentFlutterErrorOwner = this;
  }

  /// Install `PlatformDispatcher.instance.onError`, chaining to any
  /// previous handler. Same hot-reload unwinding as
  /// [installFlutterError].
  void installPlatformDispatcher() {
    if (_platformInstalled) return;
    final priorOwner = _currentPlatformOwner;
    if (priorOwner != null && priorOwner != this) {
      priorOwner._disposePlatformDispatcher();
    }
    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = _handlePlatformDispatcher;
    _platformInstalled = true;
    _currentPlatformOwner = this;
  }

  /// Replace the global `debugPrint` so Flutter framework output
  /// (layout warnings, asset chatter, `FlutterError.dumpErrorToConsole`
  /// output, and so on) flows into [logger] at [level].
  ///
  /// Hot-reload-safe like the error-handler installers: a prior
  /// owner is disposed first so the chain stays flat.
  void installDebugPrintRedirect({
    required Logger logger,
    required Level level,
  }) {
    if (_debugPrintInstalled) return;
    final priorOwner = _currentDebugPrintOwner;
    if (priorOwner != null && priorOwner != this) {
      priorOwner._disposeDebugPrint();
    }
    _previousDebugPrint = debugPrint;
    _debugPrintLogger = logger;
    _debugPrintLevel = level;
    debugPrint = _handleDebugPrint;
    _debugPrintInstalled = true;
    _currentDebugPrintOwner = this;
  }

  /// Restore the previously-installed handlers. Used in tests; not
  /// publicly surfaced through `initLoq` since process-lifetime
  /// teardown is the typical case.
  void dispose() {
    _disposeFlutterError();
    _disposePlatformDispatcher();
    _disposeDebugPrint();
  }

  void _disposeFlutterError() {
    if (!_flutterInstalled) return;
    if (FlutterError.onError == _handleFlutterError) {
      FlutterError.onError = _previousFlutterHandler;
    }
    _flutterInstalled = false;
    if (identical(_currentFlutterErrorOwner, this)) {
      _currentFlutterErrorOwner = null;
    }
  }

  void _disposePlatformDispatcher() {
    if (!_platformInstalled) return;
    if (PlatformDispatcher.instance.onError == _handlePlatformDispatcher) {
      PlatformDispatcher.instance.onError = _previousPlatformHandler;
    }
    _platformInstalled = false;
    if (identical(_currentPlatformOwner, this)) {
      _currentPlatformOwner = null;
    }
  }

  void _disposeDebugPrint() {
    if (!_debugPrintInstalled) return;
    if (debugPrint == _handleDebugPrint) {
      debugPrint = _previousDebugPrint ?? debugPrintThrottled;
    }
    _debugPrintInstalled = false;
    _debugPrintLogger = null;
    _debugPrintLevel = null;
    if (identical(_currentDebugPrintOwner, this)) {
      _currentDebugPrintOwner = null;
    }
  }

  void _handleDebugPrint(String? message, {int? wrapWidth}) {
    if (message != null && _debugPrintLogger != null) {
      _debugPrintLogger!.log(_debugPrintLevel!, message);
    }
  }

  void _handleFlutterError(FlutterErrorDetails details) {
    if (!reportSilentFlutterErrors && details.silent) {
      _previousFlutterHandler?.call(details);
      return;
    }
    if (_admit(details.exception, details.stack)) {
      final event = FlutterFrameworkErrorEvent(
        details: details,
        defaults: defaultErrorFields(
          error: details.exception,
          stackTrace: details.stack ?? StackTrace.empty,
          source: 'flutter_framework',
          handled: false,
          flutterDetails: details,
        ),
      );
      _emit(event, 'flutter framework error');
    }
    _previousFlutterHandler?.call(details);
  }

  bool _handlePlatformDispatcher(Object error, StackTrace stack) {
    final previousHandled =
        _previousPlatformHandler?.call(error, stack) ?? false;
    if (_admit(error, stack)) {
      final event = PlatformDispatcherErrorEvent(
        error: error,
        stackTrace: stack,
        handled: previousHandled,
        defaults: defaultErrorFields(
          error: error,
          stackTrace: stack,
          source: 'platform_dispatcher',
          handled: previousHandled,
        ),
      );
      _emit(event, 'platform dispatcher error');
    }
    return previousHandled;
  }

  /// Public for use as the second arg to `runZonedGuarded`.
  void handleZoneGuard(Object error, StackTrace stack) {
    if (!_admit(error, stack)) return;
    final event = ZoneGuardErrorEvent(
      error: error,
      stackTrace: stack,
      defaults: defaultErrorFields(
        error: error,
        stackTrace: stack,
        source: 'zone_guard',
        handled: true,
      ),
    );
    _emit(event, 'zone guard error');
  }

  bool _admit(Object error, StackTrace? stack) {
    final hash = identityHashCode(error) ^ identityHashCode(stack);
    if (_dedupSet.contains(hash)) return false;
    _dedupSet.add(hash);
    _dedupQueue.add(hash);
    if (_dedupQueue.length > _dedupCapacity) {
      _dedupSet.remove(_dedupQueue.removeFirst());
    }
    return true;
  }

  void _emit(ErrorEvent event, String defaultMessage) {
    final eventMessage = _message?.call(event) ?? defaultMessage;
    final eventFields = _fields?.call(event) ?? event.defaults;
    logger.log(
      level,
      eventMessage,
      error: event.error,
      stackTrace: event.stackTrace,
      fields: eventFields,
    );
  }
}
