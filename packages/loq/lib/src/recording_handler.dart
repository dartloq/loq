import 'package:loq/src/handler.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/record.dart';

/// A [Handler] that keeps records in memory for tests.
///
/// Install it as the only handler in your test setup. That silences
/// other output and gives you a list of records to look at:
///
/// ```dart
/// final recorder = RecordingHandler();
/// LogConfig.configure(handlers: [recorder]);
///
/// // ... run the code under test ...
///
/// expect(recorder.records, hasLength(1));
/// expect(recorder.atOrAbove(Level.error), isEmpty);
/// expect(recorder.from('app.publish').first.fields['orderId'], 'abc');
/// ```
///
/// All filter getters return lazy [Iterable]s, so chained calls stay
/// cheap. Call [clear] between test cases if you reuse one instance.
class RecordingHandler implements Handler {
  /// Creates a handler. [minLevel] drops records before [handle] is
  /// even called. The default keeps every level.
  RecordingHandler({this.minLevel = Level.trace});

  /// Records below this level are dropped by [isEnabled].
  final Level minLevel;

  final List<Record> _records = [];

  /// All kept records, in the order they arrived. The returned list
  /// cannot be changed; call [clear] to empty the handler.
  List<Record> get records => List.unmodifiable(_records);

  /// How many records have been kept.
  int get count => _records.length;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) => _records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  /// Drops every kept record.
  void clear() => _records.clear();

  /// Records whose level is exactly [level].
  Iterable<Record> at(Level level) => _records.where((r) => r.level == level);

  /// Records whose level is at or above [level].
  Iterable<Record> atOrAbove(Level level) =>
      _records.where((r) => r.level >= level);

  /// Records from a logger with the given [name]. Pass `null` to find
  /// records from loggers with no name.
  Iterable<Record> from(String? name) =>
      _records.where((r) => r.loggerName == name);

  /// Records whose [Record.fields] holds [key], regardless of value.
  Iterable<Record> withField(String key) =>
      _records.where((r) => r.fields.containsKey(key));

  /// Records where [Record.fields] maps [key] to [value]. Uses `==`.
  Iterable<Record> withFieldValue(String key, Object? value) =>
      _records.where((r) => r.fields[key] == value);

  /// Records whose [Record.message] is matched by [pattern]. Pass a
  /// plain [String] for substring search, or a [RegExp].
  Iterable<Record> messageContaining(Pattern pattern) =>
      _records.where((r) => pattern.allMatches(r.message).isNotEmpty);

  /// How many records sit exactly at [level].
  int countAt(Level level) => at(level).length;

  /// How many records sit at or above [level].
  int countAtOrAbove(Level level) => atOrAbove(level).length;
}
