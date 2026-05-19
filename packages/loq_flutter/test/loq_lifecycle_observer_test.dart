// Tests routinely construct an observer and call methods on it across
// statement lines; the cascade refactor reduces readability of the
// arrange / act / assert phases.
// ignore_for_file: cascade_invocations

import 'package:flutter/widgets.dart';
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
      'test.lifecycle',
      config: LogConfig(handlers: [capture]),
    );
  });

  tearDown(LogConfig.reset);

  group('install / dispose', () {
    testWidgets('install registers with WidgetsBinding', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger)..install();
      expect(observer.isInstalled, isTrue);
      observer.dispose();
      expect(observer.isInstalled, isFalse);
    });

    testWidgets('install is idempotent', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger)
        ..install()
        ..install();
      expect(observer.isInstalled, isTrue);
      observer.dispose();
    });

    testWidgets('dispose is idempotent', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger)
        ..install()
        ..dispose()
        ..dispose();
      expect(observer.isInstalled, isFalse);
    });
  });

  group('lifecycle transitions', () {
    testWidgets('emits a record on every state change', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      observer
        ..didChangeAppLifecycleState(AppLifecycleState.resumed)
        ..didChangeAppLifecycleState(AppLifecycleState.inactive)
        ..didChangeAppLifecycleState(AppLifecycleState.paused);
      // Allow any unawaited flush futures to settle so we don't leak.
      await tester.pump();
      expect(capture.records, hasLength(3));
      expect(
        capture.records.map((r) => r.fields['loq.app.lifecycle.state']),
        ['resumed', 'inactive', 'paused'],
      );
    });

    testWidgets('records previousState in defaults', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      observer
        ..didChangeAppLifecycleState(AppLifecycleState.resumed)
        ..didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      final second = capture.records[1].fields;
      expect(second['loq.app.lifecycle.state'], 'paused');
      expect(second['loq.app.lifecycle.previous_state'], 'resumed');
      expect(observer.previousState, AppLifecycleState.paused);
    });

    testWidgets('builds the right sealed event subclass', (tester) async {
      final observers = <LifecycleEvent>[];
      final observer = LoqLifecycleObserver(
        logger: logger,
        fields: (event) {
          observers.add(event);
          return event.defaults;
        },
      );
      AppLifecycleState.values.forEach(observer.didChangeAppLifecycleState);
      await tester.pump();
      const stateToType = {
        AppLifecycleState.resumed: 'AppResumedEvent',
        AppLifecycleState.inactive: 'AppInactiveEvent',
        AppLifecycleState.hidden: 'AppHiddenEvent',
        AppLifecycleState.paused: 'AppPausedEvent',
        AppLifecycleState.detached: 'AppDetachedEvent',
      };
      expect(
        observers.map((e) => e.runtimeType.toString()).toList(),
        AppLifecycleState.values.map((s) => stateToType[s]).toList(),
      );
    });
  });

  group('flush behaviour', () {
    testWidgets('flushes on paused by default', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(capture.flushCount, 1);
    });

    testWidgets('flushes on detached by default', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.detached);
      await tester.pump();
      expect(capture.flushCount, 1);
    });

    testWidgets('does not flush on resumed / inactive', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
      );
      observer
        ..didChangeAppLifecycleState(AppLifecycleState.resumed)
        ..didChangeAppLifecycleState(AppLifecycleState.inactive);
      await tester.pump();
      expect(capture.flushCount, 0);
    });

    testWidgets('does not flush on hidden by default', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(capture.flushCount, 0);
    });

    testWidgets('flushOnHidden: true flushes on hidden', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
        flushOnHidden: true,
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(capture.flushCount, 1);
    });

    testWidgets('flushOnPaused: false suppresses paused flush', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
        flushOnPaused: false,
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(capture.flushCount, 0);
    });

    testWidgets(
      'flushHandlers null reads LogConfig.global at flush time',
      (tester) async {
        final observer = LoqLifecycleObserver(logger: logger);

        // No handlers configured yet; first flush should be a no-op.
        observer.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump();
        expect(capture.flushCount, 0);

        // Now register the capturing handler globally.
        LogConfig.configure(handlers: [capture]);
        observer.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump();
        expect(
          capture.flushCount,
          1,
          reason: 'reconfigure mid-run should be picked up',
        );
      },
    );

    testWidgets(
      'a failing flush is contained and surfaces through onHandlerError',
      (tester) async {
        final other = CapturingHandler();
        final reported = <Object>[];
        LogConfig.configure(
          onHandlerError: (h, e, st) => reported.add(e),
        );
        final observer = LoqLifecycleObserver(
          logger: logger,
          flushHandlers: [capture..failNextFlush = StateError('boom'), other],
        );
        observer.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump();
        expect(capture.flushCount, 1);
        expect(other.flushCount, 1, reason: 'sibling handlers still flush');
        expect(reported, hasLength(1));
        expect(reported.single, isA<StateError>());
      },
    );
  });

  group('hooks', () {
    testWidgets('levelResolver overrides per-event level', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        levelResolver: (event) => event is AppPausedEvent ? Level.warn : null,
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(capture.records.single.level, Level.warn);
    });

    testWidgets('message hook replaces default message', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        message: (_) => 'lifecycle ping',
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(capture.records.single.message, 'lifecycle ping');
    });

    testWidgets('fields hook can compose defaults', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        fields: (event) => {...event.defaults, 'extra': 1},
      );
      observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      final fields = capture.records.single.fields;
      expect(fields['extra'], 1);
      expect(fields['loq.app.lifecycle.state'], 'resumed');
    });
  });

  group('memory pressure', () {
    testWidgets('emits MemoryPressureEvent at Level.warn by default',
        (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      observer.didHaveMemoryPressure();
      await tester.pump();
      expect(capture.records, hasLength(1));
      expect(capture.records.single.level, Level.warn);
      expect(capture.records.single.message, 'memory pressure');
      expect(capture.records.single.fields['loq.memory.pressure'], isTrue);
    });

    testWidgets('flushes handlers by default', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
      );
      observer.didHaveMemoryPressure();
      await tester.pump();
      expect(capture.flushCount, 1);
    });

    testWidgets('flushOnMemoryPressure: false suppresses the flush',
        (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
        flushOnMemoryPressure: false,
      );
      observer.didHaveMemoryPressure();
      await tester.pump();
      expect(capture.flushCount, 0);
    });

    testWidgets('levelResolver overrides memoryPressureLevel default',
        (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        levelResolver: (event) =>
            event is MemoryPressureEvent ? Level.fatal : null,
      );
      observer.didHaveMemoryPressure();
      await tester.pump();
      expect(capture.records.single.level, Level.fatal);
    });
  });

  group('locale changes', () {
    testWidgets('emits LocaleChangeEvent with locales and previous_locales',
        (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      observer.didChangeLocales(const [Locale('en')]);
      observer.didChangeLocales(const [Locale('es')]);
      await tester.pump();
      expect(capture.records, hasLength(2));
      final second = capture.records[1].fields;
      expect(second['loq.app.locales'], ['es']);
      expect(second['loq.app.previous_locales'], ['en']);
    });

    testWidgets('passes null locales through', (tester) async {
      final observer = LoqLifecycleObserver(logger: logger);
      observer.didChangeLocales(null);
      await tester.pump();
      expect(capture.records, hasLength(1));
      expect(capture.records.single.fields['loq.app.locales'], isNull);
    });

    testWidgets('does not trigger a flush', (tester) async {
      final observer = LoqLifecycleObserver(
        logger: logger,
        flushHandlers: [capture],
      );
      observer.didChangeLocales(const [Locale('en')]);
      await tester.pump();
      expect(capture.flushCount, 0);
    });
  });

  group('background-duration tracking', () {
    testWidgets(
      'computes loq.app.background_duration_ms on resume after pause',
      (tester) async {
        final observer = LoqLifecycleObserver(logger: logger);
        observer.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 50));
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        final resumed = capture.records.last;
        final duration = resumed.fields['loq.app.background_duration_ms'];
        expect(duration, isA<int>());
        expect(duration! as int, greaterThanOrEqualTo(0));
      },
    );

    testWidgets(
      'omits background_duration on resume without a prior pause',
      (tester) async {
        final observer = LoqLifecycleObserver(logger: logger);
        observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        final fields = capture.records.single.fields;
        expect(fields.containsKey('loq.app.background_duration_ms'), isFalse);
      },
    );
  });
}
