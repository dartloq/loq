import 'dart:async';

import 'package:loq/loq.dart';

/// Abstract base class for handlers that buffer records and flush in batches.
///
/// Subclasses implement [writeAll] to define how a batch of records
/// is written (e.g., to a network endpoint, file, or database).
///
/// ```dart
/// class MyBatchHandler extends BufferedHandler {
///   MyBatchHandler() : super(maxBufferSize: 50);
///
///   @override
///   Future<void> writeAll(List<Record> records) async {
///     await sendToBackend(records);
///   }
/// }
/// ```
abstract class BufferedHandler implements Handler {
  /// Creates a buffered handler.
  ///
  /// [maxBufferSize] is the number of records that triggers an automatic
  /// flush. [flushInterval], if provided, sets up a periodic timer that
  /// flushes regardless of buffer size.
  BufferedHandler({
    this.minLevel = Level.info,
    this.maxBufferSize = 100,
    this.flushInterval,
  }) {
    if (flushInterval != null) {
      _timer = Timer.periodic(flushInterval!, (_) => flush());
    }
  }

  /// Minimum level to accept.
  final Level minLevel;

  /// Number of records that triggers an automatic flush.
  final int maxBufferSize;

  /// Optional periodic flush interval.
  final Duration? flushInterval;

  final List<Record> _buffer = [];
  Timer? _timer;
  bool _flushing = false;
  bool _closed = false;

  /// Write a batch of records. Subclasses implement this.
  Future<void> writeAll(List<Record> records);

  @override
  bool isEnabled(Level level) => !_closed && level >= minLevel;

  @override
  void handle(Record record) {
    if (_closed) return;
    _buffer.add(record);
    if (_buffer.length >= maxBufferSize) {
      unawaited(flush());
    }
  }

  @override
  Future<void> flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    try {
      final batch = List<Record>.of(_buffer);
      _buffer.clear();
      await writeAll(batch);
    } finally {
      _flushing = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await flush();
  }
}
