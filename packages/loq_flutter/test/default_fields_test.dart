import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq_flutter/loq_flutter.dart';

import 'test_helpers.dart';

void main() {
  group('defaultScreenNameResolver', () {
    test('returns settings.name when non-null', () {
      final route = FakePageRoute(name: '/home');
      expect(defaultScreenNameResolver(route), '/home');
    });

    test('falls back to runtimeType.toString() when settings.name is null', () {
      final route = FakePageRoute();
      expect(defaultScreenNameResolver(route), 'FakePageRoute');
    });
  });

  group('defaultNavigationFields', () {
    final routeA = FakePageRoute(name: '/a');
    final routeB = FakePageRoute(name: '/b');

    test('produces screen.name and screen.previous_name via resolver', () {
      final fields = defaultNavigationFields(
        kind: 'push',
        route: routeA,
        previousRoute: routeB,
      );
      expect(fields['app.screen.name'], '/a');
      expect(fields['loq.app.screen.previous_name'], '/b');
      expect(fields['loq.navigation.kind'], 'push');
      expect(fields['loq.navigation.route_type'], 'FakePageRoute');
      expect(fields['loq.navigation.is_first_route'], isFalse);
    });

    test('is_first_route is true when previousRoute is null', () {
      final fields = defaultNavigationFields(
        kind: 'push',
        route: routeA,
        previousRoute: null,
      );
      expect(fields['loq.navigation.is_first_route'], isTrue);
      expect(fields['loq.app.screen.previous_name'], isNull);
    });

    test('honours custom nameResolver', () {
      final fields = defaultNavigationFields(
        kind: 'push',
        route: routeA,
        previousRoute: routeB,
        nameResolver: (_) => 'OVERRIDE',
      );
      expect(fields['app.screen.name'], 'OVERRIDE');
      expect(fields['loq.app.screen.previous_name'], 'OVERRIDE');
    });

    test('handles null route on event subject', () {
      final fields = defaultNavigationFields(
        kind: 'replace',
        route: null,
        previousRoute: routeB,
      );
      expect(fields['app.screen.name'], isNull);
      expect(fields['loq.navigation.route_type'], isNull);
    });
  });

  group('defaultLifecycleFields', () {
    test('emits short state names', () {
      final fields = defaultLifecycleFields(
        state: AppLifecycleState.paused,
        previousState: AppLifecycleState.resumed,
      );
      expect(fields['loq.app.lifecycle.state'], 'paused');
      expect(fields['loq.app.lifecycle.previous_state'], 'resumed');
    });

    test('previous_state is null when previousState is null', () {
      final fields = defaultLifecycleFields(
        state: AppLifecycleState.resumed,
        previousState: null,
      );
      expect(fields['loq.app.lifecycle.previous_state'], isNull);
    });

    test('covers every AppLifecycleState', () {
      for (final state in AppLifecycleState.values) {
        final fields = defaultLifecycleFields(
          state: state,
          previousState: null,
        );
        expect(fields['loq.app.lifecycle.state'], isNotNull);
      }
    });

    test('omits backgroundDuration when null', () {
      final fields = defaultLifecycleFields(
        state: AppLifecycleState.resumed,
        previousState: AppLifecycleState.paused,
      );
      expect(fields.containsKey('loq.app.background_duration_ms'), isFalse);
    });

    test('emits backgroundDuration in milliseconds when supplied', () {
      final fields = defaultLifecycleFields(
        state: AppLifecycleState.resumed,
        previousState: AppLifecycleState.paused,
        backgroundDuration: const Duration(seconds: 2, milliseconds: 500),
      );
      expect(fields['loq.app.background_duration_ms'], 2500);
    });
  });

  group('defaultMemoryPressureFields', () {
    test('emits loq.memory.pressure marker', () {
      final fields = defaultMemoryPressureFields();
      expect(fields['loq.memory.pressure'], isTrue);
    });
  });

  group('defaultLocaleChangeFields', () {
    test('emits locales and previous_locales as string lists', () {
      final fields = defaultLocaleChangeFields(
        locales: const [Locale('en'), Locale('fr')],
        previousLocales: const [Locale('es')],
      );
      expect(fields['loq.app.locales'], ['en', 'fr']);
      expect(fields['loq.app.previous_locales'], ['es']);
    });

    test('passes nulls through', () {
      final fields = defaultLocaleChangeFields(
        locales: null,
        previousLocales: null,
      );
      expect(fields['loq.app.locales'], isNull);
      expect(fields['loq.app.previous_locales'], isNull);
    });
  });

  group('defaultErrorFields', () {
    final boom = StateError('boom');
    final stack = StackTrace.fromString('frame0\nframe1');

    test('produces OTel exception fields and source/handled', () {
      final fields = defaultErrorFields(
        error: boom,
        stackTrace: stack,
        source: 'zone_guard',
        handled: true,
      );
      expect(fields['exception.type'], 'StateError');
      expect(fields['exception.message'], boom.toString());
      expect(fields['exception.stacktrace'], stack.toString());
      expect(fields['loq.error.source'], 'zone_guard');
      expect(fields['loq.error.handled'], isTrue);
      expect(fields.containsKey('loq.flutter.library'), isFalse);
    });

    test('adds flutter.* fields when flutterDetails non-null', () {
      final details = FlutterErrorDetails(
        exception: boom,
        stack: stack,
        library: 'widgets library',
        context: ErrorDescription('while building'),
        silent: true,
      );
      final fields = defaultErrorFields(
        error: boom,
        stackTrace: stack,
        source: 'flutter_framework',
        handled: false,
        flutterDetails: details,
      );
      expect(fields['loq.flutter.library'], 'widgets library');
      expect(fields['loq.flutter.context'], contains('while building'));
      expect(fields['loq.flutter.silent'], isTrue);
    });

    test('captures informationCollector output as loq.flutter.information', () {
      final details = FlutterErrorDetails(
        exception: boom,
        stack: stack,
        informationCollector: () => [
          ErrorDescription('The relevant error-causing widget was Foo'),
          ErrorDescription('extra context'),
        ],
      );
      final fields = defaultErrorFields(
        error: boom,
        stackTrace: stack,
        source: 'flutter_framework',
        handled: false,
        flutterDetails: details,
      );
      final info = fields['loq.flutter.information']! as List<String>;
      expect(info, hasLength(2));
      expect(info.first, contains('relevant error-causing widget'));
    });

    test('omits loq.flutter.information when collector returns empty', () {
      final details = FlutterErrorDetails(
        exception: boom,
        stack: stack,
        informationCollector: () => const [],
      );
      final fields = defaultErrorFields(
        error: boom,
        stackTrace: stack,
        source: 'flutter_framework',
        handled: false,
        flutterDetails: details,
      );
      expect(fields.containsKey('loq.flutter.information'), isFalse);
    });
  });
}
