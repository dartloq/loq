import 'dart:async';
import 'dart:convert';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

/// A handler that captures records for testing.
class TestHandler implements Handler {
  TestHandler({this.minLevel = Level.trace});

  final Level minLevel;
  final List<Record> records = [];

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

void main() {
  // -------------------------------------------------------------------------
  // Level
  // -------------------------------------------------------------------------

  group('Level', () {
    test('values are ordered with gaps', () {
      expect(Level.trace.value, 0);
      expect(Level.debug.value, 4);
      expect(Level.info.value, 8);
      expect(Level.warn.value, 12);
      expect(Level.error.value, 16);
      expect(Level.fatal.value, 20);
    });

    test('>= operator', () {
      expect(Level.info >= Level.debug, isTrue);
      expect(Level.info >= Level.info, isTrue);
      expect(Level.debug >= Level.info, isFalse);
    });

    test('< operator', () {
      expect(Level.debug < Level.info, isTrue);
      expect(Level.info < Level.info, isFalse);
      expect(Level.info < Level.debug, isFalse);
    });

    test('compareTo', () {
      expect(Level.trace.compareTo(Level.fatal), isNegative);
      expect(Level.info.compareTo(Level.info), isZero);
      expect(Level.fatal.compareTo(Level.trace), isPositive);
    });

    test('values sort correctly', () {
      final shuffled = [
        Level.fatal,
        Level.trace,
        Level.warn,
        Level.debug,
        Level.error,
        Level.info,
      ]..sort();
      expect(shuffled, [
        Level.trace,
        Level.debug,
        Level.info,
        Level.warn,
        Level.error,
        Level.fatal,
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Record
  // -------------------------------------------------------------------------

  group('Record', () {
    test('stores all fields', () {
      final time = DateTime(2024);
      final zone = Zone.current;
      final record = Record(
        time: time,
        level: Level.info,
        message: 'hello',
        fields: {'key': 'value'},
        loggerName: 'test',
        zone: zone,
      );

      expect(record.time, time);
      expect(record.level, Level.info);
      expect(record.message, 'hello');
      expect(record.fields, {'key': 'value'});
      expect(record.loggerName, 'test');
      expect(record.zone, zone);
    });

    test('loggerName is optional', () {
      final record = Record(
        time: DateTime(2024),
        level: Level.info,
        message: 'hi',
        fields: {},
        zone: Zone.current,
      );
      expect(record.loggerName, isNull);
    });

    test('withFields merges fields', () {
      final original = Record(
        time: DateTime(2024),
        level: Level.info,
        message: 'msg',
        fields: {'a': 1, 'b': 2},
        loggerName: 'test',
        zone: Zone.current,
      );

      final updated = original.withFields({'b': 99, 'c': 3});

      expect(updated.fields, {'a': 1, 'b': 99, 'c': 3});
      // Original is unchanged.
      expect(original.fields, {'a': 1, 'b': 2});
      // Metadata is preserved.
      expect(updated.time, original.time);
      expect(updated.level, original.level);
      expect(updated.message, original.message);
      expect(updated.loggerName, original.loggerName);
    });
  });

  // -------------------------------------------------------------------------
  // Logger
  // -------------------------------------------------------------------------

  group('Logger', () {
    late TestHandler handler;
    late Logger log;

    setUp(() {
      handler = TestHandler();
      log = Logger('test', config: LogConfig(handlers: [handler]));
    });

    test('emits records at each level', () {
      log
        ..trace('t')
        ..debug('d')
        ..info('i')
        ..warn('w')
        ..error('e')
        ..fatal('f');

      expect(handler.records.map((r) => r.level).toList(), [
        Level.trace,
        Level.debug,
        Level.info,
        Level.warn,
        Level.error,
        Level.fatal,
      ]);
      expect(
        handler.records.map((r) => r.message).toList(),
        ['t', 'd', 'i', 'w', 'e', 'f'],
      );
    });

    test('sets loggerName', () {
      log.info('hi');
      expect(handler.records.single.loggerName, 'test');
    });

    test('loggerName is null when created without a name', () {
      Logger(null, config: LogConfig(handlers: [handler])).info('hi');
      expect(handler.records.single.loggerName, isNull);
    });

    test('includes call-site fields', () {
      log.info('msg', fields: {'a': 1, 'b': 'two'});
      expect(handler.records.single.fields, {'a': 1, 'b': 'two'});
    });

    test('error method includes error and stackTrace fields', () {
      final st = StackTrace.current;
      log.error('oops', error: 'bad', stackTrace: st, fields: {'ctx': 42});

      final fields = handler.records.single.fields;
      expect(fields['error'], 'bad');
      expect(fields['stackTrace'], st);
      expect(fields['ctx'], 42);
    });

    test('fatal method includes error and stackTrace fields', () {
      final st = StackTrace.current;
      log.fatal(
        'crash',
        error: Exception('boom'),
        stackTrace: st,
        fields: {'ctx': 'shutdown'},
      );

      final fields = handler.records.single.fields;
      expect(fields['error'], isA<Exception>());
      expect(fields['stackTrace'], st);
      expect(fields['ctx'], 'shutdown');
    });

    test('error/fatal omit error fields when not provided', () {
      log
        ..error('oops')
        ..fatal('crash');

      for (final r in handler.records) {
        expect(r.fields.containsKey('error'), isFalse);
        expect(r.fields.containsKey('stackTrace'), isFalse);
      }
    });

    test('sets time close to now', () {
      final before = DateTime.now();
      log.info('now');
      final after = DateTime.now();

      final recorded = handler.records.single.time;
      expect(recorded.isAfter(before) || recorded == before, isTrue);
      expect(recorded.isBefore(after) || recorded == after, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Logger.withFields (bound context)
  // -------------------------------------------------------------------------

  group('Logger.withFields', () {
    late TestHandler handler;
    late Logger log;

    setUp(() {
      handler = TestHandler();
      log = Logger('svc', config: LogConfig(handlers: [handler]));
    });

    test('includes bound fields in every record', () {
      log.withFields({'requestId': 'r-1'})
        ..info('a')
        ..info('b');

      for (final r in handler.records) {
        expect(r.fields['requestId'], 'r-1');
      }
    });

    test('does not mutate the original logger', () {
      final _ = log.withFields({'x': 1});
      log.info('original');
      expect(handler.records.single.fields.containsKey('x'), isFalse);
    });

    test('call-site fields override bound fields', () {
      log.withFields({'a': 1}).info('msg', fields: {'a': 99});
      expect(handler.records.single.fields['a'], 99);
    });

    test('chained withFields merge', () {
      log.withFields({'a': 1}).withFields({'b': 2}).info('msg');
      expect(handler.records.single.fields, {'a': 1, 'b': 2});
    });

    test('preserves logger name', () {
      log.withFields({'x': 1}).info('msg');
      expect(handler.records.single.loggerName, 'svc');
    });
  });

  // -------------------------------------------------------------------------
  // Early-out filtering
  // -------------------------------------------------------------------------

  group('early-out filtering', () {
    test('skips record creation when no handler is enabled', () {
      final handler = TestHandler(minLevel: Level.error);
      Logger('x', config: LogConfig(handlers: [handler]))
        ..info('ignored')
        ..error('kept');

      expect(handler.records, hasLength(1));
      expect(handler.records.single.level, Level.error);
    });

    test('dispatches to only enabled handlers', () {
      final infoHandler = TestHandler(minLevel: Level.info);
      final errorHandler = TestHandler(minLevel: Level.error);
      Logger(
        'x',
        config: LogConfig(handlers: [infoHandler, errorHandler]),
      )
        ..info('info only')
        ..error('both');

      expect(infoHandler.records, hasLength(2));
      expect(errorHandler.records, hasLength(1));
      expect(errorHandler.records.single.message, 'both');
    });
  });

  // -------------------------------------------------------------------------
  // Processors
  // -------------------------------------------------------------------------

  group('processors', () {
    test('processor can transform records', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            (r) => r.withFields({'injected': true}),
          ],
        ),
      ).info('msg');
      expect(handler.records.single.fields['injected'], true);
    });

    test('processor returning null drops the record', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [(r) => null],
        ),
      ).info('dropped');

      expect(handler.records, isEmpty);
    });

    test('processors run in order', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            (r) => r.withFields({'step': 1}),
            (r) => r.withFields({'step': 2}),
          ],
        ),
      ).info('msg');

      // Second processor overwrites 'step'.
      expect(handler.records.single.fields['step'], 2);
    });

    test('later processors see earlier mutations', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            (r) => r.withFields({'n': 1}),
            (r) => r.withFields({'n': (r.fields['n']! as int) + 1}),
          ],
        ),
      ).info('msg');

      expect(handler.records.single.fields['n'], 2);
    });

    test('null from first processor short-circuits the chain', () {
      var secondCalled = false;
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            (r) => null,
            (r) {
              secondCalled = true;
              return r;
            },
          ],
        ),
      ).info('msg');

      expect(handler.records, isEmpty);
      expect(secondCalled, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Built-in processors
  // -------------------------------------------------------------------------

  group('filterByLevel', () {
    test('passes records at or above the level', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [filterByLevel(Level.warn)],
        ),
      )
        ..info('no')
        ..warn('yes')
        ..error('yes');

      expect(handler.records.map((r) => r.message).toList(), ['yes', 'yes']);
    });
  });

  group('redact', () {
    test('replaces matching field values', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            redact({'password', 'ssn'}),
          ],
        ),
      ).info('msg', fields: {'password': 'secret', 'name': 'Alice'});

      final fields = handler.records.single.fields;
      expect(fields['password'], '***');
      expect(fields['name'], 'Alice');
    });

    test('uses custom replacement', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            redact({'token'}, replacement: '[REDACTED]'),
          ],
        ),
      ).info('msg', fields: {'token': 'abc123'});

      expect(handler.records.single.fields['token'], '[REDACTED]');
    });

    test('leaves non-matching fields untouched', () {
      final handler = TestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [
            redact({'secret'}),
          ],
        ),
      ).info('msg', fields: {'visible': 'ok'});

      expect(handler.records.single.fields, {'visible': 'ok'});
    });
  });

  group('sample', () {
    test('keeps every Nth record', () {
      final handler = TestHandler();
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          processors: [sample(3)],
        ),
      );

      for (var i = 1; i <= 9; i++) {
        log.info('msg$i');
      }

      expect(
        handler.records.map((r) => r.message).toList(),
        ['msg3', 'msg6', 'msg9'],
      );
    });
  });

  // -------------------------------------------------------------------------
  // Zone context
  // -------------------------------------------------------------------------

  group('withLogContext', () {
    late TestHandler handler;

    setUp(() {
      handler = TestHandler();
    });

    test('injects zone fields into records', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      withLogContext({'requestId': 'r-1'}, () {
        log.info('inside');
      });

      expect(handler.records.single.fields['requestId'], 'r-1');
    });

    test('nested contexts merge', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      withLogContext({'a': 1}, () {
        withLogContext({'b': 2}, () {
          log.info('nested');
        });
      });

      final fields = handler.records.single.fields;
      expect(fields['a'], 1);
      expect(fields['b'], 2);
    });

    test('inner context overrides outer for same key', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      withLogContext({'x': 'outer'}, () {
        withLogContext({'x': 'inner'}, () {
          log.info('msg');
        });
      });

      expect(handler.records.single.fields['x'], 'inner');
    });

    test('call-site fields override zone fields', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      withLogContext({'a': 'zone'}, () {
        log.info('msg', fields: {'a': 'call'});
      });

      expect(handler.records.single.fields['a'], 'call');
    });

    test('bound fields override zone fields', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      final bound = log.withFields({'a': 'bound'});

      withLogContext({'a': 'zone'}, () {
        bound.info('msg');
      });

      expect(handler.records.single.fields['a'], 'bound');
    });

    test('works across async boundaries', () async {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      await withLogContext({'async': true}, () async {
        await Future<void>.delayed(Duration.zero);
        log.info('after await');
      });

      expect(handler.records.single.fields['async'], true);
    });

    test('does not leak outside the zone', () {
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      withLogContext({'scoped': true}, () {
        log.info('inside');
      });
      log.info('outside');

      expect(handler.records[0].fields['scoped'], true);
      expect(handler.records[1].fields.containsKey('scoped'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Field precedence (zone < bound < call-site)
  // -------------------------------------------------------------------------

  group('field precedence', () {
    test('call-site > bound > zone', () {
      final handler = TestHandler();
      final log = Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          zoneAccessor: defaultZoneAccessor,
        ),
      );

      final bound = log.withFields({'x': 'bound', 'y': 'bound'});

      withLogContext({'x': 'zone', 'y': 'zone', 'z': 'zone'}, () {
        bound.info('msg', fields: {'x': 'call'});
      });

      final fields = handler.records.single.fields;
      expect(fields['x'], 'call');
      expect(fields['y'], 'bound');
      expect(fields['z'], 'zone');
    });
  });

  // -------------------------------------------------------------------------
  // LogConfig
  // -------------------------------------------------------------------------

  group('LogConfig', () {
    tearDown(LogConfig.reset);

    test('global defaults to ConsoleHandler', () {
      expect(LogConfig.global.handlers, hasLength(1));
      expect(LogConfig.global.handlers.first, isA<ConsoleHandler>());
    });

    test('configure updates global config', () {
      final handler = TestHandler();
      LogConfig.configure(handlers: [handler]);
      expect(LogConfig.global.handlers, [handler]);
    });

    test('configure preserves unset fields', () {
      final processor = filterByLevel(Level.warn);
      LogConfig.configure(processors: [processor]);
      // Handlers should still be the previous value.
      expect(LogConfig.global.processors, [processor]);
      expect(LogConfig.global.handlers, isNotEmpty);
    });

    test('reset restores defaults', () {
      LogConfig.configure(handlers: [TestHandler()], processors: [(r) => r]);
      LogConfig.reset();
      expect(LogConfig.global.handlers, hasLength(1));
      expect(LogConfig.global.handlers.first, isA<ConsoleHandler>());
      expect(LogConfig.global.processors, isEmpty);
    });

    test('logger uses global config by default', () {
      final handler = TestHandler();
      LogConfig.configure(handlers: [handler]);

      Logger('global').info('hello');

      expect(handler.records, hasLength(1));
    });

    test('per-logger config overrides global', () {
      final globalHandler = TestHandler();
      final localHandler = TestHandler();
      LogConfig.configure(handlers: [globalHandler]);

      Logger('local', config: LogConfig(handlers: [localHandler]))
          .info('hello');

      expect(globalHandler.records, isEmpty);
      expect(localHandler.records, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // ConsoleHandler
  // -------------------------------------------------------------------------

  group('ConsoleHandler', () {
    /// Runs [body] while capturing all [print] output.
    List<String> capturePrint(void Function() body) {
      final lines = <String>[];
      final spec = ZoneSpecification(
        print: (self, parent, zone, line) => lines.add(line),
      );
      Zone.current.fork(specification: spec).run(body);
      return lines;
    }

    test('isEnabled respects minLevel', () {
      final handler = ConsoleHandler(minLevel: Level.warn);
      expect(handler.isEnabled(Level.info), isFalse);
      expect(handler.isEnabled(Level.warn), isTrue);
      expect(handler.isEnabled(Level.error), isTrue);
    });

    test('defaults to info minLevel', () {
      final handler = ConsoleHandler();
      expect(handler.isEnabled(Level.debug), isFalse);
      expect(handler.isEnabled(Level.info), isTrue);
    });

    test('prints formatted message with time, level, and logger name', () {
      final lines = capturePrint(() {
        Logger('svc', config: LogConfig(handlers: [ConsoleHandler(minLevel: Level.trace)]))
            .info('hello');
      });

      expect(lines, hasLength(1));
      expect(lines.single, matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} \[INFO \] svc: hello$')));
    });

    test('prints fields after pipe separator', () {
      final lines = capturePrint(() {
        Logger('x', config: LogConfig(handlers: [ConsoleHandler(minLevel: Level.trace)]))
            .info('msg', fields: {'a': 1, 'b': 'two'});
      });

      expect(lines.single, contains('| a=1, b=two'));
    });

    test('omits logger name when null', () {
      final lines = capturePrint(() {
        Logger(null, config: LogConfig(handlers: [ConsoleHandler(minLevel: Level.trace)]))
            .warn('no name');
      });

      expect(lines.single, matches(RegExp(r'\[WARN \] no name$')));
    });

    test('prints error and stackTrace on separate lines', () {
      final st = StackTrace.current;
      final lines = capturePrint(() {
        Logger('x', config: LogConfig(handlers: [ConsoleHandler(minLevel: Level.trace)]))
            .error('oops', error: 'boom', stackTrace: st);
      });

      expect(lines, hasLength(3));
      expect(lines[0], isNot(contains('error=')));
      expect(lines[1], '  error: boom');
      expect(lines[2], '  $st');
    });
  });

  // -------------------------------------------------------------------------
  // JsonHandler
  // -------------------------------------------------------------------------

  group('JsonHandler', () {
    test('isEnabled respects minLevel', () {
      final handler = JsonHandler(minLevel: Level.error);
      expect(handler.isEnabled(Level.warn), isFalse);
      expect(handler.isEnabled(Level.error), isTrue);
    });

    test('writes valid JSON lines', () {
      final lines = <String>[];
      final handler = JsonHandler(minLevel: Level.trace, writer: lines.add);
      Logger('json', config: LogConfig(handlers: [handler]))
          .info('hello', fields: {'count': 42});

      expect(lines, hasLength(1));
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['level'], 'info');
      expect(parsed['msg'], 'hello');
      expect(parsed['logger'], 'json');
      expect(parsed['count'], 42);
      expect(parsed['time'], isA<String>());
    });

    test('omits logger key when name is null', () {
      final lines = <String>[];
      final handler = JsonHandler(minLevel: Level.trace, writer: lines.add);
      Logger(null, config: LogConfig(handlers: [handler])).info('anon');

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed.containsKey('logger'), isFalse);
    });

    test('normalizes nested objects to strings', () {
      final lines = <String>[];
      final handler = JsonHandler(minLevel: Level.trace, writer: lines.add);
      Logger('x', config: LogConfig(handlers: [handler]))
          .info('msg', fields: {'obj': Object()});

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['obj'], isA<String>());
    });

    test('normalizes lists and maps', () {
      final lines = <String>[];
      final handler = JsonHandler(minLevel: Level.trace, writer: lines.add);
      Logger('x', config: LogConfig(handlers: [handler])).info(
        'msg',
        fields: {
          'list': [1, 'two', Object()],
          'map': {42: 'num-key'},
        },
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      final list = parsed['list'] as List;
      expect(list[0], 1);
      expect(list[1], 'two');
      expect(list[2], isA<String>());
      final map = parsed['map'] as Map;
      expect(map['42'], 'num-key');
    });

    test('preserves primitive types', () {
      final lines = <String>[];
      final handler = JsonHandler(minLevel: Level.trace, writer: lines.add);
      Logger('x', config: LogConfig(handlers: [handler])).info(
        'msg',
        fields: {
          'str': 'hello',
          'int': 42,
          'double': 3.14,
          'bool': true,
          'null': null,
        },
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['str'], 'hello');
      expect(parsed['int'], 42);
      expect(parsed['double'], 3.14);
      expect(parsed['bool'], true);
      expect(parsed['null'], isNull);
    });
  });

  // -------------------------------------------------------------------------
  // defaultZoneAccessor
  // -------------------------------------------------------------------------

  group('defaultZoneAccessor', () {
    test('returns null outside withLogContext', () {
      expect(defaultZoneAccessor(Zone.current), isNull);
    });

    test('returns fields inside withLogContext', () {
      withLogContext({'a': 1}, () {
        expect(defaultZoneAccessor(Zone.current), {'a': 1});
      });
    });
  });
}
