import 'package:flutter_test/flutter_test.dart';
import 'package:loq_flutter/loq_flutter.dart';

import 'test_helpers.dart';

void main() {
  group('NavigationEvent sealed hierarchy', () {
    final routeA = FakePageRoute(name: '/a');
    final routeB = FakePageRoute(name: '/b');
    final defaults = {'loq.navigation.kind': 'push'};

    test('NavigationPushEvent carries route, previousRoute, defaults', () {
      final event = NavigationPushEvent(
        route: routeA,
        previousRoute: routeB,
        defaults: defaults,
      );
      expect(event.route, same(routeA));
      expect(event.previousRoute, same(routeB));
      expect(event.defaults, defaults);
    });

    test('NavigationPushEvent.previousRoute may be null on first push', () {
      final event = NavigationPushEvent(
        route: routeA,
        previousRoute: null,
        defaults: defaults,
      );
      expect(event.previousRoute, isNull);
    });

    test('NavigationPopEvent carries route, previousRoute, defaults', () {
      final event = NavigationPopEvent(
        route: routeA,
        previousRoute: routeB,
        defaults: defaults,
      );
      expect(event.route, same(routeA));
      expect(event.previousRoute, same(routeB));
      expect(event.defaults, defaults);
    });

    test(
        'NavigationReplaceEvent maps newRoute → route, '
        'oldRoute → previousRoute', () {
      final event = NavigationReplaceEvent(
        newRoute: routeA,
        oldRoute: routeB,
        defaults: defaults,
      );
      expect(event.route, same(routeA));
      expect(event.previousRoute, same(routeB));
      expect(event.defaults, defaults);
    });

    test('NavigationReplaceEvent permits null on both routes', () {
      final event = NavigationReplaceEvent(
        newRoute: null,
        oldRoute: null,
        defaults: defaults,
      );
      expect(event.route, isNull);
      expect(event.previousRoute, isNull);
    });

    test('NavigationRemoveEvent carries route, previousRoute, defaults', () {
      final event = NavigationRemoveEvent(
        route: routeA,
        previousRoute: routeB,
        defaults: defaults,
      );
      expect(event.route, same(routeA));
      expect(event.previousRoute, same(routeB));
      expect(event.defaults, defaults);
    });

    test('exhaustive switch on NavigationEvent compiles', () {
      String kindOf(NavigationEvent event) => switch (event) {
            NavigationPushEvent() => 'push',
            NavigationPopEvent() => 'pop',
            NavigationReplaceEvent() => 'replace',
            NavigationRemoveEvent() => 'remove',
          };
      expect(
        kindOf(
          NavigationPushEvent(
            route: routeA,
            previousRoute: null,
            defaults: defaults,
          ),
        ),
        'push',
      );
      expect(
        kindOf(
          NavigationPopEvent(
            route: routeA,
            previousRoute: routeB,
            defaults: defaults,
          ),
        ),
        'pop',
      );
      expect(
        kindOf(
          NavigationReplaceEvent(
            newRoute: routeA,
            oldRoute: routeB,
            defaults: defaults,
          ),
        ),
        'replace',
      );
      expect(
        kindOf(
          NavigationRemoveEvent(
            route: routeA,
            previousRoute: routeB,
            defaults: defaults,
          ),
        ),
        'remove',
      );
    });
  });
}
