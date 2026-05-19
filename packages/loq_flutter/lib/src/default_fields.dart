import 'package:flutter/widgets.dart';
// Read by dartdoc so [MemoryPressureEvent] and [LocaleChangeEvent]
// resolve in the function docstrings below.
import 'package:loq_flutter/src/lifecycle_event.dart';

/// Default screen-name resolution: returns the route's
/// `settings.name` if non-null, otherwise the route's
/// `runtimeType.toString()`.
///
/// `LoqNavigatorObserver` calls this through its `nameResolver` chain
/// when the user hasn't supplied a custom one. Exported so callers
/// can layer their own resolver on top (for example with go_router or
/// auto_route, which often leave `settings.name` null).
String? defaultScreenNameResolver(Route<dynamic> route) =>
    route.settings.name ?? route.runtimeType.toString();

/// Builds the default field map for a navigation event.
///
/// Used by `LoqNavigatorObserver` to build the `defaults` map carried
/// on each `NavigationEvent`. Exported so callers can call it from
/// their own custom event paths (custom resolvers, hand-rolled
/// observers, and so on).
///
/// Keys produced:
///
/// - `app.screen.name`: current screen name via [nameResolver] of
///   [route], falling back to [defaultScreenNameResolver]. Matches
///   OTel's `app.screen.name` attribute (Development status).
/// - `loq.app.screen.previous_name`: same, applied to
///   [previousRoute]. Lives in the `loq.*` namespace because OTel
///   doesn't standardize previous-screen tracking.
/// - `loq.navigation.kind`: verbatim [kind] string (for example
///   `push`, `pop`).
/// - `loq.navigation.route_type`: `route.runtimeType.toString()` of
///   the subject route, when non-null.
/// - `loq.navigation.is_first_route`: `true` when [previousRoute] is
///   `null` (the first push, or the first observed route).
Map<String, Object?> defaultNavigationFields({
  required String kind,
  required Route<dynamic>? route,
  required Route<dynamic>? previousRoute,
  String? Function(Route<dynamic>)? nameResolver,
}) {
  final resolver = nameResolver ?? defaultScreenNameResolver;
  final screenName = route == null ? null : resolver(route);
  final previousName = previousRoute == null ? null : resolver(previousRoute);
  return <String, Object?>{
    'app.screen.name': screenName,
    'loq.app.screen.previous_name': previousName,
    'loq.navigation.kind': kind,
    'loq.navigation.route_type': route?.runtimeType.toString(),
    'loq.navigation.is_first_route': previousRoute == null,
  };
}

/// Builds the default field map for a lifecycle event.
///
/// Used by `LoqLifecycleObserver`. Exported so callers can call it
/// from their own custom event paths.
///
/// Keys produced (all under the `loq.*` namespace because OTel does
/// not currently standardize app-lifecycle attributes):
///
/// - `loq.app.lifecycle.state`: the short name of [state]
///   (`resumed`, `inactive`, `hidden`, `paused`, `detached`).
/// - `loq.app.lifecycle.previous_state`: same for [previousState],
///   or `null` if no previous state.
/// - `loq.app.background_duration_ms`: when [backgroundDuration] is
///   non-null, the wall-clock time the app spent paused before this
///   event. Set by `LoqLifecycleObserver` on resumed events.
Map<String, Object?> defaultLifecycleFields({
  required AppLifecycleState state,
  required AppLifecycleState? previousState,
  Duration? backgroundDuration,
}) {
  return <String, Object?>{
    'loq.app.lifecycle.state': _lifecycleStateName(state),
    'loq.app.lifecycle.previous_state':
        previousState == null ? null : _lifecycleStateName(previousState),
    if (backgroundDuration != null)
      'loq.app.background_duration_ms': backgroundDuration.inMilliseconds,
  };
}

/// Builds the default field map for a [MemoryPressureEvent].
///
/// Used by `LoqLifecycleObserver`. Exported so callers can call it
/// from their own custom event paths.
///
/// Keys produced:
///
/// - `loq.memory.pressure`: always `true`. Carried as a field marker
///   rather than a separate event-shaped attribute, so log pipelines
///   that filter by field-key see one steady record shape.
Map<String, Object?> defaultMemoryPressureFields() => <String, Object?>{
      'loq.memory.pressure': true,
    };

/// Builds the default field map for a [LocaleChangeEvent].
///
/// Used by `LoqLifecycleObserver`. Exported so callers can call it
/// from their own custom event paths.
///
/// Keys produced (both under `loq.*` because OTel doesn't standardize
/// locale-list reporting):
///
/// - `loq.app.locales`: `Locale.toString()` for each entry in
///   [locales], or `null` if [locales] is `null`.
/// - `loq.app.previous_locales`: same shape for [previousLocales].
Map<String, Object?> defaultLocaleChangeFields({
  required List<Locale>? locales,
  required List<Locale>? previousLocales,
}) {
  return <String, Object?>{
    'loq.app.locales': locales?.map((l) => l.toString()).toList(),
    'loq.app.previous_locales':
        previousLocales?.map((l) => l.toString()).toList(),
  };
}

/// Builds the default field map for an error event.
///
/// Used by `initLoq`'s error-capture integrations. Exported so
/// callers can call it from their own error-routing paths.
///
/// Keys produced:
///
/// - `exception.type`: `error.runtimeType.toString()`. OTel Stable.
/// - `exception.message`: `error.toString()`. OTel Stable.
/// - `exception.stacktrace`: `stackTrace.toString()`. OTel Stable.
/// - `loq.error.source`: verbatim [source] (for example
///   `flutter_framework`, `platform_dispatcher`, `zone_guard`). Under
///   `loq.*` because OTel doesn't standardize an error-source
///   attribute.
/// - `loq.error.handled`: verbatim [handled]. Under `loq.*` for the
///   same reason.
/// - `loq.flutter.library`: when [flutterDetails] is non-null,
///   `flutterDetails.library` (for example `widgets library`).
///   Framework metadata, under `loq.*`.
/// - `loq.flutter.context`: when [flutterDetails] is non-null, the
///   text form of `flutterDetails.context`.
/// - `loq.flutter.silent`: when [flutterDetails] is non-null,
///   `flutterDetails.silent`.
/// - `loq.flutter.information`: when [flutterDetails] is non-null
///   and `informationCollector` is set, the rendered diagnostic
///   notes as a `List<String>` (one entry per `DiagnosticsNode`).
///   Carries widget-tree context such as the widget that caused the
///   error. Left out when empty.
Map<String, Object?> defaultErrorFields({
  required Object error,
  required StackTrace stackTrace,
  required String source,
  required bool handled,
  FlutterErrorDetails? flutterDetails,
}) {
  final fields = <String, Object?>{
    'exception.type': error.runtimeType.toString(),
    'exception.message': error.toString(),
    'exception.stacktrace': stackTrace.toString(),
    'loq.error.source': source,
    'loq.error.handled': handled,
  };
  if (flutterDetails != null) {
    fields['loq.flutter.library'] = flutterDetails.library;
    fields['loq.flutter.context'] = flutterDetails.context?.toString();
    fields['loq.flutter.silent'] = flutterDetails.silent;
    final collector = flutterDetails.informationCollector;
    if (collector != null) {
      final information = collector()
          .map((node) => node.toStringDeep().trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (information.isNotEmpty) {
        fields['loq.flutter.information'] = information;
      }
    }
  }
  return fields;
}

String _lifecycleStateName(AppLifecycleState state) => switch (state) {
      AppLifecycleState.resumed => 'resumed',
      AppLifecycleState.inactive => 'inactive',
      AppLifecycleState.hidden => 'hidden',
      AppLifecycleState.paused => 'paused',
      AppLifecycleState.detached => 'detached',
    };
