/// Structured logging for Dart.
///
/// Loq provides a pipeline-based logging architecture with pluggable handlers,
/// structured key-value fields, context propagation via Zones, and
/// OpenTelemetry-ready design.
///
/// ```dart
/// import 'package:loq/loq.dart';
///
/// final log = Logger('my_service');
/// log.info('request handled', fields: {'path': '/api', 'status': 200});
/// ```
///
/// See the [README](https://pub.dev/packages/loq) for full documentation.
library;

export 'src/buffered_handler.dart';
export 'src/console_handler.dart';
export 'src/field_group.dart';
export 'src/handler.dart';
export 'src/isolate_handler.dart';
export 'src/json_handler.dart';
export 'src/lazy.dart';
export 'src/level.dart';
export 'src/log_config.dart';
export 'src/logger.dart';
export 'src/multi_handler.dart';
export 'src/processors.dart';
export 'src/record.dart';
export 'src/source_location.dart';
export 'src/zone_context.dart';
