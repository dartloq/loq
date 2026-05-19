// Tests construct LoqErrorState and call methods on it across
// statement lines; cascade refactors obscure the arrange / act phase.
// ignore_for_file: cascade_invocations

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';
// Test-only access to internal state, marked @visibleForTesting in
// init_loq.dart.
import 'package:loq_flutter/src/init_loq.dart' show LoqErrorState;

import 'test_helpers.dart';

void main() {
  late CapturingHandler capture;
  late Logger logger;

  FlutterExceptionHandler? savedFlutterHandler;
  ErrorCallback? savedPlatformHandler;

  setUp(() {
    savedFlutterHandler = FlutterError.onError;
    savedPlatformHandler = PlatformDispatcher.instance.onError;
    capture = CapturingHandler();
    logger = Logger('test.error', config: LogConfig(handlers: [capture]));
  });

  tearDown(() {
    FlutterError.onError = savedFlutterHandler;
    PlatformDispatcher.instance.onError = savedPlatformHandler;
    LogConfig.reset();
  });

  group('LoqErrorState: FlutterError integration', () {
    test('install replaces FlutterError.onError; dispose restores', () {
      final original = FlutterError.onError;
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installFlutterError();
      expect(FlutterError.onError, isNot(equals(original)));
      state.dispose();
      expect(FlutterError.onError, equals(original));
    });

    test('chains to previous handler', () {
      final previousCalls = <FlutterErrorDetails>[];
      FlutterError.onError = previousCalls.add;
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      ).installFlutterError();
      final details = FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      );
      FlutterError.onError!(details);
      expect(previousCalls, hasLength(1));
      expect(capture.records, hasLength(1));
      expect(
        capture.records.single.fields['loq.error.source'],
        'flutter_framework',
      );
    });

    test('respects reportSilentFlutterErrors flag', () {
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      ).installFlutterError();
      final silent = FlutterErrorDetails(
        exception: StateError('quiet'),
        silent: true,
      );
      FlutterError.onError!(silent);
      expect(capture.records, isEmpty);
    });

    test('reportSilentFlutterErrors: true includes silent details', () {
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: true,
      ).installFlutterError();
      final silent = FlutterErrorDetails(
        exception: StateError('quiet'),
        silent: true,
      );
      FlutterError.onError!(silent);
      expect(capture.records, hasLength(1));
      expect(capture.records.single.fields['loq.flutter.silent'], isTrue);
    });

    test('install is idempotent', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )
        ..installFlutterError()
        ..installFlutterError();
      // Sanity: the previous handler captured at first install is still
      // the test framework's default, not our own handler.
      state.dispose();
    });

    test(
      'second install unwinds the prior owner (hot-reload safety)',
      () {
        // Simulate the hot-reload sequence: initLoq runs once, then
        // a second initLoq call creates a new LoqErrorState. Without
        // unwinding, the second instance would chain to the first
        // (which is itself one of ours), growing the chain on every
        // reload.
        final originalHandler = FlutterError.onError;
        LoqErrorState(
          logger: logger,
          level: Level.fatal,
          reportSilentFlutterErrors: false,
        ).installFlutterError();
        expect(FlutterError.onError, isNot(equals(originalHandler)));

        final second = LoqErrorState(
          logger: logger,
          level: Level.fatal,
          reportSilentFlutterErrors: false,
        )..installFlutterError();

        // After the second install, the first should have been
        // disposed and the second should chain to the original
        // handler, not to the first's wrapper.
        second.dispose();
        expect(
          FlutterError.onError,
          equals(originalHandler),
          reason: 'dispose should restore the pre-loq handler, '
              'meaning the second never chained through the first',
        );
      },
    );
  });

  group('LoqErrorState: PlatformDispatcher integration', () {
    test('install replaces PlatformDispatcher.onError; dispose restores', () {
      final original = PlatformDispatcher.instance.onError;
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installPlatformDispatcher();
      expect(PlatformDispatcher.instance.onError, isNot(equals(original)));
      state.dispose();
      expect(PlatformDispatcher.instance.onError, equals(original));
    });

    test('previous handler return value drives the handled field', () {
      PlatformDispatcher.instance.onError = (_, __) => true;
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      ).installPlatformDispatcher();
      PlatformDispatcher.instance.onError!(
        StateError('boom'),
        StackTrace.current,
      );
      expect(capture.records, hasLength(1));
      expect(capture.records.single.fields['loq.error.handled'], isTrue);
    });

    test('previous handler missing means handled defaults to false', () {
      PlatformDispatcher.instance.onError = null;
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      ).installPlatformDispatcher();
      PlatformDispatcher.instance.onError!(
        StateError('boom'),
        StackTrace.current,
      );
      expect(capture.records.single.fields['loq.error.handled'], isFalse);
    });
  });

  group('LoqErrorState: debugPrint redirect', () {
    // Flutter's test framework asserts `debugPrint == debugPrintThrottled`
    // at the end of every test (before tearDown runs), so each test
    // must restore via `state.dispose()` inside its own body.

    test('install replaces debugPrint; dispose restores', () {
      final original = debugPrint;
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installDebugPrintRedirect(logger: logger, level: Level.debug);
      expect(debugPrint, isNot(equals(original)));
      state.dispose();
      expect(debugPrint, equals(original));
    });

    test('forwards debugPrint messages to the configured logger', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installDebugPrintRedirect(logger: logger, level: Level.warn);
      try {
        debugPrint('hello from framework');
        expect(capture.records, hasLength(1));
        expect(capture.records.single.message, 'hello from framework');
        expect(capture.records.single.level, Level.warn);
      } finally {
        state.dispose();
      }
    });

    test('drops null messages', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installDebugPrintRedirect(logger: logger, level: Level.debug);
      try {
        debugPrint(null);
        expect(capture.records, isEmpty);
      } finally {
        state.dispose();
      }
    });

    test('second install unwinds the prior owner (hot-reload safety)', () {
      final originalDebugPrint = debugPrint;
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      ).installDebugPrintRedirect(logger: logger, level: Level.debug);
      expect(debugPrint, isNot(equals(originalDebugPrint)));

      final second = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installDebugPrintRedirect(logger: logger, level: Level.debug);

      second.dispose();
      expect(
        debugPrint,
        equals(originalDebugPrint),
        reason: 'second dispose should restore the pre-loq debugPrint, '
            'not chain through the first wrapper',
      );
    });
  });

  group('LoqErrorState: dedup queue', () {
    test('same error via two paths emits only once', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )
        ..installFlutterError()
        ..installPlatformDispatcher();
      final error = StateError('boom');
      final stack = StackTrace.current;
      final details = FlutterErrorDetails(exception: error, stack: stack);

      FlutterError.onError!(details);
      PlatformDispatcher.instance.onError!(error, stack);
      state.handleZoneGuard(error, stack);

      expect(capture.records, hasLength(1));
    });

    test('distinct errors are not deduped', () {
      LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      ).installFlutterError();
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('a'),
          stack: StackTrace.current,
        ),
      );
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('b'),
          stack: StackTrace.current,
        ),
      );
      expect(capture.records, hasLength(2));
    });

    test('dedup queue evicts oldest beyond capacity', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      );
      final firstError = StateError('first');
      final firstStack = StackTrace.current;

      // Capacity is 16; push 20 distinct errors through to evict 'first'.
      state.handleZoneGuard(firstError, firstStack);
      for (var i = 0; i < 20; i++) {
        state.handleZoneGuard(StateError('e$i'), StackTrace.current);
      }

      // 'first' should be evicted; re-emit should not dedupe.
      capture.records.clear();
      state.handleZoneGuard(firstError, firstStack);
      expect(capture.records, hasLength(1));
    });
  });

  group('LoqErrorState: fields and hooks', () {
    test('zone-guard event emits zone_guard source and handled=true', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      );
      state.handleZoneGuard(StateError('boom'), StackTrace.current);
      final fields = capture.records.single.fields;
      expect(fields['loq.error.source'], 'zone_guard');
      expect(fields['loq.error.handled'], isTrue);
    });

    test('message hook replaces default message', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
        message: (_) => 'custom error message',
      );
      state.handleZoneGuard(StateError('boom'), StackTrace.current);
      expect(capture.records.single.message, 'custom error message');
    });

    test('fields hook can compose defaults', () {
      final state = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
        fields: (event) => {...event.defaults, 'extra': 1},
      );
      state.handleZoneGuard(StateError('boom'), StackTrace.current);
      expect(capture.records.single.fields['extra'], 1);
      expect(capture.records.single.fields['loq.error.source'], 'zone_guard');
    });
  });

  group('initLoq', () {
    testWidgets('runs body and installs lifecycle observer', (tester) async {
      var bodyRan = false;
      await initLoq(
        () {
          bodyRan = true;
        },
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
        wireZoneGuard: false,
      );
      expect(bodyRan, isTrue);
    });

    testWidgets('installLifecycleObserver: false skips install',
        (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      await initLoq(
        () {},
        installLifecycleObserver: false,
        lifecycleObserver: observer,
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
        wireZoneGuard: false,
      );
      expect(observer.isInstalled, isFalse);
    });

    testWidgets('uses supplied lifecycleObserver instance', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      await initLoq(
        () {},
        lifecycleObserver: observer,
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
        wireZoneGuard: false,
      );
      expect(observer.isInstalled, isTrue);
      observer.dispose();
    });

    testWidgets('zone guard captures errors thrown from body', (tester) async {
      LogConfig.configure(handlers: [capture]);
      await initLoq(
        () {
          throw StateError('body boom');
        },
        errorLogger: logger,
        installLifecycleObserver: false,
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
      );
      expect(capture.records, hasLength(1));
      expect(capture.records.single.fields['loq.error.source'], 'zone_guard');
    });

    testWidgets('config is applied via LogConfig.configure', (tester) async {
      final other = CapturingHandler();
      await initLoq(
        () {},
        config: LogConfig(handlers: [other]),
        installLifecycleObserver: false,
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
        wireZoneGuard: false,
      );
      expect(LogConfig.global.handlers, contains(other));
    });

    testWidgets('captureSourceLocation flag flows into LogConfig.global',
        (tester) async {
      expect(LogConfig.global.captureSourceLocation, isFalse);
      await initLoq(
        () {},
        captureSourceLocation: true,
        installLifecycleObserver: false,
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
        wireZoneGuard: false,
      );
      expect(LogConfig.global.captureSourceLocation, isTrue);
    });

    testWidgets(
      'wireFlutterErrors and wirePlatformDispatcher install the slots',
      (tester) async {
        final defaultFlutter = FlutterError.onError;
        final defaultPlatform = PlatformDispatcher.instance.onError;
        await initLoq(
          () {},
          installLifecycleObserver: false,
          wireZoneGuard: false,
        );
        expect(FlutterError.onError, isNot(equals(defaultFlutter)));
        expect(
          PlatformDispatcher.instance.onError,
          isNot(equals(defaultPlatform)),
        );
      },
    );

    testWidgets(
      'redirectFlutterDebugPrint: false leaves debugPrint alone',
      (tester) async {
        final defaultDebugPrint = debugPrint;
        await initLoq(
          () {},
          installLifecycleObserver: false,
          wireFlutterErrors: false,
          wirePlatformDispatcher: false,
          wireZoneGuard: false,
        );
        expect(debugPrint, equals(defaultDebugPrint));
      },
    );

    testWidgets(
      'flutterDebugLogger defaults to loq_flutter.debug_print',
      (tester) async {
        final savedDebugPrint = debugPrint;
        try {
          await initLoq(
            () {},
            redirectFlutterDebugPrint: true,
            // No flutterDebugLogger provided; falls back to the
            // default Logger('loq_flutter.debug_print').
            installLifecycleObserver: false,
            wireFlutterErrors: false,
            wirePlatformDispatcher: false,
            wireZoneGuard: false,
          );
          expect(debugPrint, isNot(equals(savedDebugPrint)));
        } finally {
          debugPrint = savedDebugPrint;
        }
      },
    );

    testWidgets(
      'redirectFlutterDebugPrint: true forwards debugPrint to a logger',
      (tester) async {
        // Flutter's test framework asserts `debugPrint` is reset to
        // its default at the end of each test. We must restore before
        // the test body returns, so a try/finally rather than
        // addTearDown.
        final savedDebugPrint = debugPrint;
        try {
          await initLoq(
            () {},
            flutterDebugLogger: logger,
            redirectFlutterDebugPrint: true,
            installLifecycleObserver: false,
            wireFlutterErrors: false,
            wirePlatformDispatcher: false,
            wireZoneGuard: false,
          );

          debugPrint('framework chatter');
          expect(capture.records, hasLength(1));
          expect(capture.records.single.message, 'framework chatter');
        } finally {
          debugPrint = savedDebugPrint;
        }
      },
    );

    testWidgets('async body is awaited before lifecycle install',
        (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      var bodyDone = false;
      // Microtask (not Future.delayed): Duration.zero timers don't
      // resolve in testWidgets' fake-async zone without tester.pump.
      await initLoq(
        () async {
          await Future<void>.microtask(() {});
          bodyDone = true;
        },
        lifecycleObserver: observer,
        wireFlutterErrors: false,
        wirePlatformDispatcher: false,
        wireZoneGuard: false,
      );
      expect(bodyDone, isTrue);
      expect(observer.isInstalled, isTrue);
      observer.dispose();
    });
  });
}
