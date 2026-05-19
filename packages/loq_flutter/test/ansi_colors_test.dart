import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

void main() {
  group('ansiForegroundFromColor', () {
    test('emits a 24-bit SGR sequence from an opaque colour', () {
      // 0xff112233 → R=0x11, G=0x22, B=0x33 → 17, 34, 51.
      expect(
        ansiForegroundFromColor(const Color(0xff112233)),
        '\x1B[38;2;17;34;51m',
      );
    });

    test('ignores alpha', () {
      // Half-transparent red should still report (255, 0, 0).
      expect(
        ansiForegroundFromColor(const Color(0x80ff0000)),
        '\x1B[38;2;255;0;0m',
      );
    });

    test('rounds and clamps the channel bytes', () {
      // Color.from accepts doubles directly so we can verify rounding
      // and clamping without going through 0xRRGGBB packing.
      expect(
        ansiForegroundFromColor(
          const Color.from(alpha: 1, red: 0.5, green: 0, blue: 1),
        ),
        '\x1B[38;2;128;0;255m',
      );
      expect(
        ansiForegroundFromColor(
          const Color.from(alpha: 1, red: 2, green: -1, blue: 0.5),
        ),
        '\x1B[38;2;255;0;128m',
      );
    });
  });

  group('ansiLevelColors', () {
    test('produces a Map<Level, String> suitable for ConsoleHandler', () {
      final escapes = ansiLevelColors({
        Level.warn: const Color(0xffffc107), // amber 500
        Level.error: const Color(0xffff5722), // deep orange 500
      });
      expect(escapes.keys, {Level.warn, Level.error});
      expect(escapes[Level.warn], '\x1B[38;2;255;193;7m');
      expect(escapes[Level.error], '\x1B[38;2;255;87;34m');
    });

    test('empty map produces an empty escape map', () {
      expect(ansiLevelColors(const {}), isEmpty);
    });

    test('round-trips into ConsoleHandler.levelColors', () {
      // Smoke test: we can hand the converted map to ConsoleHandler
      // without runtime errors, which is the only thing this helper
      // is for.
      ConsoleHandler(
        useColor: true,
        levelColors: ansiLevelColors({
          Level.fatal: const Color(0xffb71c1c),
        }),
      );
    });
  });
}
