import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loq_flutter/loq_flutter.dart';

void main() {
  group('LifecycleEvent sealed hierarchy', () {
    const defaults = {'loq.app.lifecycle.state': 'paused'};

    test('AppResumedEvent state is resumed', () {
      const event = AppResumedEvent(
        previousState: AppLifecycleState.paused,
        defaults: defaults,
      );
      expect(event.state, AppLifecycleState.resumed);
      expect(event.previousState, AppLifecycleState.paused);
      expect(event.defaults, defaults);
    });

    test('AppInactiveEvent state is inactive', () {
      const event = AppInactiveEvent(
        previousState: AppLifecycleState.resumed,
        defaults: defaults,
      );
      expect(event.state, AppLifecycleState.inactive);
      expect(event.previousState, AppLifecycleState.resumed);
    });

    test('AppHiddenEvent state is hidden', () {
      const event = AppHiddenEvent(
        previousState: AppLifecycleState.inactive,
        defaults: defaults,
      );
      expect(event.state, AppLifecycleState.hidden);
      expect(event.previousState, AppLifecycleState.inactive);
    });

    test('AppPausedEvent state is paused', () {
      const event = AppPausedEvent(
        previousState: AppLifecycleState.hidden,
        defaults: defaults,
      );
      expect(event.state, AppLifecycleState.paused);
      expect(event.previousState, AppLifecycleState.hidden);
    });

    test('AppDetachedEvent state is detached', () {
      const event = AppDetachedEvent(
        previousState: AppLifecycleState.paused,
        defaults: defaults,
      );
      expect(event.state, AppLifecycleState.detached);
      expect(event.previousState, AppLifecycleState.paused);
    });

    test('previousState is nullable when no prior state', () {
      const event = AppResumedEvent(
        previousState: null,
        defaults: defaults,
      );
      expect(event.previousState, isNull);
    });

    test('exhaustive switch on LifecycleEvent compiles', () {
      String shortNameOf(LifecycleEvent event) => switch (event) {
            AppResumedEvent() => 'resumed',
            AppInactiveEvent() => 'inactive',
            AppHiddenEvent() => 'hidden',
            AppPausedEvent() => 'paused',
            AppDetachedEvent() => 'detached',
            MemoryPressureEvent() => 'memory_pressure',
            LocaleChangeEvent() => 'locale_change',
          };
      expect(
        shortNameOf(
          const AppPausedEvent(
            previousState: null,
            defaults: defaults,
          ),
        ),
        'paused',
      );
    });

    test('AppLifecycleStateEvent groups the five state variants', () {
      String? stateOf(LifecycleEvent event) => switch (event) {
            AppLifecycleStateEvent(:final state) => state.name,
            _ => null,
          };
      expect(
        stateOf(
          const AppHiddenEvent(previousState: null, defaults: defaults),
        ),
        'hidden',
      );
      expect(
        stateOf(
          const MemoryPressureEvent(defaults: defaults),
        ),
        isNull,
      );
    });
  });

  group('MemoryPressureEvent', () {
    test('carries defaults', () {
      const event = MemoryPressureEvent(
        defaults: {'loq.memory.pressure': true},
      );
      expect(event.defaults['loq.memory.pressure'], isTrue);
    });
  });

  group('LocaleChangeEvent', () {
    test('carries locales, previousLocales, defaults', () {
      const en = Locale('en');
      const es = Locale('es');
      const event = LocaleChangeEvent(
        locales: [es],
        previousLocales: [en],
        defaults: {
          'loq.app.locales': ['es'],
        },
      );
      expect(event.locales, [es]);
      expect(event.previousLocales, [en]);
      expect(event.defaults['loq.app.locales'], ['es']);
    });

    test('locales and previousLocales may be null', () {
      const event = LocaleChangeEvent(
        locales: null,
        previousLocales: null,
        defaults: {},
      );
      expect(event.locales, isNull);
      expect(event.previousLocales, isNull);
    });
  });
}
