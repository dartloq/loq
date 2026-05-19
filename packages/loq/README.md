# loq

Structured logging for Dart. Pipeline architecture, OTel-ready, works everywhere.

```dart
import 'package:loq/loq.dart';

final log = Logger('my_service');
log.info('request handled', fields: {'path': '/api', 'status': 200});
```

## Why loq?

Most Dart logging packages give you string messages with levels. Loq gives you **structured key-value fields** that flow through a processor pipeline to pluggable handlers — console, JSON, OpenTelemetry, Crashlytics, or your own.

**Before** (unstructured):
```
INFO: 2026-04-09: Payment processed for order abc-123, amount $99.95
```

**After** (structured with loq):
```json
{"time":"2026-04-09T12:34:56.789Z","level":"info","msg":"payment processed","logger":"payments","orderId":"abc-123","amount":99.95}
```

Structured logs are searchable, filterable, and directly consumable by observability backends like Grafana, Datadog, and Elastic.

## Features

- **Structured fields** — attach typed key-value data to every log
- **Pipeline architecture** — Logger → Processors → Handlers
- **Bound loggers** — `logger.withFields()` returns a new logger with inherited context
- **Zone-based context** — fields flow through async calls automatically
- **Early-out filtering** — skip all work when a level is disabled
- **Pure Dart** — no platform dependencies, works on server, Flutter, CLI, web
- **OTel-ready** — designed to bridge into OpenTelemetry (adapter coming soon)

## Quick start

```dart
import 'package:loq/loq.dart';

void main() {
  // Optional: configure handlers and processors
  LogConfig.configure(
    handlers: [ConsoleHandler(minLevel: Level.debug)],
    zoneAccessor: defaultZoneAccessor,
  );

  final log = Logger('app');
  log.info('started', fields: {'port': 8080});
}
```

Loggers resolve `LogConfig.global` lazily at every log call, so the order of `LogConfig.configure()` and `Logger()` doesn't matter — a logger created before `configure()` runs picks up the new config on its next log call. Pin a config to a specific logger by passing `Logger('app', config: LogConfig(...))`; that logger then ignores subsequent global changes.

Read the log level from an env var with `Level.tryParse`:

```dart
final level = Level.tryParse(Platform.environment['LOG_LEVEL'] ?? '');
LogConfig.configure(handlers: [
  ConsoleHandler(minLevel: level ?? Level.info),
]);
```

Flush buffered handlers at shutdown:

```dart
await LogConfig.shutdown();
```

Misbehaving handlers don't crash the host — `isEnabled()` and `handle()` exceptions are caught and surfaced via `LogConfig`'s `onHandlerError` (default prints a `loq:`-prefixed diagnostic; override to redirect to Sentry, stderr, etc.).

## Bound loggers

Attach context that flows through every subsequent log call:

```dart
final log = Logger('api');
final reqLog = log.withFields({'requestId': 'abc-123', 'userId': 42});

reqLog.info('handling request');       // includes requestId, userId
reqLog.warn('slow query', fields: {'ms': 340});  // includes all three
```

For subsystem-scoped loggers, `named()` appends a dotted suffix:

```dart
final dbLog = Logger('app').named('db');           // 'app.db'
final queryLog = dbLog.named('queries');           // 'app.db.queries'
```

## Zone context

Attach fields that automatically propagate through async code — no need to pass loggers around:

```dart
withLogContext({'traceId': 'xyz', 'tenantId': 'acme'}, () async {
  final log = Logger('db');
  log.info('query executed');  // includes traceId and tenantId
  await someAsyncWork();
  log.info('done');            // still includes them
});
```

## Error logging

```dart
try {
  await riskyOperation();
} catch (e, st) {
  log.error('operation failed', error: e, stackTrace: st, fields: {
    'orderId': order.id,
  });
}
```

## Processors

Processors form a chain that transforms, enriches, or filters records before they reach handlers:

```dart
LogConfig.configure(
  processors: [
    redact({'password', 'token'}),   // replace sensitive values
    filterByLevel(Level.info),        // drop debug/trace in production
    sample(10),                       // pass ~1 in 10 records (for high-volume)
  ],
  handlers: [JsonHandler()],
);
```

For per-scope filtering by logger name, use `levelByName`:

```dart
LogConfig.configure(
  processors: [
    levelByName({
      'app.db.queries': Level.trace,  // most specific kept loudest
      'app.db':         Level.warn,
      'app':            Level.info,
      '':               Level.error,   // root catch-all
    }),
  ],
);

// Logger('app.db.queries.select') → keep trace+
// Logger('app.db.connection')     → keep warn+
// Logger('payments')              → keep error+ (hits the '' catch-all)
```

Longest matching prefix wins, walking dotted logger names parent-by-parent. Pairs with `Logger.named()` chains. Records with a null logger name fall back to `defaultLevel`.

## Handlers

Handlers are the output backends. Loq ships with `ConsoleHandler` (dev) and `JsonHandler` (production).

`ConsoleHandler` can color the level token with ANSI escapes via `useColor: true`. Off by default to avoid escape sequences in non-TTY contexts (CI logs, file redirection). Wire detection at your app entrypoint:

```dart
import 'dart:io';

LogConfig.configure(handlers: [
  ConsoleHandler(
    useColor: stdout.supportsAnsiEscapes &&
        Platform.environment['NO_COLOR'] == null,
  ),
]);
```

Color scheme follows the standard convention: gray (trace), cyan (debug), green (info), yellow (warn), red (error), bright-red bold (fatal). Custom levels fall into the nearest band by severity.

Override per level via `levelColors` (partial overrides keep the rest of the defaults):

```dart
ConsoleHandler(
  useColor: true,
  levelColors: const {
    Level.info: '\x1B[35m',          // magenta INFO
    Level(11): '\x1B[1;94m',         // bright bold blue for a custom notice level
  },
)
```

Custom levels are looked up by exact match first, then by their nearest standard band (e.g. `Level(11)` falls under `Level.info` if no exact entry exists).

Write your own handler by implementing the `Handler` interface:

```dart
class MyHandler implements Handler {
  @override
  bool isEnabled(Level level) => level >= Level.warn;

  @override
  void handle(Record record) {
    // Send to your backend
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
```

## JSON output

```dart
LogConfig.configure(handlers: [JsonHandler()]);

final log = Logger('api');
log.info('request completed', fields: {'path': '/users', 'status': 200});

// Output:
// {"time":"2026-04-09T12:34:56.789Z","level":"info","msg":"request completed","logger":"api","path":"/users","status":200}
```

DateTime, Duration, and Uri field values are normalized automatically: DateTime → ISO 8601 (`toIso8601String()`), Duration → integer milliseconds, Uri → canonical string.

Override the DateTime format via `dateTimeFormatter` — applies to both `Record.time` and any DateTime field value, so your pipeline sees consistent timestamps:

```dart
// Epoch milliseconds for SIEM ingest
JsonHandler(
  dateTimeFormatter: (dt) => dt.millisecondsSinceEpoch.toString(),
)
```

## Thread safety

Dart is single-threaded per isolate, so loq is inherently safe within one isolate — no mutexes or locks needed.

For **cross-isolate** logging, use `IsolateHandler` to ship records from worker isolates to the main isolate:

```dart
// Main isolate — receive and handle
final receivePort = ReceivePort();
receivePort.listen((message) {
  final record = IsolateHandler.deserialize(message as Map<String, Object?>);
  mainHandler.handle(record);
});

// Worker isolate — send via callback
void worker(SendPort sendPort) {
  LogConfig.configure(handlers: [IsolateHandler(sendPort.send)]);
  Logger('worker').info('processing', fields: {'itemId': 42});
}
```

Key points:

- `LogConfig.global`, handlers, and Zone context are **per-isolate** — they don't transfer across isolate boundaries.
- `Lazy` fields are resolved before `Record` creation, so closures never cross isolate boundaries.
- `BufferedHandler` guards against re-entrant flushes with an internal `_flushing` flag, preventing timer-triggered and threshold-triggered flushes from racing.

## Testing

For tests, install `RecordingHandler` as the only handler. It keeps records in memory so you can check them, and silences other output:

```dart
import 'package:loq/loq.dart';
import 'package:loq/testing.dart';

test('publishes the order', () {
  final recorder = RecordingHandler();
  LogConfig.configure(handlers: [recorder]);

  service.publishOrder(...);

  expect(recorder.count, 1);
  expect(recorder.atOrAbove(Level.error), isEmpty);
  expect(recorder.from('app.publish').first.fields['orderId'], 'abc');
});
```

Filter getters: `at(level)`, `atOrAbove(level)`, `from(name)`, `withField(key)`, `withFieldValue(key, value)`, `messageContaining(pattern)`.

Count helpers: `count`, `countAt(level)`, `countAtOrAbove(level)`.

The `package:loq/testing.dart` sub-library is kept apart from `package:loq/loq.dart` so test helpers stay out of production code.

## Ecosystem (planned)

| Package | Description |
|---------|-------------|
| `loq` | Core structured logging (this package) |
| `loq_otel` | OpenTelemetry log bridge via Dartastic |
| `loq_flutter` | Flutter lifecycle, navigation context |
| `loq_crashlytics` | Firebase Crashlytics adapter |
| `loq_sentry` | Sentry adapter |

## Design influences

Loq's architecture follows patterns proven by [Go's slog](https://pkg.go.dev/log/slog), [Python's structlog](https://www.structlog.org/), and [.NET's Serilog](https://serilog.net/): a frontend/backend split with a processor chain between them.

## License

MIT. See [LICENSE](LICENSE).
