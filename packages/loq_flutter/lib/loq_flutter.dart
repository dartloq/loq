/// Flutter integration for loq structured logging.
///
/// Three pieces:
///
/// - [LoqNavigatorObserver]: a `NavigatorObserver` that logs route
///   changes and tracks the current screen. Exposes
///   `screenFieldsProcessor` to add `app.screen.name` (OTel
///   Development) and `loq.app.screen.previous_name` to every record.
/// - [LoqLifecycleObserver]: a `WidgetsBindingObserver` wrapper that
///   logs lifecycle events and flushes registered handlers on
///   `paused` / `detached`.
/// - [initLoq]: a one-call entry point that wraps `runApp` in
///   `runZonedGuarded` and chains `FlutterError.onError` and
///   `PlatformDispatcher.instance.onError` with save-and-restore
///   semantics.
///
/// ```dart
/// import 'package:flutter/widgets.dart';
/// import 'package:loq/loq.dart';
/// import 'package:loq_flutter/loq_flutter.dart';
///
/// final navObserver = LoqNavigatorObserver();
///
/// void main() => initLoq(() {
///   WidgetsFlutterBinding.ensureInitialized();
///   LogConfig.configure(
///     processors: [navObserver.screenFieldsProcessor],
///     handlers: [JsonHandler()],
///   );
///   runApp(MyApp(navObserver: navObserver));
/// });
/// ```
library;

// Imports consumed by dartdoc so [LoqNavigatorObserver] etc. resolve in
// the library docstring above.
import 'package:loq_flutter/src/init_loq.dart';
import 'package:loq_flutter/src/loq_lifecycle_observer.dart';
import 'package:loq_flutter/src/loq_navigator_observer.dart';

export 'src/ansi_colors.dart';
export 'src/default_fields.dart';
export 'src/error_event.dart';
export 'src/init_loq.dart' show initLoq;
export 'src/lifecycle_event.dart';
export 'src/loq_lifecycle_observer.dart';
export 'src/loq_navigator_observer.dart';
export 'src/navigation_event.dart';
