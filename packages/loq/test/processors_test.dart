import 'package:loq/loq.dart';
import 'package:loq/testing.dart';
import 'package:test/test.dart';

void main() {
  group('when', () {
    test('applies processor when condition is true', () {
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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

  group('levelByName', () {
    test('empty rules apply defaultLevel to everything', () {
      final handler = RecordingHandler();
      Logger(
        'app.foo',
        config: LogConfig(
          handlers: [handler],
          processors: [levelByName({}, defaultLevel: Level.warn)],
        ),
      )
        ..info('low')
        ..warn('high');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'high');
    });

    test('exact name match wins', () {
      final handler = RecordingHandler();
      Logger(
        'app',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'app': Level.warn}),
          ],
        ),
      )
        ..info('low')
        ..warn('high');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'high');
    });

    test('parent prefix carries down to a deeper logger name', () {
      final handler = RecordingHandler();
      Logger(
        'app.db.queries',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'app': Level.warn}),
          ],
        ),
      )
        ..info('low')
        ..warn('high');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'high');
    });

    test('longest matching prefix wins over a shorter one', () {
      final handler = RecordingHandler();
      Logger(
        'app.db.queries',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({
              'app': Level.warn,
              'app.db': Level.error,
            }),
          ],
        ),
      )
        ..warn('not enough')
        ..error('enough');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'enough');
    });

    test('empty-string key acts as a root catch-all', () {
      final handler = RecordingHandler();
      Logger(
        'unrelated',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'': Level.error}),
          ],
        ),
      )
        ..warn('low')
        ..error('high');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'high');
    });

    test('null logger name falls back to defaultLevel, not the empty rule', () {
      final handler = RecordingHandler();
      Logger(
        null,
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'': Level.fatal}, defaultLevel: Level.warn),
          ],
        ),
      )
        ..info('low')
        ..warn('high');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'high');
    });

    test('threshold is inclusive — equal level is kept', () {
      final handler = RecordingHandler();
      Logger(
        'app',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'app': Level.warn}),
          ],
        ),
      ).warn('at threshold');

      expect(handler.records, hasLength(1));
    });

    test('rule does not bleed across name boundaries', () {
      // 'foo' rule must NOT fire on 'foobar' — only on 'foo' and 'foo.*'.
      final handler = RecordingHandler();
      Logger(
        'foobar',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'foo': Level.fatal}, defaultLevel: Level.info),
          ],
        ),
      )
        ..debug('drops')
        ..info('keeps');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'keeps');
    });

    test('empty-name logger hits the empty-string rule', () {
      final handler = RecordingHandler();
      Logger(
        '',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'': Level.error}),
          ],
        ),
      )
        ..warn('drops')
        ..error('keeps');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'keeps');
    });

    test('empty-name logger without an empty rule uses defaultLevel', () {
      final handler = RecordingHandler();
      Logger(
        '',
        config: LogConfig(
          handlers: [handler],
          processors: [
            levelByName({'app': Level.fatal}, defaultLevel: Level.error),
          ],
        ),
      )
        ..warn('drops')
        ..error('keeps');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.message, 'keeps');
    });
  });

  group('addSource', () {
    test('adds source location field when present', () {
      final handler = RecordingHandler();
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
      final handler = RecordingHandler();
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
