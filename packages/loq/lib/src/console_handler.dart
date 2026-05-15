import 'package:loq/src/field_group.dart';
import 'package:loq/src/handler.dart';
import 'package:loq/src/level.dart';
import 'package:loq/src/record.dart';

const _ansiReset = '\x1B[0m';

/// Built-in level → ANSI escape mapping. Keys are the six standard
/// levels; lookups for these specific levels happen after band mapping
/// resolves custom levels (see [ConsoleHandler._ansiColorFor]).
const _defaultLevelColors = <Level, String>{
  Level.trace: '\x1B[90m', //    gray
  Level.debug: '\x1B[36m', //    cyan
  Level.info: '\x1B[32m', //     green
  Level.warn: '\x1B[33m', //     yellow
  Level.error: '\x1B[31m', //    red
  Level.fatal: '\x1B[1;91m', //  bright red bold
};

/// Returns the built-in standard level whose color band [level] falls
/// into. Custom levels (e.g. `Level(11)`) snap to the nearest standard
/// level at or below their severity — `Level(11)` → `Level.info`.
Level _bandLevelFor(Level level) => switch (level.value) {
      >= 20 => Level.fatal,
      >= 16 => Level.error,
      >= 12 => Level.warn,
      >= 8 => Level.info,
      >= 4 => Level.debug,
      _ => Level.trace,
    };

/// Prints human-readable log output. Intended for development.
class ConsoleHandler implements Handler {
  /// Creates a console handler.
  ///
  /// When [useColor] is `true`, the level token is wrapped in ANSI
  /// color escapes (gray / cyan / green / yellow / red / bright-red
  /// for trace through fatal). The rest of the line stays in the
  /// terminal's default color. Default `false` to avoid emitting
  /// escape sequences into non-TTY contexts (CI logs, file
  /// redirection).
  ///
  /// loq core can't autodetect terminal capabilities (no `dart:io`).
  /// Wire detection at your app's entrypoint:
  ///
  /// ```dart
  /// import 'dart:io';
  ///
  /// LogConfig.configure(handlers: [
  ///   ConsoleHandler(
  ///     useColor: stdout.supportsAnsiEscapes &&
  ///         Platform.environment['NO_COLOR'] == null,
  ///   ),
  /// ]);
  /// ```
  ///
  /// [levelColors] overrides the built-in color scheme. Keys are looked
  /// up by:
  ///
  /// 1. **Exact match** — `Level(11)` looks up `Level(11)` first.
  /// 2. **Nearest band** — `Level(11)` falls into the info band, so
  ///    `levelColors[Level.info]` is checked next.
  /// 3. **Built-in default** — finally the ship-with-loq scheme.
  ///
  /// Map values are raw ANSI opening escapes (e.g. `'\x1B[35m'` for
  /// magenta); the reset escape is appended automatically.
  ConsoleHandler({
    this.minLevel = Level.info,
    this.useColor = false,
    Map<Level, String>? levelColors,
  }) : _levelColors = levelColors;

  /// Minimum level to display.
  final Level minLevel;

  /// Whether to colorize the level token with ANSI escapes.
  final bool useColor;

  final Map<Level, String>? _levelColors;

  /// Resolves the ANSI escape for [level]: exact match → band override
  /// → built-in band default.
  String _ansiColorFor(Level level) {
    final exact = _levelColors?[level];
    if (exact != null) return exact;
    final band = _bandLevelFor(level);
    return _levelColors?[band] ?? _defaultLevelColors[band]!;
  }

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) {
    final time = record.time.toIso8601String().substring(11, 23);
    final lvlText = record.level.name.toUpperCase().padRight(5);
    final lvl = useColor
        ? '${_ansiColorFor(record.level)}$lvlText$_ansiReset'
        : lvlText;
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
      st.toString().trimRight().split('\n').forEach((line) {
        // Since this is a console handler, print is acceptable here
        // ignore: avoid_print
        print('  $line');
      });
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
