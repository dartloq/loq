import 'package:flutter/widgets.dart';

/// Base class for events emitted by `LoqLifecycleObserver`.
///
/// Three families live under this sealed hierarchy:
///
/// - [AppLifecycleStateEvent] (and its concrete subclasses
///   [AppResumedEvent], [AppInactiveEvent], [AppHiddenEvent],
///   [AppPausedEvent], [AppDetachedEvent]): wraps Flutter's
///   `AppLifecycleState` events.
/// - [MemoryPressureEvent]: fires when the OS signals memory
///   pressure (`WidgetsBindingObserver.didHaveMemoryPressure`).
/// - [LocaleChangeEvent]: fires when the system locale list
///   changes (`WidgetsBindingObserver.didChangeLocales`).
///
/// Hooks pattern-match on the typed event:
///
/// ```dart
/// fields: (event) => switch (event) {
///   AppLifecycleStateEvent(:final state)
///       when state == AppLifecycleState.paused =>
///         {...event.defaults, 'critical': true},
///   MemoryPressureEvent() =>
///       {...event.defaults, 'critical': true},
///   LocaleChangeEvent() ||
///   AppLifecycleStateEvent() =>
///       event.defaults,
/// },
/// ```
sealed class LifecycleEvent {
  const LifecycleEvent();

  /// The fields the observer would emit without any user
  /// transformation. The hook can spread these (`...event.defaults`)
  /// to compose, return a different map to replace, or filter to drop
  /// individual fields.
  Map<String, Object?> get defaults;
}

/// An event from Flutter's `AppLifecycleState`. One of
/// [AppResumedEvent], [AppInactiveEvent], [AppHiddenEvent],
/// [AppPausedEvent], or [AppDetachedEvent].
///
/// Pattern-match on the intermediate type to treat all five
/// uniformly:
///
/// ```dart
/// fields: (event) => switch (event) {
///   AppLifecycleStateEvent(:final state) =>
///       {...event.defaults, 'short': state.name},
///   _ => event.defaults,
/// },
/// ```
sealed class AppLifecycleStateEvent extends LifecycleEvent {
  const AppLifecycleStateEvent();

  /// The lifecycle state this event represents.
  AppLifecycleState get state;

  /// The state the app was in before this transition, or `null` if no
  /// transition has been observed yet (i.e. this is the first
  /// lifecycle event since the observer was installed).
  AppLifecycleState? get previousState;
}

/// App returning to the foreground and able to render.
final class AppResumedEvent extends AppLifecycleStateEvent {
  /// Creates a resumed event. Constructed by `LoqLifecycleObserver`;
  /// users receive instances in hook callbacks.
  const AppResumedEvent({
    required AppLifecycleState? previousState,
    required Map<String, Object?> defaults,
  })  : _previousState = previousState,
        _defaults = defaults;

  final AppLifecycleState? _previousState;
  final Map<String, Object?> _defaults;

  @override
  AppLifecycleState get state => AppLifecycleState.resumed;

  @override
  AppLifecycleState? get previousState => _previousState;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// App is losing or has lost focus but is still visible (e.g.
/// incoming call, Control Center on iOS, brief system alerts).
final class AppInactiveEvent extends AppLifecycleStateEvent {
  /// Creates an inactive event. Constructed by `LoqLifecycleObserver`;
  /// users receive instances in hook callbacks.
  const AppInactiveEvent({
    required AppLifecycleState? previousState,
    required Map<String, Object?> defaults,
  })  : _previousState = previousState,
        _defaults = defaults;

  final AppLifecycleState? _previousState;
  final Map<String, Object?> _defaults;

  @override
  AppLifecycleState get state => AppLifecycleState.inactive;

  @override
  AppLifecycleState? get previousState => _previousState;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// App is hidden (Flutter 3.13+). On desktop, fires when the window is
/// occluded or minimised. On mobile, sits between `inactive` and
/// `paused`.
final class AppHiddenEvent extends AppLifecycleStateEvent {
  /// Creates a hidden event. Constructed by `LoqLifecycleObserver`;
  /// users receive instances in hook callbacks.
  const AppHiddenEvent({
    required AppLifecycleState? previousState,
    required Map<String, Object?> defaults,
  })  : _previousState = previousState,
        _defaults = defaults;

  final AppLifecycleState? _previousState;
  final Map<String, Object?> _defaults;

  @override
  AppLifecycleState get state => AppLifecycleState.hidden;

  @override
  AppLifecycleState? get previousState => _previousState;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// App is backgrounded and not running. On iOS this fires when the
/// app transitions to background; on Android when `onStop` is called.
/// This is the right signal to flush pending writes. The OS may
/// suspend us soon.
final class AppPausedEvent extends AppLifecycleStateEvent {
  /// Creates a paused event. Constructed by `LoqLifecycleObserver`;
  /// users receive instances in hook callbacks.
  const AppPausedEvent({
    required AppLifecycleState? previousState,
    required Map<String, Object?> defaults,
  })  : _previousState = previousState,
        _defaults = defaults;

  final AppLifecycleState? _previousState;
  final Map<String, Object?> _defaults;

  @override
  AppLifecycleState get state => AppLifecycleState.paused;

  @override
  AppLifecycleState? get previousState => _previousState;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// App engine has been detached from the view hierarchy. May not fire
/// on iOS if the OS kills the process; treat `paused` as the
/// last-chance signal.
final class AppDetachedEvent extends AppLifecycleStateEvent {
  /// Creates a detached event. Constructed by `LoqLifecycleObserver`;
  /// users receive instances in hook callbacks.
  const AppDetachedEvent({
    required AppLifecycleState? previousState,
    required Map<String, Object?> defaults,
  })  : _previousState = previousState,
        _defaults = defaults;

  final AppLifecycleState? _previousState;
  final Map<String, Object?> _defaults;

  @override
  AppLifecycleState get state => AppLifecycleState.detached;

  @override
  AppLifecycleState? get previousState => _previousState;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// The OS signalled memory pressure
/// (`WidgetsBindingObserver.didHaveMemoryPressure`). iOS fires this
/// on a memory warning; Android on `onTrimMemory`. A strong "we may
/// be killed soon" signal: `LoqLifecycleObserver` flushes registered
/// handlers on this event by default.
final class MemoryPressureEvent extends LifecycleEvent {
  /// Creates a memory-pressure event. Constructed by
  /// `LoqLifecycleObserver`; users receive instances in hook
  /// callbacks.
  const MemoryPressureEvent({
    required Map<String, Object?> defaults,
  }) : _defaults = defaults;

  final Map<String, Object?> _defaults;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// The system locale list changed
/// (`WidgetsBindingObserver.didChangeLocales`). Useful for diagnosing
/// locale-sensitive bugs ("user switched from en to es and we
/// crashed").
final class LocaleChangeEvent extends LifecycleEvent {
  /// Creates a locale-change event. Constructed by
  /// `LoqLifecycleObserver`; users receive instances in hook
  /// callbacks.
  const LocaleChangeEvent({
    required this.locales,
    required this.previousLocales,
    required Map<String, Object?> defaults,
  }) : _defaults = defaults;

  /// The new locale preference list. Flutter's
  /// `WidgetsBindingObserver.didChangeLocales` may report this as
  /// `null`.
  final List<Locale>? locales;

  /// The locale preference list before this change, or `null` if no
  /// prior locale list has been observed.
  final List<Locale>? previousLocales;

  final Map<String, Object?> _defaults;

  @override
  Map<String, Object?> get defaults => _defaults;
}
