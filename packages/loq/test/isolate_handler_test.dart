import 'dart:async';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

void main() {
  group('IsolateHandler', () {
    test('serialize/deserialize round-trip', () {
      final messages = <Object?>[];
      final handler = IsolateHandler(messages.add);
      Logger(
        'worker',
        config: LogConfig(handlers: [handler]),
      ).info('hello', fields: {'count': 42, 'flag': true});

      expect(messages, hasLength(1));
      final record = IsolateHandler.deserialize(
        messages.first! as Map<String, Object?>,
      );
      expect(record.message, 'hello');
      expect(record.level, Level.info);
      expect(record.loggerName, 'worker');
      expect(record.fields['count'], 42);
      expect(record.fields['flag'], true);
    });

    test('coerces FieldGroup to nested map', () {
      final messages = <Object?>[];
      IsolateHandler(messages.add).handle(
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {
            'http': const FieldGroup({'method': 'GET'}),
          },
          zone: Zone.current,
        ),
      );

      final data = messages.first! as Map<String, Object?>;
      final fields = data['fields']! as Map<String, Object?>;
      expect(fields['http'], isA<Map<String, Object?>>());
      expect((fields['http']! as Map<String, Object?>)['method'], 'GET');
    });

    test('coerces non-primitive types to strings', () {
      final messages = <Object?>[];
      IsolateHandler(messages.add).handle(
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {'obj': Object()},
          zone: Zone.current,
        ),
      );

      final data = messages.first! as Map<String, Object?>;
      final fields = data['fields']! as Map<String, Object?>;
      expect(fields['obj'], isA<String>());
    });

    test('preserves null fields', () {
      final messages = <Object?>[];
      IsolateHandler(messages.add).handle(
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {'nullable': null},
          zone: Zone.current,
        ),
      );

      final data = messages.first! as Map<String, Object?>;
      final fields = data['fields']! as Map<String, Object?>;
      expect(fields.containsKey('nullable'), isTrue);
      expect(fields['nullable'], isNull);
    });

    test('isEnabled respects minLevel', () {
      final handler = IsolateHandler((_) {}, minLevel: Level.warn);
      expect(handler.isEnabled(Level.info), isFalse);
      expect(handler.isEnabled(Level.warn), isTrue);
    });

    test('flush and close complete without error', () async {
      final handler = IsolateHandler((_) {});
      await handler.flush();
      await handler.close();
    });
  });
}
