import 'package:loq/loq.dart';
import 'package:test/test.dart';

void main() {
  group('LogConfig (new features)', () {
    tearDown(LogConfig.reset);

    test('captureSourceLocation defaults to false', () {
      expect(LogConfig.global.captureSourceLocation, isFalse);
    });

    test('configure sets captureSourceLocation', () {
      LogConfig.configure(captureSourceLocation: true);
      expect(LogConfig.global.captureSourceLocation, isTrue);
    });

    test('reset clears captureSourceLocation', () {
      LogConfig.configure(captureSourceLocation: true);
      LogConfig.reset();
      expect(LogConfig.global.captureSourceLocation, isFalse);
    });
  });

  group('Level (custom levels)', () {
    test('custom level has numeric name', () {
      const notice = Level(10);
      expect(notice.name, 'level(10)');
    });

    test('custom level slots between built-in levels', () {
      const notice = Level(10);
      expect(notice >= Level.info, isTrue);
      expect(notice < Level.warn, isTrue);
    });

    test('custom level equality', () {
      const a = Level(10);
      const b = Level(10);
      expect(a, equals(b));
    });
  });

  group('Logger.isEnabled', () {
    test('delegates to handlers', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [ConsoleHandler(minLevel: Level.warn)],
        ),
      );
      expect(log.isEnabled(Level.info), isFalse);
      expect(log.isEnabled(Level.warn), isTrue);
      expect(log.isEnabled(Level.error), isTrue);
    });
  });

  group('Logger.log() with custom levels', () {
    test('emits record with custom level', () {
      final handler = _SimpleHandler();
      const notice = Level(10);
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).log(notice, 'custom');

      expect(handler.records.single.level, notice);
      expect(handler.records.single.level.name, 'level(10)');
    });

    test('log() passes error and stackTrace as fields', () {
      final handler = _SimpleHandler();
      final st = StackTrace.current;
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).log(Level.error, 'oops', error: 'bad', stackTrace: st);

      final fields = handler.records.single.fields;
      expect(fields['error'], 'bad');
      expect(fields['stackTrace'], st);
    });

    test('log() works without optional parameters', () {
      final handler = _SimpleHandler();
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).log(Level.info, 'bare');

      expect(handler.records.single.message, 'bare');
      expect(handler.records.single.fields, isEmpty);
    });

    test('log() merges fields with error and stackTrace', () {
      final handler = _SimpleHandler();
      final st = StackTrace.current;
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).log(
        Level.error,
        'oops',
        error: 'bad',
        stackTrace: st,
        fields: {'ctx': 42},
      );

      final fields = handler.records.single.fields;
      expect(fields['ctx'], 42);
      expect(fields['error'], 'bad');
      expect(fields['stackTrace'], st);
    });
  });
}

class _SimpleHandler implements Handler {
  final List<Record> records = [];

  @override
  bool isEnabled(Level level) => true;

  @override
  void handle(Record record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
