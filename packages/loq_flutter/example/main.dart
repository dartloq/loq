// Minimal Flutter app demonstrating loq_flutter's three pieces:
//
//   LoqNavigatorObserver   tracks the current screen and adds
//                          app.screen.name to every log app-wide
//   LoqLifecycleObserver   flushes handlers on paused / detached
//   initLoq()              wires FlutterError.onError,
//                            PlatformDispatcher.onError, and
//                            runZonedGuarded with chain-and-restore
//
// Run with: `flutter run example/main.dart`

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:loq/loq.dart';
import 'package:loq_flutter/loq_flutter.dart';

final navObserver = LoqNavigatorObserver();
final log = Logger('demo');

Future<void> main() async {
  await initLoq(() {
    WidgetsFlutterBinding.ensureInitialized();
    LogConfig.configure(
      processors: [
        navObserver.screenFieldsProcessor,
        addTimestamp(),
        addLevel(),
      ],
      handlers: [ConsoleHandler()],
    );
    runApp(const DemoApp());
  });
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'loq_flutter demo',
      navigatorObservers: [navObserver],
      home: const HomeScreen(),
      routes: {
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                // Every log here picks up `app.screen.name: /` from
                // navObserver.screenFieldsProcessor.
                log.info('button pressed', fields: {'button': 'go_settings'});
                unawaited(Navigator.of(context).pushNamed('/settings'));
              },
              child: const Text('Go to settings'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                // Uncaught errors flow through initLoq's zone-guard
                // and emit one Level.fatal record.
                throw StateError('demo error from home');
              },
              child: const Text('Throw uncaught'),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            // app.screen.name here is `/settings`.
            log.warn('settings touched');
            Navigator.of(context).pop();
          },
          child: const Text('Log and pop'),
        ),
      ),
    );
  }
}
