import 'package:flutter/widgets.dart';

/// Base class for events emitted by `LoqNavigatorObserver`.
///
/// Hooks receive one of the concrete subclasses ([NavigationPushEvent],
/// [NavigationPopEvent], [NavigationReplaceEvent],
/// [NavigationRemoveEvent]) and branch on it with an exhaustive
/// `switch`:
///
/// ```dart
/// fields: (event) => switch (event) {
///   NavigationPushEvent(:final route) =>
///       {...event.defaults, 'pushed': route.settings.name},
///   NavigationPopEvent() =>
///       {...event.defaults, 'kind': 'pop'},
///   NavigationReplaceEvent() =>
///       {...event.defaults, 'kind': 'replace'},
///   NavigationRemoveEvent() =>
///       {...event.defaults, 'kind': 'remove'},
/// },
/// ```
sealed class NavigationEvent {
  const NavigationEvent();

  /// The subject route of this event:
  ///
  /// - [NavigationPushEvent.route]: the route just pushed onto the
  ///   stack.
  /// - [NavigationPopEvent.route]: the route just popped.
  /// - [NavigationReplaceEvent.route]: the new active route
  ///   (Flutter's `newRoute`); nullable since `Navigator.replace`
  ///   allows a null replacement.
  /// - [NavigationRemoveEvent.route]: the route just removed.
  Route<dynamic>? get route;

  /// The other route alongside [route]:
  ///
  /// - [NavigationPushEvent.previousRoute]: what was on top before.
  ///   Null on the first push.
  /// - [NavigationPopEvent.previousRoute]: what is on top now, after
  ///   the pop. Null when popping the last route.
  /// - [NavigationReplaceEvent.previousRoute]: the route that was
  ///   replaced (Flutter's `oldRoute`).
  /// - [NavigationRemoveEvent.previousRoute]: the route directly
  ///   below the removed route in the stack, per Flutter's docs.
  Route<dynamic>? get previousRoute;

  /// The fields the observer would emit without any user change.
  /// The hook can spread these (`...event.defaults`) to add to them,
  /// return a different map to replace them, or filter to drop
  /// individual fields.
  Map<String, Object?> get defaults;
}

/// A route push (`Navigator.push`, `Navigator.pushNamed`, etc.).
final class NavigationPushEvent extends NavigationEvent {
  /// Creates a push event. Constructed by `LoqNavigatorObserver`; users
  /// receive instances in hook callbacks.
  const NavigationPushEvent({
    required Route<dynamic> route,
    required Route<dynamic>? previousRoute,
    required Map<String, Object?> defaults,
  })  : _route = route,
        _previousRoute = previousRoute,
        _defaults = defaults;

  final Route<dynamic> _route;
  final Route<dynamic>? _previousRoute;
  final Map<String, Object?> _defaults;

  /// The newly pushed route. Always non-null for a push.
  @override
  Route<dynamic> get route => _route;

  @override
  Route<dynamic>? get previousRoute => _previousRoute;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// A route pop (`Navigator.pop`, system back gesture, etc.).
final class NavigationPopEvent extends NavigationEvent {
  /// Creates a pop event. Constructed by `LoqNavigatorObserver`; users
  /// receive instances in hook callbacks.
  const NavigationPopEvent({
    required Route<dynamic> route,
    required Route<dynamic>? previousRoute,
    required Map<String, Object?> defaults,
  })  : _route = route,
        _previousRoute = previousRoute,
        _defaults = defaults;

  final Route<dynamic> _route;
  final Route<dynamic>? _previousRoute;
  final Map<String, Object?> _defaults;

  /// The route that was just popped. Always non-null for a pop.
  @override
  Route<dynamic> get route => _route;

  @override
  Route<dynamic>? get previousRoute => _previousRoute;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// A route replacement (`Navigator.replace`, `Navigator.pushReplacement`).
final class NavigationReplaceEvent extends NavigationEvent {
  /// Creates a replace event. Constructed by `LoqNavigatorObserver`;
  /// users receive instances in hook callbacks.
  const NavigationReplaceEvent({
    required Route<dynamic>? newRoute,
    required Route<dynamic>? oldRoute,
    required Map<String, Object?> defaults,
  })  : _newRoute = newRoute,
        _oldRoute = oldRoute,
        _defaults = defaults;

  final Route<dynamic>? _newRoute;
  final Route<dynamic>? _oldRoute;
  final Map<String, Object?> _defaults;

  /// The new active route. Flutter's `NavigatorObserver.didReplace`
  /// signature permits null; in practice non-null.
  @override
  Route<dynamic>? get route => _newRoute;

  /// The route that was replaced. Flutter's signature permits null;
  /// in practice non-null.
  @override
  Route<dynamic>? get previousRoute => _oldRoute;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// A non-top route removal (`Navigator.removeRoute`,
/// `Navigator.removeRouteBelow`).
final class NavigationRemoveEvent extends NavigationEvent {
  /// Creates a remove event. Constructed by `LoqNavigatorObserver`;
  /// users receive instances in hook callbacks.
  const NavigationRemoveEvent({
    required Route<dynamic> route,
    required Route<dynamic>? previousRoute,
    required Map<String, Object?> defaults,
  })  : _route = route,
        _previousRoute = previousRoute,
        _defaults = defaults;

  final Route<dynamic> _route;
  final Route<dynamic>? _previousRoute;
  final Map<String, Object?> _defaults;

  /// The route that was removed. Always non-null for a remove.
  @override
  Route<dynamic> get route => _route;

  @override
  Route<dynamic>? get previousRoute => _previousRoute;

  @override
  Map<String, Object?> get defaults => _defaults;
}
