import 'package:loq/loq.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('when', () {
    test('applies processor when condition is true', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            when(
              (r) => r.level >= Level.warn,
              (r) => r.withFields({'flagged': true}),
            ),
          ],
        ),
      )
        ..info('low')
        ..warn('high');

      expect(
        handler.records[0].fields.containsKey('flagged'),
        isFalse,
      );
      expect(handler.records[1].fields['flagged'], true);
    });

    test('passes through when condition is false', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [when((r) => false, (r) => null)],
        ),
      ).info('msg');

      expect(handler.records, hasLength(1));
    });
  });

  group('addTimestamp', () {
    test('adds ISO 8601 timestamp field', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [addTimestamp()],
        ),
      ).info('msg');

      final ts = handler.records.single.fields['timestamp']! as String;
      expect(DateTime.tryParse(ts), isNotNull);
    });

    test('uses custom key', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [addTimestamp(key: 'ts')],
        ),
      ).info('msg');

      expect(handler.records.single.fields.containsKey('ts'), isTrue);
    });
  });

  group('addLevel', () {
    test('adds level name field', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [addLevel()],
        ),
      ).warn('msg');

      expect(handler.records.single.fields['level'], 'warn');
    });
  });

  group('addLoggerName', () {
    test('adds logger name field', () {
      final handler = TestHandler();
      Logger(
        'svc',
        config: LogConfig(
          handlers: [handler],
          processors: [addLoggerName()],
        ),
      ).info('msg');

      expect(handler.records.single.fields['logger'], 'svc');
    });

    test('skips when logger has no name', () {
      final handler = TestHandler();
      Logger(
        null,
        config: LogConfig(
          handlers: [handler],
          processors: [addLoggerName()],
        ),
      ).info('msg');

      expect(
        handler.records.single.fields.containsKey('logger'),
        isFalse,
      );
    });
  });

  group('addSource', () {
    test('adds source location field when present', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          captureSourceLocation: true,
          processors: [addSource()],
        ),
      ).info('msg');

      expect(
        handler.records.single.fields['source'],
        isA<String>(),
      );
      expect(
        handler.records.single.fields['source']! as String,
        contains('processors_test.dart'),
      );
    });

    test('skips when no source captured', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [addSource()],
        ),
      ).info('msg');

      expect(
        handler.records.single.fields.containsKey('source'),
        isFalse,
      );
    });
  });
}
