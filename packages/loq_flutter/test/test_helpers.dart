import 'package:flutter/widgets.dart';
import 'package:loq/loq.dart';

/// A [Handler] that records every record it receives and counts
/// [flush] / [close] invocations. Used across tests to assert on
/// observer behaviour without spinning up real I/O.
class CapturingHandler implements Handler {
  CapturingHandler({this.minLevel = Level.trace});

  final Level minLevel;

  /// Records the handler has received.
  final List<Record> records = [];

  /// Number of times [flush] was awaited.
  int flushCount = 0;

  /// Number of times [close] was awaited.
  int closeCount = 0;

  /// When non-null, [flush] throws this on the next call (then clears).
  Object? failNextFlush;

  @override
  bool isEnabled(Level level) => level >= minLevel;

  @override
  void handle(Record record) => records.add(record);

  @override
  Future<void> flush() async {
    flushCount++;
    final error = failNextFlush;
    if (error != null) {
      failNextFlush = null;
      // Tests intentionally throw arbitrary Objects to drive
      // onHandlerError code paths.
      // ignore: only_throw_errors
      throw error;
    }
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}

/// A `Route<dynamic>` test double that's not a `PageRoute`. Used to
/// verify the navigator observer's PageRoute-only default.
class FakeRoute extends Route<void> {
  FakeRoute({String? name}) : super(settings: RouteSettings(name: name));
}

/// A `PageRoute<dynamic>` test double for navigator observer tests.
class FakePageRoute extends PageRoute<void> {
  FakePageRoute({String? name}) : super(settings: RouteSettings(name: name));

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      const SizedBox.shrink();
}
