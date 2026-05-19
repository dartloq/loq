// Tests routinely construct an observer and call methods on it across
// statement lines; the cascade refactor reduces readability of the
// arrange / act / assert phases.
// ignore_for_file: cascade_invocations

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

import 'test_helpers.dart';

void main() {
  late CapturingHandler capture;
  late Logger logger;

  setUp(() {
    capture = CapturingHandler();
    logger = Logger(
      'test.navigator',
      config: LogConfig(handlers: [capture]),
    );
  });

  test('constructs with default logger when none is provided', () {
    final observer = LoqNavigatorObserver();
    expect(observer.currentScreen, isNull);
  });

  group('didPush', () {
    test('emits NavigationPushEvent fields and updates currentScreen', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');

      observer.didPush(routeA, null);

      expect(capture.records, hasLength(1));
      final fields = capture.records.single.fields;
      expect(fields['loq.navigation.kind'], 'push');
      expect(fields['app.screen.name'], '/a');
      expect(fields['loq.app.screen.previous_name'], isNull);
      expect(fields['loq.navigation.is_first_route'], isTrue);
      expect(fields['loq.navigation.route_type'], 'FakePageRoute');
      expect(observer.currentScreen, '/a');
      expect(observer.previousScreen, isNull);
    });

    test('subsequent push records previousScreen', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');
      final routeB = FakePageRoute(name: '/b');

      observer
        ..didPush(routeA, null)
        ..didPush(routeB, routeA);

      expect(observer.currentScreen, '/b');
      expect(observer.previousScreen, '/a');
      final fields = capture.records.last.fields;
      expect(fields['app.screen.name'], '/b');
      expect(fields['loq.app.screen.previous_name'], '/a');
      expect(fields['loq.navigation.is_first_route'], isFalse);
    });

    test('skips non-page routes by default and does not update currentScreen',
        () {
      final observer = LoqNavigatorObserver(logger: logger);
      final page = FakePageRoute(name: '/page');
      final dialog = FakeRoute(name: '/dialog');

      observer
        ..didPush(page, null)
        ..didPush(dialog, page);

      expect(capture.records, hasLength(1));
      expect(observer.currentScreen, '/page');
    });

    test('includeNonPageRoutes: true emits dialog pushes', () {
      final observer = LoqNavigatorObserver(
        logger: logger,
        includeNonPageRoutes: true,
      );
      final page = FakePageRoute(name: '/page');
      final dialog = FakeRoute(name: '/dialog');

      observer
        ..didPush(page, null)
        ..didPush(dialog, page);

      expect(capture.records, hasLength(2));
      expect(
        observer.currentScreen,
        '/page',
        reason: 'dialog should not change currentScreen even when emitted',
      );
    });
  });

  group('didPop', () {
    test('emits NavigationPopEvent and reverts currentScreen', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');
      final routeB = FakePageRoute(name: '/b');

      observer
        ..didPush(routeA, null)
        ..didPush(routeB, routeA);
      capture.records.clear();

      observer.didPop(routeB, routeA);

      expect(capture.records, hasLength(1));
      final fields = capture.records.single.fields;
      expect(fields['loq.navigation.kind'], 'pop');
      expect(fields['app.screen.name'], '/b');
      expect(fields['loq.app.screen.previous_name'], '/a');
      expect(observer.currentScreen, '/a');
      expect(observer.previousScreen, '/b');
    });

    test('pop of non-page route is ignored by default', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final page = FakePageRoute(name: '/page');
      final dialog = FakeRoute(name: '/dialog');

      observer.didPush(page, null);
      capture.records.clear();
      observer.didPop(dialog, page);

      expect(capture.records, isEmpty);
      expect(observer.currentScreen, '/page');
    });

    test('popping last page route leaves currentScreen null', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');

      observer
        ..didPush(routeA, null)
        ..didPop(routeA, null);

      expect(observer.currentScreen, isNull);
    });
  });

  group('didReplace', () {
    test('emits NavigationReplaceEvent and updates currentScreen', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');
      final routeB = FakePageRoute(name: '/b');

      observer.didPush(routeA, null);
      capture.records.clear();
      observer.didReplace(newRoute: routeB, oldRoute: routeA);

      expect(capture.records, hasLength(1));
      final fields = capture.records.single.fields;
      expect(fields['loq.navigation.kind'], 'replace');
      expect(fields['app.screen.name'], '/b');
      expect(fields['loq.app.screen.previous_name'], '/a');
      expect(observer.currentScreen, '/b');
    });

    test('replacing a tracked page with non-page removes it from stack', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');
      final routeB = FakePageRoute(name: '/b');
      final dialog = FakeRoute(name: '/dialog');

      observer
        ..didPush(routeA, null)
        ..didPush(routeB, routeA);
      capture.records.clear();
      observer.didReplace(newRoute: dialog, oldRoute: routeB);

      expect(
        observer.currentScreen,
        '/a',
        reason: 'page-by-non-page replacement leaves prior page on top',
      );
      expect(capture.records, hasLength(1));
    });

    test('replacing non-page with page adds new page to stack', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');
      final dialog = FakeRoute(name: '/dialog');
      final newPage = FakePageRoute(name: '/new');

      observer
        ..didPush(routeA, null)
        ..didReplace(newRoute: newPage, oldRoute: dialog);

      expect(observer.currentScreen, '/new');
    });

    test('replace of untracked non-page routes is silent by default', () {
      final observer = LoqNavigatorObserver(logger: logger);
      observer.didReplace(
        newRoute: FakeRoute(name: '/a'),
        oldRoute: FakeRoute(name: '/b'),
      );
      expect(capture.records, isEmpty);
    });
  });

  group('didRemove', () {
    test('removes from stack at arbitrary position', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final routeA = FakePageRoute(name: '/a');
      final routeB = FakePageRoute(name: '/b');
      final routeC = FakePageRoute(name: '/c');

      observer
        ..didPush(routeA, null)
        ..didPush(routeB, routeA)
        ..didPush(routeC, routeB);
      capture.records.clear();

      observer.didRemove(routeB, routeA);

      expect(capture.records, hasLength(1));
      expect(capture.records.single.fields['loq.navigation.kind'], 'remove');
      expect(
        observer.currentScreen,
        '/c',
        reason: 'removing a deeper route leaves the top page intact',
      );
    });

    test('remove of non-page route is silent by default', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final page = FakePageRoute(name: '/page');
      final dialog = FakeRoute(name: '/dialog');

      observer.didPush(page, null);
      capture.records.clear();
      observer.didRemove(dialog, page);

      expect(capture.records, isEmpty);
    });
  });

  group('hooks', () {
    test('skip drops events without logging', () {
      final observer = LoqNavigatorObserver(
        logger: logger,
        skipLog: (event) => event is NavigationPopEvent,
      );
      final routeA = FakePageRoute(name: '/a');
      observer
        ..didPush(routeA, null)
        ..didPop(routeA, null);
      expect(capture.records, hasLength(1));
      expect(
        observer.currentScreen,
        isNull,
        reason: 'skip suppresses emission but state still updates',
      );
    });

    test('levelResolver overrides per-event level', () {
      final observer = LoqNavigatorObserver(
        logger: logger,
        levelResolver: (event) =>
            event is NavigationPushEvent ? Level.warn : null,
      );
      observer.didPush(FakePageRoute(name: '/a'), null);
      expect(capture.records.single.level, Level.warn);
    });

    test('fields hook replaces defaults', () {
      final observer = LoqNavigatorObserver(
        logger: logger,
        fields: (event) => {'custom': true, ...event.defaults},
      );
      observer.didPush(FakePageRoute(name: '/a'), null);
      expect(capture.records.single.fields['custom'], isTrue);
      expect(capture.records.single.fields['app.screen.name'], '/a');
    });

    test('message hook overrides default message', () {
      final observer = LoqNavigatorObserver(
        logger: logger,
        message: (event) => 'custom message',
      );
      observer.didPush(FakePageRoute(name: '/a'), null);
      expect(capture.records.single.message, 'custom message');
    });

    test('nameResolver override flows into screen.name', () {
      final observer = LoqNavigatorObserver(
        logger: logger,
        nameResolver: (_) => 'OVERRIDE',
      );
      observer.didPush(FakePageRoute(name: '/a'), null);
      expect(capture.records.single.fields['app.screen.name'], 'OVERRIDE');
    });
  });

  group('screenFieldsProcessor', () {
    test('returns record unchanged when stack is empty', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final record = Record(
        time: DateTime.now(),
        level: Level.info,
        message: 'hi',
        fields: const {},
        zone: Zone.current,
      );
      expect(observer.screenFieldsProcessor(record), same(record));
    });

    test('adds screen.name after first push', () {
      final observer = LoqNavigatorObserver(logger: logger);
      observer.didPush(FakePageRoute(name: '/a'), null);
      final record = Record(
        time: DateTime.now(),
        level: Level.info,
        message: 'hi',
        fields: const {},
        zone: Zone.current,
      );
      final out = observer.screenFieldsProcessor(record)!;
      expect(out.fields['app.screen.name'], '/a');
      expect(
        out.fields.containsKey('loq.app.screen.previous_name'),
        isFalse,
        reason: 'no previous screen on the first push',
      );
    });

    test('adds previous_name after a transition', () {
      final observer = LoqNavigatorObserver(logger: logger);
      final a = FakePageRoute(name: '/a');
      final b = FakePageRoute(name: '/b');
      observer
        ..didPush(a, null)
        ..didPush(b, a);
      final record = Record(
        time: DateTime.now(),
        level: Level.info,
        message: 'hi',
        fields: const {},
        zone: Zone.current,
      );
      final out = observer.screenFieldsProcessor(record)!;
      expect(out.fields['app.screen.name'], '/b');
      expect(out.fields['loq.app.screen.previous_name'], '/a');
    });

    test('does not overwrite an existing screen.name', () {
      final observer = LoqNavigatorObserver(logger: logger);
      observer.didPush(FakePageRoute(name: '/a'), null);
      final record = Record(
        time: DateTime.now(),
        level: Level.info,
        message: 'hi',
        fields: const {'app.screen.name': 'PRESET'},
        zone: Zone.current,
      );
      final out = observer.screenFieldsProcessor(record)!;
      expect(out.fields['app.screen.name'], 'PRESET');
    });
  });
}
