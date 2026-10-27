import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/angles.dart';
import 'package:tritrack/localization/bearing_intersections.dart';
import 'package:tritrack/localization/localization_types.dart';

PlanarObservation ray(double x, double y, double mathDeg) => PlanarObservation(
      x: x,
      y: y,
      thetaRad: Angles.degToRad(mathDeg),
    );

void main() {
  test('two crossing rays intersect at the expected point', () {
    // A from origin heading NE, B from (10,0) heading NW → cross at (5,5).
    final hits = BearingIntersections.all([ray(0, 0, 45), ray(10, 0, 135)]);
    expect(hits, hasLength(1));
    expect(hits.first.x, closeTo(5, 1e-9));
    expect(hits.first.y, closeTo(5, 1e-9));
  });

  test('parallel rays do not intersect', () {
    final hits = BearingIntersections.all([ray(0, 0, 45), ray(1, 1, 45)]);
    expect(hits, isEmpty);
  });

  test('crossing behind a ray origin is excluded by default, kept if asked', () {
    // A at origin heading WEST (−x); B at (10,0) heading north. Lines meet at
    // (10,0), but that is behind A (needs negative travel).
    final a = ray(0, 0, 180);
    final b = ray(10, 0, 90);
    expect(BearingIntersections.all([a, b]), isEmpty);
    final withBehind =
        BearingIntersections.all([a, b], includeBehind: true);
    expect(withBehind, hasLength(1));
    expect(withBehind.first.x, closeTo(10, 1e-9));
    expect(withBehind.first.y, closeTo(0, 1e-9));
  });

  test('centroid of intersections averages the points', () {
    final c = BearingIntersections.centroid(const [
      BearingIntersection(x: 0, y: 0, indexA: 0, indexB: 1),
      BearingIntersection(x: 4, y: 2, indexA: 0, indexB: 2),
    ]);
    expect(c!.$1, closeTo(2, 1e-9));
    expect(c.$2, closeTo(1, 1e-9));
  });

  test('intersection centroid of the clean Lenth data sits near the MLE', () {
    // Same 7-observation clean data as the MLE test; the mean of pairwise
    // intersections should land in the vicinity of the MLE (7.23, 1.98).
    final obs = <PlanarObservation>[
      ray(9.0, 3.2, 90 - 234),
      ray(9.4, 5.5, 90 - 215),
      ray(9.95, 9.05, 90 - 196),
      ray(8.7, 8.7, 90 - 193),
      ray(8.07, 9.7, 90 - 188),
      ray(4.4, 8.9, 90 - 160),
      ray(1.85, 5.25, 90 - 118),
    ];
    final centroid = BearingIntersections.centroid(
      BearingIntersections.all(obs),
    );
    expect(centroid, isNotNull);
    expect(centroid!.$1, closeTo(7.4, 1.5));
    expect(centroid.$2, closeTo(2.1, 1.5));
  });
}
