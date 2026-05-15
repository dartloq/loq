import 'dart:async';

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

  group('LogConfig.copyWith', () {
    test('overrides only the supplied fields', () {
      final original = LogConfig(
        processors: [filterByLevel(Level.warn)],
        handlers: [ConsoleHandler()],
        captureSourceLocation: true,
      );

      final newHandler = _SimpleHandler();
      final derived = original.copyWith(handlers: [newHandler]);

      expect(derived.handlers, [newHandler]);
      // Other fields preserved.
      expect(derived.processors, original.processors);
      expect(derived.captureSourceLocation, isTrue);
    });

    test('omitting a field preserves the current value', () {
      final original = LogConfig(
        processors: [filterByLevel(Level.warn)],
        captureSourceLocation: true,
      );
      final derived = original.copyWith();
      expect(derived.processors, original.processors);
      expect(derived.captureSourceLocation, isTrue);
    });

    test('returns a new instance, does not mutate the original', () {
      final original = LogConfig(handlers: [ConsoleHandler()]);
      final derived = original.copyWith(captureSourceLocation: true);

      expect(identical(original, derived), isFalse);
      expect(original.captureSourceLocation, isFalse);
      expect(derived.captureSourceLocation, isTrue);
    });

    test('composes cleanly with global for per-logger overrides', () {
      LogConfig.configure(
        handlers: [_SimpleHandler()],
        captureSourceLocation: true,
      );

      final perLogger = LogConfig.global.copyWith(
        processors: [filterByLevel(Level.warn)],
      );

      // Inherits global's handlers and captureSourceLocation.
      expect(perLogger.handlers, LogConfig.global.handlers);
      expect(perLogger.captureSourceLocation, isTrue);
      // Overrides only processors.
      expect(perLogger.processors, hasLength(1));
    });
  });

  group('Level.tryParse', () {
    test('parses standard names', () {
      expect(Level.tryParse('trace'), Level.trace);
      expect(Level.tryParse('debug'), Level.debug);
      expect(Level.tryParse('info'), Level.info);
      expect(Level.tryParse('warn'), Level.warn);
      expect(Level.tryParse('error'), Level.error);
      expect(Level.tryParse('fatal'), Level.fatal);
    });

    test('case-insensitive and trims whitespace', () {
      expect(Level.tryParse('INFO'), Level.info);
      expect(Level.tryParse(' Warn  '), Level.warn);
      expect(Level.tryParse('Error'), Level.error);
    });

    test('accepts warning as an alias for warn', () {
      expect(Level.tryParse('warning'), Level.warn);
      expect(Level.tryParse('WARNING'), Level.warn);
    });

    test('returns null for unknown names', () {
      expect(Level.tryParse('notice'), isNull);
      expect(Level.tryParse(''), isNull);
      expect(Level.tryParse('level(11)'), isNull);
    });
  });

  group('Logger.named', () {
    test('appends suffix with a dot', () {
      final db = Logger('app').named('db');
      // Verify by logging and inspecting record.
      final handler = _SimpleHandler();
      Logger('app', config: LogConfig(handlers: [handler]))
          .named('db')
          .info('hello');
      expect(handler.records.single.loggerName, 'app.db');
      // Smoke: chain twice.
      expect(db.named('queries').runtimeType, Logger);
    });

    test('chains across multiple levels', () {
      final handler = _SimpleHandler();
      Logger('a', config: LogConfig(handlers: [handler]))
          .named('b')
          .named('c')
          .info('hello');
      expect(handler.records.single.loggerName, 'a.b.c');
    });

    test('uses suffix alone when parent has no name', () {
      final handler = _SimpleHandler();
      Logger(null, config: LogConfig(handlers: [handler]))
          .named('db')
          .info('hello');
      expect(handler.records.single.loggerName, 'db');
    });

    test('inherits bound fields', () {
      final handler = _SimpleHandler();
      Logger('a', config: LogConfig(handlers: [handler]))
          .withFields({'tenant': 'acme'})
          .named('db')
          .info('hello');
      expect(handler.records.single.fields['tenant'], 'acme');
      expect(handler.records.single.loggerName, 'a.db');
    });
  });

  group('LogConfig.shutdown', () {
    test('closes every handler in the current global config', () async {
      final a = _ClosableHandler();
      final b = _ClosableHandler();
      LogConfig.configure(handlers: [a, b]);

      await LogConfig.shutdown();

      expect(a.closed, isTrue);
      expect(b.closed, isTrue);
    });
  });

  group('Handler error containment', () {
    test('handle() exceptions are routed to onHandlerError', () {
      final reports = <_HandlerError>[];
      final cfg = LogConfig(
        handlers: [_ThrowingOnHandle(), _SimpleHandler()],
        onHandlerError: (h, e, st) => reports.add(_HandlerError(h, e)),
      );
      // Sibling _SimpleHandler must still receive the record.
      final sibling = cfg.handlers.last as _SimpleHandler;

      Logger('x', config: cfg).info('hello');

      expect(reports, hasLength(1));
      expect(reports.single.handler, isA<_ThrowingOnHandle>());
      expect(reports.single.error, isA<StateError>());
      expect(sibling.records, hasLength(1));
    });

    test('isEnabled() exceptions are reported and the handler is skipped', () {
      final reports = <_HandlerError>[];
      final cfg = LogConfig(
        handlers: [_ThrowingOnEnabled()],
        onHandlerError: (h, e, st) => reports.add(_HandlerError(h, e)),
      );

      Logger('x', config: cfg).info('hello');

      expect(reports, hasLength(1));
      expect(reports.single.handler, isA<_ThrowingOnEnabled>());
    });

    test('default onHandlerError prints a loq-prefixed diagnostic', () {
      final printed = <String>[];
      final spec = ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      );

      Zone.current.fork(specification: spec).run(() {
        final cfg = LogConfig(handlers: [_ThrowingOnHandle()]);
        Logger('x', config: cfg).info('hello');
      });

      expect(printed, hasLength(1));
      expect(printed.single, startsWith('loq: _ThrowingOnHandle threw:'));
      expect(printed.single, contains('handle blew up'));
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

class _ClosableHandler implements Handler {
  bool closed = false;

  @override
  bool isEnabled(Level level) => true;

  @override
  void handle(Record record) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _ThrowingOnHandle implements Handler {
  @override
  bool isEnabled(Level level) => true;

  @override
  void handle(Record record) => throw StateError('handle blew up');

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

class _ThrowingOnEnabled implements Handler {
  @override
  bool isEnabled(Level level) => throw StateError('isEnabled blew up');

  @override
  void handle(Record record) {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

class _HandlerError {
  _HandlerError(this.handler, this.error);
  final Handler handler;
  final Object error;
}
