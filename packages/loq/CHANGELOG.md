## 0.1.2 (2026-05-19)

### Processors
- Added `levelByName(rules, {defaultLevel})` for per-scope filtering by
  dotted logger name. The longest matching prefix wins; the empty-string
  key is a root catch-all. Records with a null logger name fall back to
  `defaultLevel`. Pairs with `Logger.named()` chains and matches the
  per-scope filter shape used by Java/Python/.NET logging:
  ```dart
  LogConfig.configure(processors: [
    levelByName({
      'app.db.queries': Level.trace,
      'app.db':         Level.warn,
      'app':            Level.info,
      '':               Level.error,   // root catch-all
    }),
  ]);
  ```

### Testing (new sub-library `package:loq/testing.dart`)
- Added `RecordingHandler` for test checks. Keeps records in memory and
  offers filters (`at`, `atOrAbove`, `from`, `withField`,
  `withFieldValue`, `messageContaining`) and counts (`count`, `countAt`,
  `countAtOrAbove`). Install it as the only handler to silence other
  output and capture everything for the test to look at:
  ```dart
  import 'package:loq/loq.dart';
  import 'package:loq/testing.dart';

  final recorder = RecordingHandler();
  LogConfig.configure(handlers: [recorder]);
  // ... run the code under test ...
  expect(recorder.atOrAbove(Level.error), isEmpty);
  ```
  The sub-library is kept apart from `package:loq/loq.dart` so test
  helpers stay out of production code.

## 0.1.1 (2026-05-15)

### Logger
- `LogConfig.global` is now resolved lazily on every log call instead
  of being snapshotted at construction. `LogConfig.configure()` updates
  take effect immediately for any logger that did not pin an explicit
  config — order between `Logger()` and `LogConfig.configure()` no
  longer matters. Explicit `config:` passed to `Logger()` still pins
  for that logger's lifetime and propagates through `withFields`.
- Added `Logger.named(String suffix)` for subsystem-scoped logging.
  Appends a dotted suffix and inherits the parent's bound context and
  config-override decision. Chains: `Logger('app').named('db')` →
  `'app.db'`.

### LogConfig
- Added `LogConfig.copyWith()` for deriving a config that overrides
  specific fields while inheriting the rest. Closes the silent-drop
  footgun where the bare `LogConfig(...)` constructor reset every
  unspecified field to its default:
  ```dart
  Logger('hot', config: LogConfig.global.copyWith(
    processors: [sample(10)],
  ))
  ```
- Added `LogConfig.shutdown()` — closes every handler in the current
  global config in parallel. App-shutdown helper so buffered records
  reach their destinations.
- Added `onHandlerError` callback (with default reporter). Exceptions
  thrown by `Handler.isEnabled()` or `Handler.handle()` are now caught
  and routed to this callback rather than propagated to the caller —
  a misbehaving handler no longer breaks logging for siblings or the
  host. Default prints a `loq:`-prefixed diagnostic via `print()`;
  override to redirect to Sentry, stderr, etc.

### Level
- Added `Level.tryParse(String)` for reading level names from env
  vars or config files. Case-insensitive, trims whitespace, accepts
  the six standard names plus `'warning'` as an alias for `warn`.
  Returns `null` for unknown input.

### ConsoleHandler
- Added `useColor` constructor flag for ANSI-colored level output
  (gray / cyan / green / yellow / red / bright-red bold for trace
  through fatal). Default `false` to avoid emitting escape sequences
  in non-TTY contexts. Wire detection at your app entrypoint:
  ```dart
  ConsoleHandler(
    useColor: stdout.supportsAnsiEscapes &&
        Platform.environment['NO_COLOR'] == null,
  )
  ```
- Added `levelColors` constructor parameter for overriding the
  default palette per level. Partial overrides keep the rest of the
  defaults. Custom levels look up by exact match first, then fall
  through to the nearest band's override or default:
  ```dart
  ConsoleHandler(
    useColor: true,
    levelColors: const {
      Level.info: '\x1B[35m',     // magenta
      Level(11): '\x1B[1;94m',    // custom notice level
    },
  )
  ```

### JsonHandler & IsolateHandler
- Type-aware normalization for common Dart types:
  - `DateTime` → ISO 8601 string.
  - `Duration` → integer milliseconds.
  - `Uri` → canonical string.

  Previously these all hit the `v.toString()` fallback — `DateTime`
  in particular rendered as the non-ISO `'2026-05-15 10:00:00.000'`
  form, which most log pipelines reject.

### JsonHandler
- Added `dateTimeFormatter` constructor parameter for customizing how
  `Record.time` and any DateTime field value is rendered. Defaults
  to `DateTime.toIso8601String`. One handler-level setting controls
  both paths, so the entire JSON stream has a consistent shape:
  ```dart
  JsonHandler(
    dateTimeFormatter: (dt) => dt.millisecondsSinceEpoch.toString(),
  )
  ```
  `IsolateHandler` deliberately omits this — records round-trip back
  via `deserialize`, which requires ISO 8601 for the time field.

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
