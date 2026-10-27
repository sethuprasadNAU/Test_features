import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 11.93 — what a coordinate's provenance becomes when somebody moves
/// it by hand.**
///
/// The rule exists because truth-point positions became editable in the same
/// task. A point that began as a GPS fix and was later nudged is a third thing;
/// without [PositionSource.gpsFixAdjusted] it would either keep claiming to be
/// a measurement or lose that it ever was one.
void main() {
  group('positionSourceAfterHandMove', () {
    test('a GPS fix becomes a fix that was moved by hand', () {
      expect(
        positionSourceAfterHandMove(PositionSource.gpsFix),
        PositionSource.gpsFixAdjusted,
      );
    });

    test('moving it again does not lose that it began as a fix', () {
      expect(
        positionSourceAfterHandMove(PositionSource.gpsFixAdjusted),
        PositionSource.gpsFixAdjusted,
      );
    });

    test('a pin stays a pin', () {
      expect(
        positionSourceAfterHandMove(PositionSource.manualPin),
        PositionSource.manualPin,
      );
    });

    test('a typed coordinate dragged on a map becomes a placed pin', () {
      expect(
        positionSourceAfterHandMove(PositionSource.manualEntry),
        PositionSource.manualPin,
      );
    });

    // **The case the no-backfill rule reaches into.** A row from before schema
    // v11 records no source. Moving it tells us a person placed *this*
    // coordinate by hand; it does not tell us the coordinate began as a
    // measurement, and `gpsFixAdjusted` would claim exactly that.
    test('a source that was never recorded becomes a plain hand-placed pin',
        () {
      expect(positionSourceAfterHandMove(null), PositionSource.manualPin);
      expect(
        positionSourceAfterHandMove(null),
        isNot(PositionSource.gpsFixAdjusted),
        reason: 'we do not know it was ever a fix, and saying so would invent '
            'the provenance this table refuses to backfill',
      );
    });

    test('every source has an answer, so a new one cannot slip through', () {
      for (final source in PositionSource.values) {
        expect(positionSourceAfterHandMove(source), isNotNull);
      }
    });
  });
}
