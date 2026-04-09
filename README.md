# loq

Structured logging for Dart. Pipeline architecture, OTel-ready, works everywhere.

## Packages

| Package | pub.dev | Description |
|---------|---------|-------------|
| [loq](packages/loq/) | [![pub](https://img.shields.io/pub/v/loq.svg)](https://pub.dev/packages/loq) | Core structured logging |
| loq_otel | *coming soon* | OpenTelemetry log bridge |
| loq_flutter | *coming soon* | Flutter lifecycle & navigation context |
| loq_crashlytics | *coming soon* | Firebase Crashlytics adapter |
| loq_sentry | *coming soon* | Sentry adapter |

## Quick example

```dart
import 'package:loq/loq.dart';

final log = Logger('payments');
log.info('processed', fields: {'orderId': 'abc-123', 'amount': 99.95});

// Bound loggers carry context
final reqLog = log.withFields({'requestId': 'req-456'});
reqLog.info('charging card');  // includes requestId

// Zone context flows through async code
withLogContext({'traceId': 'xyz'}, () async {
  log.info('inside trace');  // includes traceId automatically
});
```

## Contributing

```bash
# Clone and setup
git clone https://github.com/fatalaa/loq.git
cd loq
dart pub get
melos bootstrap

# Run checks
melos run analyze
melos run test
```

## License

MIT. See [LICENSE](LICENSE).
