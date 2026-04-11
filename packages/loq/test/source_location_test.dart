import 'package:loq/loq.dart';
import 'package:test/test.dart';

void main() {
  group('SourceLocation', () {
    test('parses VM stack trace format', () {
      final st = StackTrace.current;
      final loc = SourceLocation.parse(st);
      expect(loc, isNotNull);
      expect(loc!.file, contains('source_location_test.dart'));
      expect(loc.line, isPositive);
      expect(loc.member, isNotNull);
    });

    test('skipFrames skips the given number of frames', () {
      final st = StackTrace.current;
      final frame0 = SourceLocation.parse(st);
      final frame1 = SourceLocation.parse(st, skipFrames: 1);
      expect(frame0, isNotNull);
      expect(frame1, isNotNull);
      expect(frame0!.line, isNot(equals(frame1!.line)));
    });

    test('returns null for out-of-range skipFrames', () {
      final st = StackTrace.current;
      expect(SourceLocation.parse(st, skipFrames: 9999), isNull);
    });

    test('toString returns file:line', () {
      const loc = SourceLocation(file: 'foo.dart', line: 42);
      expect(loc.toString(), 'foo.dart:42');
    });

    test('captures column when present', () {
      final st = StackTrace.current;
      final loc = SourceLocation.parse(st);
      expect(loc, isNotNull);
      expect(loc!.column, isNotNull);
    });
  });

  group('SourceLocation in Logger', () {
    test('captures source when captureSourceLocation is true', () {
      final handler = _SourceTestHandler();
      Logger(
        'x',
        config: LogConfig(
          handlers: [handler],
          captureSourceLocation: true,
        ),
      ).info('msg');

      final source = handler.records.single.source;
      expect(source, isNotNull);
      expect(source!.file, contains('source_location_test.dart'));
    });

    test('source is null when captureSourceLocation is false', () {
      final handler = _SourceTestHandler();
      Logger(
        'x',
        config: LogConfig(handlers: [handler]),
      ).info('msg');

      expect(handler.records.single.source, isNull);
    });
  });
}

class _SourceTestHandler implements Handler {
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
