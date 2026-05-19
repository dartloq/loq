// Integration tests for LoqNavigatorObserver paired with auto_route.
//
// auto_route's typical setup requires build_runner-generated route
// classes (`@AutoRouterConfig()`). Without codegen we can't construct
// a `RootStackRouter` subclass with real routes. What we *can* verify
// without codegen:
//
//   1. The observer is type-compatible with auto_route's
//      `navigatorObservers: () => [...]` callback shape.
//   2. Page-based navigation (what auto_route uses internally)
//      flows pushes through our observer the same way go_router and
//      vanilla `Navigator` do.
//
// The narrow scope is intentional: full auto_route integration is a
// codegen-dependent surface, and our observer's contract with it is
// "be a `NavigatorObserver`". Anything beyond that belongs in an
// example app, not a unit test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

import '../test_helpers.dart';

void main() {
  late CapturingHandler capture;
  late Logger logger;

  setUp(() {
    capture = CapturingHandler();
    logger = Logger(
      'test.autoroute',
      config: LogConfig(handlers: [capture]),
    );
  });

  test('observer is type-compatible with auto_route navigatorObservers', () {
    // auto_route's `navigatorObservers: NavigatorObserversBuilder` is
    // `List<NavigatorObserver> Function()`. This compile-only test
    // confirms our observer slots in without an adapter.
    List<LoqNavigatorObserver> builder() => [LoqNavigatorObserver()];
    expect(builder(), isNotEmpty);
  });

  testWidgets(
    'page-based navigation flows through the observer',
    (tester) async {
      // Simulates what auto_route does internally: a Navigator with a
      // pages list driven by state. Our observer must capture pushes
      // exactly like it would in the codegen path.
      final observer = LoqNavigatorObserver(logger: logger);
      var stack = const ['/feed'];

      Widget build(StateSetter setState) => MaterialApp(
            home: StatefulBuilder(
              builder: (context, innerSetState) => Navigator(
                observers: [observer],
                pages: [
                  for (final path in stack)
                    MaterialPage<void>(
                      name: path,
                      child: Scaffold(body: Text(path)),
                    ),
                ],
                onDidRemovePage: (page) {
                  innerSetState(() {
                    stack = stack.where((p) => p != page.name).toList();
                  });
                },
              ),
            ),
          );

      late StateSetter outerSet;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            outerSet = setState;
            return build(setState);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(observer.currentScreen, '/feed');

      // Push a new page by mutating the stack. Same shape as
      // auto_route's declarative navigation.
      outerSet(() => stack = const ['/feed', '/profile']);
      await tester.pumpAndSettle();

      expect(observer.currentScreen, '/profile');
      expect(
        capture.records.last.fields['app.screen.name'],
        '/profile',
      );
      expect(
        capture.records.last.fields['loq.navigation.kind'],
        'push',
      );
    },
  );
}
