# loq_shelf

Structured request logging middleware for [Shelf](https://pub.dev/packages/shelf), powered by [loq](https://pub.dev/packages/loq).

Drop-in replacement for `logRequests()` with [OpenTelemetry-aligned](https://opentelemetry.io/docs/specs/semconv/http/http-spans/) fields, zone-propagated request context, secure-by-default redaction, and configurable log levels.

## Quick start

```dart
import 'package:shelf/shelf.dart';
import 'package:loq_shelf/loq_shelf.dart';

final handler = Pipeline()
    .addMiddleware(loqMiddleware())
    .addHandler(router);
```

Every request log carries the standard OTel HTTP-server fields, and any log emitted inside the handler inherits them via zone context:

```dart
Response handleUser(Request request) {
  // Inherits http.request.method, url.path, requestId, etc.
  Logger('db').info('query executed', fields: {'table': 'users'});
  return Response.ok('ok');
}
```

> **Note vs `loq_drift`.** `loq_shelf` binds request fields into the zone on its own, because the middleware wraps the user's handler. `loq_drift`'s interceptor sits *below* the user's transaction body, so it can't bind anything on its own. `loq_drift` users wrap blocks themselves with `withLogContext` if they want per-transaction correlation.

Sample output (ConsoleHandler):

```
12:34:56.789 [INFO ] http: request started | http.request.method=GET, url.path=/api/users, url.scheme=http, server.address=localhost, network.protocol.version=1.1, requestId=1
12:34:56.790 [INFO ] db: query executed | http.request.method=GET, url.path=/api/users, requestId=1, table=users
12:34:56.791 [INFO ] http: request completed | http.request.method=GET, url.path=/api/users, requestId=1, http.response.status_code=200, duration_ms=2
```

## Events and fields

Each log event is one of three sealed types:

- **`ShelfRequestStartEvent`** for the start log. Carries `request`, `defaults`; `elapsed` is `null`.
- **`ShelfResponseEvent`** for the completion log. Carries `request`, `response`, `elapsed`, `defaults`.
- **`ShelfRequestErrorEvent`** for the error log. Carries `request`, `elapsed`, `defaults`. The caught error and stack trace reach hooks through `errorFields:`'s extra positional parameters.

The `fields:` hook receives the start and completion events; `errorFields:` receives the error event. Both return the final field map. Spread `...event.defaults` to keep the defaults; return a different map to replace. Branch on event type with `switch`:

```dart
fields: (event) => switch (event) {
  ShelfRequestStartEvent() =>
      {...event.defaults, 'phase': 'start'},
  ShelfResponseEvent(:final response) =>
      {...event.defaults, 'status_family': response.statusCode ~/ 100},
  ShelfRequestErrorEvent() =>
      event.defaults,
},
```

### Request start defaults

Also bound via `withLogContext` so downstream logs inherit them:

| Field | Source |
|-------|--------|
| `http.request.method` | `request.method` |
| `url.path` | `request.requestedUri.path` |
| `url.scheme` | `request.requestedUri.scheme` |
| `server.address` | `request.requestedUri.host` |
| `server.port` | when explicit |
| `network.protocol.version` | `request.protocolVersion` |
| `client.address` | `clientIpResolver`, defaults to `shelf_io` connection info |
| `user_agent.original` | `User-Agent` header (when present) |
| `http.request.body.size` | `Content-Length` (when set) |
| `http.route` | `routeResolver` (when supplied) |
| `requestId` | `requestIdResolver`, defaults to `X-Request-Id` header or counter |
| `http.request.header.<lower>` | for each name in `captureRequestHeaders` (sensitive values masked) |
| `url.query` | raw query string when `captureQueryParams: true` (sensitive values masked) |

### Response defaults

Inherit everything the start event carried, plus:

| Field | Source |
|-------|--------|
| `http.response.status_code` | `response.statusCode` |
| `duration_ms` | elapsed time in milliseconds |
| `http.response.body.size` | response `Content-Length` (when set) |
| `http.response.header.content-type` | response `Content-Type` (when set) |
| `http.response.header.<lower>` | for each name in `captureResponseHeaders` |
| `slow` | `true` when `slowRequestThreshold` is exceeded |

### Error defaults

Inherit everything the start event carried, plus:

| Field | Source |
|-------|--------|
| `duration_ms` | elapsed time in milliseconds |
| `error.type` | `error.runtimeType.toString()` |
| `error.message` | `error.toString()` |
| `slow` | `true` when `slowRequestThreshold` is exceeded |

Loq's `Logger` always adds `error` (the caught `Object`) and `stackTrace` to the error log on a layer below `errorFields:`, so replacing all fields with `errorFields: (_, __, ___) => {}` will still include them.

> `duration_ms` uses snake_case (industry convention across Datadog, Elastic, Logstash, etc.) rather than loq's usual camelCase.

## Dart Frog

Works via `fromShelfMiddleware()`:

```dart
// _middleware.dart
import 'package:dart_frog/dart_frog.dart';
import 'package:loq_shelf/loq_shelf.dart';

Handler middleware(Handler handler) {
  return handler.use(fromShelfMiddleware(loqMiddleware()));
}
```

## Configuration

### Route templates

Without this, dashboards explode on per-path cardinality (every `/users/42` becomes its own bucket). Supply the matched template from your router:

```dart
loqMiddleware(
  routeResolver: (req) => req.context['shelf_router/route'] as String?,
)
```

### Client IP from `X-Forwarded-For`

By default `client.address` comes from the immediate socket. Behind a proxy or CDN, override with your own resolver, and validate the trusted proxy chain before trusting the header:

```dart
loqMiddleware(
  clientIpResolver: (req) {
    final xff = req.headers['x-forwarded-for'];
    if (xff != null && _socketIsTrusted(req)) {
      return xff.split(',').first.trim();
    }
    return null;
  },
)
```

### Level resolution

`levelResolver` is the only level hook. It receives the typed event and any caught error (`null` on success). Return `null` to fall back to the per-event default (`Level.info` for start, status-family mapping for completion, `Level.error` for the error path). `slowRequestThreshold`'s warn-bump still stacks on top:

```dart
loqMiddleware(
  levelResolver: (event, error) => switch (event) {
    ShelfResponseEvent(:final response) when response.statusCode == 404 =>
      Level.info, // 404 is normal traffic for this service
    ShelfRequestErrorEvent() when error is TimeoutException =>
      Level.warn,
    _ => null, // fall back to defaults
  },
)
```

### Skip noisy endpoints

`skip:` bypasses the middleware entirely: no logs and no `withLogContext` binding, so any log emitted from the handler won't carry the request fields either.

```dart
loqMiddleware(
  skip: (req) {
    final p = req.requestedUri.path;
    return p == '/healthz' || p == '/metrics';
  },
)
```

> **Note vs `loq_drift`.** `loq_drift`'s `skipLog:` only drops the log; the underlying query still runs (it has to). The `Log` suffix marks the narrower scope. If you work with both packages, treat the names as deliberately different to remind you that `loq_drift` can't skip its own work.

### Slow request threshold

Adds `slow: true` and ensures the completion level is at least `warn` (preserving `error`/`fatal`):

```dart
loqMiddleware(
  slowRequestThreshold: const Duration(milliseconds: 500),
)
```

### Capture additional headers

Allowlist of headers to bind. Request headers propagate via zone context; response headers attach to the completion log only.

```dart
loqMiddleware(
  captureRequestHeaders: ['user-agent', 'cf-ray', 'authorization'],
  captureResponseHeaders: ['cache-status', 'x-served-by'],
)
```

Lookup is case-insensitive. Output field names follow the OTel convention `http.request.header.<lowercase>` and `http.response.header.<lowercase>` regardless of how you cased the name in the allowlist. Missing headers are dropped.

### Capture query parameters

Opt-in. Adds `url.query` as the raw query string with sensitive values masked. Preserves order, repeated keys, and URL encoding.

```dart
loqMiddleware(captureQueryParams: true)
// /search?q=cats&page=2 -> url.query: "q=cats&page=2"
// /search?q=cats&api_key=secret -> url.query: "q=cats&api_key=***"
```

If you need structured access to specific keys downstream, pull them out from the `fields:` hook instead:

```dart
loqMiddleware(
  fields: (event) => switch (event) {
    ShelfRequestStartEvent() => {
        ...event.defaults,
        'tenant_id':
            event.request.requestedUri.queryParameters['tenant_id'],
      },
    _ => event.defaults,
  },
)
```

### Redaction

**Secure by default.** Captured request headers `authorization`, `proxy-authorization`, `cookie`, `x-api-key`, `x-auth-token` and response `set-cookie` are masked to `***`. When `captureQueryParams: true`, common token-bearing keys (`token`, `access_token`, `refresh_token`, `api_key`, `apikey`, `key`, `password`, `secret`, `signature`, `sig`) are also masked.

The header key is preserved so presence is observable in logs. Override per category; empty set disables:

```dart
loqMiddleware(
  captureRequestHeaders: ['authorization'],
  redactRequestHeaders: const {},          // disable redaction entirely
  redactResponseHeaders: const {'set-cookie', 'x-internal-token'},
  redactQueryParams: const {'access_token'},
)
```

#### Sharing the threat model with loq core

If you also want loq core's `redact()` processor to mask additional fields contributed by your own code, plug in the prefixed-name constants so you don't have to repeat the HTTP defaults:

```dart
import 'package:loq/loq.dart';
import 'package:loq_shelf/loq_shelf.dart';

LogConfig.configure(
  processors: [
    redact({
      ...defaultRedactedRequestHeaderFields,   // http.request.header.authorization, etc.
      ...defaultRedactedResponseHeaderFields,  // http.response.header.set-cookie
      'tenant_secret',                          // your own sensitive field
    }),
  ],
);
```

loq_shelf already masks captured HTTP headers inline; these constants exist so other loggers and processors can share the same threat model without rebuilding the prefix mapping. There's no equivalent constant for query params because `url.query` is a single string field whose contents (not key) carry the sensitive parts; substring redaction is handled inline by the middleware.

### Custom message strings

Useful when downstream log pipelines key off specific event names:

```dart
loqMiddleware(
  startMessage: 'http.request.start',
  completeMessage: 'http.request.end',
  errorMessage: 'http.request.error',
)
```

### Custom logger

```dart
loqMiddleware(
  logger: Logger('api', config: LogConfig(
    handlers: [JsonHandler()],
    processors: [addTimestamp()],
  )),
)
```

### Customizing fields

`fields:` and `errorFields:` are the one transformation point for their respective events. Each receives a typed event and returns the final fields. Compose, filter, or fully replace:

```dart
// Add fields on top of defaults (applies to start and response)
loqMiddleware(
  fields: (event) => {
    ...event.defaults,
    'tenant_id': resolveTenant(event.request),
  },
)

// Drop a default field
loqMiddleware(
  fields: (event) =>
      Map.of(event.defaults)..remove('user_agent.original'),
)

// Replace entirely (opts out of OTel defaults for both start and response)
loqMiddleware(
  fields: (event) => {
    'method': event.request.method,
    'path': event.request.requestedUri.path,
  },
)

// Per-event shaping with pattern matching
loqMiddleware(
  fields: (event) => switch (event) {
    ShelfResponseEvent(:final response) => {
        ...event.defaults,
        'contentLength': response.headers['content-length'],
      },
    _ => event.defaults,
  },
)

// Annotate error logs based on the exception type
loqMiddleware(
  errorFields: (event, error, stack) => {
    ...event.defaults,
    'error.retryable': error is TimeoutException || error is SocketException,
    if (error is HttpException) 'error.code': error.uri?.path,
  },
)
```

## API reference

```dart
Middleware loqMiddleware({
  // Setup
  Logger? logger,
  String Function(Request request)? requestIdResolver,
  // Behavior
  bool Function(Request request)? skip,
  bool logStart = true,
  Duration? slowRequestThreshold,
  // Field hooks
  Map<String, Object?> Function(ShelfLogEvent event)? fields,
  Map<String, Object?> Function(
    ShelfLogEvent event,
    Object error,
    StackTrace stackTrace,
  )? errorFields,
  // Resolvers
  String? Function(Request request)? routeResolver,
  String? Function(Request request)? clientIpResolver,
  Level? Function(ShelfLogEvent event, Object? error)? levelResolver,
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
})
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| **Setup** | | |
| `logger` | `Logger('http')` | Logger instance for middleware logs |
| `requestIdResolver` | `X-Request-Id` header or counter | Returns the request ID; always invoked when building defaults |
| **Behavior** | | |
| `skip` | `null` | Bypass middleware entirely when `true` |
| `logStart` | `true` | Emit "request started" log |
| `slowRequestThreshold` | `null` | Adds `slow: true` to defaults and bumps completion level to >= `warn` |
| **Field hooks** | | |
| `fields` | identity | Transforms start and completion defaults; receives the typed event |
| `errorFields` | identity | Transforms error defaults; receives event, error, stack |
| **Resolvers** | | |
| `routeResolver` | `null` | Returns `http.route` template (e.g. `/users/{id}`) |
| `clientIpResolver` | `shelf_io` connection info | Returns `client.address` |
| `levelResolver` | `null` | Overrides level for any event (status-family / `Level.info` / `Level.error` defaults) |
| **Capture** | | |
| `captureRequestHeaders` | `null` | Request header allowlist; output `http.request.header.<lowercase>` |
| `captureResponseHeaders` | `null` | Response header allowlist; output `http.response.header.<lowercase>` |
| `captureQueryParams` | `false` | Add `url.query` (raw query string with sensitive values masked) |
| **Redaction** (`null` = use defaults, `{}` = disable) | | |
| `redactRequestHeaders` | `defaultRedactedRequestHeaders` | Header names whose values are masked |
| `redactResponseHeaders` | `defaultRedactedResponseHeaders` | Header names whose values are masked |
| `redactQueryParams` | `defaultRedactedQueryParams` | Query keys whose values are masked |
| **Messages** | | |
| `startMessage` | `'request started'` | Start-log message |
| `completeMessage` | `'request completed'` | Completion-log message |
| `errorMessage` | `'request failed'` | Error-log message |

## License

MIT. See [LICENSE](LICENSE).
