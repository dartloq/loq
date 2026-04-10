## 0.1.0

- **Lazy fields**: `Lazy<T>` wraps expensive computations that are only evaluated
  if the record passes early-out filtering. Resolved in `Logger._log()` before
  Record creation so handlers never see `Lazy` instances.
- **FieldGroup**: namespace related fields under a key. `JsonHandler` renders
  them as nested JSON objects; `ConsoleHandler` uses dotted-key notation.
- **SourceLocation**: opt-in call-site capture via `LogConfig.captureSourceLocation`.
  Parses Dart VM stack trace frames for file, line, column, and member.
- **Record.source**: dedicated optional field for source location.
- **Record.copyWith()** and **Record.withSource()**: convenience methods for
  processors and immutable record manipulation.
- **Logger.isEnabled()**: public method to guard expensive field computation.
- **MultiHandler**: dispatches records to multiple sub-handlers.
- **BufferedHandler**: abstract base for batched output with size threshold,
  periodic timer, concurrent flush guard, and close semantics.
- **IsolateHandler**: callback-based handler for cross-isolate logging.
  Serializes records to plain maps; works with `SendPort.send` on native
  and any messaging callback on web.
- **New processors**: `when()`, `addTimestamp()`, `addLevel()`,
  `addLoggerName()`, `addSource()`.
- **Level as extension type**: replaced enum with `extension type const Level(int)`
  enabling custom levels without forking the package.

## 0.0.1

- Initial version.
