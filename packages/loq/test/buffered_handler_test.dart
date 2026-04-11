import 'package:loq/loq.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('BufferedHandler', () {
    test('flushes at maxBufferSize', () async {
      final batched = _TestBufferedHandler(maxBufferSize: 3);
      for (var i = 0; i < 3; i++) {
        batched.handle(makeRecord('msg$i'));
      }
      // Wait for the fire-and-forget flush to complete.
      await Future<void>.delayed(Duration.zero);
      expect(batched.batches, hasLength(1));
      expect(batched.batches.first, hasLength(3));
    });

    test('does not flush below threshold', () async {
      final batched = _TestBufferedHandler(maxBufferSize: 10)
        ..handle(makeRecord('msg'));
      await Future<void>.delayed(Duration.zero);
      expect(batched.batches, isEmpty);
    });

    test('flushes on close', () async {
      final batched = _TestBufferedHandler()..handle(makeRecord('msg'));
      await batched.close();
      expect(batched.batches, hasLength(1));
    });

    test('ignores records after close', () async {
      final batched = _TestBufferedHandler();
      await batched.close();
      batched.handle(makeRecord('ignored'));
      expect(batched.batches.expand((b) => b), isEmpty);
    });

    test('isEnabled returns false after close', () async {
      final batched = _TestBufferedHandler();
      await batched.close();
      expect(batched.isEnabled(Level.fatal), isFalse);
    });

    test('concurrent flush guard prevents double-flush', () async {
      final batched = _SlowBufferedHandler()
        ..handle(makeRecord('a'))
        ..handle(makeRecord('b'));

      // Start two flushes concurrently.
      final f1 = batched.flush();
      final f2 = batched.flush();
      await Future.wait([f1, f2]);

      // Only one batch should have been written.
      expect(batched.batches, hasLength(1));
    });

    test('flushes on timer interval', () async {
      final batched = _TestBufferedHandler(
        flushInterval: const Duration(milliseconds: 50),
      )..handle(makeRecord('msg'));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(batched.batches, hasLength(1));

      await batched.close();
    });
  });
}

class _TestBufferedHandler extends BufferedHandler {
  _TestBufferedHandler({
    super.maxBufferSize,
    super.flushInterval,
  });

  final List<List<Record>> batches = [];

  @override
  Future<void> writeAll(List<Record> records) async {
    batches.add(records);
  }
}

class _SlowBufferedHandler extends BufferedHandler {
  _SlowBufferedHandler();

  final List<List<Record>> batches = [];

  @override
  Future<void> writeAll(List<Record> records) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    batches.add(records);
  }
}
