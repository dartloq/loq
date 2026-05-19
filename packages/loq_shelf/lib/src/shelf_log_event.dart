import 'package:shelf/shelf.dart';

/// Base class for events emitted by `loqMiddleware()`.
///
/// Hooks receive one of the concrete subclasses
/// ([ShelfRequestStartEvent], [ShelfResponseEvent],
/// [ShelfRequestErrorEvent]) and can branch on it with an exhaustive
/// `switch`:
///
/// ```dart
/// fields: (event) => switch (event) {
///   ShelfRequestStartEvent() =>
///       {...event.defaults, 'phase': 'start'},
///   ShelfResponseEvent(:final response) =>
///       {...event.defaults, 'status_family': response.statusCode ~/ 100},
///   ShelfRequestErrorEvent() =>
///       {...event.defaults, 'phase': 'error'},
/// },
/// ```
sealed class ShelfLogEvent {
  const ShelfLogEvent();

  /// The Shelf request this event belongs to. Available on every
  /// variant, since the middleware always has the request in scope.
  Request get request;

  /// The fields the middleware would emit without any user
  /// transformation. The hook can spread these (`...event.defaults`)
  /// to compose, return a different map to replace, or filter to drop
  /// individual fields.
  Map<String, Object?> get defaults;

  /// Elapsed wall-clock time for the request, or `null` for the
  /// start event (which fires before any work has happened).
  Duration? get elapsed;
}

/// The "request started" event. Fires before the inner handler runs.
/// Carries [request] and the start [defaults] (OTel core fields,
/// captured request headers, `url.query` when enabled, `requestId`).
final class ShelfRequestStartEvent extends ShelfLogEvent {
  /// Creates a request-start event. Constructed by `loqMiddleware`;
  /// users receive instances in hook callbacks.
  const ShelfRequestStartEvent({
    required Request request,
    required Map<String, Object?> defaults,
  })  : _request = request,
        _defaults = defaults;

  final Request _request;
  final Map<String, Object?> _defaults;

  @override
  Request get request => _request;

  @override
  Map<String, Object?> get defaults => _defaults;

  /// Always `null` for the start event: no work has happened yet.
  @override
  Duration? get elapsed => null;
}

/// The "request completed" event. Fires after the inner handler
/// returns a [response]. The [defaults] inherit everything the start
/// event carried, plus the response-side fields
/// (`http.response.status_code`, `duration_ms`,
/// `http.response.body.size`, captured response headers, `slow`).
final class ShelfResponseEvent extends ShelfLogEvent {
  /// Creates a response event. Constructed by `loqMiddleware`; users
  /// receive instances in hook callbacks.
  const ShelfResponseEvent({
    required Request request,
    required this.response,
    required Duration elapsed,
    required Map<String, Object?> defaults,
  })  : _request = request,
        _elapsed = elapsed,
        _defaults = defaults;

  /// The response returned by the inner handler.
  final Response response;

  final Request _request;
  final Duration _elapsed;
  final Map<String, Object?> _defaults;

  @override
  Request get request => _request;

  @override
  Duration get elapsed => _elapsed;

  @override
  Map<String, Object?> get defaults => _defaults;
}

/// The "request failed" event. Fires when the inner handler throws
/// (other than [HijackException], which is rethrown without logging).
/// The [defaults] inherit everything the start event carried, plus the
/// error-side fields (`duration_ms`, `error.type`, `error.message`,
/// `slow`).
///
/// The caught error and stack trace are not on the event itself;
/// they reach hooks through `errorFields:`'s extra positional
/// parameters, mirroring `loq_drift`'s shape.
final class ShelfRequestErrorEvent extends ShelfLogEvent {
  /// Creates a request-error event. Constructed by `loqMiddleware`;
  /// users receive instances in hook callbacks.
  const ShelfRequestErrorEvent({
    required Request request,
    required Duration elapsed,
    required Map<String, Object?> defaults,
  })  : _request = request,
        _elapsed = elapsed,
        _defaults = defaults;

  final Request _request;
  final Duration _elapsed;
  final Map<String, Object?> _defaults;

  @override
  Request get request => _request;

  @override
  Duration get elapsed => _elapsed;

  @override
  Map<String, Object?> get defaults => _defaults;
}
