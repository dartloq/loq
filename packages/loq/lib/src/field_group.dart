import 'package:loq/loq.dart';

/// Groups related fields under a namespace.
///
/// Place a `FieldGroup` as a value in the fields map. The map key
/// becomes the group name; handlers decide how to render it:
///
/// - [JsonHandler] renders it as a nested JSON object.
/// - [ConsoleHandler] uses dotted-key notation (e.g. `http.method=GET`).
///
/// ```dart
/// log.info('request', fields: {
///   'http': FieldGroup({'method': 'GET', 'path': '/api', 'status': 200}),
/// });
/// ```
class FieldGroup {
  /// Creates a field group with the given [fields].
  const FieldGroup(this.fields);

  /// The grouped key-value pairs.
  final Map<String, Object?> fields;

  @override
  String toString() =>
      '{${fields.entries.map((e) => '${e.key}=${e.value}').join(', ')}}';
}
