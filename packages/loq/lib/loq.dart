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

export 'src/loq_base.dart';
