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
}
