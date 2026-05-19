// Integration tests for `LoqErrorState` chained against a
// Crashlytics-shape package: one that *replaces* the global handlers
// rather than chaining. Checks that our chain-and-restore behaviour
// holds up against the real-world "drop the previous handler"
// pattern Firebase Crashlytics ships in its setup snippet.
//
// We don't depend on `firebase_crashlytics` directly. Its native
// plugin would refuse to load in a headless test. Instead a
// `_FakeCrashlytics` mimics the slot mutation.

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq/loq.dart';
// Visible-for-testing access to LoqErrorState.
import 'package:loq_flutter/src/init_loq.dart' show LoqErrorState;

import '../test_helpers.dart';

/// Mimics the Crashlytics setup snippet:
///
/// ```dart
/// FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterError;
/// PlatformDispatcher.instance.onError = (e, s) {
///   FirebaseCrashlytics.instance.recordError(e, s, fatal: true);
///   return true;
/// };
/// ```
///
/// Replaces both handlers without saving the prior values.
class _FakeCrashlytics {
  final List<FlutterErrorDetails> flutterReports = [];
  final List<Object> platformReports = [];

  void install() {
    FlutterError.onError = flutterReports.add;
    PlatformDispatcher.instance.onError = (error, _) {
      platformReports.add(error);
      return true;
    };
  }
}

void main() {
  late CapturingHandler capture;
  late Logger logger;
  FlutterExceptionHandler? savedFlutter;
  ErrorCallback? savedPlatform;

  setUp(() {
    savedFlutter = FlutterError.onError;
    savedPlatform = PlatformDispatcher.instance.onError;
    capture = CapturingHandler();
    logger = Logger(
      'test.crashlytics_coexistence',
      config: LogConfig(handlers: [capture]),
    );
  });

  tearDown(() {
    FlutterError.onError = savedFlutter;
    PlatformDispatcher.instance.onError = savedPlatform;
  });

  test(
    'Crashlytics-shape installed first, then loq: both receive errors',
    () {
      final crashlytics = _FakeCrashlytics()..install();
      final loq = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installFlutterError();
      addTearDown(loq.dispose);

      final boom = StateError('boom');
      FlutterError.onError!(
        FlutterErrorDetails(exception: boom, stack: StackTrace.current),
      );

      // loq's wrapper emits AND chains to Crashlytics-shape's handler.
      expect(capture.records, hasLength(1));
      expect(
        capture.records.single.fields['loq.error.source'],
        'flutter_framework',
      );
      expect(
        crashlytics.flutterReports,
        hasLength(1),
        reason: 'chain must reach Crashlytics-shape too',
      );
    },
  );

  test(
    'loq installed first, then Crashlytics-shape: Crashlytics wins',
    () {
      // The reverse order. Crashlytics-shape replaces our wrapper
      // without chaining, so subsequent errors bypass loq. This is
      // the documented install-order pitfall: README says install
      // loq AFTER Firebase/Crashlytics setup.
      final loq = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installFlutterError();
      addTearDown(loq.dispose);

      final crashlytics = _FakeCrashlytics()..install();

      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('boom'),
          stack: StackTrace.current,
        ),
      );

      expect(crashlytics.flutterReports, hasLength(1));
      expect(
        capture.records,
        isEmpty,
        reason: "Crashlytics-shape clobbered loq's handler; "
            'install order matters',
      );
    },
  );

  test(
    'disposing loq restores the Crashlytics-shape handler intact',
    () {
      final crashlytics = _FakeCrashlytics()..install();
      final crashlyticsHandler = FlutterError.onError;

      final loq = LoqErrorState(
        logger: logger,
        level: Level.fatal,
        reportSilentFlutterErrors: false,
      )..installFlutterError();

      // Our wrapper is now in place.
      expect(FlutterError.onError, isNot(equals(crashlyticsHandler)));

      loq.dispose();

      // Crashlytics-shape's handler is restored verbatim and still
      // receives errors.
      expect(FlutterError.onError, equals(crashlyticsHandler));
      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('after dispose'),
          stack: StackTrace.current,
        ),
      );
      expect(crashlytics.flutterReports, hasLength(1));
      expect(
        capture.records,
        isEmpty,
        reason: 'loq is disposed; should not emit',
      );
    },
  );

  test('PlatformDispatcher chain returns Crashlytics-shape value', () {
    final crashlytics = _FakeCrashlytics()..install();
    final loq = LoqErrorState(
      logger: logger,
      level: Level.fatal,
      reportSilentFlutterErrors: false,
    )..installPlatformDispatcher();
    addTearDown(loq.dispose);

    final returned = PlatformDispatcher.instance.onError!(
      StateError('async boom'),
      StackTrace.current,
    );

    // Crashlytics-shape returns true; our wrapper propagates that.
    expect(returned, isTrue);
    expect(crashlytics.platformReports, hasLength(1));
    expect(capture.records, hasLength(1));
    expect(capture.records.single.fields['loq.error.handled'], isTrue);
  });
}
