import 'package:loq/src/level.dart';
import 'package:loq/src/logger.dart';
import 'package:loq/src/record.dart';

/// A function that transforms, enriches, or filters a [Record].
///
/// Return the record (possibly modified) to pass it along.
/// Return `null` to drop it.
typedef Processor = Record? Function(Record record);

/// A backend that writes processed [Record]s somewhere.
///
/// Implement this for custom sinks: files, network, OTel, Crashlytics, etc.
abstract interface class Handler {
  /// Whether this handler wants records at [level].
  ///
  /// Called before any allocation — if all handlers return `false`,
  /// the [Logger] skips building the [Record] entirely.
  bool isEnabled(Level level);

  /// Write a fully processed record.
  void handle(Record record);

  /// Flush any buffered output.
  Future<void> flush();

  /// Release resources.
  Future<void> close();
}
