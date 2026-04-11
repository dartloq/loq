import 'dart:async';

import 'package:loq/loq.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('MultiHandler', () {
    test('dispatches to all enabled handlers', () {
      final h1 = TestHandler(minLevel: Level.info);
      final h2 = TestHandler(minLevel: Level.error);
      MultiHandler([h1, h2]).handle(makeRecord('err', level: Level.error));

      expect(h1.records, hasLength(1));
      expect(h2.records, hasLength(1));
    });

    test('skips disabled handlers', () {
      final h1 = TestHandler(minLevel: Level.info);
      final h2 = TestHandler(minLevel: Level.error);
      MultiHandler([h1, h2]).handle(makeRecord('info'));

      expect(h1.records, hasLength(1));
      expect(h2.records, isEmpty);
    });

    test('isEnabled returns true if any handler is enabled', () {
      final h1 = TestHandler(minLevel: Level.error);
      final h2 = TestHandler(minLevel: Level.info);
      final multi = MultiHandler([h1, h2]);

      expect(multi.isEnabled(Level.info), isTrue);
      expect(multi.isEnabled(Level.trace), isFalse);
    });

    test('flush calls all handlers', () async {
      var flushed = 0;
      final h1 = _CallbackHandler(onFlush: () => flushed++);
      final h2 = _CallbackHandler(onFlush: () => flushed++);
      await MultiHandler([h1, h2]).flush();
      expect(flushed, 2);
    });

    test('close calls all handlers', () async {
      var closed = 0;
      final h1 = _CallbackHandler(onClose: () => closed++);
      final h2 = _CallbackHandler(onClose: () => closed++);
      await MultiHandler([h1, h2]).close();
      expect(closed, 2);
    });
  });
}

class _CallbackHandler implements Handler {
  _CallbackHandler({
    void Function()? onFlush,
    void Function()? onClose,
  })  : _onFlush = onFlush ?? (() {}),
        _onClose = onClose ?? (() {});

  final void Function() _onFlush;
  final void Function() _onClose;

  @override
  bool isEnabled(Level level) => true;

  @override
  void handle(Record record) {}

  @override
  Future<void> flush() async => _onFlush();

  @override
  Future<void> close() async => _onClose();
}
