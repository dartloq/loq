## 0.1.0

- Initial release.
- `LoqNavigatorObserver`: a `NavigatorObserver` that emits a structured
  log record on every `didPush` / `didPop` / `didReplace` / `didRemove`
  and tracks the current screen as instance state. Keeps to
  `PageRoute` by default so dialogs and modals stay out of the log
  stream; pass `includeNonPageRoutes: true` to track every route.
- `LoqNavigatorObserver.screenFieldsProcessor`: a `Processor` that
  adds `app.screen.name` and `loq.app.screen.previous_name` to every
  record emitted by any logger, sourced from the observer's tracked
  state. Wire it into `LogConfig.global.processors` to make screen
  context follow every log.
- `LoqLifecycleObserver`: a `WidgetsBindingObserver` wrapper that
  emits lifecycle events and flushes registered handlers on `paused`
  and `detached` (opt-in `hidden`). `flushHandlers` defaults to
  `LogConfig.global.handlers` read at flush time, so changes through
  `LogConfig.configure` are picked up.
- `initLoq()`: one-call setup that runs the user's `runApp` inside
  `runZonedGuarded` and wires `FlutterError.onError` and
  `PlatformDispatcher.instance.onError` with **chain-and-restore**
  semantics so it lives alongside other packages that touch those
  slots (Crashlytics, Sentry, etc.). Installs `LoqLifecycleObserver`
  by default; pass `installLifecycleObserver: false` to skip.
- **Bounded LRU hash queue** dedupes the same exception across
  capture paths (`PlatformDispatcher.onError` plus `runZonedGuarded`),
  so it logs once even when both fire.
- **`reportSilentFlutterErrors: false`** by default. Drops
  `FlutterErrorDetails.silent` so framework-handled errors don't
  add noise. Override per call site.
- Default fields follow the OpenTelemetry semantic conventions where
  OTel defines them; everything else lives under the `loq.*`
  namespace so it can't collide with future OTel additions.
  - OTel-verbatim: `exception.type`, `exception.message`,
    `exception.stacktrace` (Stable); `app.screen.name` (Development).
  - Loq-namespaced: `loq.app.screen.previous_name`,
    `loq.navigation.kind`, `loq.navigation.route_type`,
    `loq.navigation.is_first_route`, `loq.app.lifecycle.state`,
    `loq.app.lifecycle.previous_state`, `loq.error.source`,
    `loq.error.handled`, `loq.flutter.library`, `loq.flutter.context`,
    `loq.flutter.silent`.
- Sealed event hierarchies for hooks: `NavigationEvent`
  (`NavigationPushEvent` / `NavigationPopEvent` /
  `NavigationReplaceEvent` / `NavigationRemoveEvent`), `LifecycleEvent`
  (`AppResumedEvent` / `AppInactiveEvent` / `AppHiddenEvent` /
  `AppPausedEvent` / `AppDetachedEvent`), `ErrorEvent`
  (`FlutterFrameworkErrorEvent` / `PlatformDispatcherErrorEvent` /
  `ZoneGuardErrorEvent`). One typed `fields:` hook covers every event
  variant; pattern-match with `switch` to branch.
- Public default helpers: `defaultNavigationFields`,
  `defaultLifecycleFields`, `defaultErrorFields`,
  `defaultScreenNameResolver`. Build on them through `...defaults` in
  the `fields:` hook.
- Resolver-suffix hooks: `nameResolver` (screen-name extraction;
  override for go_router or auto_route), `levelResolver` (per-event
  level override). `skipLog` predicate (on `LoqNavigatorObserver`)
  drops the log for noisy events while still updating internal screen
  state; named after `loq_drift`'s `skipLog` to flag the narrower
  scope vs. `loq_shelf`'s `skip`. `message` override for every event.
- Works with raw `Navigator`, `go_router` (`observers:`), and
  `auto_route` (`navigatorObservers:`). README has setup recipes for
  each.
- `ansiForegroundFromColor(Color)` and `ansiLevelColors(Map<Level,
  Color>)`: turn Flutter `Color` values into 24-bit ANSI true-color
  escapes for `ConsoleHandler`'s `levelColors:` map. Lets users on
  Flutter stay in `Colors.deepOrange` idioms instead of hand-coding
  `'\x1B[31m'`.
- **Hot-reload safety**: `LoqErrorState` keeps a process-wide
  reference to the instance that owns `FlutterError.onError` and
  `PlatformDispatcher.onError`. A second `initLoq` call (typical on
  hot reload) disposes the prior owner first so the handler chain
  stays flat instead of growing one level per reload.
- **`FlutterErrorDetails.informationCollector`** is now captured as
  `loq.flutter.information`: a `List<String>` of widget-tree
  diagnostic notes (e.g. "The relevant error-causing widget was:
  Foo"). Left out when empty.
- **`MemoryPressureEvent`**: `LoqLifecycleObserver` now overrides
  `didHaveMemoryPressure`. Emits at `Level.warn` by default
  (`memoryPressureLevel:` to override) and flushes registered
  handlers (`flushOnMemoryPressure: false` to turn off). Field:
  `loq.memory.pressure`.
- **`LocaleChangeEvent`**: `LoqLifecycleObserver` overrides
  `didChangeLocales`. Emits at `Level.debug` carrying the new and
  previous locale lists. Fields: `loq.app.locales`,
  `loq.app.previous_locales`. No flush.
- **App-in-background duration**: when `AppResumedEvent` follows
  `AppPausedEvent`, the resumed event's defaults include
  `loq.app.background_duration_ms`: wall-clock time the app spent
  paused. Useful for stale-session checks.
- **`LifecycleEvent` hierarchy refactor**: the five
  `AppLifecycleState` variants now live under a new intermediate
  `AppLifecycleStateEvent` sealed class. `MemoryPressureEvent` and
  `LocaleChangeEvent` extend `LifecycleEvent` directly. Switch on
  `AppLifecycleStateEvent` to treat all five app-state events the
  same way.
- **`captureSourceLocation` flag on `initLoq()`**: top-level setting
  that flows into `LogConfig.captureSourceLocation`, turning on
  source-location capture for dev builds without a separate
  `LogConfig.configure` call.
- **`debugPrint` redirect on `initLoq()`**: optional
  `redirectFlutterDebugPrint: true` flag captures Flutter framework
  output (layout warnings, asset chatter,
  `FlutterError.dumpErrorToConsole`, and so on) into a configurable
  logger. Only touches `debugPrint`, not plain `print()`, so
  `ConsoleHandler` stays loop-free. Hot-reload-safe via the same
  static-owner pattern as the error slots. Off by default since
  debug builds are noisy. Configurable via `flutterDebugLogger:`
  and `flutterDebugLevel:`.
