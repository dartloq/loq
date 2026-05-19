import 'dart:async';
import 'dart:io';

import 'package:loq/loq.dart';
import 'package:loq/testing.dart';
import 'package:loq_shelf/loq_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  late RecordingHandler recorder;
  late Logger logger;

  setUp(() {
    final s = setUpRecorder();
    recorder = s.recorder;
    logger = s.logger;
  });

  // ---------------------------------------------------------------------------
  // fields hook
  // ---------------------------------------------------------------------------

  group('fields hook', () {
    test('uniform replacement applies to start and response logs', () async {
      final middleware = loqMiddleware(
        logger: logger,
        fields: (event) => {
          'method': event.request.method,
          'path': event.request.requestedUri.path,
          'host': event.request.headers['host'] ?? 'unknown',
        },
      );
      final handler = middleware(okHandler);

      await handler(
        request('GET', '/api', headers: {'host': 'example.com'}),
      );

      final start = recorder.records.first;
      expect(start.fields['host'], 'example.com');
      // OTel defaults are dropped when the user returns their own map.
      expect(start.fields.containsKey('requestId'), isFalse);
      expect(start.fields.containsKey('http.request.method'), isFalse);
      expect(start.fields.containsKey('url.scheme'), isFalse);
    });

    test('compose with defaults via spread', () async {
      final middleware = loqMiddleware(
        logger: logger,
        fields: (event) => {...event.defaults, 'tenant_id': 'acme'},
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      final start = recorder.records.first;
      expect(start.fields['tenant_id'], 'acme');
      expect(start.fields['http.request.method'], 'GET');
      expect(start.fields['url.path'], '/api');
      expect(start.fields.containsKey('requestId'), isTrue);
    });

    test('filter individual defaults', () async {
      final middleware = loqMiddleware(
        logger: logger,
        fields: (event) =>
            Map.of(event.defaults)..remove('user_agent.original'),
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api', headers: {'user-agent': 'curl'}));

      final start = recorder.records.first;
      expect(start.fields.containsKey('user_agent.original'), isFalse);
      expect(start.fields['http.request.method'], 'GET');
    });

    test('per-event shaping via pattern matching', () async {
      final middleware = loqMiddleware(
        logger: logger,
        fields: (event) => switch (event) {
          ShelfResponseEvent(:final response) => {
              ...event.defaults,
              'contentLength': response.headers['content-length'],
            },
          _ => event.defaults,
        },
      );
      final handler = middleware(
        (_) => Future.value(
          Response.ok('hello', headers: {'content-length': '5'}),
        ),
      );

      await handler(request('GET', '/data'));

      final complete = recorder.records.last;
      expect(complete.fields['contentLength'], '5');
      // Start log is untouched.
      final start = recorder.records.first;
      expect(start.fields.containsKey('contentLength'), isFalse);
    });

    test('requestIdResolver callback always runs as part of defaults',
        () async {
      var requestIdCalled = false;
      final middleware = loqMiddleware(
        logger: logger,
        requestIdResolver: (_) {
          requestIdCalled = true;
          return 'precomputed';
        },
        fields: (event) => {'method': event.request.method},
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/test'));

      expect(requestIdCalled, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // log control
  // ---------------------------------------------------------------------------

  group('log control', () {
    test('logStart: false suppresses start log', () async {
      final middleware = loqMiddleware(
        logger: logger,
        logStart: false,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/quiet'));

      expect(recorder.records, hasLength(1));
      expect(recorder.records.single.message, 'request completed');
    });

    test('default response level: 2xx at info', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/ok'));

      expect(recorder.records.last.level, Level.info);
    });

    test('default response level: 4xx at warn', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler =
          middleware((_) => Future.value(Response.notFound('nope')));

      await handler(request('GET', '/missing'));

      expect(recorder.records.last.level, Level.warn);
    });

    test('default response level: 5xx at error', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(
        (_) => Future.value(Response.internalServerError()),
      );

      await handler(request('GET', '/broken'));

      expect(recorder.records.last.level, Level.error);
    });
  });

  // ---------------------------------------------------------------------------
  // routeResolver
  // ---------------------------------------------------------------------------

  group('routeResolver', () {
    test('populates http.route when non-null', () async {
      final middleware = loqMiddleware(
        logger: logger,
        routeResolver: (req) => '/users/{id}',
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/users/42'));

      expect(recorder.records.first.fields['http.route'], '/users/{id}');
    });

    test('omits http.route when resolver returns null', () async {
      final middleware = loqMiddleware(
        logger: logger,
        routeResolver: (_) => null,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/raw'));

      expect(
        recorder.records.first.fields.containsKey('http.route'),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // clientIpResolver
  // ---------------------------------------------------------------------------

  group('clientIpResolver', () {
    test('populates client.address from custom resolver', () async {
      final middleware = loqMiddleware(
        logger: logger,
        clientIpResolver: (req) => req.headers['x-forwarded-for'],
      );
      final handler = middleware(okHandler);

      await handler(
        request('GET', '/api', headers: {'x-forwarded-for': '10.0.0.5'}),
      );

      expect(recorder.records.first.fields['client.address'], '10.0.0.5');
    });

    test('default extractor reads shelf_io connection info', () async {
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      final req = Request(
        'GET',
        Uri.parse('http://localhost/api'),
        context: {
          'shelf.io.connection_info':
              FakeConnectionInfo(InternetAddress('192.168.1.10')),
        },
      );

      await handler(req);

      expect(
        recorder.records.first.fields['client.address'],
        '192.168.1.10',
      );
    });

    test(
        'omits client.address when resolver returns null and no '
        'connection info', () async {
      final middleware = loqMiddleware(
        logger: logger,
        clientIpResolver: (_) => null,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      expect(
        recorder.records.first.fields.containsKey('client.address'),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // levelResolver
  // ---------------------------------------------------------------------------

  group('levelResolver', () {
    test('overrides completion level when non-null', () async {
      final middleware = loqMiddleware(
        logger: logger,
        levelResolver: (event, error) => Level.debug,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      expect(recorder.records.last.level, Level.debug);
    });

    test('overrides error level when non-null', () async {
      final middleware = loqMiddleware(
        logger: logger,
        levelResolver: (event, error) => error != null ? Level.warn : null,
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.level, Level.warn);
    });

    test('null return falls back to default behavior', () async {
      final middleware = loqMiddleware(
        logger: logger,
        levelResolver: (event, error) => null,
      );
      final handler =
          middleware((_) => Future.value(Response.internalServerError()));

      await handler(request('GET', '/broken'));

      expect(recorder.records.last.level, Level.error);
    });

    test('slow bump still applies after levelResolver returns info', () async {
      final middleware = loqMiddleware(
        logger: logger,
        levelResolver: (event, error) => Level.info,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(request('GET', '/slow'));

      expect(recorder.records.last.level, Level.warn);
      expect(recorder.records.last.fields['slow'], isTrue);
    });

    test('receives the typed event for branching', () async {
      ShelfLogEvent? capturedStart;
      ShelfLogEvent? capturedResponse;
      ShelfLogEvent? capturedError;

      Level? track(ShelfLogEvent event, Object? error) {
        if (event is ShelfRequestStartEvent) capturedStart = event;
        if (event is ShelfResponseEvent) capturedResponse = event;
        if (event is ShelfRequestErrorEvent) capturedError = event;
        return null;
      }

      // Success path.
      var middleware = loqMiddleware(
        logger: logger,
        levelResolver: track,
      );
      var handler = middleware(okHandler);
      await handler(request('GET', '/ok'));

      // Error path.
      middleware = loqMiddleware(
        logger: logger,
        levelResolver: track,
      );
      handler = middleware((_) => throw Exception('boom'));
      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      expect(capturedStart, isA<ShelfRequestStartEvent>());
      expect(capturedResponse, isA<ShelfResponseEvent>());
      expect(capturedError, isA<ShelfRequestErrorEvent>());
    });
  });

  // ---------------------------------------------------------------------------
  // errorFields hook
  // ---------------------------------------------------------------------------

  group('errorFields hook', () {
    test('can add fields on top of defaults', () async {
      final middleware = loqMiddleware(
        logger: logger,
        errorFields: (event, error, stack) => {
          ...event.defaults,
          'error.retryable': false,
        },
      );
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.fields['error.retryable'], isFalse);
      expect(errorRecord.fields['error.type'], 'FormatException');
      expect(errorRecord.fields['duration_ms'], isA<int>());
    });

    test('event.defaults carries request fields', () async {
      Map<String, Object?>? capturedDefaults;
      final middleware = loqMiddleware(
        logger: logger,
        errorFields: (event, error, stack) {
          capturedDefaults = event.defaults;
          return event.defaults;
        },
      );
      final handler = middleware((_) => throw const FormatException('boom'));

      await expectLater(
        () => handler(request('GET', '/users/42')),
        throwsA(isA<FormatException>()),
      );

      // 0.2.0: the error event's defaults include the request fields,
      // so the user sees the full picture without needing to re-add them.
      expect(capturedDefaults, isNotNull);
      expect(capturedDefaults!['http.request.method'], 'GET');
      expect(capturedDefaults!['url.path'], '/users/42');
      expect(capturedDefaults!.containsKey('requestId'), isTrue);
      expect(capturedDefaults!['error.type'], 'FormatException');
      expect(capturedDefaults!['duration_ms'], isA<int>());
    });

    test('can replace defaults entirely', () async {
      final middleware = loqMiddleware(
        logger: logger,
        errorFields: (event, error, stack) => {'minimal': true},
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord = recorder.messageContaining('request failed').single;
      expect(errorRecord.fields['minimal'], isTrue);
      // User opted out of the error-specific defaults.
      expect(errorRecord.fields.containsKey('error.type'), isFalse);
      expect(errorRecord.fields.containsKey('duration_ms'), isFalse);
    });

    test('receives error and stack trace', () async {
      Object? capturedError;
      StackTrace? capturedStack;
      final middleware = loqMiddleware(
        logger: logger,
        errorFields: (event, error, stack) {
          capturedError = error;
          capturedStack = stack;
          return event.defaults;
        },
      );
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      expect(capturedError, isA<FormatException>());
      expect(capturedStack, isNotNull);
    });

    test('slow flag is included in defaults when threshold exceeded', () async {
      Map<String, Object?>? capturedDefaults;
      final middleware = loqMiddleware(
        logger: logger,
        slowRequestThreshold: Duration.zero,
        errorFields: (event, error, stack) {
          capturedDefaults = event.defaults;
          return event.defaults;
        },
      );
      final handler = middleware((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw Exception('slow boom');
      });

      await expectLater(
        () => handler(request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      expect(capturedDefaults!['slow'], isTrue);
    });
  });
}
