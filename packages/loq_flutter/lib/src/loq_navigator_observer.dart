import 'package:flutter/widgets.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/src/default_fields.dart';
import 'package:loq_flutter/src/navigation_event.dart';

/// A `NavigatorObserver` that emits structured log records on every
/// route transition and tracks the current screen as instance state.
///
/// ```dart
/// final navObserver = LoqNavigatorObserver();
///
/// void main() {
///   LogConfig.configure(
///     processors: [navObserver.screenFieldsProcessor],
///     handlers: [JsonHandler()],
///   );
///   runApp(MyApp(navObserver: navObserver));
/// }
///
/// // MyApp passes navObserver into MaterialApp.navigatorObservers,
/// // GoRouter(observers: [...]), or AutoRouter(navigatorObservers:
/// // () => [...]).
/// ```
///
/// Defaults to tracking `PageRoute<dynamic>` only. Dialogs, modals,
/// and other non-page routes don't appear in the log stream and don't
/// update `currentScreen`. Pass `includeNonPageRoutes: true` for full
/// coverage.
class LoqNavigatorObserver extends NavigatorObserver {
  /// Creates a navigator observer.
  ///
  /// [logger] is used to emit records. Defaults to a logger named
  /// `loq_flutter.navigator`.
  ///
  /// [level] is the default level for every navigation event. Override
  /// per-event through [levelResolver].
  ///
  /// [includeNonPageRoutes] (default `false`) toggles whether non-page
  /// routes (dialogs, modals, popups) emit log records. Off by default
  /// to keep the stream readable. `currentScreen` is always
  /// `PageRoute`-only regardless of this flag. Non-page routes never
  /// update the perceived-screen state.
  ///
  /// [nameResolver] extracts a screen name from a `Route`. Defaults to
  /// [defaultScreenNameResolver] (`route.settings.name` then
  /// `route.runtimeType.toString()`). Override for go_router or
  /// auto_route, which often leave `settings.name` null.
  ///
  /// [skipLog] drops the log for matching events. State tracking
  /// (`currentScreen`, `previousScreen`, the internal page stack)
  /// still updates; only the emission is suppressed. The `Log` suffix
  /// mirrors `loq_drift`'s narrower `skipLog` to flag scope vs.
  /// `loq_shelf`'s `skip`, which bypasses a whole middleware.
  ///
  /// [fields] is a single transformation hook for the record's
  /// fields. Spread `...event.defaults` to compose or return a
  /// different map to replace.
  ///
  /// [levelResolver] overrides the level per event. Returning `null`
  /// falls back to [level].
  ///
  /// [message] overrides the record message per event.
  LoqNavigatorObserver({
    Logger? logger,
    this.level = Level.debug,
    this.includeNonPageRoutes = false,
    String? Function(Route<dynamic>)? nameResolver,
    bool Function(NavigationEvent event)? skipLog,
    Map<String, Object?> Function(NavigationEvent event)? fields,
    Level? Function(NavigationEvent event)? levelResolver,
    String Function(NavigationEvent event)? message,
  })  : _logger = logger ?? Logger('loq_flutter.navigator'),
        _nameResolver = nameResolver ?? defaultScreenNameResolver,
        _skipLog = skipLog,
        _fields = fields,
        _levelResolver = levelResolver,
        _message = message;

  final Logger _logger;
  final String? Function(Route<dynamic>) _nameResolver;
  final bool Function(NavigationEvent event)? _skipLog;
  final Map<String, Object?> Function(NavigationEvent event)? _fields;
  final Level? Function(NavigationEvent event)? _levelResolver;
  final String Function(NavigationEvent event)? _message;

  /// Default record level. May be overridden by [_levelResolver].
  final Level level;

  /// Whether non-`PageRoute` transitions emit log records.
  final bool includeNonPageRoutes;

  // Internal page-route stack. Holds only PageRoutes since dialogs /
  // modals don't change perceived screen state.
  final List<Route<dynamic>> _pageStack = [];

  String? _previousScreen;

  /// The current screen name (top of the page-route stack).
  ///
  /// Returns `null` before any `PageRoute` has been observed, or after
  /// all page routes have been popped.
  String? get currentScreen {
    if (_pageStack.isEmpty) return null;
    return _nameResolver(_pageStack.last);
  }

  /// The screen the user was on immediately before the most recent
  /// transition. `null` until at least one transition has been observed.
  String? get previousScreen => _previousScreen;

  /// A [Processor] that adds `app.screen.name` and
  /// `loq.app.screen.previous_name` to every record sourced from this
  /// observer's tracked state. `app.screen.name` matches OTel's
  /// Development-status attribute; the previous-name companion lives
  /// under the `loq.*` namespace because OTel doesn't standardize it.
  ///
  /// Existing values are not overwritten. Records that already carry
  /// either field (the observer's own navigation logs, or user-set
  /// fields) pass through unchanged.
  ///
  /// ```dart
  /// LogConfig.configure(
  ///   processors: [navObserver.screenFieldsProcessor],
  /// );
  /// ```
  Processor get screenFieldsProcessor => (record) {
        final current = currentScreen;
        final previous = _previousScreen;
        final hasCurrent = record.fields.containsKey('app.screen.name');
        final hasPrevious =
            record.fields.containsKey('loq.app.screen.previous_name');
        final additions = <String, Object?>{};
        if (!hasCurrent && current != null) {
          additions['app.screen.name'] = current;
        }
        if (!hasPrevious && previous != null) {
          additions['loq.app.screen.previous_name'] = previous;
        }
        if (additions.isEmpty) return record;
        return record.withFields(additions);
      };

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final isPage = route is PageRoute;
    if (isPage) {
      _previousScreen =
          _pageStack.isEmpty ? null : _nameResolver(_pageStack.last);
      _pageStack.add(route);
    }
    if (!isPage && !includeNonPageRoutes) return;
    final event = NavigationPushEvent(
      route: route,
      previousRoute: previousRoute,
      defaults: defaultNavigationFields(
        kind: 'push',
        route: route,
        previousRoute: previousRoute,
        nameResolver: _nameResolver,
      ),
    );
    _emit(event, 'navigation push');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final isPage = route is PageRoute;
    if (isPage) {
      _previousScreen = _nameResolver(route);
      _pageStack.remove(route);
    }
    if (!isPage && !includeNonPageRoutes) return;
    final event = NavigationPopEvent(
      route: route,
      previousRoute: previousRoute,
      defaults: defaultNavigationFields(
        kind: 'pop',
        route: route,
        previousRoute: previousRoute,
        nameResolver: _nameResolver,
      ),
    );
    _emit(event, 'navigation pop');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    // We update the stack when *either* route is a page route and
    // currently tracked. A non-page replacement of a page route, or a
    // page replacement of a non-page route, both surface in the stack
    // here.
    final oldIsTrackedPage = oldRoute != null && _pageStack.contains(oldRoute);
    final newIsPage = newRoute is PageRoute;
    if (oldIsTrackedPage) {
      _previousScreen = _nameResolver(oldRoute);
      final index = _pageStack.indexOf(oldRoute);
      if (newIsPage) {
        _pageStack[index] = newRoute;
      } else {
        _pageStack.removeAt(index);
      }
    } else if (newIsPage) {
      _previousScreen =
          _pageStack.isEmpty ? null : _nameResolver(_pageStack.last);
      _pageStack.add(newRoute);
    }
    final shouldEmit = oldIsTrackedPage || newIsPage || includeNonPageRoutes;
    if (!shouldEmit) return;
    final event = NavigationReplaceEvent(
      newRoute: newRoute,
      oldRoute: oldRoute,
      defaults: defaultNavigationFields(
        kind: 'replace',
        route: newRoute,
        previousRoute: oldRoute,
        nameResolver: _nameResolver,
      ),
    );
    _emit(event, 'navigation replace');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final isPage = route is PageRoute;
    final wasTracked = _pageStack.contains(route);
    if (isPage && wasTracked) {
      _previousScreen = _nameResolver(route);
      _pageStack.remove(route);
    }
    if (!isPage && !includeNonPageRoutes) return;
    final event = NavigationRemoveEvent(
      route: route,
      previousRoute: previousRoute,
      defaults: defaultNavigationFields(
        kind: 'remove',
        route: route,
        previousRoute: previousRoute,
        nameResolver: _nameResolver,
      ),
    );
    _emit(event, 'navigation remove');
  }

  void _emit(NavigationEvent event, String defaultMessage) {
    if (_skipLog != null && _skipLog(event)) return;
    final eventLevel = _levelResolver?.call(event) ?? level;
    final eventMessage = _message?.call(event) ?? defaultMessage;
    final eventFields = _fields?.call(event) ?? event.defaults;
    _logger.log(eventLevel, eventMessage, fields: eventFields);
  }
}
