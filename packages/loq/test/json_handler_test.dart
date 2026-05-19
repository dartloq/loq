import 'dart:convert';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('JsonHandler (new features)', () {
    test('renders FieldGroup as nested JSON object', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord(
          'msg',
          fields: {
            'http': const FieldGroup({'method': 'GET', 'status': 200}),
          },
        ),
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      final http = parsed['http'] as Map<String, dynamic>;
      expect(http['method'], 'GET');
      expect(http['status'], 200);
    });

    test('includes source in JSON output', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord(
          'msg',
          source: const SourceLocation(file: 'app.dart', line: 10),
        ),
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['source'], 'app.dart:10');
    });

    test('omits source when absent', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add)
          .handle(makeRecord('msg'));

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed.containsKey('source'), isFalse);
    });

    test('resolves Lazy values (belt-and-suspenders)', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord('msg', fields: {'lazy': Lazy(() => 'resolved')}),
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['lazy'], 'resolved');
    });

    test('flush and close complete without error', () async {
      final handler = JsonHandler();
      await handler.flush();
      await handler.close();
    });

    test('DateTime renders as ISO 8601 string', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord(
          'msg',
          time: DateTime.utc(2024),
          fields: {'when': DateTime.utc(2026, 5, 15, 10, 30)},
        ),
      );
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['when'], '2026-05-15T10:30:00.000Z');
    });

    test('Duration renders as milliseconds', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord(
          'msg',
          fields: {'elapsed': const Duration(milliseconds: 1500)},
        ),
      );
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['elapsed'], 1500);
    });

    test('Uri renders as canonical string', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord(
          'msg',
          fields: {'src': Uri.parse('https://example.com/api?q=1')},
        ),
      );
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['src'], 'https://example.com/api?q=1');
    });

    test('dateTimeFormatter customizes Record.time', () {
      final lines = <String>[];
      JsonHandler(
        minLevel: Level.trace,
        writer: lines.add,
        dateTimeFormatter: (dt) => dt.millisecondsSinceEpoch.toString(),
      ).handle(
        makeRecord('msg', time: DateTime.utc(2026, 5, 15, 10, 30)),
      );
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(
        parsed['time'],
        DateTime.utc(2026, 5, 15, 10, 30).millisecondsSinceEpoch.toString(),
      );
    });

    test('dateTimeFormatter also applies to DateTime field values', () {
      final lines = <String>[];
      JsonHandler(
        minLevel: Level.trace,
        writer: lines.add,
        dateTimeFormatter: (dt) => 'epoch:${dt.millisecondsSinceEpoch}',
      ).handle(
        makeRecord(
          'msg',
          time: DateTime.utc(2024),
          fields: {'when': DateTime.utc(2026, 5, 15, 10, 30)},
        ),
      );
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['when'], startsWith('epoch:'));
      expect(parsed['time'], startsWith('epoch:'));
    });

    test('omitting dateTimeFormatter keeps the ISO 8601 default', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        makeRecord('msg', time: DateTime.utc(2026, 5, 15, 10, 30)),
      );
      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['time'], '2026-05-15T10:30:00.000Z');
    });
  });
}
