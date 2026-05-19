import 'package:loq_shelf/loq_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

void main() {
  group('ShelfRequestStartEvent', () {
    test('exposes request, defaults, and null elapsed', () {
      final req = request('GET', '/api');
      final defaults = <String, Object?>{
        'http.request.method': 'GET',
        'url.path': '/api',
        'requestId': '1',
      };
      final event = ShelfRequestStartEvent(request: req, defaults: defaults);

      expect(event.request, same(req));
      expect(event.defaults, equals(defaults));
      expect(event.elapsed, isNull);
    });

    test('is a ShelfLogEvent', () {
      final event = ShelfRequestStartEvent(
        request: request('GET', '/api'),
        defaults: const {},
      );
      expect(event, isA<ShelfLogEvent>());
    });
  });

  group('ShelfResponseEvent', () {
    test('exposes request, response, elapsed, and defaults', () {
      final req = request('POST', '/submit');
      final resp = Response.ok('ok');
      const elapsed = Duration(milliseconds: 42);
      final defaults = <String, Object?>{
        'http.request.method': 'POST',
        'http.response.status_code': 200,
        'duration_ms': 42,
      };
      final event = ShelfResponseEvent(
        request: req,
        response: resp,
        elapsed: elapsed,
        defaults: defaults,
      );

      expect(event.request, same(req));
      expect(event.response, same(resp));
      expect(event.elapsed, equals(elapsed));
      expect(event.defaults, equals(defaults));
    });

    test('is a ShelfLogEvent', () {
      final event = ShelfResponseEvent(
        request: request('GET', '/'),
        response: Response.ok('ok'),
        elapsed: Duration.zero,
        defaults: const {},
      );
      expect(event, isA<ShelfLogEvent>());
    });
  });

  group('ShelfRequestErrorEvent', () {
    test('exposes request, elapsed, and defaults', () {
      final req = request('GET', '/boom');
      const elapsed = Duration(milliseconds: 7);
      final defaults = <String, Object?>{
        'http.request.method': 'GET',
        'error.type': 'FormatException',
        'duration_ms': 7,
      };
      final event = ShelfRequestErrorEvent(
        request: req,
        elapsed: elapsed,
        defaults: defaults,
      );

      expect(event.request, same(req));
      expect(event.elapsed, equals(elapsed));
      expect(event.defaults, equals(defaults));
    });

    test('is a ShelfLogEvent', () {
      final event = ShelfRequestErrorEvent(
        request: request('GET', '/'),
        elapsed: Duration.zero,
        defaults: const {},
      );
      expect(event, isA<ShelfLogEvent>());
    });
  });

  group('pattern matching', () {
    test('exhaustive switch dispatches per concrete event', () {
      final start = ShelfRequestStartEvent(
        request: request('GET', '/a'),
        defaults: const {'k': 's'},
      );
      final resp = ShelfResponseEvent(
        request: request('GET', '/b'),
        response: Response.ok('ok'),
        elapsed: Duration.zero,
        defaults: const {'k': 'r'},
      );
      final err = ShelfRequestErrorEvent(
        request: request('GET', '/c'),
        elapsed: Duration.zero,
        defaults: const {'k': 'e'},
      );

      String label(ShelfLogEvent event) => switch (event) {
            ShelfRequestStartEvent() => 'start',
            ShelfResponseEvent() => 'response',
            ShelfRequestErrorEvent() => 'error',
          };

      expect(label(start), 'start');
      expect(label(resp), 'response');
      expect(label(err), 'error');
    });
  });
}
