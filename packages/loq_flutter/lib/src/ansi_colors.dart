import 'dart:ui';

import 'package:loq/loq.dart';

/// Builds a 24-bit ANSI foreground escape from a Flutter [Color].
///
/// The result is a SGR sequence of the form `\x1B[38;2;R;G;Bm`,
/// directly usable as a value in [ConsoleHandler]'s `levelColors`
/// map. The caller stays in Flutter idioms (`Colors.deepOrange`,
/// `Color(0xff112233)`, theme colors) and the conversion to the
/// terminal wire format is handled here.
///
/// Alpha is dropped: terminals don't blend. RGB is read from the
/// floating-point `.r` / `.g` / `.b` channel getters Flutter
/// introduced in 3.27, scaled to 0–255.
///
/// 24-bit (true color) ANSI is supported by every modern terminal
/// emulator on macOS, Linux, and Windows (since Windows 10 1607). We
/// don't fall back to the 256-color palette. If you're targeting a
/// terminal that doesn't speak 24-bit, hand-pick escape strings via
/// [ConsoleHandler]'s `levelColors` map directly.
String ansiForegroundFromColor(Color color) {
  final r = _byte(color.r);
  final g = _byte(color.g);
  final b = _byte(color.b);
  return '\x1B[38;2;$r;$g;${b}m';
}

/// Converts a Flutter [Color] map into the shape [ConsoleHandler]'s
/// `levelColors` map expects.
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:loq/loq.dart';
/// import 'package:loq_flutter/loq_flutter.dart';
///
/// LogConfig.configure(handlers: [
///   ConsoleHandler(
///     useColor: true,
///     levelColors: ansiLevelColors({
///       Level.warn: Colors.amber,
///       Level.error: Colors.deepOrange,
///       Level.fatal: Colors.red.shade900,
///     }),
///   ),
/// ]);
/// ```
///
/// Looked-up by [ConsoleHandler] in the same order as its raw-string
/// equivalent: exact match → nearest band → built-in default. So
/// supplying only [Level.warn] colours the warn band; debug / info
/// fall back to the default ANSI palette.
Map<Level, String> ansiLevelColors(Map<Level, Color> colors) => colors.map(
      (level, color) => MapEntry(level, ansiForegroundFromColor(color)),
    );

int _byte(double channel) => (channel * 255).round().clamp(0, 255);
