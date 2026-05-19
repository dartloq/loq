import 'package:loq/loq.dart';
import 'package:loq/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('RecordingHandler', () {
    test('records list starts empty and count is zero', () {
      final h = RecordingHandler();
      expect(h.records, isEmpty);
      expect(h.count, 0);
    });

    test('handle keeps records in arrival order', () {
      final h = RecordingHandler()
        ..handle(makeRecord('first'))
        ..handle(makeRecord('second'));
      expect(h.records.map((r) => r.message), ['first', 'second']);
      expect(h.count, 2);
    });

    test('records getter returns an unmodifiable list', () {
      final h = RecordingHandler()..handle(makeRecord('msg'));
      expect(() => h.records.add(makeRecord('msg')), throwsUnsupportedError);
    });

    test('clear drops every kept record', () {
      final h = RecordingHandler()
        ..handle(makeRecord('msg'))
        ..handle(makeRecord('msg'));
      expect(h.count, 2);
      h.clear();
      expect(h.count, 0);
      expect(h.records, isEmpty);
    });

    test('default minLevel of trace lets every level through', () {
      final h = RecordingHandler();
      expect(h.isEnabled(Level.trace), isTrue);
      expect(h.isEnabled(Level.debug), isTrue);
      expect(h.isEnabled(Level.fatal), isTrue);
    });

    test('a higher minLevel gates isEnabled', () {
      final h = RecordingHandler(minLevel: Level.warn);
      expect(h.isEnabled(Level.debug), isFalse);
      expect(h.isEnabled(Level.info), isFalse);
      expect(h.isEnabled(Level.warn), isTrue);
      expect(h.isEnabled(Level.error), isTrue);
    });

    test('flush and close finish without error', () async {
      final h = RecordingHandler();
      await h.flush();
      await h.close();
    });

    test('at returns only records sitting exactly at that level', () {
      final h = RecordingHandler()
        ..handle(makeRecord('i'))
        ..handle(makeRecord('w', level: Level.warn))
        ..handle(makeRecord('i2'));
      expect(h.at(Level.info).map((r) => r.message), ['i', 'i2']);
      expect(h.at(Level.warn).map((r) => r.message), ['w']);
      expect(h.at(Level.error), isEmpty);
    });

    test('atOrAbove returns records at or above the given level', () {
      final h = RecordingHandler()
        ..handle(makeRecord('d', level: Level.debug))
        ..handle(makeRecord('i'))
        ..handle(makeRecord('e', level: Level.error));
      expect(h.atOrAbove(Level.info).map((r) => r.message), ['i', 'e']);
      expect(h.atOrAbove(Level.error).map((r) => r.message), ['e']);
      expect(h.atOrAbove(Level.fatal), isEmpty);
    });

    test('from matches by logger name, with null for anonymous loggers', () {
      final h = RecordingHandler()
        ..handle(makeRecord('a', loggerName: 'a'))
        ..handle(makeRecord('b', loggerName: 'b'))
        ..handle(makeRecord('n'));
      expect(h.from('a').map((r) => r.message), ['a']);
      expect(h.from('b').map((r) => r.message), ['b']);
      expect(h.from(null).map((r) => r.message), ['n']);
    });

    test('withField matches presence of the key', () {
      final h = RecordingHandler()
        ..handle(makeRecord('with', fields: {'k': 1}))
        ..handle(makeRecord('without'));
      expect(h.withField('k').map((r) => r.message), ['with']);
    });

    test('withFieldValue matches the exact value, including null', () {
      final h = RecordingHandler()
        ..handle(makeRecord('one', fields: {'k': 1}))
        ..handle(makeRecord('two', fields: {'k': 2}))
        ..handle(makeRecord('null', fields: {'k': null}));
      expect(h.withFieldValue('k', 1).map((r) => r.message), ['one']);
      expect(h.withFieldValue('k', null).map((r) => r.message), ['null']);
    });

    test('messageContaining works with a String substring', () {
      final h = RecordingHandler()
        ..handle(makeRecord('order 1 placed'))
        ..handle(makeRecord('order 2 placed'))
        ..handle(makeRecord('refund issued'));
      expect(
        h.messageContaining('order').map((r) => r.message),
        ['order 1 placed', 'order 2 placed'],
      );
    });

    test('messageContaining works with a RegExp', () {
      final h = RecordingHandler()
        ..handle(makeRecord('order 1 placed'))
        ..handle(makeRecord('order 2 placed'))
        ..handle(makeRecord('refund issued'));
      expect(
        h.messageContaining(RegExp(r'\d')).map((r) => r.message),
        ['order 1 placed', 'order 2 placed'],
      );
    });

    test('countAt and countAtOrAbove report sizes', () {
      final h = RecordingHandler()
        ..handle(makeRecord('msg'))
        ..handle(makeRecord('msg'))
        ..handle(makeRecord('msg', level: Level.warn))
        ..handle(makeRecord('msg', level: Level.error));
      expect(h.countAt(Level.info), 2);
      expect(h.countAt(Level.warn), 1);
      expect(h.countAtOrAbove(Level.warn), 2);
      expect(h.countAtOrAbove(Level.info), 4);
    });

    test('plugs into a Logger via LogConfig', () {
      final h = RecordingHandler();
      Logger('svc', config: LogConfig(handlers: [h]))
        ..info('hi')
        ..warn('uh oh');
      expect(h.count, 2);
      expect(h.from('svc').map((r) => r.message), ['hi', 'uh oh']);
      expect(h.atOrAbove(Level.warn).single.message, 'uh oh');
    });
  });
}
