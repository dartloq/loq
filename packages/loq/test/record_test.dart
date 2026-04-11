import 'dart:async';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

void main() {
  group('Record.withSource', () {
    test('sets source and preserves other fields', () {
      final record = Record(
        time: DateTime(2024),
        level: Level.info,
        message: 'msg',
        fields: {'a': 1},
        loggerName: 'test',
        zone: Zone.current,
      );
      const loc = SourceLocation(file: 'a.dart', line: 10);
      final updated = record.withSource(loc);

      expect(updated.source, loc);
      expect(updated.message, 'msg');
      expect(updated.fields, {'a': 1});
      expect(updated.loggerName, 'test');
      expect(record.source, isNull);
    });
  });

  group('Record.copyWith', () {
    test('replaces specified fields', () {
      final record = Record(
        time: DateTime(2024),
        level: Level.info,
        message: 'original',
        fields: {'a': 1},
        loggerName: 'test',
        zone: Zone.current,
      );
      final copy = record.copyWith(
        message: 'changed',
        fields: {'b': 2},
      );

      expect(copy.message, 'changed');
      expect(copy.fields, {'b': 2});
      expect(copy.level, Level.info);
      expect(copy.loggerName, 'test');
    });

    test('keeps original values when not specified', () {
      final record = Record(
        time: DateTime(2024),
        level: Level.warn,
        message: 'msg',
        fields: {'x': 1},
        loggerName: 'svc',
        source: const SourceLocation(file: 'f.dart', line: 1),
        zone: Zone.current,
      );
      final copy = record.copyWith(message: 'new');

      expect(copy.level, Level.warn);
      expect(copy.fields, {'x': 1});
      expect(copy.loggerName, 'svc');
      expect(copy.source?.file, 'f.dart');
    });
  });
}
