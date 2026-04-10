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

## Bound loggers

Attach context that flows through every subsequent log call:

```dart
final log = Logger('api');
final reqLog = log.withFields({'requestId': 'abc-123', 'userId': 42});

reqLog.info('handling request');       // includes requestId, userId
reqLog.warn('slow query', fields: {'ms': 340});  // includes all three
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

## Handlers

Handlers are the output backends. Loq ships with `ConsoleHandler` (dev) and `JsonHandler` (production). Write your own by implementing the `Handler` interface:

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
