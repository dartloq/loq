import 'dart:async';

import 'package:loq/src/log_config.dart';

final _loqContextKey = Object();

/// Run [body] with ambient log fields that flow through async calls.
///
/// ```dart
/// withLogContext({'requestId': id}, () async {
///   log.info('start');   // includes requestId
///   await doWork();
///   log.info('done');    // still includes requestId
/// });
/// ```
R withLogContext<R>(Map<String, Object?> fields, R Function() body) {
  final current = Zone.current[_loqContextKey] as Map<String, Object?>?;
  return runZoned(
    body,
    zoneValues: {
      _loqContextKey: {...?current, ...fields},
    },
  );
}

/// Default [LogConfig.zoneAccessor] that reads from [withLogContext].
Map<String, Object?>? defaultZoneAccessor(Zone zone) =>
    zone[_loqContextKey] as Map<String, Object?>?;
