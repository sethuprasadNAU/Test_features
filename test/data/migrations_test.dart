import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/migrations.dart';

/// `latestSchemaVersion` has exactly one definition, in `package:tritrack_sync`
/// (task 10.1) — the app's migration set must stay in step with it rather than
/// each side computing its own idea of "current". This is the guard that
/// makes drift between the two visible immediately instead of silently.
void main() {
  test('the migrations list is contiguous 1..latestSchemaVersion', () {
    final versions = migrations.map((m) => m.version).toList()..sort();
    expect(versions, List.generate(latestSchemaVersion, (i) => i + 1));
    expect(() => assertMigrationsMatchLatestSchemaVersion(), returnsNormally);
  });
}
