import 'package:loq/loq.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('Lazy', () {
    test('computes value on first access', () {
      var called = false;
      final lazy = Lazy(() {
        called = true;
        return 42;
      });
      expect(called, isFalse);
      expect(lazy.value, 42);
      expect(called, isTrue);
    });

    test('caches value — factory called only once', () {
      var count = 0;
      Lazy(() => ++count)
        ..value
        ..value
        ..value;
      expect(count, 1);
    });

    test('toString resolves the value', () {
      final lazy = Lazy(() => 'hello');
      expect(lazy.toString(), 'hello');
    });
  });

  group('Lazy in Logger', () {
    test('resolves Lazy values before Record creation', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).info('msg', fields: {'lazy': Lazy(() => 'computed')});

      final value = handler.records.single.fields['lazy'];
      expect(value, 'computed');
      expect(value, isNot(isA<Lazy>()));
    });

    test('Lazy not resolved on early-out', () {
      var resolved = false;
      final handler = TestHandler(minLevel: Level.error);
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).info(
        'msg',
        fields: {
          'lazy': Lazy(() {
            resolved = true;
            return 'val';
          }),
        },
      );

      expect(resolved, isFalse);
      expect(handler.records, isEmpty);
    });
  });
}
