import 'dart:io' show HttpConnectionInfo;

import 'package:loq/loq.dart';
import 'package:loq_shelf/src/shelf_log_event.dart';
import 'package:shelf/shelf.dart';

/// Request headers redacted by default when captured.
///
/// Override via `redactRequestHeaders`. Pass an empty set to disable
/// redaction entirely.
const defaultRedactedRequestHeaders = <String>{
  'authorization',
  'proxy-authorization',
  'cookie',
  'x-api-key',
  'x-auth-token',
};

/// Response headers redacted by default when captured.
const defaultRedactedResponseHeaders = <String>{
  'set-cookie',
};

/// Query parameter keys whose values are redacted by default when
/// `captureQueryParams: true`.
const defaultRedactedQueryParams = <String>{
  'token',
  'access_token',
  'refresh_token',
  'api_key',
  'apikey',
  'key',
  'password',
  'secret',
  'signature',
  'sig',
};

/// Output field names for the default-redacted request headers, prefixed
/// with `http.request.header.`. Useful for composing with loq core's
/// `redact()` processor, e.g. to additionally redact fields contributed
/// by user code:
///
/// ```dart
/// LogConfig.configure(
///   processors: [
///     redact({...defaultRedactedRequestHeaderFields, 'tenant_secret'}),
///   ],
/// );
/// ```
///
/// loq_shelf already masks these inline at capture time; this constant
/// is provided so other processors / loggers can share the same threat
/// model without rebuilding the prefix mapping.
final defaultRedactedRequestHeaderFields = <String>{
  for (final h in defaultRedactedRequestHeaders) 'http.request.header.$h',
};

/// Output field names for the default-redacted response headers, prefixed
/// with `http.response.header.`. See [defaultRedactedRequestHeaderFields].
final defaultRedactedResponseHeaderFields = <String>{
  for (final h in defaultRedactedResponseHeaders) 'http.response.header.$h',
};

// Note: there is no `defaultRedactedQueryFields` equivalent because
// `url.query` is a single string field whose *contents* (not key) carry
// the sensitive parts. Core's `redact()` cannot mask substrings, so
// query redaction is handled inline by the middleware itself.

const _redactedValue = '***';

/// Hook for the start and completion log events. Gets the typed event
/// (use pattern matching to branch on shape) and returns the final
/// fields. Spread `...event.defaults` to keep the defaults; return a
/// different map to replace.
typedef ShelfFieldsHook = Map<String, Object?> Function(ShelfLogEvent event);

/// Hook for the error log event. Gets the typed event plus the caught
/// error and stack trace.
typedef ShelfErrorFieldsHook = Map<String, Object?> Function(
  ShelfLogEvent event,
  Object error,
  StackTrace stackTrace,
);

/// Hook that overrides the level for any event. Returning `null` falls
/// back to the per-event default. The error is non-null on the error
/// path.
typedef ShelfLevelResolver = Level? Function(
  ShelfLogEvent event,
  Object? error,
);

Level _defaultResponseLevel(int statusCode) {
  if (statusCode >= 500) return Level.error;
  if (statusCode >= 400) return Level.warn;
  return Level.info;
}

/// Best-effort client address from shelf_io's connection info.
///
/// Returns null when the request wasn't served by shelf_io (no connection
/// info present, e.g. in tests using `Request` directly).
String? _defaultClientAddress(Request request) {
  final info = request.context['shelf.io.connection_info'];
  if (info is! HttpConnectionInfo) return null;
  return info.remoteAddress.address;
}

Map<String, Object?> _captureHeaders(
  Map<String, String> headers,
  List<String>? names,
  Set<String> redacted,
  String prefix,
) {
  if (names == null || names.isEmpty) return const {};
  final result = <String, Object?>{};
  for (final name in names) {
    final lower = name.toLowerCase();
    final value = headers[lower];
    if (value != null) {
      result['$prefix$lower'] =
          redacted.contains(lower) ? _redactedValue : value;
    }
  }
  return result;
}

/// Returns a copy of [rawQuery] with values of redacted keys replaced by
/// `***`. Preserves order, repeated keys, URL encoding, and bare keys.
String _redactQueryString(String rawQuery, Set<String> redactedKeys) {
  if (rawQuery.isEmpty || redactedKeys.isEmpty) return rawQuery;
  final parts = rawQuery.split('&');
  final out = <String>[];
  for (final part in parts) {
    final eq = part.indexOf('=');
    if (eq < 0) {
      out.add(part);
      continue;
    }
    final key = part.substring(0, eq);
    final decodedKey = Uri.decodeQueryComponent(key);
    if (redactedKeys.contains(decodedKey.toLowerCase())) {
      out.add('$key=$_redactedValue');
    } else {
      out.add(part);
    }
  }
  return out.join('&');
}

/// Structured request logging middleware for Shelf.
///
/// Drop-in replacement for Shelf's `logRequests()` that emits structured
/// log records aligned with OpenTelemetry HTTP server semantic conventions,
/// with zone context propagation, default redaction of sensitive headers
/// and query parameters, and configurable log levels.
///
/// ```dart
/// final handler = Pipeline()
///     .addMiddleware(loqMiddleware())
///     .addHandler(router);
/// ```
///
/// ## Default fields
///
/// Every event builds a `defaults` map of everything the middleware
/// would emit on its own. The [fields] hook (or [errorFields] for the
/// error path) gets the typed [ShelfLogEvent] and returns the final
/// fields. Spread `...event.defaults` to keep the defaults; return a
/// different map to replace.
///
/// **Request start defaults** (also bound via [withLogContext] so
/// downstream logs inherit them):
///
/// - OTel core: `http.request.method`, `url.path`, `url.scheme`,
///   `server.address`, `server.port`, `network.protocol.version`,
///   `requestId`
/// - When available: `client.address`, `user_agent.original`,
///   `http.request.body.size`, `http.route`
/// - When [captureRequestHeaders] is set: `http.request.header.<lower>`
///   for each captured header (sensitive values masked)
/// - When [captureQueryParams] is `true` and the query is non-empty:
///   `url.query` (sensitive values masked)
///
/// **Response defaults** (everything the start event carried, plus):
///
/// - OTel core: `http.response.status_code`, `duration_ms`,
///   `http.response.body.size`, `http.response.header.content-type`
/// - When [captureResponseHeaders] is set:
///   `http.response.header.<lower>` for each captured header
/// - When [slowRequestThreshold] is exceeded: `slow: true`
///
/// **Error defaults** (everything the start event carried, plus):
///
/// - `duration_ms`, `error.type`, `error.message`
/// - When [slowRequestThreshold] is exceeded: `slow: true`
///
/// In addition, loq's [Logger] always contributes `error` (the caught
/// `Object`) and `stackTrace` to the error log. These are added below
/// the [errorFields] layer, so even replacing [errorFields] with
/// `(_, __, ___) => {}` will not strip them.
///
/// Note: `duration_ms` uses snake_case (industry convention across
/// Datadog, Elastic, Logstash, etc.) rather than loq's usual camelCase.
///
/// ## Parameters
///
/// ### Setup
///
/// - [logger]: the [Logger] to use. Defaults to `Logger('http')`.
/// - [requestIdResolver]: extracts a request ID. Defaults to
///   `X-Request-Id` header, falling back to an incrementing counter.
///   Always invoked as part of building defaults; whether the result
///   reaches the final fields depends on [fields].
///
/// ### Behavior
///
/// - [skip]: predicate that bypasses the middleware when `true`. No
///   logs, no zone context. For health checks, readiness probes,
///   metrics scrapers.
/// - [logStart]: emit "request started" log. Default `true`.
/// - [slowRequestThreshold]: when exceeded, adds `slow: true` to the
///   defaults and bumps the completion level to at least [Level.warn]
///   (never lowers `error` or higher). Error-path level is not bumped.
///
/// ### Field hooks
///
/// Both take a [ShelfLogEvent] and return the final map. Spread
/// `...event.defaults` to keep the defaults; return a different map to
/// replace.
///
/// - [fields]: transforms the start and completion defaults. Branch
///   on event type with `switch` for path-specific shaping.
/// - [errorFields]: transforms the error defaults; also gets the
///   caught error and stack trace.
///
/// ### Resolvers
///
/// Each returns `T?`; returning `null` falls back to the built-in
/// default.
///
/// - [routeResolver]: returns the route template (e.g.
///   `/users/{id}`) for `http.route`. Hand-wire from `shelf_router`
///   or Dart Frog adapters to avoid path-cardinality explosions in
///   dashboards.
/// - [clientIpResolver]: returns the client IP for `client.address`.
///   Defaults to probing `shelf.io.connection_info`. Override to apply
///   `X-Forwarded-For` / `Forwarded` resolution with your own
///   trusted-proxy policy.
/// - [levelResolver]: overrides level for any event. Gets the typed
///   [ShelfLogEvent] and any caught error (`null` on success).
///   Return `null` to fall back to status-family mapping
///   ([ShelfResponseEvent]) or [Level.error] ([ShelfRequestErrorEvent]).
///   [slowRequestThreshold]'s warn-bump still applies on top.
///
/// ### Capture
///
/// - [captureRequestHeaders] / [captureResponseHeaders]: header name
///   allowlists. Case-insensitive lookup. Output field names follow
///   OTel convention: `http.request.header.<lowercase>` and
///   `http.response.header.<lowercase>`. Missing headers are dropped.
/// - [captureQueryParams]: when `true`, adds `url.query` (raw query
///   string, sensitive values masked). Default `false`.
///
/// ### Redaction
///
/// Each is a case-insensitive `Set<String>`. `null` (default) uses
/// the built-in defaults. `{}` (empty set) disables redaction.
///
/// - [redactRequestHeaders]: default [defaultRedactedRequestHeaders].
/// - [redactResponseHeaders]: default [defaultRedactedResponseHeaders].
/// - [redactQueryParams]: default [defaultRedactedQueryParams].
///
/// ### Messages
///
/// Log message text overrides:
/// [startMessage], [completeMessage], [errorMessage].
Middleware loqMiddleware({
  // Setup
  Logger? logger,
  String Function(Request request)? requestIdResolver,
  // Behavior
  bool Function(Request request)? skip,
  bool logStart = true,
  Duration? slowRequestThreshold,
  // Field hooks
  ShelfFieldsHook? fields,
  ShelfErrorFieldsHook? errorFields,
  // Resolvers
  String? Function(Request request)? routeResolver,
  String? Function(Request request)? clientIpResolver,
  ShelfLevelResolver? levelResolver,
  // Capture
  List<String>? captureRequestHeaders,
  List<String>? captureResponseHeaders,
  bool captureQueryParams = false,
  // Redaction
  Set<String>? redactRequestHeaders,
  Set<String>? redactResponseHeaders,
  Set<String>? redactQueryParams,
  // Messages
  String startMessage = 'request started',
  String completeMessage = 'request completed',
  String errorMessage = 'request failed',
}) {
  var counter = 0;
  final log = logger ?? Logger('http');

  final extractId = requestIdResolver ??
      (Request req) => req.headers['x-request-id'] ?? '${++counter}';

  final extractClient = clientIpResolver ?? _defaultClientAddress;

  final reqRedact = redactRequestHeaders ?? defaultRedactedRequestHeaders;
  final respRedact = redactResponseHeaders ?? defaultRedactedResponseHeaders;
  final qpRedact = redactQueryParams ?? defaultRedactedQueryParams;

  Map<String, Object?> buildRequestDefaults(Request request) {
    final uri = request.requestedUri;
    final userAgent = request.headers['user-agent'];
    final bodySize = request.contentLength;
    final clientAddress = extractClient(request);
    final route = routeResolver?.call(request);
    final rawQuery = uri.query;
    return <String, Object?>{
      'http.request.method': request.method,
      'url.path': uri.path,
      'url.scheme': uri.scheme,
      'server.address': uri.host,
      if (uri.hasPort) 'server.port': uri.port,
      'network.protocol.version': request.protocolVersion,
      if (clientAddress != null) 'client.address': clientAddress,
      if (userAgent != null) 'user_agent.original': userAgent,
      if (bodySize != null) 'http.request.body.size': bodySize,
      if (route != null) 'http.route': route,
      'requestId': extractId(request),
      ..._captureHeaders(
        request.headers,
        captureRequestHeaders,
        reqRedact,
        'http.request.header.',
      ),
      if (captureQueryParams && rawQuery.isNotEmpty)
        'url.query': _redactQueryString(rawQuery, qpRedact),
    };
  }

  return (innerHandler) {
    return (request) {
      if (skip != null && skip(request)) {
        return innerHandler(request);
      }

      final requestDefaults = buildRequestDefaults(request);
      final startEvent = ShelfRequestStartEvent(
        request: request,
        defaults: requestDefaults,
      );
      final startFields = fields != null ? fields(startEvent) : requestDefaults;

      // Bind the user's start-hook return to the zone so inner logs
      // and downstream events inherit exactly what the user chose.
      // Passing the raw defaults instead would keep them visible on
      // inner logs even when the user replaced the start fields with
      // a different shape, breaking the "fields hook is the single
      // transformation point" contract.
      void logStartEvent() {
        if (!logStart) return;
        final level = levelResolver?.call(startEvent, null) ?? Level.info;
        log.log(level, startMessage, fields: startFields);
      }

      void logCompletion(Response response, Duration elapsed) {
        final isSlow =
            slowRequestThreshold != null && elapsed > slowRequestThreshold;
        final contentType = response.headers['content-type'];
        final bodySize = response.contentLength;
        final responseDefaults = <String, Object?>{
          ...requestDefaults,
          'http.response.status_code': response.statusCode,
          if (bodySize != null) 'http.response.body.size': bodySize,
          if (contentType != null)
            'http.response.header.content-type': contentType,
          'duration_ms': elapsed.inMilliseconds,
          ..._captureHeaders(
            response.headers,
            captureResponseHeaders,
            respRedact,
            'http.response.header.',
          ),
          if (isSlow) 'slow': true,
        };
        final event = ShelfResponseEvent(
          request: request,
          response: response,
          elapsed: elapsed,
          defaults: responseDefaults,
        );
        final finalFields = fields != null ? fields(event) : responseDefaults;
        var level = levelResolver?.call(event, null) ??
            _defaultResponseLevel(response.statusCode);
        if (isSlow && level < Level.warn) {
          level = Level.warn;
        }
        log.log(level, completeMessage, fields: finalFields);
      }

      void logFailure(Object error, StackTrace stackTrace, Duration elapsed) {
        final isSlow =
            slowRequestThreshold != null && elapsed > slowRequestThreshold;
        final errorDefaults = <String, Object?>{
          ...requestDefaults,
          'duration_ms': elapsed.inMilliseconds,
          'error.type': error.runtimeType.toString(),
          'error.message': error.toString(),
          if (isSlow) 'slow': true,
        };
        final event = ShelfRequestErrorEvent(
          request: request,
          elapsed: elapsed,
          defaults: errorDefaults,
        );
        final finalFields = errorFields != null
            ? errorFields(event, error, stackTrace)
            : errorDefaults;
        final level = levelResolver?.call(event, error) ?? Level.error;
        log.log(
          level,
          errorMessage,
          error: error,
          stackTrace: stackTrace,
          fields: finalFields,
        );
      }

      return withLogContext(startFields, () async {
        logStartEvent();
        final stopwatch = Stopwatch()..start();
        try {
          final response = await innerHandler(request);
          stopwatch.stop();
          logCompletion(response, stopwatch.elapsed);
          return response;
        } on HijackException {
          rethrow;
        } catch (error, stackTrace) {
          stopwatch.stop();
          logFailure(error, stackTrace, stopwatch.elapsed);
          rethrow;
        }
      });
    };
  };
}
