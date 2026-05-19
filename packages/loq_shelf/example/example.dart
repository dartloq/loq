// Showcase server exercising every loq_shelf capability:
//
//   skip                       bypass health checks
//   slowRequestThreshold       flag and escalate slow requests
//   routeResolver              bounded http.route cardinality
//   clientIpResolver           X-Forwarded-For resolution
//   levelResolver              custom per-event level logic
//   captureRequestHeaders      opt-in header allowlist (zone-propagated)
//   captureResponseHeaders     response header allowlist
//   captureQueryParams         url.query with default redaction
//   redactRequestHeaders       extend the built-in redaction set
//   fields                     unified per-event hook
//                              (ShelfRequestStartEvent / ShelfResponseEvent)
//   errorFields                ShelfRequestErrorEvent annotation
//   startMessage / *Message    event names downstream tools key off
//   withLogContext (in handler) nested scopes inherit and extend context
//
// Run with: `dart run example/example.dart`
// Try the curls printed on startup.

import 'dart:async';
import 'dart:io';

import 'package:loq/loq.dart';
import 'package:loq_shelf/loq_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

final log = Logger('app');

// --- Handlers -------------------------------------------------------------

Future<Response> _handleUser(Request request) async {
  // Inherits the request's OTel fields (method, path, route, requestId,
  // tenant_id, captured headers, etc.) via zone context.
  log.info('fetching user', fields: {'table': 'users'});

  // Bind an additional field for a nested scope. The "user resolved"
  // log inherits everything above PLUS user_id.
  return withLogContext({'user_id': 42}, () async {
    log.info('user resolved');
    return Response.ok(
      '{"id": 42, "name": "Tibor"}\n',
      headers: {
        'content-type': 'application/json',
        'cache-status': 'MISS',
      },
    );
  });
}

Future<Response> _handleSlow(Request request) async {
  await Future<void>.delayed(const Duration(milliseconds: 800));
  return Response.ok('done\n');
}

Future<Response> _handleError(Request request) =>
    throw const FormatException('bad input');

Future<Response> _handleTimeout(Request request) async {
  // Simulate waiting on something before giving up so the error log
  // shows a realistic non-zero duration_ms.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  throw TimeoutException('upstream slow');
}

Future<Response> _handleHealth(Request request) =>
    Future.value(Response.ok('OK\n'));

Future<Response> _handleNotFound(Request request) =>
    Future.value(Response.notFound('not found\n'));

// --- Resolvers ------------------------------------------------------------

// In a real app, plug your router's matched-template into routeResolver
// (e.g. shelf_router stores it under `request.context['shelf_router/route']`).
String? _resolveRoute(Request request) {
  final path = request.requestedUri.path;
  if (path.startsWith('/users/')) return '/users/{id}';
  if (path == '/slow') return '/slow';
  if (path == '/error') return '/error';
  if (path == '/timeout') return '/timeout';
  if (path == '/healthz') return '/healthz';
  return null;
}

// Read the first X-Forwarded-For hop when present, else fall back to the
// middleware's default (shelf_io connection info). In production, gate
// this on whether the immediate socket is in your trusted-proxy list.
String? _resolveClientIp(Request request) {
  final xff = request.headers['x-forwarded-for'];
  if (xff != null && xff.isNotEmpty) return xff.split(',').first.trim();
  return null;
}

// --- Main -----------------------------------------------------------------

void main() async {
  // Swap ConsoleHandler for JsonHandler() to get one structured JSON
  // object per line, the shape you'd ship to Datadog/Elastic/Grafana.
  LogConfig.configure(
    handlers: [ConsoleHandler(minLevel: Level.trace)],
    zoneAccessor: defaultZoneAccessor,
  );

  final middleware = loqMiddleware(
    // ---- Setup ----
    logger: Logger('http'),

    // ---- Behavior ----
    skip: (req) => req.requestedUri.path == '/healthz',
    slowRequestThreshold: const Duration(milliseconds: 500),

    // ---- Field hooks ----
    // One hook for every success-path event (start + response). Branch
    // on event type to add context that only applies on one of them.
    fields: (event) => switch (event) {
      ShelfRequestStartEvent() => {
          ...event.defaults,
          if (event.request.headers['x-tenant-id'] != null)
            'tenant_id': event.request.headers['x-tenant-id'],
        },
      ShelfResponseEvent(:final response) => {
          ...event.defaults,
          'cache_hit': response.headers['cache-status'] == 'HIT',
        },
      ShelfRequestErrorEvent() => event.defaults,
    },
    errorFields: (event, error, stack) => {
      ...event.defaults,
      'error.retryable': error is TimeoutException || error is SocketException,
    },

    // ---- Resolvers (each returns T?; null falls back to defaults) ----
    routeResolver: _resolveRoute,
    clientIpResolver: _resolveClientIp,
    // 404 is part of normal traffic for this API, don't pollute warn.
    levelResolver: (event, error) => switch (event) {
      ShelfResponseEvent(:final response) when response.statusCode == 404 =>
        Level.info,
      _ => null,
    },

    // ---- Capture ----
    captureRequestHeaders: ['authorization', 'x-trace-id', 'referer'],
    captureResponseHeaders: ['cache-status'],
    captureQueryParams: true,

    // ---- Redaction (extend the built-in defaults) ----
    redactRequestHeaders: {
      ...defaultRedactedRequestHeaders,
      'x-internal-token',
    },

    // ---- Messages (keyed by downstream log pipelines) ----
    startMessage: 'http.request.start',
    completeMessage: 'http.request.end',
    errorMessage: 'http.request.error',
  );

  final handler = const Pipeline().addMiddleware(middleware).addHandler(
    (request) {
      final path = request.requestedUri.path;
      if (path == '/healthz') return _handleHealth(request);
      if (path == '/slow') return _handleSlow(request);
      if (path == '/error') return _handleError(request);
      if (path == '/timeout') return _handleTimeout(request);
      if (path.startsWith('/users/')) return _handleUser(request);
      return _handleNotFound(request);
    },
  );

  final server = await io.serve(handler, 'localhost', 8080);
  log
    ..info(
      'server started',
      fields: {'host': server.address.host, 'port': server.port},
    )
    ..info('--- Try these: ---')
    ..info('curl http://localhost:8080/users/42')
    ..info('curl "http://localhost:8080/users/42?api_key=secret&page=2"')
    ..info(
      'curl -H "Authorization: Bearer xyz" '
      '-H "X-Tenant-Id: acme" '
      'http://localhost:8080/users/42',
    )
    ..info(
      'curl -H "X-Forwarded-For: 203.0.113.7" '
      'http://localhost:8080/users/42  (client.address)',
    )
    ..info('curl http://localhost:8080/slow      (warn: slow=true)')
    ..info('curl http://localhost:8080/missing   (info via levelResolver)')
    ..info('curl http://localhost:8080/error     (FormatException)')
    ..info(
      'curl http://localhost:8080/timeout   '
      '(TimeoutException, error.retryable=true)',
    )
    ..info('curl http://localhost:8080/healthz   (skipped, no log)');
}
