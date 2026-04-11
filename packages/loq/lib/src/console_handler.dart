import 'package:loq/src/field_group.dart';
import 'package:loq/src/handler.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/record.dart';

/// Prints human-readable log output. Intended for development.
class ConsoleHandler implements Handler {
  /// Creates a console handler.
  ConsoleHandler({this.minLevel = Level.info});

  /// Minimum level to display.
  final Level minLevel;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) {
    final time = record.time.toIso8601String().substring(11, 23);
    final lvl = record.level.name.toUpperCase().padRight(5);
    final src = record.loggerName != null ? ' ${record.loggerName}:' : '';
    final loc = record.source != null ? ' (${record.source})' : '';

    final buf = StringBuffer('$time [$lvl]$src ${record.message}$loc');

    final visible = record.fields.entries
        .where((e) => e.key != 'error' && e.key != 'stackTrace');
    if (visible.isNotEmpty) {
      buf.write(
        ' | ${visible.map((e) => _formatField(e.key, e.value)).join(', ')}',
      );
    }

    // Since this is a console handler, print is acceptable here
    // ignore: avoid_print
    print(buf);

    final err = record.fields['error'];
    if (err != null) {
      // Since this is a console handler, print is acceptable here
      // ignore: avoid_print
      print('  error: $err');
    }
    final st = record.fields['stackTrace'];
    if (st != null) {
      final lines = st.toString().trimRight().split('\n');
      for (final line in lines) {
        // Since this is a console handler, print is acceptable here
        // ignore: avoid_print
        print('  $line');
      }
    }
  }

  String _formatField(String key, Object? value) {
    if (value is FieldGroup) {
      return value.fields.entries
          .map((e) => _formatField('$key.${e.key}', e.value))
          .join(', ');
    }
    return '$key=$value';
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
