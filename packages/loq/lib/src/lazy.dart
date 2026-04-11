import 'package:loq/loq.dart';

/// A deferred field value that is computed on first access and cached.
///
/// Use this for expensive computations that should only run if the log
/// record actually reaches a handler (i.e., is not filtered out by
/// early-out level checks).
///
/// ```dart
/// log.info('request', fields: {
///   'payload': Lazy(() => jsonEncode(largeObject)),
/// });
/// ```
///
/// The [Logger] resolves all `Lazy` values after the early-out check
/// but before creating the [Record], so handlers never see `Lazy`
/// instances — they receive the computed value directly.
class Lazy<T extends Object> {
  /// Creates a lazy value backed by [_factory].
  Lazy(this._factory);

  final T Function() _factory;
  late T _cached;
  bool _resolved = false;

  /// The computed value. Calls the factory on first access, then caches.
  T get value {
    if (!_resolved) {
      _cached = _factory();
      _resolved = true;
    }
    return _cached;
  }

  @override
  String toString() => value.toString();
}
