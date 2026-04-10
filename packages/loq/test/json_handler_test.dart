import 'dart:async';
import 'dart:convert';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

void main() {
  group('JsonHandler (new features)', () {
    test('renders FieldGroup as nested JSON object', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {
            'http': const FieldGroup({'method': 'GET', 'status': 200}),
          },
          zone: Zone.current,
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
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {},
          source: const SourceLocation(file: 'app.dart', line: 10),
          zone: Zone.current,
        ),
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['source'], 'app.dart:10');
    });

    test('omits source when absent', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {},
          zone: Zone.current,
        ),
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed.containsKey('source'), isFalse);
    });

    test('resolves Lazy values (belt-and-suspenders)', () {
      final lines = <String>[];
      JsonHandler(minLevel: Level.trace, writer: lines.add).handle(
        Record(
          time: DateTime(2024),
          level: Level.info,
          message: 'msg',
          fields: {'lazy': Lazy(() => 'resolved')},
          zone: Zone.current,
        ),
      );

      final parsed = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(parsed['lazy'], 'resolved');
    });

    test('flush and close complete without error', () async {
      final handler = JsonHandler();
      await handler.flush();
      await handler.close();
    });
  });
}
