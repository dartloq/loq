# loq

[![CI](https://github.com/dartloq/loq/actions/workflows/ci.yml/badge.svg)](https://github.com/dartloq/loq/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/dartloq/loq/graph/badge.svg?token=7WTPMV87PF)](https://codecov.io/gh/dartloq/loq)
[![pub](https://img.shields.io/pub/v/loq.svg)](https://pub.dev/packages/loq)
[![license](https://img.shields.io/github/license/dartloq/loq.svg)](LICENSE)

Structured logging for Dart. Pipeline architecture, OTel-ready, works everywhere.

## Packages

Click a package name for its full README — API reference, configuration examples, and integration recipes.

| Package | pub.dev | Coverage | Description |
|---------|---------|----------|-------------|
| [loq](packages/loq/README.md) | [![pub](https://img.shields.io/pub/v/loq.svg)](https://pub.dev/packages/loq) | [![codecov](https://codecov.io/gh/dartloq/loq/graph/badge.svg?token=7WTPMV87PF&flags[0]=loq)](https://codecov.io/gh/dartloq/loq?flags[0]=loq) | Core structured logging |
| [loq_shelf](packages/loq_shelf/README.md) | [![pub](https://img.shields.io/pub/v/loq_shelf.svg)](https://pub.dev/packages/loq_shelf) | [![codecov](https://codecov.io/gh/dartloq/loq/graph/badge.svg?token=7WTPMV87PF&flags[0]=loq_shelf)](https://codecov.io/gh/dartloq/loq?flags[0]=loq_shelf) | Shelf / Dart Frog / Jaspr middleware |
| [loq_drift](packages/loq_drift/README.md) | [![pub](https://img.shields.io/pub/v/loq_drift.svg)](https://pub.dev/packages/loq_drift) | [![codecov](https://codecov.io/gh/dartloq/loq/graph/badge.svg?token=7WTPMV87PF&flags[0]=loq_drift)](https://codecov.io/gh/dartloq/loq?flags[0]=loq_drift) | Drift query logging interceptor |
| loq_otel | *coming soon* | — | OpenTelemetry log bridge |
| loq_flutter | *coming soon* | — | Flutter lifecycle & navigation context |
| loq_crashlytics | *coming soon* | — | Firebase Crashlytics adapter |
| loq_serverpod | *coming soon* | — | Serverpod integration |
| loq_sentry | *coming soon* | — | Sentry adapter |

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
git clone https://github.com/dartloq/loq.git
cd loq
dart pub get
melos bootstrap

# Run checks
melos run analyze
melos run test
```

## License

MIT. See [LICENSE](LICENSE).
