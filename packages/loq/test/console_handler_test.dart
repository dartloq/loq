import 'dart:async';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

/// Runs [body] while capturing all [print] output.
List<String> capturePrint(void Function() body) {
  final lines = <String>[];
  final spec = ZoneSpecification(
    print: (self, parent, zone, line) => lines.add(line),
  );
  Zone.current.fork(specification: spec).run(body);
  return lines;
}

void main() {
  group('ConsoleHandler (new features)', () {
    test('shows source location in output', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace).handle(
          Record(
            time: DateTime(2024),
            level: Level.info,
            message: 'hello',
            fields: {},
            loggerName: 'test',
            source: const SourceLocation(file: 'app.dart', line: 42),
            zone: Zone.current,
          ),
        );
      });

      expect(lines.single, contains('(app.dart:42)'));
    });

    test('renders FieldGroup with dotted keys', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace).handle(
          Record(
            time: DateTime(2024),
            level: Level.info,
            message: 'req',
            fields: {
              'http': const FieldGroup({'method': 'GET', 'path': '/api'}),
            },
            zone: Zone.current,
          ),
        );
      });

      expect(lines.single, contains('http.method=GET'));
      expect(lines.single, contains('http.path=/api'));
    });

    test('no source location in output when absent', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace).handle(
          Record(
            time: DateTime(2024),
            level: Level.info,
            message: 'hello',
            fields: {},
            zone: Zone.current,
          ),
        );
      });

      expect(lines.single, isNot(contains('(')));
    });

    test('flush and close complete without error', () async {
      final handler = ConsoleHandler();
      await handler.flush();
      await handler.close();
    });
  });

  group('ConsoleHandler (color support)', () {
    Record makeRecord(Level level) => Record(
          time: DateTime(2024),
          level: level,
          message: 'msg',
          fields: const {},
          loggerName: 'app',
          zone: Zone.current,
        );

    test('no escapes when useColor is false (default)', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace).handle(makeRecord(Level.info));
      });

      expect(lines.single, isNot(contains('\x1B[')));
    });

    test('info wraps level token in green escape', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.info));
      });

      // Level token wrapped with ANSI green + reset.
      expect(lines.single, contains('\x1B[32mINFO \x1B[0m'));
    });

    test('warn uses yellow', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.warn));
      });
      expect(lines.single, contains('\x1B[33mWARN \x1B[0m'));
    });

    test('error uses red', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.error));
      });
      expect(lines.single, contains('\x1B[31mERROR\x1B[0m'));
    });

    test('fatal uses bright red bold', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.fatal));
      });
      expect(lines.single, contains('\x1B[1;91mFATAL\x1B[0m'));
    });

    test('debug uses cyan', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.debug));
      });
      expect(lines.single, contains('\x1B[36mDEBUG\x1B[0m'));
    });

    test('trace uses gray', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.trace));
      });
      expect(lines.single, contains('\x1B[90mTRACE\x1B[0m'));
    });

    test('custom level falls into nearest band by severity', () {
      // Level(11) sits between info(8) and warn(12) — should render
      // as info green.
      const notice = Level(11);
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(notice));
      });
      // The level name renders as "LEVEL(11)" which is longer than 5 chars,
      // so padding leaves it as-is. Check for the color wrap.
      expect(lines.single, contains('\x1B[32m'));
      expect(lines.single, contains('\x1B[0m'));
    });

    test('only the level token is colored, not the rest of the line', () {
      final lines = capturePrint(() {
        ConsoleHandler(minLevel: Level.trace, useColor: true)
            .handle(makeRecord(Level.error));
      });

      // Reset occurs immediately after the level token, before the
      // logger name and message.
      final line = lines.single;
      final resetIdx = line.indexOf('\x1B[0m');
      final appIdx = line.indexOf(' app:');
      expect(resetIdx, greaterThan(0));
      expect(appIdx, greaterThan(resetIdx));
      // No further escapes after the reset.
      expect(
        line.substring(resetIdx + '\x1B[0m'.length).contains('\x1B['),
        isFalse,
      );
    });
  });

  group('ConsoleHandler (custom level colors)', () {
    Record makeRecord(Level level) => Record(
          time: DateTime(2024),
          level: level,
          message: 'msg',
          fields: const {},
          loggerName: 'app',
          zone: Zone.current,
        );

    test('exact match for a built-in level overrides the default', () {
      final lines = capturePrint(() {
        ConsoleHandler(
          minLevel: Level.trace,
          useColor: true,
          levelColors: const {Level.info: '\x1B[35m'}, // magenta
        ).handle(makeRecord(Level.info));
      });
      expect(lines.single, contains('\x1B[35mINFO \x1B[0m'));
    });

    test('exact match for a custom level wins', () {
      const notice = Level(11);
      final lines = capturePrint(() {
        ConsoleHandler(
          minLevel: Level.trace,
          useColor: true,
          levelColors: const {notice: '\x1B[35m'}, // magenta
        ).handle(makeRecord(notice));
      });
      expect(lines.single, contains('\x1B[35m'));
      expect(lines.single, contains('\x1B[0m'));
    });

    test(
        'custom level falls through to user-overridden band when no '
        'exact match', () {
      const notice = Level(11); // bands as info
      final lines = capturePrint(() {
        ConsoleHandler(
          minLevel: Level.trace,
          useColor: true,
          // Only override info; notice has no exact entry but bands to info.
          levelColors: const {Level.info: '\x1B[35m'},
        ).handle(makeRecord(notice));
      });
      expect(lines.single, contains('\x1B[35m'));
    });

    test(
        'levels not in the map keep the built-in defaults '
        '(partial overrides)', () {
      final lines = capturePrint(() {
        ConsoleHandler(
          minLevel: Level.trace,
          useColor: true,
          // Override only info; error should remain default red.
          levelColors: const {Level.info: '\x1B[35m'},
        ).handle(makeRecord(Level.error));
      });
      expect(lines.single, contains('\x1B[31mERROR\x1B[0m'));
    });

    test('empty levelColors map behaves like null (all defaults)', () {
      final lines = capturePrint(() {
        ConsoleHandler(
          minLevel: Level.trace,
          useColor: true,
          levelColors: const {},
        ).handle(makeRecord(Level.warn));
      });
      expect(lines.single, contains('\x1B[33mWARN \x1B[0m'));
    });
  });
}
