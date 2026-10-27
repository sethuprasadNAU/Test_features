import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/bearing_wedge_cache.dart';
import 'package:tritrack/features/map/services/geo_math.dart';
import 'package:tritrack/localization/coordinate_projection.dart';

/// Task 11.131. Dragging a bearing's tip is a `setState` per frame, and the
/// wedge layer rebuilds every visible bearing's polygon on every one of them.
/// The claim this cache exists to make is narrow and worth checking directly:
/// **during a drag, exactly one wedge is recomputed, however many are on
/// screen.** Counting recomputes is the only way to tell that apart from
/// recomputing all of them and getting identical answers.
void main() {
  List<WedgeArgs> args(int count) => [
        for (var i = 0; i < count; i++)
          WedgeArgs(
            observationId: 'obs-$i',
            latitude: 35.19 + i * 0.01,
            longitude: -111.62,
            bearingDeg: 155.2,
            halfWidthDeg: 12.0,
            rangeMeters: 400,
          ),
      ];

  void draw(BearingWedgeCache cache, List<WedgeArgs> rows) {
    for (final r in rows) {
      cache.points(
        observationId: r.observationId,
        latitude: r.latitude,
        longitude: r.longitude,
        bearingDeg: r.bearingDeg,
        halfWidthDeg: r.halfWidthDeg,
        rangeMeters: r.rangeMeters,
      );
    }
  }

  test('a frame that changes one bearing recomputes exactly one wedge', () {
    final cache = BearingWedgeCache();
    final rows = args(20);

    draw(cache, rows);
    expect(cache.recomputeCount, 20, reason: 'first frame computes them all');

    // A second frame with nothing changed.
    draw(cache, rows);
    expect(cache.recomputeCount, 20, reason: 'no input changed');

    // One drag frame: one bearing is longer.
    rows[7] = rows[7].withRange(650);
    draw(cache, rows);
    expect(cache.recomputeCount, 21);

    // Ten more drag frames on the same bearing.
    for (var i = 1; i <= 10; i++) {
      rows[7] = rows[7].withRange(650 + i * 25.0);
      draw(cache, rows);
    }
    expect(cache.recomputeCount, 31,
        reason: 'one recompute per frame, not twenty');
    expect(cache.length, 20);
  });

  test('a longer wedge is a wider one — the half-angle is not scaled', () {
    final cache = BearingWedgeCache();
    const origin = GeoPoint(35.19, -111.62);

    List<double> spanAt(double range) {
      final pts = cache.points(
        observationId: 'obs-1',
        latitude: origin.latitude,
        longitude: origin.longitude,
        bearingDeg: 90.0,
        halfWidthDeg: 12.0,
        rangeMeters: range,
      );
      // Point 0 is the origin; the rest are the arc from bearing−12° to +12°.
      final first = distanceAndBearing(
          origin, GeoPoint(pts[1].latitude, pts[1].longitude));
      final last = distanceAndBearing(
          origin, GeoPoint(pts.last.latitude, pts.last.longitude));
      return [
        first.distanceMeters,
        last.distanceMeters,
        // Chord across the mouth of the cone.
        distanceAndBearing(GeoPoint(pts[1].latitude, pts[1].longitude),
                GeoPoint(pts.last.latitude, pts.last.longitude))
            .distanceMeters,
        first.bearingDeg,
        last.bearingDeg,
      ];
    }

    final near = spanAt(400);
    final far = spanAt(1600);

    // The radius is the number that changed.
    expect(near[0], closeTo(400, 1));
    expect(far[0], closeTo(1600, 1));
    // The half-angle did not: the edges still sit at 90°±12°.
    expect(near[3], closeTo(78.0, 0.5));
    expect(near[4], closeTo(102.0, 0.5));
    expect(far[3], closeTo(78.0, 0.5));
    expect(far[4], closeTo(102.0, 0.5));
    // Which means the cone got *wider*, in proportion — that is the honest
    // picture the task turns on, and a stretched-in-place shape would fail it.
    expect(far[2] / near[2], closeTo(4.0, 0.05));
  });
}

class WedgeArgs {
  const WedgeArgs({
    required this.observationId,
    required this.latitude,
    required this.longitude,
    required this.bearingDeg,
    required this.halfWidthDeg,
    required this.rangeMeters,
  });

  final String observationId;
  final double latitude;
  final double longitude;
  final double bearingDeg;
  final double halfWidthDeg;
  final double rangeMeters;

  WedgeArgs withRange(double range) => WedgeArgs(
        observationId: observationId,
        latitude: latitude,
        longitude: longitude,
        bearingDeg: bearingDeg,
        halfWidthDeg: halfWidthDeg,
        rangeMeters: range,
      );
}
