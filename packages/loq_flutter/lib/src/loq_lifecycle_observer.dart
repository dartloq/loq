import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/src/default_fields.dart';
import 'package:loq_flutter/src/lifecycle_event.dart';

/// A `WidgetsBindingObserver` wrapper that emits structured log
/// records on app lifecycle transitions, memory-pressure events, and
/// locale changes. Optionally flushes registered handlers on
/// `paused` / `detached` / memory-pressure events.
///
/// ```dart
/// final lifecycle = LoqLifecycleObserver();
///
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   lifecycle.install();
///   runApp(MyApp());
/// }
/// ```
///
/// `initLoq()` auto-installs an instance of this class by default;
/// users who want a custom instance can pass it via
/// `initLoq(..., lifecycleObserver: LoqLifecycleObserver(...))`.
///
/// On web, lifecycle states are emitted by Flutter but are unreliable
/// (`paused` / `detached` may not fire before the tab closes). The
/// observer still installs and emits, since lifecycle changes that DO
/// fire are still useful. Set [enabledOnWeb] to `false` to skip
/// registration entirely.
class LoqLifecycleObserver with WidgetsBindingObserver {
  /// Creates a lifecycle observer.
  ///
  /// [logger] is used to emit records. Defaults to a logger named
  /// `loq_flutter.lifecycle`.
  ///
  /// [level] is the default level for [AppLifecycleStateEvent] and
  /// [LocaleChangeEvent]. Override per-event through [levelResolver].
  ///
  /// [memoryPressureLevel] (default `Level.warn`) is the default
  /// level for [MemoryPressureEvent]. Override per-event through
  /// [levelResolver].
  ///
  /// [flushHandlers] is the list of handlers to flush on
  /// [flushOnPaused] / [flushOnDetached] / [flushOnHidden] /
  /// [flushOnMemoryPressure] transitions. When `null`, the observer
  /// reads `LogConfig.global.handlers` **at flush time** so
  /// reconfigures through `LogConfig.configure` are picked up.
  ///
  /// [flushOnPaused] (default `true`): flush on
  /// `AppLifecycleState.paused`. This is the "OS may suspend us soon"
  /// signal and the right place for last-chance writes.
  ///
  /// [flushOnDetached] (default `true`): flush on
  /// `AppLifecycleState.detached`. Best-effort: on iOS the OS may
  /// kill the process before this fires, so [flushOnPaused] is
  /// load-bearing.
  ///
  /// [flushOnHidden] (default `false`): flush on Flutter 3.13+
  /// `AppLifecycleState.hidden`. Off by default since the meaning
  /// still varies across platforms.
  ///
  /// [flushOnMemoryPressure] (default `true`): flush on
  /// `didHaveMemoryPressure`. The OS may kill the process next, so
  /// this is a high-priority flush.
  ///
  /// [enabledOnWeb] (default `true`): when `false`, [install] is a
  /// no-op on web (`kIsWeb`). Use this to skip lifecycle handling
  /// entirely for web builds.
  LoqLifecycleObserver({
    Logger? logger,
    this.level = Level.debug,
    this.memoryPressureLevel = Level.warn,
    List<Handler>? flushHandlers,
    this.flushOnPaused = true,
    this.flushOnDetached = true,
    this.flushOnHidden = false,
    this.flushOnMemoryPressure = true,
    this.enabledOnWeb = true,
    Map<String, Object?> Function(LifecycleEvent event)? fields,
    Level? Function(LifecycleEvent event)? levelResolver,
    String Function(LifecycleEvent event)? message,
  })  : _logger = logger ?? Logger('loq_flutter.lifecycle'),
        _explicitHandlers = flushHandlers,
        _fields = fields,
        _levelResolver = levelResolver,
        _message = message;

  final Logger _logger;
  final List<Handler>? _explicitHandlers;
  final Map<String, Object?> Function(LifecycleEvent event)? _fields;
  final Level? Function(LifecycleEvent event)? _levelResolver;
  final String Function(LifecycleEvent event)? _message;

  /// Default record level for [AppLifecycleStateEvent] and
  /// [LocaleChangeEvent]. May be overridden per-event by the
  /// resolver.
  final Level level;

  /// Default record level for [MemoryPressureEvent]. May be
  /// overridden per-event by the resolver.
  final Level memoryPressureLevel;

  /// Whether to flush handlers on `AppLifecycleState.paused`.
  final bool flushOnPaused;

  /// Whether to flush handlers on `AppLifecycleState.detached`.
  final bool flushOnDetached;

  /// Whether to flush handlers on `AppLifecycleState.hidden`.
  final bool flushOnHidden;

  /// Whether to flush handlers on memory-pressure events.
  final bool flushOnMemoryPressure;

  /// Whether [install] registers the observer on web (`kIsWeb`).
  final bool enabledOnWeb;

  AppLifecycleState? _previousState;
  List<Locale>? _previousLocales;
  DateTime? _pausedAt;
  bool _installed = false;

  /// The last observed lifecycle state, or `null` before any
  /// transition has been observed.
  AppLifecycleState? get previousState => _previousState;

  /// Whether [install] has registered this observer with
  /// `WidgetsBinding.instance`.
  bool get isInstalled => _installed;

  /// Register with `WidgetsBinding.instance.addObserver`. Call after
  /// `WidgetsFlutterBinding.ensureInitialized()`.
  ///
  /// Idempotent. Returns without registering on web if
  /// [enabledOnWeb] is `false`.
  void install() {
    if (_installed) return;
    // Dead-code-eliminated on non-web, so test runs can't reach it.
    if (kIsWeb && !enabledOnWeb) return; // coverage:ignore-line
    WidgetsBinding.instance.addObserver(this);
    _installed = true;
  }

  /// Unregister from `WidgetsBinding.instance`. Idempotent.
  void dispose() {
    if (!_installed) return;
    WidgetsBinding.instance.removeObserver(this);
    _installed = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previous = _previousState;
    // Compute background duration when leaving paused → resumed.
    Duration? backgroundDuration;
    if (state == AppLifecycleState.resumed && _pausedAt != null) {
      backgroundDuration = DateTime.now().difference(_pausedAt!);
    }
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _pausedAt = null;
    }

    final defaults = defaultLifecycleFields(
      state: state,
      previousState: previous,
      backgroundDuration: backgroundDuration,
    );
    final event = _buildStateEvent(state, previous, defaults);
    _previousState = state;

    _emit(event, _defaultStateMessage(state));

    if (_shouldFlushState(state)) {
      unawaited(_flushAll());
    }
  }

  @override
  void didHaveMemoryPressure() {
    final event = MemoryPressureEvent(
      defaults: defaultMemoryPressureFields(),
    );
    _emit(event, 'memory pressure', defaultLevel: memoryPressureLevel);
    if (flushOnMemoryPressure) {
      unawaited(_flushAll());
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    final previous = _previousLocales;
    final event = LocaleChangeEvent(
      locales: locales,
      previousLocales: previous,
      defaults: defaultLocaleChangeFields(
        locales: locales,
        previousLocales: previous,
      ),
    );
    _previousLocales = locales;
    _emit(event, 'locales changed');
  }

  AppLifecycleStateEvent _buildStateEvent(
    AppLifecycleState state,
    AppLifecycleState? previous,
    Map<String, Object?> defaults,
  ) =>
      switch (state) {
        AppLifecycleState.resumed =>
          AppResumedEvent(previousState: previous, defaults: defaults),
        AppLifecycleState.inactive =>
          AppInactiveEvent(previousState: previous, defaults: defaults),
        AppLifecycleState.hidden =>
          AppHiddenEvent(previousState: previous, defaults: defaults),
        AppLifecycleState.paused =>
          AppPausedEvent(previousState: previous, defaults: defaults),
        AppLifecycleState.detached =>
          AppDetachedEvent(previousState: previous, defaults: defaults),
      };

  String _defaultStateMessage(AppLifecycleState state) => switch (state) {
        AppLifecycleState.resumed => 'app resumed',
        AppLifecycleState.inactive => 'app inactive',
        AppLifecycleState.hidden => 'app hidden',
        AppLifecycleState.paused => 'app paused',
        AppLifecycleState.detached => 'app detached',
      };

  bool _shouldFlushState(AppLifecycleState state) => switch (state) {
        AppLifecycleState.paused => flushOnPaused,
        AppLifecycleState.detached => flushOnDetached,
        AppLifecycleState.hidden => flushOnHidden,
        AppLifecycleState.resumed || AppLifecycleState.inactive => false,
      };

  void _emit(
    LifecycleEvent event,
    String defaultMessage, {
    Level? defaultLevel,
  }) {
    final eventLevel = _levelResolver?.call(event) ?? defaultLevel ?? level;
    final eventMessage = _message?.call(event) ?? defaultMessage;
    final eventFields = _fields?.call(event) ?? event.defaults;
    _logger.log(eventLevel, eventMessage, fields: eventFields);
  }

  Future<void> _flushAll() async {
    final handlers = _explicitHandlers ?? LogConfig.global.handlers;
    final onError = LogConfig.global.onHandlerError;
    await Future.wait(
      handlers.map((h) async {
        try {
          await h.flush();
          // Containment: a misbehaving handler must not break the
          // flush sequence for sibling handlers or the host.
          // ignore: avoid_catches_without_on_clauses
        } catch (e, st) {
          onError(h, e, st);
        }
      }),
    );
  }
}
