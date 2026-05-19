// Integration tests for LoqNavigatorObserver paired with a real
// go_router instance. Headless widget tests; live in test/integration/
// rather than integration_test/ because we don't need a device target
// (no platform-specific behaviour under test). Same convention as
// loq_drift's test/integration/ split.

// go_router examples in the README inline two screens per route; the
// repetition is intentional for readability.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

import '../test_helpers.dart';

/// The `nameResolver` recipe from the README: go_router sets
/// `Page.name` (via the route's `name:` parameter) but leaves
/// `route.settings.name` null on the underlying `PageRoute`.
String? goRouterNameResolver(Route<dynamic> route) {
  final settings = route.settings;
  if (settings is Page) {
    return settings.name ?? settings.key?.toString();
  }
  return settings.name ?? route.runtimeType.toString();
}

void main() {
  late CapturingHandler capture;
  late Logger logger;
  late LoqNavigatorObserver observer;

  setUp(() {
    capture = CapturingHandler();
    logger = Logger('test.gorouter', config: LogConfig(handlers: [capture]));
    observer = LoqNavigatorObserver(
      logger: logger,
      nameResolver: goRouterNameResolver,
    );
  });

  testWidgets('observer captures pushes through a real GoRouter',
      (tester) async {
    final router = GoRouter(
      observers: [observer],
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (_, __) => const _Screen('home'),
        ),
        GoRoute(
          path: '/settings',
          name: 'settings',
          builder: (_, __) => const _Screen('settings'),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(
      observer.currentScreen,
      'home',
      reason: 'initial route should set currentScreen',
    );

    router.go('/settings');
    await tester.pumpAndSettle();

    expect(observer.currentScreen, 'settings');
    expect(
      capture.records.map((r) => r.fields['app.screen.name']),
      contains('settings'),
    );

    // Clean up router resources so the test exits cleanly.
    router.dispose();
  });

  testWidgets(
    'screenFieldsProcessor injects screen.name into unrelated log records',
    (tester) async {
      LogConfig.configure(
        processors: [observer.screenFieldsProcessor],
        handlers: [capture],
      );
      addTearDown(LogConfig.reset);

      final router = GoRouter(
        observers: [observer],
        routes: [
          GoRoute(
            path: '/',
            name: 'home',
            builder: (_, __) => const _Screen('home'),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      Logger('app').info('hi from app');
      final hi = capture.records.lastWhere((r) => r.message == 'hi from app');
      expect(hi.fields['app.screen.name'], 'home');

      router.dispose();
    },
  );

  testWidgets(
    'one observer per branch in a StatefulShellRoute',
    (tester) async {
      // Flutter's NavigatorObserver asserts it's attached to exactly
      // ONE Navigator at a time. StatefulShellRoute gives each branch
      // its own Navigator, so we need a separate observer per branch.
      // Their screenFieldsProcessors compose into LogConfig.global.
      final feedObserver = LoqNavigatorObserver(
        logger: logger,
        nameResolver: goRouterNameResolver,
      );
      final profileObserver = LoqNavigatorObserver(
        logger: logger,
        nameResolver: goRouterNameResolver,
      );

      final router = GoRouter(
        observers: [observer],
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, __, shell) => _ShellScaffold(shell: shell),
            branches: [
              StatefulShellBranch(
                observers: [feedObserver],
                routes: [
                  GoRoute(
                    path: '/feed',
                    name: 'feed',
                    builder: (_, __) => const _Screen('feed'),
                  ),
                ],
              ),
              StatefulShellBranch(
                observers: [profileObserver],
                routes: [
                  GoRoute(
                    path: '/profile',
                    name: 'profile',
                    builder: (_, __) => const _Screen('profile'),
                  ),
                ],
              ),
            ],
          ),
        ],
        initialLocation: '/feed',
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // Each branch's observer tracks its own navigator's stack.
      // Exactly one of them should have a current screen after setup
      // (the active branch); the inactive branch's navigator is
      // built lazily by IndexedStack.
      final tracked = [
        feedObserver.currentScreen,
        profileObserver.currentScreen,
      ].where((s) => s != null).toList();
      expect(
        tracked,
        isNotEmpty,
        reason: 'at least one branch should report a current screen',
      );
      expect(capture.records, isNotEmpty);

      router.dispose();
    },
  );
}

class _Screen extends StatelessWidget {
  const _Screen(this.name);
  final String name;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(name)));
}

class _ShellScaffold extends StatelessWidget {
  const _ShellScaffold({required this.shell});
  final StatefulNavigationShell shell;
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: shell, bottomNavigationBar: const SizedBox.shrink());
}
