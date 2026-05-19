## 0.2.0

### Breaking

- **Sealed event hierarchy.** Hooks now receive a typed `ShelfLogEvent`
  instead of raw `Request` / `Response` / `Duration` positional
  arguments. Three concrete variants live under the sealed base:
  - `ShelfRequestStartEvent` for the start log. Carries `request` and
    `defaults`; `elapsed` is `null`.
  - `ShelfResponseEvent` for the completion log. Carries `request`,
    `response`, `elapsed`, `defaults`.
  - `ShelfRequestErrorEvent` for the error log. Carries `request`,
    `elapsed`, `defaults`. The caught error and stack trace reach
    hooks through `errorFields:`'s extra positional parameters.

  Branch on the event with `switch` for per-path shaping.

- **Hook collapse.** The three separate `fields:` / `responseFields:` /
  `errorFields:` callbacks are now two, both event-typed:
  - `fields: (ShelfLogEvent event) -> Map<String, Object?>` for the
    start and completion paths.
  - `errorFields: (ShelfLogEvent event, Object error, StackTrace stack)
    -> Map<String, Object?>` for the error path.

- **`levelResolver` signature** is now
  `(ShelfLogEvent event, Object? error) -> Level?`. The previous
  `Response?` / `Duration` top-level parameters are reachable through
  the event. `levelResolver` now also applies to
  `ShelfRequestStartEvent`, with a fallback of `Level.info`. Returning
  `null` falls back to the per-event default (`Level.info` for start,
  status-family mapping for response, `Level.error` for error).

- **Error event defaults inherit request defaults.** The error event's
  `defaults` now includes everything the start event carried (method,
  path, requestId, captured headers, and so on) plus the error-specific
  fields (`duration_ms`, `error.type`, `error.message`, `slow`).
  Replacing `errorFields:` with a partial map no longer silently loses
  the request context inside the hook; users see the full picture in
  `event.defaults`. The emitted record was already inheriting these
  via the bound logger; the change is to what the hook sees, making
  it consistent with `loq_drift`.

- Requires `loq ^0.1.2`.

### Migration

```dart
// 0.1.x
loqMiddleware(
  fields: (req, defaults) => {...defaults, 'tenant': resolveTenant(req)},
  responseFields: (response, elapsed, defaults) => {
    ...defaults,
    'cache_hit': response.headers['cache-status'] == 'HIT',
  },
  errorFields: (error, stack, elapsed, defaults) => {
    ...defaults,
    'error.retryable': error is TimeoutException,
  },
  levelResolver: (response, elapsed, error) {
    if (response?.statusCode == 404) return Level.info;
    return null;
  },
)

// 0.2.0
loqMiddleware(
  fields: (event) => switch (event) {
    ShelfRequestStartEvent() => {
        ...event.defaults,
        'tenant': resolveTenant(event.request),
      },
    ShelfResponseEvent(:final response) => {
        ...event.defaults,
        'cache_hit': response.headers['cache-status'] == 'HIT',
      },
    ShelfRequestErrorEvent() => event.defaults,
  },
  errorFields: (event, error, stack) => {
    ...event.defaults,
    'error.retryable': error is TimeoutException,
  },
  levelResolver: (event, error) => switch (event) {
    ShelfResponseEvent(:final response) when response.statusCode == 404 =>
      Level.info,
    _ => null,
  },
)
```

### Internal

- Inner middleware closure restructured around named `logStartEvent` /
  `logCompletion` / `logFailure` helpers. The try/catch is now pure
  flow control. Cuts the closure body roughly in half without changing
  observable behavior.

- Tests split by feature area to keep each file readable:
  `loq_middleware_test.dart` (core, OTel defaults, request ID, skip,
  slow, messages, concurrency), `loq_middleware_hooks_test.dart`
  (fields, errorFields, levelResolver, route/clientIp resolvers,
  default level mapping), `loq_middleware_capture_test.dart` (header
  and query capture, redaction, prefixed-fields constants),
  `shelf_log_event_test.dart` (sealed event unit tests).

- Test fixtures moved to `test/test_helpers.dart` (`FakeConnectionInfo`,
  `request()`). The hand-rolled `TestLogHandler` is gone; tests use
  `RecordingHandler` from `package:loq/testing.dart` and lean on its
  `from`, `messageContaining`, `at`, `atOrAbove` filters where they
  shorten the assertions.

## 0.1.0

- Initial release.
- `loqMiddleware()`, structured request logging for Shelf.
- Default fields aligned with OpenTelemetry HTTP server semantic
  conventions: `http.request.method`, `url.path`, `url.scheme`,
  `server.address`, `server.port`, `network.protocol.version`,
  `client.address`, `user_agent.original`, `http.request.body.size`,
  `http.route`, `http.response.status_code`, `http.response.body.size`,
  `http.response.header.content-type`, `error.type`, `error.message`.
  Plus `requestId` (loq-specific) and `duration_ms`.
- Request fields propagate via zone context, so any log inside the
  handler inherits them.
- Configurable request ID extraction via `requestIdResolver`.
- `fields` / `responseFields` / `errorFields` are the single
  transformation point for their respective logs. Each receives a
  `defaults` map containing everything the middleware would
  contribute (OTel core, captured headers, `url.query`, `slow`,
  whichever apply) and returns the final field map. Spread
  `...defaults` to compose on top; return a different map to
  replace (which drops anything not re-included).
- `logStart` flag to suppress start logs in production.
- `levelResolver`, single hook that overrides level for both
  completion and error paths; sees response, elapsed duration, and
  error. Returning `null` falls back to the default mapping
  (5xx -> error, 4xx -> warn, else -> info; `error` for errors).
  `slowRequestThreshold`'s warn-bump still stacks on top.
- `routeResolver`, supplies route templates (e.g. `/users/{id}`)
  for `http.route`, preventing per-path cardinality explosions in
  dashboards.
- `clientIpResolver`, override for `client.address`. Defaults to
  reading `shelf_io` connection info.
- `skip` predicate to bypass logging for health checks, readiness
  probes, and metrics scrapers.
- `slowRequestThreshold` to flag and escalate requests that exceed
  a duration: adds `slow: true` and ensures the level is at least
  `warn`.
- `captureRequestHeaders` / `captureResponseHeaders` allowlists for
  binding selected headers as structured fields. Output field names
  follow the OTel convention `http.request.header.<lowercase>` and
  `http.response.header.<lowercase>`. Request headers propagate
  via zone context.
- `captureQueryParams` to opt in to logging the query string as
  `url.query` (raw wire form, sensitive values masked, order and
  repeats preserved).
- **Secure-by-default redaction.** `authorization`,
  `proxy-authorization`, `cookie`, `x-api-key`, `x-auth-token`
  (request), `set-cookie` (response), and common token-bearing
  query keys (`token`, `access_token`, `refresh_token`, `api_key`,
  `apikey`, `key`, `password`, `secret`, `signature`, `sig`) are
  masked to `***` when captured. Override via
  `redactRequestHeaders` / `redactResponseHeaders` /
  `redactQueryParams`; pass `{}` to disable.
- Exposed `defaultRedactedRequestHeaderFields` and
  `defaultRedactedResponseHeaderFields`, the same threat model
  with the OTel `http.request.header.` / `http.response.header.`
  prefix applied. Plug into loq core's `redact()` processor to
  share the HTTP defaults with redaction of fields contributed by
  user code, without manually rebuilding the prefix mapping.
- `startMessage` / `completeMessage` / `errorMessage` overrides.
