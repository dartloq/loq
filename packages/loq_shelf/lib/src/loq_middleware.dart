import 'dart:io' show HttpConnectionInfo;

import 'package:loq/loq.dart';
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
/// `redact()` processor — e.g. to additionally redact fields contributed
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
/// Each of the three log events (start / completion / error) computes a
/// `defaults` map of everything the middleware would otherwise
/// contribute. The corresponding `*Fields` callback receives this map
/// and returns the final field set.
///
/// **Request log defaults** (bound via [withLogContext] so downstream
/// logs inherit them):
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
/// **Completion log defaults** (added to the start defaults):
///
/// - OTel core: `http.response.status_code`, `duration_ms`,
///   `http.response.body.size`, `http.response.header.content-type`
/// - When [captureResponseHeaders] is set:
///   `http.response.header.<lower>` for each captured header
/// - When [slowRequestThreshold] is exceeded: `slow: true`
///
/// **Error log defaults** (independent of the request log):
///
/// - `duration_ms`, `error.type`, `error.message`
/// - When [slowRequestThreshold] is exceeded: `slow: true`
///
/// In addition, loq's [Logger] always contributes `error` (the caught
/// `Object`) and `stackTrace` to the error log. These are added below
/// the [errorFields] layer, so even fully replacing [errorFields] with
/// `(_, __, ___, ____) => {}` will not strip them.
///
/// Note: `duration_ms` uses snake_case (industry convention across
/// Datadog, Elastic, Logstash, etc.) rather than loq's usual camelCase.
///
/// ## Parameters
///
/// ### Setup
///
/// - [logger] — the [Logger] to use. Defaults to `Logger('http')`.
/// - [requestIdResolver] — extracts a request ID. Defaults to
///   `X-Request-Id` header, falling back to an incrementing counter.
///   Always invoked as part of building defaults; whether the result
///   reaches the final fields depends on [fields].
///
/// ### Behavior
///
/// - [skip] — predicate that bypasses the middleware when `true`. No
///   logs, no zone context. For health checks, readiness probes,
///   metrics scrapers.
/// - [logStart] — emit "request started" log. Default `true`.
/// - [slowRequestThreshold] — when exceeded, adds `slow: true` to the
///   defaults and bumps the completion level to at least [Level.warn]
///   (never lowers `error` or higher). Error-path level is not bumped.
///
/// ### Field hooks
///
/// All three take `defaults` (everything the middleware would
/// contribute) and return the final map. Spread `...defaults` to
/// compose; return a different map to replace.
///
/// - [fields] — transforms the request defaults.
/// - [responseFields] — transforms the completion defaults.
/// - [errorFields] — transforms the error defaults.
///
/// ### Resolvers
///
/// Each returns `T?`; returning `null` falls back to the built-in
/// default.
///
/// - [routeResolver] — returns the route template (e.g.
///   `/users/{id}`) for `http.route`. Hand-wire from `shelf_router`
///   or Dart Frog adapters to avoid path-cardinality explosions in
///   dashboards.
/// - [clientIpResolver] — returns the client IP for `client.address`.
///   Defaults to probing `shelf.io.connection_info`. Override to apply
///   `X-Forwarded-For` / `Forwarded` resolution with your own
///   trusted-proxy policy.
/// - [levelResolver] — overrides level for both completion (response
///   non-null, error null) and error path (response null, error
///   non-null). Return `null` to fall back to status-family mapping
///   (completion) or [Level.error] (error path).
///   [slowRequestThreshold]'s warn-bump still applies on top.
///
/// ### Capture
///
/// - [captureRequestHeaders] / [captureResponseHeaders] — header name
///   allowlists. Case-insensitive lookup. Output field names follow
///   OTel convention: `http.request.header.<lowercase>` and
///   `http.response.header.<lowercase>`. Missing headers are dropped.
/// - [captureQueryParams] — when `true`, adds `url.query` (raw query
///   string, sensitive values masked). Default `false`.
///
/// ### Redaction
///
/// Each is a case-insensitive `Set<String>`. `null` (default) → use
/// the built-in defaults. `{}` (empty set) → disable redaction.
///
/// - [redactRequestHeaders] — default [defaultRedactedRequestHeaders].
/// - [redactResponseHeaders] — default [defaultRedactedResponseHeaders].
/// - [redactQueryParams] — default [defaultRedactedQueryParams].
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
  Map<String, Object?> Function(
    Request request,
    Map<String, Object?> defaults,
  )? fields,
  Map<String, Object?> Function(
    Response response,
    Duration elapsed,
    Map<String, Object?> defaults,
  )? responseFields,
  Map<String, Object?> Function(
    Object error,
    StackTrace stackTrace,
    Duration elapsed,
    Map<String, Object?> defaults,
  )? errorFields,
  // Resolvers
  String? Function(Request request)? routeResolver,
  String? Function(Request request)? clientIpResolver,
  Level? Function(Response? response, Duration elapsed, Object? error)?
      levelResolver,
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

  Map<String, Object?> defaultRequestFields(Request request) {
    final uri = request.requestedUri;
    final userAgent = request.headers['user-agent'];
    final bodySize = request.contentLength;
    final clientAddress = extractClient(request);
    final route = routeResolver?.call(request);
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
    };
  }

  Map<String, Object?> defaultResponseFields(
    Response response,
    Duration elapsed,
  ) {
    final contentType = response.headers['content-type'];
    final bodySize = response.contentLength;
    return <String, Object?>{
      'http.response.status_code': response.statusCode,
      if (bodySize != null) 'http.response.body.size': bodySize,
      if (contentType != null) 'http.response.header.content-type': contentType,
      'duration_ms': elapsed.inMilliseconds,
    };
  }

  final reqRedact = redactRequestHeaders ?? defaultRedactedRequestHeaders;
  final respRedact = redactResponseHeaders ?? defaultRedactedResponseHeaders;
  final qpRedact = redactQueryParams ?? defaultRedactedQueryParams;

  return (innerHandler) {
    return (request) {
      if (skip != null && skip(request)) {
        return innerHandler(request);
      }

      final rawQuery = request.requestedUri.query;
      final defaults = <String, Object?>{
        ...defaultRequestFields(request),
        ..._captureHeaders(
          request.headers,
          captureRequestHeaders,
          reqRedact,
          'http.request.header.',
        ),
        if (captureQueryParams && rawQuery.isNotEmpty)
          'url.query': _redactQueryString(rawQuery, qpRedact),
      };
      final reqFields = fields != null ? fields(request, defaults) : defaults;

      return withLogContext(reqFields, () async {
        final reqLog = log.withFields(reqFields);
        if (logStart) {
          reqLog.info(startMessage);
        }

        final stopwatch = Stopwatch()..start();
        try {
          final response = await innerHandler(request);
          stopwatch.stop();
          final elapsed = stopwatch.elapsed;
          final isSlow =
              slowRequestThreshold != null && elapsed > slowRequestThreshold;

          final respDefaults = <String, Object?>{
            ...defaultResponseFields(response, elapsed),
            ..._captureHeaders(
              response.headers,
              captureResponseHeaders,
              respRedact,
              'http.response.header.',
            ),
            if (isSlow) 'slow': true,
          };
          final respFields = responseFields != null
              ? responseFields(response, elapsed, respDefaults)
              : respDefaults;

          var level = levelResolver?.call(response, elapsed, null) ??
              _defaultResponseLevel(response.statusCode);
          if (isSlow && level < Level.warn) {
            level = Level.warn;
          }
          reqLog.log(level, completeMessage, fields: respFields);

          return response;
        } on HijackException {
          rethrow;
        } catch (error, stackTrace) {
          stopwatch.stop();
          final elapsed = stopwatch.elapsed;
          final isSlow =
              slowRequestThreshold != null && elapsed > slowRequestThreshold;

          final level =
              levelResolver?.call(null, elapsed, error) ?? Level.error;

          final errDefaults = <String, Object?>{
            'duration_ms': elapsed.inMilliseconds,
            'error.type': error.runtimeType.toString(),
            'error.message': error.toString(),
            if (isSlow) 'slow': true,
          };
          final errBase = errorFields != null
              ? errorFields(error, stackTrace, elapsed, errDefaults)
              : errDefaults;

          reqLog.log(
            level,
            errorMessage,
            error: error,
            stackTrace: stackTrace,
            fields: errBase,
          );

          rethrow;
        }
      });
    };
  };
}
