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
  // Request header capture
  // ---------------------------------------------------------------------------

  group('captureRequestHeaders', () {
    test('binds requested headers as fields on every log', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['user-agent', 'cf-ray'],
      );
      final handler = middleware(okHandler);

      await handler(
        request(
          'GET',
          '/api',
          headers: {'user-agent': 'curl/8.0', 'cf-ray': 'abc-DFW'},
        ),
      );

      for (final record in recorder.records) {
        expect(record.fields['http.request.header.user-agent'], 'curl/8.0');
        expect(record.fields['http.request.header.cf-ray'], 'abc-DFW');
      }
    });

    test('output field name follows OTel http.request.header.<lowercase>',
        () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['User-Agent'],
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(
        recorder.records.first.fields['http.request.header.user-agent'],
        'curl',
      );
      expect(
        recorder.records.first.fields.containsKey('User-Agent'),
        isFalse,
      );
    });

    test('missing headers are silently dropped', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['user-agent', 'missing-header'],
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(
        recorder.records.first.fields['http.request.header.user-agent'],
        'curl',
      );
      expect(
        recorder.records.first.fields
            .containsKey('http.request.header.missing-header'),
        isFalse,
      );
    });

    test('headers propagate to inner zone-context logs', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['x-trace-id'],
      );
      final handler = middleware((_) {
        Logger('inner', config: config).info('inside');
        return Response.ok('ok');
      });

      await handler(request('GET', '/api', headers: {'x-trace-id': 'tr-9'}));

      final inner = recorder.messageContaining('inside').single;
      expect(inner.fields['http.request.header.x-trace-id'], 'tr-9');
    });

    test('captured headers are present in fields callback defaults', () async {
      Map<String, Object?>? observedDefaults;
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['user-agent'],
        fields: (event) {
          if (event is ShelfRequestStartEvent) {
            observedDefaults = event.defaults;
          }
          return event.defaults;
        },
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api', headers: {'user-agent': 'curl'}));

      expect(observedDefaults!['http.request.header.user-agent'], 'curl');
    });

    test('replacement via fields drops captured headers', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['user-agent'],
        fields: (event) => {'method': event.request.method},
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api', headers: {'user-agent': 'curl'}));

      final start = recorder.records.first;
      expect(start.fields['method'], 'GET');
      expect(
        start.fields.containsKey('http.request.header.user-agent'),
        isFalse,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Response header capture
  // ---------------------------------------------------------------------------

  group('captureResponseHeaders', () {
    test('adds response headers to completion log only', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureResponseHeaders: ['cache-status'],
      );
      final handler = middleware(
        (_) => Future.value(
          Response.ok('ok', headers: {'cache-status': 'HIT'}),
        ),
      );

      await handler(request('GET', '/api'));

      final start = recorder.records.first;
      final complete = recorder.records.last;
      expect(complete.fields['http.response.header.cache-status'], 'HIT');
      expect(start.fields.containsKey('cache-status'), isFalse);
    });

    test('missing response headers are silently dropped', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureResponseHeaders: ['x-served-by'],
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/api'));

      expect(
        recorder.records.last.fields
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
      final middleware = loqMiddleware(logger: logger);
      final handler = middleware(okHandler);

      await handler(request('GET', '/search?q=cats'));

      for (final record in recorder.records) {
        expect(record.fields.containsKey('url.query'), isFalse);
      }
    });

    test('adds url.query as the raw query string when enabled', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/search?q=cats&page=2'));

      expect(recorder.records.first.fields['url.query'], 'q=cats&page=2');
    });

    test('no url.query field when query string is empty', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/search'));

      expect(
        recorder.records.first.fields.containsKey('url.query'),
        isFalse,
      );
    });

    test('url.query propagates via zone context', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
      );
      final handler = middleware((_) {
        Logger('inner', config: config).info('inside');
        return Response.ok('ok');
      });

      await handler(request('GET', '/search?q=cats'));

      final inner = recorder.messageContaining('inside').single;
      expect(inner.fields['url.query'], 'q=cats');
    });

    test('preserves repeated keys and order', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/search?id=1&id=2&id=3'));

      expect(recorder.records.first.fields['url.query'], 'id=1&id=2&id=3');
    });

    test('preserves bare keys (no =)', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
        redactQueryParams: const {'token'},
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/search?flag&q=cats'));

      expect(recorder.records.first.fields['url.query'], 'flag&q=cats');
    });
  });

  // ---------------------------------------------------------------------------
  // Default redaction
  // ---------------------------------------------------------------------------

  group('default redaction', () {
    test('redacts authorization, cookie, x-api-key by default', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['authorization', 'cookie', 'x-api-key'],
      );
      final handler = middleware(okHandler);

      await handler(
        request(
          'GET',
          '/api',
          headers: {
            'authorization': 'Bearer secret',
            'cookie': 'session=abc',
            'x-api-key': 'k-123',
          },
        ),
      );

      final start = recorder.records.first;
      expect(start.fields['http.request.header.authorization'], '***');
      expect(start.fields['http.request.header.cookie'], '***');
      expect(start.fields['http.request.header.x-api-key'], '***');
    });

    test('redacts set-cookie on response by default', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureResponseHeaders: ['set-cookie'],
      );
      final handler = middleware(
        (_) => Future.value(
          Response.ok('ok', headers: {'set-cookie': 'session=xyz; HttpOnly'}),
        ),
      );

      await handler(request('GET', '/api'));

      expect(
        recorder.records.last.fields['http.response.header.set-cookie'],
        '***',
      );
    });

    test('redacts default-sensitive query params', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
      );
      final handler = middleware(okHandler);

      await handler(request('GET', '/search?q=cats&api_key=secret'));

      expect(
        recorder.records.first.fields['url.query'],
        'q=cats&api_key=***',
      );
    });

    test('non-sensitive captured headers pass through unredacted', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['user-agent', 'authorization'],
      );
      final handler = middleware(okHandler);

      await handler(
        request(
          'GET',
          '/api',
          headers: {
            'user-agent': 'curl/8.0',
            'authorization': 'Bearer secret',
          },
        ),
      );

      final start = recorder.records.first;
      expect(start.fields['http.request.header.user-agent'], 'curl/8.0');
      expect(start.fields['http.request.header.authorization'], '***');
    });

    test('empty redactRequestHeaders disables redaction', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['authorization'],
        redactRequestHeaders: const {},
      );
      final handler = middleware(okHandler);

      await handler(
        request('GET', '/api', headers: {'authorization': 'Bearer raw'}),
      );

      expect(
        recorder.records.first.fields['http.request.header.authorization'],
        'Bearer raw',
      );
    });

    test('custom redactRequestHeaders replaces defaults', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureRequestHeaders: ['user-agent', 'authorization'],
        redactRequestHeaders: const {'user-agent'},
      );
      final handler = middleware(okHandler);

      await handler(
        request(
          'GET',
          '/api',
          headers: {
            'user-agent': 'curl',
            'authorization': 'Bearer raw',
          },
        ),
      );

      final start = recorder.records.first;
      expect(start.fields['http.request.header.user-agent'], '***');
      expect(start.fields['http.request.header.authorization'], 'Bearer raw');
    });

    test('custom redactQueryParams replaces defaults', () async {
      final middleware = loqMiddleware(
        logger: logger,
        captureQueryParams: true,
        redactQueryParams: const {'session_id'},
      );
      final handler = middleware(okHandler);

      await handler(
        request('GET', '/search?q=cats&session_id=secret&api_key=visible'),
      );

      expect(
        recorder.records.first.fields['url.query'],
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
      final cfg = LogConfig(
        handlers: [recorder],
        processors: [
          redact({
            ...defaultRedactedRequestHeaderFields,
            'tenant_secret',
          }),
        ],
        zoneAccessor: defaultZoneAccessor,
      );

      final middleware = loqMiddleware(
        logger: Logger('http', config: cfg),
        captureRequestHeaders: ['authorization'],
        // Disable inline redaction so the core processor does the work.
        redactRequestHeaders: const {},
      );
      final handler = middleware(okHandler);

      await handler(
        request('GET', '/api', headers: {'authorization': 'Bearer raw'}),
      );

      expect(
        recorder.records.first.fields['http.request.header.authorization'],
        '***',
      );
    });
  });
}
