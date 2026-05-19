import 'dart:async';

import 'package:loq/loq.dart';
import 'package:loq/testing.dart';
import 'package:loq_shelf/loq_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late RecordingHandler recorder;
  late LogConfig config;
  late Logger logger;

  setUp(() {
    final s = setUpRecorder();
    recorder = s.recorder;
    config = s.config;
    logger = s.logger;
  });

  // ---------------------------------------------------------------------------
  // Core behavior
  // ---------------------------------------------------------------------------

  group('core behavior', () {
    test('logs request start and completion with fields', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/api/users'));

      expect(recorder.records, hasLength(2));

      final start = recorder.records.first;
      expect(start.message, 'request started');
      expect(start.fields['http.request.method'], 'GET');
      expect(start.fields['url.path'], '/api/users');
      expect(start.fields.containsKey('requestId'), isTrue);

      final complete = recorder.records.last;
      expect(complete.message, 'request completed');
      expect(complete.fields['http.response.status_code'], 200);
      expect(complete.fields['duration_ms'], isA<int>());
    });

    test('zone context propagates to inner handler', () async {
      final middleware = loqMiddleware(logger: logger);

      final handler = middleware((_) {
        Logger('inner', config: config).info('inside handler');
        return Response.ok('ok');
      });

      await handler(request('POST', '/submit'));

      final innerRecord = recorder.messageContaining('inside handler').single;
      expect(innerRecord.fields['http.request.method'], 'POST');
      expect(innerRecord.fields['url.path'], '/submit');
    });

    test('logs errors at error level', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.level, Level.error);
      expect(errorRecord.fields['error'], isA<Exception>());
      expect(errorRecord.fields['duration_ms'], isA<int>());
    });

    test('error log inherits request defaults', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(request('GET', '/users/42')),
        throwsA(isA<Exception>()),
      );

      // 0.2.0: ShelfRequestErrorEvent.defaults carries the request
      // fields so users see the full picture inside errorFields hooks.
      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.fields['http.request.method'], 'GET');
      expect(errorRecord.fields['url.path'], '/users/42');
      expect(errorRecord.fields.containsKey('requestId'), isTrue);
    });

    test('HijackException passes through without logging', () async {
      final middleware = loqMiddleware(
        logger: logger,
        logStart: false,
      );
      final handler = middleware((_) => throw const HijackException());

      await expectLater(
        () => handler(request('GET', '/ws')),
        throwsA(isA<HijackException>()),
      );

      expect(recorder.messageContaining('request failed'), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Request ID
  // ---------------------------------------------------------------------------

  group('request ID', () {
    test('extracts X-Request-Id header', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(
        request('GET', '/api', headers: {'x-request-id': 'abc-123'}),
      );

      expect(recorder.records.first.fields['requestId'], 'abc-123');
    });

    test('falls back to incrementing counter', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/a'));
      await handler(request('GET', '/b'));

      final ids = recorder
          .messageContaining('request started')
          .map((r) => r.fields['requestId'])
          .toList();
      expect(ids, ['1', '2']);
    });

    test('custom requestIdResolver', () async {
      final middleware = loqMiddleware(
        logger: logger,
        requestIdResolver: (req) => 'custom-${req.method}',
      );
      final handler = middleware(okHandler);

      await handler(request('PUT', '/update'));

      expect(recorder.records.first.fields['requestId'], 'custom-PUT');
    });
  });

  // ---------------------------------------------------------------------------
  // Integration
  // ---------------------------------------------------------------------------

  group('integration', () {
    test('custom logger receives all records', () async {
      final customLog = Logger('custom', config: config);
      final middleware = loqMiddleware(logger: customLog);
      final handler = middleware(okHandler);

      await handler(request('GET', '/test'));

      for (final record in recorder.records) {
        expect(record.loggerName, 'custom');
      }
    });

    test('defaults to Logger("http") when no logger provided', () async {
      LogConfig.configure(
        handlers: [recorder],
        zoneAccessor: defaultZoneAccessor,
      );
      addTearDown(LogConfig.reset);

      final middleware = loqMiddleware();
      final handler = middleware(okHandler);

      await handler(request('GET', '/default'));

      expect(recorder.from('http'), hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Skip
  // ---------------------------------------------------------------------------

  group('skip', () {
    test('bypasses middleware when predicate returns true', () async {
      final middleware = loqMiddleware(
        logger: logger,
        skip: (req) => req.requestedUri.path == '/healthz',
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/healthz'));

      expect(recorder.records, isEmpty);
    });

    test('still logs when predicate returns false', () async {
      final middleware = loqMiddleware(
        logger: logger,
        skip: (req) => req.requestedUri.path == '/healthz',
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api/users'));

      expect(recorder.records, hasLength(2));
    });

    test('skipped requests do not bind zone context', () async {
      final middleware = loqMiddleware(
        logger: logger,
        skip: (_) => true,
      );
      final handler = middleware((_) {
        Logger('inner', config: config).info('inside');
        return Response.ok('ok');
      });

      await handler(request('GET', '/skipped'));

      final inner = recorder.messageContaining('inside').single;
      expect(inner.fields.containsKey('http.request.method'), isFalse);
      expect(inner.fields.containsKey('url.path'), isFalse);
      expect(inner.fields.containsKey('requestId'), isFalse);
    });

    test('errors in skipped requests propagate without logging', () async {
      final middleware = loqMiddleware(
        logger: logger,
        skip: (_) => true,
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(request('GET', '/skipped')),
        throwsA(isA<Exception>()),
      );

      expect(recorder.records, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Slow request threshold
  // ---------------------------------------------------------------------------

  group('slowRequestThreshold', () {
    test('adds slow:true and bumps info to warn when exceeded', () async {
      final middleware = loqMiddleware(
        logger: logger,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(request('GET', '/slow'));

      final complete = recorder.records.last;
      expect(complete.fields['slow'], isTrue);
      expect(complete.level, Level.warn);
    });

    test('does not bump error level downward', () async {
      final middleware = loqMiddleware(
        logger: logger,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          Response.internalServerError,
        ),
      );

      await handler(request('GET', '/slow-and-broken'));

      final complete = recorder.records.last;
      expect(complete.level, Level.error);
      expect(complete.fields['slow'], isTrue);
    });

    test('no slow field or level change when under threshold', () async {
      final middleware = loqMiddleware(
        logger: logger,
        slowRequestThreshold: const Duration(seconds: 10),
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/fast'));

      final complete = recorder.records.last;
      expect(complete.fields.containsKey('slow'), isFalse);
      expect(complete.level, Level.info);
    });

    test('adds slow field to error log when error path is slow', () async {
      final middleware = loqMiddleware(
        logger: logger,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw Exception('slow boom');
      });

      await expectLater(
        () => handler(request('GET', '/slow-fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.fields['slow'], isTrue);
      expect(errorRecord.level, Level.error);
    });

    test('no slow field when threshold is null (default)', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(request('GET', '/no-threshold'));

      final complete = recorder.records.last;
      expect(complete.fields.containsKey('slow'), isFalse);
    });

    test('levelResolver explicit error blocks slow bump from downgrading',
        () async {
      final middleware = loqMiddleware(
        logger: logger,
        levelResolver: (event, error) => Level.error,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(request('GET', '/slow'));

      final complete = recorder.records.last;
      expect(complete.level, Level.error);
      expect(complete.fields['slow'], isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Message overrides
  // ---------------------------------------------------------------------------

  group('message overrides', () {
    test('startMessage replaces the default start text', () async {
      final middleware = loqMiddleware(
        logger: logger,
        startMessage: 'http.request.start',
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      expect(recorder.records.first.message, 'http.request.start');
    });

    test('completeMessage replaces the default completion text', () async {
      final middleware = loqMiddleware(
        logger: logger,
        completeMessage: 'http.request.end',
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      expect(recorder.records.last.message, 'http.request.end');
    });

    test('errorMessage replaces the default error text', () async {
      final middleware = loqMiddleware(
        logger: logger,
        errorMessage: 'http.request.error',
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord =
          recorder.messageContaining('http.request.error').single;
      expect(errorRecord.level, Level.error);
    });
  });

  // ---------------------------------------------------------------------------
  // OTel default fields
  // ---------------------------------------------------------------------------

  group('OTel default fields', () {
    test('emits url.scheme, server.address, network.protocol.version',
        () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      final start = recorder.records.first;
      expect(start.fields['url.scheme'], 'http');
      expect(start.fields['server.address'], 'localhost');
      expect(start.fields['network.protocol.version'], '1.1');
    });

    test('emits user_agent.original when User-Agent header is present',
        () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(recorder.records.first.fields['user_agent.original'], 'curl');
    });

    test('omits user_agent.original when header absent', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      expect(
        recorder.records.first.fields.containsKey('user_agent.original'),
        isFalse,
      );
    });

    test('emits http.response.body.size and content-type on completion',
        () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(
        (_) => Future.value(
          Response.ok(
            'hello',
            headers: {
              'content-length': '5',
              'content-type': 'text/plain',
            },
          ),
        ),
      );

      await handler(request('GET', '/api'));

      final complete = recorder.records.last;
      expect(complete.fields['http.response.body.size'], 5);
      expect(
        complete.fields['http.response.header.content-type'],
        'text/plain',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // error.type / error.message
  // ---------------------------------------------------------------------------

  group('error.type and error.message', () {
    test('emits error.type as the runtime type name', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.fields['error.type'], 'FormatException');
    });

    test('emits error.message as the error toString', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.fields['error.message'], 'FormatException: bad');
    });
  });

  // ---------------------------------------------------------------------------
  // Concurrency
  // ---------------------------------------------------------------------------

  group('concurrency', () {
    test('concurrent requests get unique request IDs', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 10),
          () => Response.ok('ok'),
        ),
      );

      Future<Response> send(int i) async => handler(request('GET', '/c/$i'));
      await Future.wait([for (var i = 0; i < 20; i++) send(i)]);

      expect(recorder.records, hasLength(40));

      final ids = recorder
          .messageContaining('request started')
          .map((r) => r.fields['requestId'])
          .toList();
      expect(ids.toSet(), hasLength(20));
    });

    test('zone context does not leak between concurrent requests', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware((_) {
        Logger('inner', config: config).info('handling');
        return Future<Response>.delayed(
          const Duration(milliseconds: 10),
          () => Response.ok('ok'),
        );
      });

      Future<Response> send(Request req) async => handler(req);
      await Future.wait([
        send(request('GET', '/alpha')),
        send(request('POST', '/beta')),
        send(request('PUT', '/gamma')),
      ]);

      final innerRecords = recorder.messageContaining('handling').toList();
      expect(innerRecords, hasLength(3));

      final pairs = innerRecords
          .map(
            (r) => '${r.fields['http.request.method']} ${r.fields['url.path']}',
          )
          .toSet();
      expect(
        pairs,
        containsAll(['GET /alpha', 'POST /beta', 'PUT /gamma']),
      );
    });
  });
}
