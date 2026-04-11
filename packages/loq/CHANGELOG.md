## 0.1.0

### New types
- `Lazy<T>` for deferred field values — only evaluated if the record passes
  early-out filtering, resolved before Record creation so handlers never see
  `Lazy` instances.
- `FieldGroup` for namespacing related fields — `JsonHandler` renders as nested
  JSON objects, `ConsoleHandler` uses dotted-key notation.
- `SourceLocation` for opt-in call-site capture via
  `LogConfig.captureSourceLocation`. Parses Dart VM stack trace frames.

### Record
- Added optional `source` field for call-site location.
- Added `withSource()` and `copyWith()` methods.

### Logger
- Added `isEnabled()` to guard expensive field computation.
- Lazy values are now resolved in `_log()` before Record creation.
- Source location captured automatically when `captureSourceLocation` is enabled.

### New processors
- `when()` — conditionally apply a processor.
- `addTimestamp()` — add ISO 8601 timestamp field.
- `addLevel()` — add level name field.
- `addLoggerName()` — add logger name field.
- `addSource()` — copy Record.source to fields map.

### New handlers
- `MultiHandler` — dispatches to multiple sub-handlers.
- `BufferedHandler` — abstract base for batched output with size threshold,
  periodic timer, and concurrent flush guard.
- `IsolateHandler` — callback-based cross-isolate logging. Serializes records
  to plain maps; works with `SendPort.send` on native and any messaging
  callback on web.

### Handler improvements
- `ConsoleHandler` now renders source location after the message, uses
  dotted-key notation for `FieldGroup`, and indents stack trace lines
  consistently.
- `JsonHandler` now renders `FieldGroup` as nested objects, includes
  `record.source` in output, and resolves `Lazy` values as a safety net.

### Other
- `Level` changed from enum to `extension type const Level(int)`, enabling
  custom levels without forking the package.
- `LogConfig.configure()` now accepts `captureSourceLocation`.
- Split single-file implementation into 15 focused source files.
- Thread safety documentation added to README.

## 0.0.1

- Initial version.
