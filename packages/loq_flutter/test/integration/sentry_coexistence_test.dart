// Integration tests for `LoqErrorState` chained against a Sentry-shape
// package: one that *correctly* chains and restores like loq does.
// Checks that two well-behaved chain-and-restore packages compose:
// install order doesn't matter, and disposal in any order leaves the
// other intact.
//
// We don't depend on `sentry_flutter` directly (heavy native plugins).
// `_FakeSentry` mimics Sentry's `FlutterErrorIntegration` and
// `OnErrorIntegration` minus the actual capture: just the slot
// management.

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq/loq.dart';
// Visible-for-testing access to LoqErrorState.
import 'package:loq_flutter/src/init_loq.dart' show LoqErrorState;

import '../test_helpers.dart';

/// Mimics Sentry's chain-and-restore wiring:
/// `_previous = FlutterError.onError; FlutterError.onError = _wrap;`
/// and restores on `close`.
class _FakeSentry {
  final List<FlutterErrorDetails> flutterReports = [];
  final List<Object> platformReports = [];
  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  bool _installed = false;

  void install() {
    if (_installed) return;
    _previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      flutterReports.add(details);
      _previousFlutter?.call(details);
    };
    _previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      platformReports.add(error);
      final prev = _previousPlatform?.call(error, stack) ?? false;
      return prev;
    };
    _installed = true;
  }

  void close() {
    if (!_installed) return;
    // Sentry doesn't bother checking identity on restore; the wrapper
    // closure isn't a named identity. Just restore.
    FlutterError.onError = _previousFlutter;
    PlatformDispatcher.instance.onError = _previousPlatform;
    _installed = false;
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
      'test.sentry_coexistence',
      config: LogConfig(handlers: [capture]),
    );
  });

  tearDown(() {
    FlutterError.onError = savedFlutter;
    PlatformDispatcher.instance.onError = savedPlatform;
  });

  test('Sentry-shape then loq: both receive errors via the chain', () {
    final sentry = _FakeSentry()..install();
    final loq = LoqErrorState(
      logger: logger,
      level: Level.fatal,
      reportSilentFlutterErrors: false,
    )..installFlutterError();
    addTearDown(loq.dispose);
    addTearDown(sentry.close);

    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      ),
    );

    expect(capture.records, hasLength(1));
    expect(sentry.flutterReports, hasLength(1));
  });

  test('loq then Sentry-shape: both receive errors via the chain', () {
    // Reverse install order. Both packages chain, so order doesn't
    // matter, unlike Crashlytics-shape.
    final loq = LoqErrorState(
      logger: logger,
      level: Level.fatal,
      reportSilentFlutterErrors: false,
    )..installFlutterError();
    final sentry = _FakeSentry()..install();
    addTearDown(loq.dispose);
    addTearDown(sentry.close);

    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('boom'),
        stack: StackTrace.current,
      ),
    );

    // Sentry-shape is on top; it chains to loq. Both fire.
    expect(sentry.flutterReports, hasLength(1));
    expect(capture.records, hasLength(1));
  });

  test('disposing loq leaves Sentry-shape intact', () {
    final sentry = _FakeSentry()..install();
    final sentryHandler = FlutterError.onError;

    LoqErrorState(
      logger: logger,
      level: Level.fatal,
      reportSilentFlutterErrors: false,
    )
      ..installFlutterError()
      ..dispose();

    // Sentry-shape's wrapper is back in the slot.
    expect(FlutterError.onError, equals(sentryHandler));
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('after dispose'),
        stack: StackTrace.current,
      ),
    );
    expect(sentry.flutterReports, hasLength(1));
    expect(capture.records, isEmpty);
    sentry.close();
  });

  test('closing Sentry-shape after loq install leaves loq intact', () {
    final loq = LoqErrorState(
      logger: logger,
      level: Level.fatal,
      reportSilentFlutterErrors: false,
    )..installFlutterError();
    final sentry = _FakeSentry()..install();
    final loqHandler = sentry._previousFlutter;

    // Sentry's close restores whatever the slot was before its
    // install, which was loq's wrapper.
    sentry.close();
    expect(
      FlutterError.onError,
      equals(loqHandler),
      reason: "Sentry-shape close should restore loq's wrapper, "
          'not blow it away',
    );

    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('after sentry close'),
        stack: StackTrace.current,
      ),
    );
    expect(
      capture.records,
      hasLength(1),
      reason: 'loq still active after Sentry-shape close',
    );
    loq.dispose();
  });
}
