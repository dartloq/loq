import 'package:loq/loq.dart';

void main() {
  // -- Configure once at startup --
  LogConfig.configure(
    processors: [
      redact({'password', 'ssn'}),
    ],
    handlers: [
      ConsoleHandler(minLevel: Level.debug),
    ],
    zoneAccessor: defaultZoneAccessor,
    captureSourceLocation: true,
  );

  // -- Custom log levels --
  const notice = Level(11);
  final log = Logger('app')
    ..log(notice, 'strange activity')

    // -- Basic logging --
    ..info('service started', fields: {'port': 8080});

  // -- Bound loggers --
  final reqLog = log.withFields({'requestId': 'abc-123', 'userId': 42})
    ..info('processing payment', fields: {'amount': 99.95});

  // -- Error logging --
  try {
    throw const FormatException('invalid card number');
  } on FormatException catch (e, st) {
    reqLog.error('payment failed', error: e, stackTrace: st);
  }

  // -- Lazy fields --
  log
    ..info(
      'stats',
      fields: {
        'expensive': Lazy(() => List.generate(1000, (i) => i).length),
      },
    )

    // -- Field groups --
    ..info(
      'request',
      fields: {
        'http': const FieldGroup({
          'method': 'GET',
          'path': '/api',
          'status': 200,
        }),
      },
    );

  // -- Zone context --
  withLogContext({'traceId': 'trace-xyz'}, () {
    Logger('db')
        .info('query executed', fields: {'table': 'users', 'rows': 150});
  });

  // -- Redaction --
  log.info(
    'user signup',
    fields: {
      'email': 'user@example.com',
      'password': 'hunter2', // replaced with ***
    },
  );

  // -- MultiHandler --
  final multi = MultiHandler([
    ConsoleHandler(),
    JsonHandler(minLevel: Level.warn),
  ]);
  Logger('multi', config: LogConfig(handlers: [multi]))
      .warn('dual output', fields: {'count': 1});
}
