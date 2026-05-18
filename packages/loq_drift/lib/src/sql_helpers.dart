import 'package:drift/drift.dart';

/// Maps a Drift [SqlDialect] to the OpenTelemetry `db.system.name`
/// canonical value.
///
/// Used as the default for `dbSystemResolver`. Dialects without a
/// recognized OTel canonical mapping fall back to `other_sql` (the
/// Stable catch-all per the OTel database semantic conventions). If
/// you want a specific value emitted for a non-standard dialect
/// (e.g. `duckdb`), supply a custom `dbSystemResolver`.
String defaultDbSystemName(SqlDialect dialect) {
  return switch (dialect) {
    SqlDialect.sqlite => 'sqlite',
    SqlDialect.postgres => 'postgresql',
    SqlDialect.mariadb => 'mariadb',
    _ => 'other_sql',
  };
}

/// Extracts the leading SQL keyword from [statement] for use as
/// `db.operation.name` on `runCustom` calls. Returns `null` when the
/// statement has no leading word.
///
/// Skips leading whitespace and `--` line comments. Doesn't try to
/// rewrite CTEs (`WITH ... SELECT`); the `WITH` keyword is reported as-is.
String? extractOperationName(String statement) {
  var i = 0;
  while (i < statement.length) {
    final c = statement.codeUnitAt(i);
    // whitespace
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      i++;
      continue;
    }
    // -- line comment
    if (c == 0x2D &&
        i + 1 < statement.length &&
        statement.codeUnitAt(i + 1) == 0x2D) {
      final newline = statement.indexOf('\n', i + 2);
      if (newline < 0) return null;
      i = newline + 1;
      continue;
    }
    break;
  }
  if (i >= statement.length) return null;
  final start = i;
  while (i < statement.length) {
    final c = statement.codeUnitAt(i);
    final isAlpha = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    if (!isAlpha) break;
    i++;
  }
  if (i == start) return null;
  return statement.substring(start, i).toUpperCase();
}
