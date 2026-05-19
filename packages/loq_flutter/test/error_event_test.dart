import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq_flutter/loq_flutter.dart';

void main() {
  group('ErrorEvent sealed hierarchy', () {
    final boom = StateError('boom');
    final stack = StackTrace.current;
    const defaults = {'exception.type': 'StateError'};

    test('FlutterFrameworkErrorEvent reads error from details', () {
      final details = FlutterErrorDetails(
        exception: boom,
        stack: stack,
        library: 'widgets library',
      );
      final event = FlutterFrameworkErrorEvent(
        details: details,
        defaults: defaults,
      );
      expect(event.error, same(boom));
      expect(event.stackTrace, same(stack));
      expect(event.handled, isFalse);
      expect(event.details.library, 'widgets library');
    });

    test('FlutterFrameworkErrorEvent.stackTrace falls back to empty', () {
      final details = FlutterErrorDetails(exception: boom);
      final event = FlutterFrameworkErrorEvent(
        details: details,
        defaults: defaults,
      );
      expect(event.stackTrace, StackTrace.empty);
    });

    test('PlatformDispatcherErrorEvent carries handled flag', () {
      final event = PlatformDispatcherErrorEvent(
        error: boom,
        stackTrace: stack,
        handled: true,
        defaults: defaults,
      );
      expect(event.error, same(boom));
      expect(event.stackTrace, same(stack));
      expect(event.handled, isTrue);
      expect(event.defaults, defaults);
    });

    test('ZoneGuardErrorEvent.handled is always true', () {
      final event = ZoneGuardErrorEvent(
        error: boom,
        stackTrace: stack,
        defaults: defaults,
      );
      expect(event.handled, isTrue);
    });

    test('exhaustive switch on ErrorEvent compiles', () {
      String sourceOf(ErrorEvent event) => switch (event) {
            FlutterFrameworkErrorEvent() => 'flutter_framework',
            PlatformDispatcherErrorEvent() => 'platform_dispatcher',
            ZoneGuardErrorEvent() => 'zone_guard',
          };
      expect(
        sourceOf(
          ZoneGuardErrorEvent(
            error: boom,
            stackTrace: stack,
            defaults: defaults,
          ),
        ),
        'zone_guard',
      );
    });
  });
}
