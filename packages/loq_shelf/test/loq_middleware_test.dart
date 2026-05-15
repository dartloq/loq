import 'dart:async';
import 'dart:io';

import 'package:loq/loq.dart' as loq;
import 'package:loq_shelf/loq_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// A stand-in for the [HttpConnectionInfo] that `shelf_io` injects.
class _FakeConnectionInfo implements HttpConnectionInfo {
  _FakeConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 0;

  @override
  int get localPort => 0;
}

/// A log handler that captures records for testing.
class TestLogHandler implements loq.Handler {
  final List<loq.Record> records = [];

  @override
  bool isEnabled(loq.Level level) => true;

  @override
  void handle(loq.Record record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}

/// Creates a Shelf [Request] for testing.
Request _request(
  String method,
  String path, {
  Map<String, String>? headers,
}) =>
    Request(method, Uri.parse('http://localhost$path'), headers: headers);

void main() {
  late TestLogHandler logHandler;
  late loq.LogConfig config;

  setUp(() {
    logHandler = TestLogHandler();
    config = loq.LogConfig(
      handlers: [logHandler],
      zoneAccessor: loq.defaultZoneAccessor,
    );
  });

  // ---------------------------------------------------------------------------
  // Core behavior
  // ---------------------------------------------------------------------------

  group('core behavior', () {
    test('logs request start and completion with fields', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api/users'));

      expect(logHandler.records, hasLength(2));

      final start = logHandler.records.first;
      expect(start.message, 'request started');
      expect(start.fields['http.request.method'], 'GET');
      expect(start.fields['url.path'], '/api/users');
      expect(start.fields.containsKey('requestId'), isTrue);

      final complete = logHandler.records.last;
      expect(complete.message, 'request completed');
      expect(complete.fields['http.response.status_code'], 200);
      expect(complete.fields['duration_ms'], isA<int>());
    });

    test('zone context propagates to inner handler', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));

      final handler = middleware((request) {
        // Log from inside the handler — should inherit zone context.
        loq.Logger('inner', config: config).info('inside handler');
        return Future.value(Response.ok('ok'));
      });

      await handler(_request('POST', '/submit'));

      final innerRecord =
          logHandler.records.firstWhere((r) => r.message == 'inside handler');
      expect(innerRecord.fields['http.request.method'], 'POST');
      expect(innerRecord.fields['url.path'], '/submit');
    });

    test('logs errors at error level', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.level, loq.Level.error);
      expect(errorRecord.fields['error'], isA<Exception>());
      expect(errorRecord.fields['duration_ms'], isA<int>());
    });

    test('HijackException passes through without logging', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        logStart: false,
      );
      final handler = middleware((_) => throw const HijackException());

      await expectLater(
        () => handler(_request('GET', '/ws')),
        throwsA(isA<HijackException>()),
      );

      // Only the start log (suppressed) — no error log for HijackException.
      expect(
        logHandler.records.where((r) => r.message == 'request failed'),
        isEmpty,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Request ID
  // ---------------------------------------------------------------------------

  group('request ID', () {
    test('extracts X-Request-Id header', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request('GET', '/api', headers: {'x-request-id': 'abc-123'}),
      );

      expect(logHandler.records.first.fields['requestId'], 'abc-123');
    });

    test('falls back to incrementing counter', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/a'));
      await handler(_request('GET', '/b'));

      final ids = logHandler.records
          .where((r) => r.message == 'request started')
          .map((r) => r.fields['requestId'])
          .toList();
      expect(ids, ['1', '2']);
    });

    test('custom requestIdResolver', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        requestIdResolver: (req) => 'custom-${req.method}',
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('PUT', '/update'));

      expect(logHandler.records.first.fields['requestId'], 'custom-PUT');
    });
  });

  // ---------------------------------------------------------------------------
  // Field customization
  // ---------------------------------------------------------------------------

  group('field customization', () {
    test('fields replaces defaults entirely when not composing', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        fields: (req, _) => {
          'method': req.method,
          'path': req.requestedUri.path,
          'host': req.headers['host'] ?? 'unknown',
        },
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request('GET', '/api', headers: {'host': 'example.com'}),
      );

      final first = logHandler.records.first;
      expect(first.fields['host'], 'example.com');
      // None of the OTel defaults are present when user returns their own map.
      expect(first.fields.containsKey('requestId'), isFalse);
      expect(first.fields.containsKey('http.request.method'), isFalse);
      expect(first.fields.containsKey('url.scheme'), isFalse);
    });

    test('fields can compose with defaults via spread', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        fields: (req, defaults) => {...defaults, 'tenant_id': 'acme'},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      final first = logHandler.records.first;
      expect(first.fields['tenant_id'], 'acme');
      // OTel defaults still present.
      expect(first.fields['http.request.method'], 'GET');
      expect(first.fields['url.path'], '/api');
      expect(first.fields.containsKey('requestId'), isTrue);
    });

    test('fields can filter defaults', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        fields: (req, defaults) =>
            Map.of(defaults)..remove('user_agent.original'),
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api', headers: {'user-agent': 'curl'}));

      final first = logHandler.records.first;
      expect(first.fields.containsKey('user_agent.original'), isFalse);
      expect(first.fields['http.request.method'], 'GET');
    });

    test('requestIdResolver callback always runs as part of defaults',
        () async {
      var requestIdCalled = false;
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        requestIdResolver: (_) {
          requestIdCalled = true;
          return 'precomputed';
        },
        // User replaces with a map that doesn't carry requestId forward.
        fields: (req, _) => {'method': req.method},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/test'));

      // Callback runs as part of building defaults; user controls inclusion.
      expect(requestIdCalled, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Log control
  // ---------------------------------------------------------------------------

  group('log control', () {
    test('logStart: false suppresses start log', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        logStart: false,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/quiet'));

      expect(logHandler.records, hasLength(1));
      expect(logHandler.records.single.message, 'request completed');
    });

    test('default responseLevel: 2xx at info', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/ok'));

      final complete = logHandler.records.last;
      expect(complete.level, loq.Level.info);
    });

    test('default responseLevel: 4xx at warn', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler =
          middleware((_) => Future.value(Response.notFound('nope')));

      await handler(_request('GET', '/missing'));

      final complete = logHandler.records.last;
      expect(complete.level, loq.Level.warn);
    });

    test('default responseLevel: 5xx at error', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware(
        (_) => Future.value(Response.internalServerError()),
      );

      await handler(_request('GET', '/broken'));

      final complete = logHandler.records.last;
      expect(complete.level, loq.Level.error);
    });

    test('custom level via levelResolver', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        levelResolver: (response, elapsed, error) => loq.Level.debug,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/custom'));

      final complete = logHandler.records.last;
      expect(complete.level, loq.Level.debug);
    });

    test('custom responseFields with defaults composition', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        responseFields: (response, elapsed, defaults) => {
          ...defaults,
          'contentLength': response.headers['content-length'],
        },
      );
      final handler = middleware(
        (_) => Future.value(
          Response.ok('hello', headers: {'content-length': '5'}),
        ),
      );

      await handler(_request('GET', '/data'));

      final complete = logHandler.records.last;
      expect(complete.fields['contentLength'], '5');
    });
  });

  // ---------------------------------------------------------------------------
  // Integration
  // ---------------------------------------------------------------------------

  group('integration', () {
    test('custom logger receives all records', () async {
      final customLog = loq.Logger('custom', config: config);
      final middleware = loqMiddleware(logger: customLog);
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/test'));

      for (final record in logHandler.records) {
        expect(record.loggerName, 'custom');
      }
    });

    test('defaults to Logger("http") when no logger provided', () async {
      // Configure the global config so we can capture records.
      loq.LogConfig.configure(
        handlers: [logHandler],
        zoneAccessor: loq.defaultZoneAccessor,
      );
      addTearDown(loq.LogConfig.reset);

      final middleware = loqMiddleware();
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/default'));

      expect(logHandler.records.first.loggerName, 'http');
    });
  });

  // ---------------------------------------------------------------------------
  // Skip
  // ---------------------------------------------------------------------------

  group('skip', () {
    test('bypasses middleware when predicate returns true', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        skip: (req) => req.requestedUri.path == '/healthz',
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/healthz'));

      expect(logHandler.records, isEmpty);
    });

    test('still logs when predicate returns false', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        skip: (req) => req.requestedUri.path == '/healthz',
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api/users'));

      expect(logHandler.records, hasLength(2));
    });

    test('skipped requests do not bind zone context', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        skip: (_) => true,
      );
      final handler = middleware((request) {
        loq.Logger('inner', config: config).info('inside');
        return Future.value(Response.ok('ok'));
      });

      await handler(_request('GET', '/skipped'));

      final inner = logHandler.records.firstWhere((r) => r.message == 'inside');
      expect(inner.fields.containsKey('method'), isFalse);
      expect(inner.fields.containsKey('path'), isFalse);
      expect(inner.fields.containsKey('requestId'), isFalse);
    });

    test('errors in skipped requests propagate without logging', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        skip: (_) => true,
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(_request('GET', '/skipped')),
        throwsA(isA<Exception>()),
      );

      expect(logHandler.records, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Slow request threshold
  // ---------------------------------------------------------------------------

  group('slowRequestThreshold', () {
    test('adds slow:true and bumps info to warn when exceeded', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(_request('GET', '/slow'));

      final complete = logHandler.records.last;
      expect(complete.fields['slow'], isTrue);
      expect(complete.level, loq.Level.warn);
    });

    test('does not bump error level downward', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          Response.internalServerError,
        ),
      );

      await handler(_request('GET', '/slow-and-broken'));

      final complete = logHandler.records.last;
      expect(complete.level, loq.Level.error);
      expect(complete.fields['slow'], isTrue);
    });

    test('no slow field or level change when under threshold', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        slowRequestThreshold: const Duration(seconds: 10),
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/fast'));

      final complete = logHandler.records.last;
      expect(complete.fields.containsKey('slow'), isFalse);
      expect(complete.level, loq.Level.info);
    });

    test('adds slow field to error log when error path is slow', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw Exception('slow boom');
        },
      );

      await expectLater(
        () => handler(_request('GET', '/slow-fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.fields['slow'], isTrue);
      expect(errorRecord.level, loq.Level.error);
    });

    test('no slow field when threshold is null (default)', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(_request('GET', '/no-threshold'));

      final complete = logHandler.records.last;
      expect(complete.fields.containsKey('slow'), isFalse);
    });

    test('respects levelResolver returning error when slow bump would lower it',
        () async {
      // levelResolver returns error for all responses.
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        levelResolver: (response, elapsed, error) => loq.Level.error,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(_request('GET', '/slow'));

      final complete = logHandler.records.last;
      // Slow bump must not downgrade an explicit error.
      expect(complete.level, loq.Level.error);
      expect(complete.fields['slow'], isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Header capture
  // ---------------------------------------------------------------------------

  group('captureRequestHeaders', () {
    test('binds requested headers as fields on every log', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['user-agent', 'cf-ray'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request(
          'GET',
          '/api',
          headers: {'user-agent': 'curl/8.0', 'cf-ray': 'abc-DFW'},
        ),
      );

      for (final record in logHandler.records) {
        expect(record.fields['http.request.header.user-agent'], 'curl/8.0');
        expect(record.fields['http.request.header.cf-ray'], 'abc-DFW');
      }
    });

    test('output field name follows OTel http.request.header.<lowercase>',
        () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['User-Agent'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(
        logHandler.records.first.fields['http.request.header.user-agent'],
        'curl',
      );
      // User-supplied casing is not preserved on the output field.
      expect(
        logHandler.records.first.fields.containsKey('User-Agent'),
        isFalse,
      );
    });

    test('missing headers are silently dropped', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['user-agent', 'missing-header'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(
        logHandler.records.first.fields['http.request.header.user-agent'],
        'curl',
      );
      expect(
        logHandler.records.first.fields
            .containsKey('http.request.header.missing-header'),
        isFalse,
      );
    });

    test('headers propagate to inner zone-context logs', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['x-trace-id'],
      );
      final handler = middleware((_) {
        loq.Logger('inner', config: config).info('inside');
        return Future.value(Response.ok('ok'));
      });

      await handler(_request('GET', '/api', headers: {'x-trace-id': 'tr-9'}));

      final inner = logHandler.records.firstWhere((r) => r.message == 'inside');
      expect(inner.fields['http.request.header.x-trace-id'], 'tr-9');
    });

    test('captured headers are present in fields callback defaults', () async {
      Map<String, Object?>? observedDefaults;
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['user-agent'],
        fields: (req, defaults) {
          observedDefaults = defaults;
          return defaults;
        },
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api', headers: {'user-agent': 'curl'}));

      // The captured header is folded into defaults — visible to the
      // callback for inspection, composition, or removal.
      expect(observedDefaults!['http.request.header.user-agent'], 'curl');
    });

    test('replacement via fields drops captured headers', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['user-agent'],
        fields: (req, _) => {'method': req.method},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api', headers: {'user-agent': 'curl'}));

      final start = logHandler.records.first;
      expect(start.fields['method'], 'GET');
      // Replacement opts out of the captured-header default — same
      // contract as for OTel core defaults.
      expect(
        start.fields.containsKey('http.request.header.user-agent'),
        isFalse,
      );
    });
  });

  group('captureResponseHeaders', () {
    test('adds response headers to completion log only', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureResponseHeaders: ['cache-status'],
      );
      final handler = middleware(
        (_) => Future.value(
          Response.ok('ok', headers: {'cache-status': 'HIT'}),
        ),
      );

      await handler(_request('GET', '/api'));

      final start = logHandler.records.first;
      final complete = logHandler.records.last;
      expect(complete.fields['http.response.header.cache-status'], 'HIT');
      expect(start.fields.containsKey('cache-status'), isFalse);
    });

    test('missing response headers are silently dropped', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureResponseHeaders: ['x-served-by'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      expect(
        logHandler.records.last.fields
            .containsKey('http.response.header.x-served-by'),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Query parameter capture
  // ---------------------------------------------------------------------------

  group('captureQueryParams', () {
    test('disabled by default', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/search?q=cats'));

      for (final record in logHandler.records) {
        expect(record.fields.containsKey('url.query'), isFalse);
      }
    });

    test('adds url.query as the raw query string when enabled', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/search?q=cats&page=2'));

      expect(logHandler.records.first.fields['url.query'], 'q=cats&page=2');
    });

    test('no url.query field when query string is empty', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/search'));

      expect(
        logHandler.records.first.fields.containsKey('url.query'),
        isFalse,
      );
    });

    test('url.query propagates via zone context', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
      );
      final handler = middleware((_) {
        loq.Logger('inner', config: config).info('inside');
        return Future.value(Response.ok('ok'));
      });

      await handler(_request('GET', '/search?q=cats'));

      final inner = logHandler.records.firstWhere((r) => r.message == 'inside');
      expect(inner.fields['url.query'], 'q=cats');
    });

    test('preserves repeated keys and order', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/search?id=1&id=2&id=3'));

      expect(logHandler.records.first.fields['url.query'], 'id=1&id=2&id=3');
    });

    test('preserves bare keys (no =)', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
        redactQueryParams: const {'token'},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/search?flag&q=cats'));

      expect(logHandler.records.first.fields['url.query'], 'flag&q=cats');
    });
  });

  // ---------------------------------------------------------------------------
  // Message overrides
  // ---------------------------------------------------------------------------

  group('message overrides', () {
    test('startMessage replaces the default start text', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        startMessage: 'http.request.start',
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      expect(logHandler.records.first.message, 'http.request.start');
    });

    test('completeMessage replaces the default completion text', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        completeMessage: 'http.request.end',
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      expect(logHandler.records.last.message, 'http.request.end');
    });

    test('errorMessage replaces the default error text', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        errorMessage: 'http.request.error',
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord = logHandler.records.firstWhere(
        (r) => r.message == 'http.request.error',
      );
      expect(errorRecord.level, loq.Level.error);
    });
  });

  // ---------------------------------------------------------------------------
  // OTel default fields
  // ---------------------------------------------------------------------------

  group('OTel default fields', () {
    test('emits url.scheme, server.address, network.protocol.version',
        () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      final start = logHandler.records.first;
      expect(start.fields['url.scheme'], 'http');
      expect(start.fields['server.address'], 'localhost');
      expect(start.fields['network.protocol.version'], '1.1');
    });

    test('emits user_agent.original when User-Agent header is present',
        () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(logHandler.records.first.fields['user_agent.original'], 'curl');
    });

    test('omits user_agent.original when header absent', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      expect(
        logHandler.records.first.fields.containsKey('user_agent.original'),
        isFalse,
      );
    });

    test('emits http.response.body.size and content-type on completion',
        () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
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

      await handler(_request('GET', '/api'));

      final complete = logHandler.records.last;
      expect(complete.fields['http.response.body.size'], 5);
      expect(
        complete.fields['http.response.header.content-type'],
        'text/plain',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Route resolver
  // ---------------------------------------------------------------------------

  group('routeResolver', () {
    test('populates http.route when non-null', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        routeResolver: (req) => '/users/{id}',
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/users/42'));

      expect(logHandler.records.first.fields['http.route'], '/users/{id}');
    });

    test('omits http.route when resolver returns null', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        routeResolver: (_) => null,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/raw'));

      expect(
        logHandler.records.first.fields.containsKey('http.route'),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Client IP resolver
  // ---------------------------------------------------------------------------

  group('clientIpResolver', () {
    test('populates client.address from custom resolver', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        clientIpResolver: (req) => req.headers['x-forwarded-for'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request('GET', '/api', headers: {'x-forwarded-for': '10.0.0.5'}),
      );

      expect(logHandler.records.first.fields['client.address'], '10.0.0.5');
    });

    test('default extractor reads shelf_io connection info', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      final req = Request(
        'GET',
        Uri.parse('http://localhost/api'),
        context: {
          'shelf.io.connection_info':
              _FakeConnectionInfo(InternetAddress('192.168.1.10')),
        },
      );

      await handler(req);

      expect(
        logHandler.records.first.fields['client.address'],
        '192.168.1.10',
      );
    });

    test(
        'omits client.address when resolver returns null '
        'and no connection info', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        clientIpResolver: (_) => null,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      expect(
        logHandler.records.first.fields.containsKey('client.address'),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Level resolver
  // ---------------------------------------------------------------------------

  group('levelResolver', () {
    test('overrides completion level when non-null', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        levelResolver: (response, elapsed, error) => loq.Level.debug,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/api'));

      expect(logHandler.records.last.level, loq.Level.debug);
    });

    test('overrides error level when non-null', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        levelResolver: (response, elapsed, error) =>
            error != null ? loq.Level.warn : null,
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.level, loq.Level.warn);
    });

    test('null return falls back to default behavior', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        levelResolver: (response, elapsed, error) => null,
      );
      final handler =
          middleware((_) => Future.value(Response.internalServerError()));

      await handler(_request('GET', '/broken'));

      expect(logHandler.records.last.level, loq.Level.error);
    });

    test('slow bump still applies after levelResolver returns info', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        levelResolver: (response, elapsed, error) => loq.Level.info,
        slowRequestThreshold: Duration.zero,
      );
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 5),
          () => Response.ok('ok'),
        ),
      );

      await handler(_request('GET', '/slow'));

      expect(logHandler.records.last.level, loq.Level.warn);
      expect(logHandler.records.last.fields['slow'], isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // errorFields
  // ---------------------------------------------------------------------------

  group('errorFields', () {
    test('can add fields on top of defaults', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        errorFields: (error, stack, elapsed, defaults) => {
          ...defaults,
          'error.retryable': false,
        },
      );
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.fields['error.retryable'], isFalse);
      expect(errorRecord.fields['error.type'], 'FormatException');
      expect(errorRecord.fields['duration_ms'], isA<int>());
    });

    test('can replace defaults entirely', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        errorFields: (error, stack, elapsed, defaults) => {
          'minimal': true,
        },
      );
      final handler = middleware((_) => throw Exception('boom'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.fields['minimal'], isTrue);
      // User opted out of the defaults.
      expect(errorRecord.fields.containsKey('error.type'), isFalse);
      expect(errorRecord.fields.containsKey('duration_ms'), isFalse);
    });

    test('receives error and stack trace', () async {
      Object? capturedError;
      StackTrace? capturedStack;
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        errorFields: (error, stack, elapsed, defaults) {
          capturedError = error;
          capturedStack = stack;
          return defaults;
        },
      );
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      expect(capturedError, isA<FormatException>());
      expect(capturedStack, isNotNull);
    });

    test('slow flag is included in defaults when threshold exceeded', () async {
      Map<String, Object?>? capturedDefaults;
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        slowRequestThreshold: Duration.zero,
        errorFields: (error, stack, elapsed, defaults) {
          capturedDefaults = defaults;
          return defaults;
        },
      );
      final handler = middleware((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw Exception('slow boom');
      });

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<Exception>()),
      );

      expect(capturedDefaults!['slow'], isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // error.type
  // ---------------------------------------------------------------------------

  group('error.type and error.message', () {
    test('emits error.type as the runtime type name', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.fields['error.type'], 'FormatException');
    });

    test('emits error.message as the error toString', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((_) => throw const FormatException('bad'));

      await expectLater(
        () => handler(_request('GET', '/fail')),
        throwsA(isA<FormatException>()),
      );

      final errorRecord =
          logHandler.records.firstWhere((r) => r.message == 'request failed');
      expect(errorRecord.fields['error.message'], 'FormatException: bad');
    });
  });

  // ---------------------------------------------------------------------------
  // Default redaction
  // ---------------------------------------------------------------------------

  group('default redaction', () {
    test('redacts authorization, cookie, x-api-key by default', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['authorization', 'cookie', 'x-api-key'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request(
          'GET',
          '/api',
          headers: {
            'authorization': 'Bearer secret',
            'cookie': 'session=abc',
            'x-api-key': 'k-123',
          },
        ),
      );

      final start = logHandler.records.first;
      expect(start.fields['http.request.header.authorization'], '***');
      expect(start.fields['http.request.header.cookie'], '***');
      expect(start.fields['http.request.header.x-api-key'], '***');
    });

    test('redacts set-cookie on response by default', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureResponseHeaders: ['set-cookie'],
      );
      final handler = middleware(
        (_) => Future.value(
          Response.ok('ok', headers: {'set-cookie': 'session=xyz; HttpOnly'}),
        ),
      );

      await handler(_request('GET', '/api'));

      expect(
        logHandler.records.last.fields['http.response.header.set-cookie'],
        '***',
      );
    });

    test('redacts default-sensitive query params', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(_request('GET', '/search?q=cats&api_key=secret'));

      expect(
        logHandler.records.first.fields['url.query'],
        'q=cats&api_key=***',
      );
    });

    test('non-sensitive captured headers pass through unredacted', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['user-agent', 'authorization'],
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request(
          'GET',
          '/api',
          headers: {
            'user-agent': 'curl/8.0',
            'authorization': 'Bearer secret',
          },
        ),
      );

      final start = logHandler.records.first;
      expect(start.fields['http.request.header.user-agent'], 'curl/8.0');
      expect(start.fields['http.request.header.authorization'], '***');
    });

    test('empty redactRequestHeaders disables redaction', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['authorization'],
        redactRequestHeaders: const {},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request('GET', '/api', headers: {'authorization': 'Bearer raw'}),
      );

      expect(
        logHandler.records.first.fields['http.request.header.authorization'],
        'Bearer raw',
      );
    });

    test('custom redactRequestHeaders replaces defaults', () async {
      // Custom set redacts user-agent but not authorization.
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureRequestHeaders: ['user-agent', 'authorization'],
        redactRequestHeaders: const {'user-agent'},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request(
          'GET',
          '/api',
          headers: {
            'user-agent': 'curl',
            'authorization': 'Bearer raw',
          },
        ),
      );

      final start = logHandler.records.first;
      expect(start.fields['http.request.header.user-agent'], '***');
      expect(start.fields['http.request.header.authorization'], 'Bearer raw');
    });

    test('custom redactQueryParams replaces defaults', () async {
      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: config),
        captureQueryParams: true,
        redactQueryParams: const {'session_id'},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request(
          'GET',
          '/search?q=cats&session_id=secret&api_key=visible',
        ),
      );

      expect(
        logHandler.records.first.fields['url.query'],
        'q=cats&session_id=***&api_key=visible',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Prefixed redaction-field constants
  // ---------------------------------------------------------------------------

  group('prefixed redaction-field constants', () {
    test('defaultRedactedRequestHeaderFields applies the OTel prefix', () {
      expect(
        defaultRedactedRequestHeaderFields,
        containsAll(<String>[
          'http.request.header.authorization',
          'http.request.header.proxy-authorization',
          'http.request.header.cookie',
          'http.request.header.x-api-key',
          'http.request.header.x-auth-token',
        ]),
      );
      // Same cardinality as the unprefixed set.
      expect(
        defaultRedactedRequestHeaderFields,
        hasLength(defaultRedactedRequestHeaders.length),
      );
    });

    test('defaultRedactedResponseHeaderFields applies the OTel prefix', () {
      expect(
        defaultRedactedResponseHeaderFields,
        equals({'http.response.header.set-cookie'}),
      );
    });

    test('composes with loq.redact processor', () async {
      // Verify the constant plugs into the core processor cleanly:
      // user-contributed sensitive field gets masked alongside the
      // captured headers.
      final cfg = loq.LogConfig(
        handlers: [logHandler],
        processors: [
          loq.redact({
            ...defaultRedactedRequestHeaderFields,
            'tenant_secret',
          }),
        ],
        zoneAccessor: loq.defaultZoneAccessor,
      );

      final middleware = loqMiddleware(
        logger: loq.Logger('http', config: cfg),
        captureRequestHeaders: ['authorization'],
        // Disable inline redaction so we see the core processor doing
        // the work end-to-end.
        redactRequestHeaders: const {},
      );
      final handler = middleware((_) => Future.value(Response.ok('ok')));

      await handler(
        _request('GET', '/api', headers: {'authorization': 'Bearer raw'}),
      );

      // The core redact() processor masked the captured header by name.
      expect(
        logHandler.records.first.fields['http.request.header.authorization'],
        '***',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Concurrency
  // ---------------------------------------------------------------------------

  group('concurrency', () {
    test('concurrent requests get unique request IDs', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      // Handler that simulates async work — forces interleaving.
      final handler = middleware(
        (_) => Future<Response>.delayed(
          const Duration(milliseconds: 10),
          () => Response.ok('ok'),
        ),
      );

      // Fire 20 requests concurrently.
      Future<Response> send(int i) async => handler(_request('GET', '/c/$i'));
      await Future.wait([for (var i = 0; i < 20; i++) send(i)]);

      // Each request produces a start + complete log → 40 records.
      expect(logHandler.records, hasLength(40));

      // Extract all request IDs from start logs.
      final ids = logHandler.records
          .where((r) => r.message == 'request started')
          .map((r) => r.fields['requestId'])
          .toList();

      // All 20 IDs should be unique.
      expect(ids.toSet(), hasLength(20));
    });

    test('zone context does not leak between concurrent requests', () async {
      final middleware =
          loqMiddleware(logger: loq.Logger('http', config: config));
      final handler = middleware((request) {
        // Log from inside — should see only THIS request's path.
        loq.Logger('inner', config: config).info('handling');
        return Future<Response>.delayed(
          const Duration(milliseconds: 10),
          () => Response.ok('ok'),
        );
      });

      // Fire requests to different paths concurrently.
      Future<Response> send(Request req) async => handler(req);
      await Future.wait([
        send(_request('GET', '/alpha')),
        send(_request('POST', '/beta')),
        send(_request('PUT', '/gamma')),
      ]);

      // Each inner log should have the correct method+path pair.
      final innerRecords =
          logHandler.records.where((r) => r.message == 'handling').toList();
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
