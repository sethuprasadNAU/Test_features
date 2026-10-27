import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **The compatibility boundary, checked from the server's side** (task
/// 11.242). The Postgres DDL is generated from `tableSpecs`, so a change to
/// that declaration reaches the server in the same commit — and if it is a
/// change a device on the current `schemaMajorVersion` cannot survive, the
/// server would start storing rows those devices refuse, or refusing rows
/// they send, while both sides still announce the same major. See
/// `wire_shape_freeze.dart` for the table of changes and
/// `test/data/wire_shape_frozen_test.dart` in the app for the other caller.
void main() {
  test('the wire is compatible with every device on the current major', () {
    expect(assertWireShapeCompatibleWithMajor, returnsNormally);
  });
}
