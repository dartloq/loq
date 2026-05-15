## 0.1.0

- Initial release.
- `loqMiddleware()` — structured request logging for Shelf.
- Default fields aligned with OpenTelemetry HTTP server semantic
  conventions: `http.request.method`, `url.path`, `url.scheme`,
  `server.address`, `server.port`, `network.protocol.version`,
  `client.address`, `user_agent.original`, `http.request.body.size`,
  `http.route`, `http.response.status_code`, `http.response.body.size`,
  `http.response.header.content-type`, `error.type`, `error.message`.
  Plus `requestId` (loq-specific) and `duration_ms`.
- Request fields propagate via zone context — any log inside the
  handler inherits them.
- Configurable request ID extraction via `requestIdResolver`.
- `fields` / `responseFields` / `errorFields` are the single
  transformation point for their respective logs. Each receives a
  `defaults` map containing everything the middleware would
  contribute (OTel core, captured headers, `url.query`, `slow` —
  whichever apply) and returns the final field map. Spread
  `...defaults` to compose on top; return a different map to
  replace (which drops anything not re-included).
- `logStart` flag to suppress start logs in production.
- `levelResolver` — single hook that overrides level for both
  completion and error paths; sees response, elapsed duration, and
  error. Returning `null` falls back to the default mapping
  (5xx → error, 4xx → warn, else → info; `error` for errors).
  `slowRequestThreshold`'s warn-bump still stacks on top.
- `routeResolver` — supplies route templates (e.g. `/users/{id}`)
  for `http.route`, preventing per-path cardinality explosions in
  dashboards.
- `clientIpResolver` — override for `client.address`. Defaults to
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
  `defaultRedactedResponseHeaderFields` — the same threat model
  with the OTel `http.request.header.` / `http.response.header.`
  prefix applied. Plug into loq core's `redact()` processor to
  share the HTTP defaults with redaction of fields contributed by
  user code, without manually rebuilding the prefix mapping.
- `startMessage` / `completeMessage` / `errorMessage` overrides.
