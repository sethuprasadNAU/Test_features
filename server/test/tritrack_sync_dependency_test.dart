import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Not a test of `tritrack_sync` itself (that package has its own suite) —
/// this only proves the server's by-path dependency on it actually resolves
/// and compiles end to end, which is the concrete, checkable half of task
/// 10.3's "depending on packages/tritrack_sync by path" requirement. The
/// schema/merge work that actually *uses* these lands in task 10.5+.
void main() {
  test('the shared table/schema constants are reachable from the server', () {
    expect(Tables.observations, 'Observations');
    expect(latestSchemaVersion, greaterThan(0));
  });

  test('the shared merge resolver is reachable from the server', () {
    final newer = {'revision': 2, 'updated_at': '2026-01-01T00:00:00.000Z'};
    final older = {'revision': 1, 'updated_at': '2026-01-01T00:00:00.000Z'};
    expect(MergeResolver.incomingWins(newer, older), isTrue);
  });
}
