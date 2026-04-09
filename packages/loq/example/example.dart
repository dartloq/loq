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
  );

  // -- Basic logging --
  final log = Logger('app')..info('service started', fields: {'port': 8080});

  // -- Bound loggers --
  final reqLog = log.withFields({'requestId': 'abc-123', 'userId': 42})
    ..info('processing payment', fields: {'amount': 99.95});

  // -- Error logging --
  try {
    throw const FormatException('invalid card number');
  } on FormatException catch (e, st) {
    reqLog.error('payment failed', error: e, stackTrace: st);
  }

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
}
