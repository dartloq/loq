# loq_flutter

Flutter integration for [loq](https://pub.dev/packages/loq) structured logging.

```dart
import 'package:flutter/widgets.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

final navObserver = LoqNavigatorObserver();

void main() => initLoq(() {
  WidgetsFlutterBinding.ensureInitialized();
  LogConfig.configure(
    processors: [navObserver.screenFieldsProcessor],
    handlers: [JsonHandler()],
  );
  runApp(MyApp(navObserver: navObserver));
});
```

Three pieces:

- **`LoqNavigatorObserver`**: logs route push/pop/replace/remove and tracks the current screen. Exposes a `Processor` that adds `app.screen.name` to every record app-wide.
- **`LoqLifecycleObserver`**: emits lifecycle events and flushes buffered handlers on `paused` / `detached`.
- **`initLoq()`**: one-call setup. Wraps `runApp` in `runZonedGuarded`, chains `FlutterError.onError` and `PlatformDispatcher.instance.onError` with save-and-restore so it plays nicely with Crashlytics or Sentry, and installs the lifecycle observer by default.

## Why

Most Flutter logging adapters either drop framework errors silently or replace the global error slots, breaking everything else that wants to read them. `loq_flutter` is a thin Flutter glue layer over loq core that:

1. **Chains, doesn't replace.** Every global slot we touch is saved before install and called from inside our wrapper. Dispose puts the old handler back. You can stack `loq_flutter` with Crashlytics or Sentry without losing reports on either side.
2. **Dedupes across capture paths.** A bounded LRU hash queue keeps one record per exception even when `PlatformDispatcher.onError` and `runZonedGuarded` both fire.
3. **Tracks screen context.** A `Processor` exported by `LoqNavigatorObserver` reads the observer's internal stack and adds `app.screen.name` / `loq.app.screen.previous_name` to every record without manual threading.
4. **Flushes on lifecycle.** Last-chance flush on `paused` / `detached`. You can turn each one off.

## Setup

The full setup, with everything turned on:

```dart
import 'package:flutter/widgets.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

final navObserver = LoqNavigatorObserver();

Future<void> main() async {
  await initLoq(() {
    WidgetsFlutterBinding.ensureInitialized();
    LogConfig.configure(
      processors: [navObserver.screenFieldsProcessor],
      handlers: [JsonHandler()],
    );
    runApp(MyApp(navObserver: navObserver));
  });
}

class MyApp extends StatelessWidget {
  const MyApp({required this.navObserver, super.key});
  final LoqNavigatorObserver navObserver;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [navObserver],
      home: const HomeScreen(),
    );
  }
}
```

That's it. Every log record now carries `app.screen.name`, every uncaught Flutter framework error / async error / zone error becomes a `Level.fatal` record, and buffered handlers flush when the app goes to background.

## Default fields

Field names follow OpenTelemetry semantic conventions where OTel defines an attribute (at any stability level: even Development is better than inventing our own). Everything else lives under the `loq.*` namespace so it can't collide with future OTel additions.

### Navigation

| Field | OTel | Description |
| --- | --- | --- |
| `app.screen.name` | Development | Current screen name from the resolver chain. |
| `loq.app.screen.previous_name` | none | Previous screen, or `null` on the first push. |
| `loq.navigation.kind` | none | `push` / `pop` / `replace` / `remove`. |
| `loq.navigation.route_type` | none | `route.runtimeType.toString()` of the subject route. |
| `loq.navigation.is_first_route` | none | `true` when this is the first observed change. |

### Lifecycle

OTel does not currently standardize app lifecycle state, so all fields are under `loq.*`.

| Field | Description |
| --- | --- |
| `loq.app.lifecycle.state` | `resumed` / `inactive` / `hidden` / `paused` / `detached`. |
| `loq.app.lifecycle.previous_state` | Same vocabulary, or `null` on the first event. |
| `loq.app.background_duration_ms` | Wall-clock time the app spent paused. Attached to the resumed event when the prior state was `paused`. Left out otherwise. |
| `loq.memory.pressure` | `true`, on `didHaveMemoryPressure` events. |
| `loq.app.locales` | `List<String>` of `Locale.toString()`, on `didChangeLocales` events. |
| `loq.app.previous_locales` | Same shape, locale list before the change. |

### Errors

| Field | OTel | Description |
| --- | --- | --- |
| `exception.type` | Stable | `error.runtimeType.toString()`. |
| `exception.message` | Stable | `error.toString()`. |
| `exception.stacktrace` | Stable | `stackTrace.toString()`. |
| `loq.error.source` | none | `flutter_framework` / `platform_dispatcher` / `zone_guard`. |
| `loq.error.handled` | none | Upstream-handler status (always `false` for `FlutterError.onError`, always `true` for zone-guard, dynamic for `PlatformDispatcher.onError`). |
| `loq.flutter.library` | none | From `FlutterErrorDetails.library` (Flutter framework errors only). |
| `loq.flutter.context` | none | Text form of `FlutterErrorDetails.context`. |
| `loq.flutter.silent` | none | From `FlutterErrorDetails.silent`. |
| `loq.flutter.information` | none | `List<String>` of widget-tree diagnostic notes from `FlutterErrorDetails.informationCollector`, when non-empty. Carries context like "The relevant error-causing widget was: Foo". |

> **OTel status note.** `app.screen.name` is currently Development in OpenTelemetry. The attribute name is stable but its meaning could narrow in future minor versions. Written down here so dashboards keying off it know to watch the spec.

## Sealed event hooks

All three observers expose one `fields:` callback that takes a sealed event:

```dart
final observer = LoqNavigatorObserver(
  fields: (event) => switch (event) {
    NavigationPushEvent(:final route) => {
      ...event.defaults,
      'pushed_via': '${route.navigator}',
    },
    NavigationPopEvent() => event.defaults,
    NavigationReplaceEvent() || NavigationRemoveEvent() =>
      event.defaults,
  },
);
```

Same shape for `LoqLifecycleObserver(fields: (event) { ... })` over `LifecycleEvent`, and `initLoq(errorFields: (event) { ... })` over `ErrorEvent`. Spread `...event.defaults` to add to it, or return a different map to replace it outright.

Other hooks on every observer:

| Hook | Purpose |
| --- | --- |
| `logger` | Custom `Logger` (defaults to `loq_flutter.<area>`). |
| `level` | Default record level (override per-event via `levelResolver`). |
| `levelResolver` | Per-event level override; returning `null` falls back to `level`. |
| `message` | Per-event message override. |

## Setup recipes

### go_router

```dart
final navObserver = LoqNavigatorObserver(
  // go_router leaves route.settings.name null for most routes.
  // Pull the name out of the Page settings instead.
  nameResolver: (route) {
    final settings = route.settings;
    if (settings is Page) {
      return settings.name ?? settings.key?.toString();
    }
    return settings.name ?? route.runtimeType.toString();
  },
);

final router = GoRouter(
  observers: [navObserver],
  routes: [
    GoRoute(path: '/', name: 'home', builder: (_, __) => HomeScreen()),
    GoRoute(path: '/settings', name: 'settings',
        builder: (_, __) => SettingsScreen()),
  ],
);
```

### auto_route

```dart
final navObserver = LoqNavigatorObserver();

@AutoRouterConfig()
class AppRouter extends RootStackRouter {
  @override
  List<AutoRoute> get routes => [...];

  @override
  List<NavigatorObserver> get navigatorObservers => () => [navObserver];
}
```

### go_router with shell routes

Flutter's `NavigatorObserver` asserts that one observer instance is attached to **at most one Navigator at a time**. Passing the same observer to two Navigators throws at attach time. `StatefulShellRoute` gives each branch its own Navigator, so the recipe is **one observer per branch** plus one for the root, then drop all their `screenFieldsProcessor`s into `LogConfig.global.processors`:

```dart
final rootObserver = LoqNavigatorObserver();
final feedObserver = LoqNavigatorObserver();
final profileObserver = LoqNavigatorObserver();

LogConfig.configure(
  processors: [
    rootObserver.screenFieldsProcessor,
    feedObserver.screenFieldsProcessor,
    profileObserver.screenFieldsProcessor,
  ],
  handlers: [JsonHandler()],
);

final router = GoRouter(
  observers: [rootObserver],
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (_, __, shell) => HomeShell(shell: shell),
      branches: [
        StatefulShellBranch(
          observers: [feedObserver],
          routes: [GoRoute(path: '/feed', builder: ...)],
        ),
        StatefulShellBranch(
          observers: [profileObserver],
          routes: [GoRoute(path: '/profile', builder: ...)],
        ),
      ],
    ),
  ],
);
```

Each observer tracks only its own Navigator's stack. The chained processors add `app.screen.name` from whichever observer most recently saw a push. In practice that's whichever branch the user is on. Existing `app.screen.name` values (set by an observer's own emission, or by user code) are not overwritten, so the chain is order-safe.

### Plain Navigator

```dart
MaterialApp(
  navigatorObservers: [navObserver],
  home: HomeScreen(),
);
```

## Console colors from Flutter `Color`s

`loq` core's `ConsoleHandler` takes raw ANSI escapes like `'\x1B[31m'` in its `levelColors:` map. `loq_flutter` adds a thin converter so you can stay in Flutter idioms:

```dart
import 'package:flutter/material.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

LogConfig.configure(handlers: [
  ConsoleHandler(
    useColor: true,
    levelColors: ansiLevelColors({
      Level.warn: Colors.amber,
      Level.error: Colors.deepOrange,
      Level.fatal: Colors.red.shade900,
    }),
  ),
]);
```

`ansiLevelColors(Map<Level, Color>)` emits 24-bit ANSI true-color escapes (`\x1B[38;2;R;G;Bm`). Every modern terminal on macOS, Linux, and Windows 10+ supports them. Alpha is dropped (terminals don't blend). Levels you don't supply fall back to loq's built-in palette (gray / cyan / green / yellow / red / bright-red).

Single-value primitive: `ansiForegroundFromColor(Color)` returns one escape, useful for hand-rolled mixes.

## Pairing with Crashlytics or Sentry

`loq_flutter`'s error wiring uses **chain-and-restore** semantics: at install time it saves the previous `FlutterError.onError` and `PlatformDispatcher.onError`, and on dispose it puts them back. Stacking with other observers works, *if you install them in the right order*.

### Install order

```dart
Future<void> main() async {
  await Firebase.initializeApp();

  // Sentry or Crashlytics first: they set the global error slots.
  await SentryFlutter.init((options) { ... });

  // initLoq LAST. It picks up the existing handlers as "previous"
  // and chains them.
  await initLoq(() { ... });
}
```

If you call `initLoq()` first and then `SentryFlutter.init()`, Sentry's setup will write over our handler without restoring it, and Flutter framework errors stop reaching loq. The order above keeps everything working.

### Dedup story

`loq_flutter`'s bounded LRU dedup applies on the **loq side only**. If you've also wired Crashlytics's recommended `FlutterError.onError = recordFlutterError` (which Crashlytics's setup snippet does), Crashlytics itself gets one report per source. Different problem, different fix: `loq_crashlytics` (Phase 8) will own that path and dedupe through the same queue.

## `initLoq()` options

```dart
initLoq(
  body,
  config: LogConfig(handlers: [JsonHandler()]),
  errorLogger: Logger('app.errors'),
  errorLevel: Level.fatal,
  wireFlutterErrors: true,
  wirePlatformDispatcher: true,
  wireZoneGuard: true,
  installLifecycleObserver: true,
  lifecycleObserver: customLifecycleObserver, // optional
  reportSilentFlutterErrors: false,
  captureSourceLocation: true,  // surfaces LogConfig's flag
  errorFields: (event) => { ... },
  message: (event) => '...',
);
```

Every `wire*` flag opts out of one capture path. The lifecycle observer can be swapped out or skipped. `reportSilentFlutterErrors: false` (the default) drops `FlutterErrorDetails.silent` records: those are framework-handled and not real bugs. `captureSourceLocation: true` turns on loq core's call-site capture for dev builds (it does a `StackTrace.current` per log; turn it off in release).

**Hot reload is safe.** `initLoq` tracks which `LoqErrorState` owns `FlutterError.onError`, `PlatformDispatcher.onError`, and the `debugPrint` slot. A second `initLoq` call (typical on hot reload) disposes the prior owner first, so the handler chain stays flat. No leak per reload, no double emissions.

### Capturing Flutter framework output

Flutter framework code writes to `debugPrint` for "RenderFlex overflowed by N pixels", "Multiple widgets used the same GlobalKey", asset-bundle warnings, and `FlutterError.dumpErrorToConsole` output. `initLoq` can redirect that stream into loq:

```dart
initLoq(
  body,
  redirectFlutterDebugPrint: true,             // opt-in, off by default
  flutterDebugLogger: Logger('app.flutter'),   // optional, defaults to `loq_flutter.debug_print`
  flutterDebugLevel: Level.debug,              // default
);
```

Off by default because debug builds are noisy. The redirection only touches `debugPrint`, not plain `print()`: that means `ConsoleHandler` (which calls `print()` to emit) keeps working without recursion. User-written `print('...')` calls are unaffected. Dispose restores the original `debugPrint`.

## Memory pressure and locale changes

`LoqLifecycleObserver` also forwards two other `WidgetsBindingObserver` callbacks:

- **`didHaveMemoryPressure`**: iOS memory warnings, Android `onTrimMemory`. Emits a `MemoryPressureEvent` at `Level.warn` by default and flushes registered handlers (the OS may kill us next). Override the level via `memoryPressureLevel:`, or turn off the flush via `flushOnMemoryPressure: false`.
- **`didChangeLocales`**: system locale list changed. Emits a `LocaleChangeEvent` at `Level.debug` carrying the new and previous locale lists. Useful for tracking down locale-tied bugs ("user switched from `en` to `es` and we crashed"). Does not flush.

Pattern-match on the sealed event family to handle them differently:

```dart
final lifecycle = LoqLifecycleObserver(
  fields: (event) => switch (event) {
    MemoryPressureEvent() =>
        {...event.defaults, 'severity': 'critical'},
    LocaleChangeEvent(:final locales) =>
        {...event.defaults, 'count': locales?.length ?? 0},
    AppLifecycleStateEvent() => event.defaults,
  },
);
```

## Lifecycle and flushing

```dart
final lifecycle = LoqLifecycleObserver(
  flushHandlers: [crashReportingHandler, networkHandler],
  flushOnPaused: true,    // last-chance flush
  flushOnDetached: true,  // best-effort; iOS may kill before this fires
  flushOnHidden: false,   // Flutter 3.13+ hidden state, off by default
);
```

By default `flushHandlers` reads `LogConfig.global.handlers` **at flush time**, so any reconfigure through `LogConfig.configure` is picked up.

Flush runs on `paused` and `detached` by default, not on `inactive`. `inactive` fires for brief breaks (incoming call, Control Center on iOS, system alerts) where flushing would be wasted work.

## Web

Lifecycle states are emitted on Flutter web but they're unreliable: `paused` / `detached` may not fire before the tab closes. The observer still installs and emits records for events that *do* fire. Pass `enabledOnWeb: false` to skip the registration on web:

```dart
LoqLifecycleObserver(enabledOnWeb: !kIsWeb || debugWebLifecycle);
```

## Testing

Tests can drive `didChangeAppLifecycleState` and the `NavigatorObserver` overrides directly, paired with a capturing `Handler`. See the package's own test suite for patterns. `LoqLifecycleObserver` is safe to construct without a `WidgetsBinding`; just don't call `install()` outside of a test that initializes one.
