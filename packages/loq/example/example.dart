// Demo of loq's capabilities. Run with: `dart run example/example.dart`.

import 'package:loq/loq.dart';

void main() {
  // -- Configure once at startup --
  // The processor chain runs in order; handlers receive the result.
  LogConfig.configure(
    processors: [
      addTimestamp(), // ISO 8601 timestamp field
      redact({'password', 'ssn'}), // mask sensitive fields with ***
    ],
    handlers: [
      ConsoleHandler(minLevel: Level.debug),
    ],
    zoneAccessor: defaultZoneAccessor,
    captureSourceLocation: true, // include call-site in records
  );

  // -- Basic logging --
  final log = Logger('app')..info('service started', fields: {'port': 8080});

  // -- Custom log levels --
  const notice = Level(11); // slots between info(8) and warn(12)
  log.log(notice, 'strange activity');

  // -- Bound loggers --
  final reqLog = log.withFields({'requestId': 'abc-123', 'userId': 42})
    ..info('processing payment', fields: {'amount': 99.95});

  // -- Error logging --
  try {
    throw const FormatException('invalid card number');
  } on FormatException catch (e, st) {
    reqLog.error('payment failed', error: e, stackTrace: st);
  }

  // -- Lazy fields (only evaluated if a handler accepts the record) --
  log.info(
    'stats',
    fields: {
      'expensive': Lazy(_expensiveValue),
    },
  );

  // -- isEnabled guard (for multi-statement work that doesn't fit Lazy) --
  if (log.isEnabled(Level.debug)) {
    final snapshot = _buildDebugSnapshot();
    log.debug('snapshot', fields: snapshot);
  }

  // -- Field groups: namespace related fields --
  log.info(
    'request',
    fields: {
      'http': const FieldGroup({
        'method': 'GET',
        'path': '/api',
        'status': 200,
      }),
    },
  );

  // -- Zone context: fields flow through async boundaries --
  withLogContext({'traceId': 'trace-xyz'}, () {
    Logger('db').info(
      'query executed',
      fields: {'table': 'users', 'rows': 150},
    );
  });

  // -- Redaction (configured above) --
  log.info(
    'user signup',
    fields: {
      'email': 'user@example.com',
      'password': 'hunter2', // → password=***
    },
  );

  // -- Sampling: pass ~1 in N records (for high-volume loggers) --
  final hot = Logger(
    'hot',
    config: LogConfig(
      processors: [sample(3)],
      handlers: [ConsoleHandler()],
    ),
  );
  for (var i = 0; i < 6; i++) {
    hot.info('hit', fields: {'i': i}); // ~2 of 6 reach the console
  }

  // -- Conditional processor: apply X only when a predicate matches --
  // Use LogConfig.global.copyWith() to inherit captureSourceLocation
  // (and any other global settings) — only override what we need.
  Logger(
    'selective',
    config: LogConfig.global.copyWith(
      processors: [
        // Add the `source` field only when the record is marked critical.
        when((r) => r.fields['critical'] == true, addSource()),
      ],
    ),
  )
    ..info('routine')
    ..info('big deal', fields: {'critical': true});

  // -- Standalone JSON output for production pipelines --
  Logger('api', config: LogConfig(handlers: [JsonHandler()]))
      .info('request completed', fields: {'path': '/users', 'status': 200});

  // -- MultiHandler: same record to multiple sinks --
  Logger(
    'dual',
    config: LogConfig(
      handlers: [
        MultiHandler([
          ConsoleHandler(),
          JsonHandler(minLevel: Level.warn),
        ]),
      ],
    ),
  ).warn('dual output', fields: {'count': 1});
}

int _expensiveValue() => List.generate(1000, (i) => i).length;

Map<String, Object?> _buildDebugSnapshot() => {'cpu': 0.42, 'mem_mb': 256};
