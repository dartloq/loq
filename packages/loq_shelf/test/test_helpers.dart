import 'dart:io';

import 'package:loq/loq.dart';
import 'package:loq/testing.dart';
import 'package:shelf/shelf.dart';

/// A stand-in for the [HttpConnectionInfo] that `shelf_io` injects on
/// real requests. Tests that drive the default client-IP extractor pass
/// an instance via
/// `Request(context: {'shelf.io.connection_info': FakeConnectionInfo(...)})`.
class FakeConnectionInfo implements HttpConnectionInfo {
  FakeConnectionInfo(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 0;

  @override
  int get localPort => 0;
}

/// Creates a Shelf [Request] for testing. Wraps the common case of
/// `Request(method, Uri.parse('http://localhost$path'), headers: headers)`.
Request request(
  String method,
  String path, {
  Map<String, String>? headers,
}) =>
    Request(method, Uri.parse('http://localhost$path'), headers: headers);

/// Standard recorder + config + logger triple for middleware tests.
/// Wire into `setUp`:
///
/// ```dart
/// late RecordingHandler recorder;
/// late LogConfig config;
/// late Logger logger;
///
/// setUp(() {
///   final s = setUpRecorder();
///   recorder = s.recorder;
///   config = s.config;
///   logger = s.logger;
/// });
/// ```
({RecordingHandler recorder, LogConfig config, Logger logger}) setUpRecorder() {
  final recorder = RecordingHandler();
  final config = LogConfig(
    handlers: [recorder],
    zoneAccessor: defaultZoneAccessor,
  );
  return (
    recorder: recorder,
    config: config,
    logger: Logger('http', config: config),
  );
}

/// Inner handler that returns a 200 OK. Most middleware tests don't
/// care about the handler shape, just that it returns successfully.
Response okHandler(Request _) => Response.ok('ok');
