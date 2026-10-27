import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **The compatibility boundary, checked on every commit** (task 11.242).
///
/// `schemaMajorVersion` promises that two builds announcing the same major can
/// sync. Task 11.240 broke that promise without moving the number — it made
/// `Tags.color_hex` nullable, so a v15 phone handed a v16 row refused it at
/// its own database and its sync never advanced again
/// (`v15_device_meets_v16_row_test.dart` holds the measurement) — and nothing
/// noticed, because the rule lived in a document.
///
/// `assertWireShapeCompatibleWithMajor` (`wire_shape_freeze.dart` in the sync
/// package) is that rule as a check: the wire's shape is frozen when a major
/// begins, and any later change an older build on that major cannot survive —
/// a column losing or gaining `NOT NULL`, changing type, leaving the wire,
/// joining the key, a bound tightening, a new `NOT NULL` column — fails here
/// with the remedy in the message. The package's own suite watches every one
/// of those refusals fire; **this file exists so the pre-commit hook, which
/// runs `flutter test` and nothing else, runs the check too.** The server
/// suite calls it as well (`server/test/schema/wire_shape_frozen_test.dart`),
/// for the same reason from the other side.
void main() {
  test('the wire is compatible with every device on the current major', () {
    expect(assertWireShapeCompatibleWithMajor, returnsNormally);
  });

  test('the freeze covers every table the app syncs', () {
    // A freeze that quietly omitted a table would pass the check above for
    // that table forever. `Tables.all` is what the merger iterates.
    final frozen = frozenWireShapes[schemaMajorVersion];
    expect(frozen, isNotNull);
    expect(frozen!.tables.map((t) => t.name), containsAll(Tables.all));
  });
}
