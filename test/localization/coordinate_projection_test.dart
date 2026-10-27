import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/coordinate_projection.dart';

void main() {
  const flagstaff = GeoPoint(35.1983, -111.6513);
  final projection = LocalTangentProjection(flagstaff);

  test('origin projects to (0, 0)', () {
    final p = projection.forward(flagstaff);
    expect(p.east, closeTo(0, 1e-6));
    expect(p.north, closeTo(0, 1e-6));
  });

  test('forward/inverse round-trips to sub-millimeter over a few km', () {
    const points = [
      GeoPoint(35.21, -111.63),
      GeoPoint(35.18, -111.67),
      GeoPoint(35.2050, -111.6600),
    ];
    for (final p in points) {
      final round = projection.inverse(projection.forward(p));
      expect(round.latitude, closeTo(p.latitude, 1e-9));
      expect(round.longitude, closeTo(p.longitude, 1e-9));
    }
  });

  test('one degree of latitude north is ~111 km of northing', () {
    final p = projection.forward(GeoPoint(flagstaff.latitude + 1, flagstaff.longitude));
    final expected = LocalTangentProjection.earthRadiusMeters * math.pi / 180.0;
    expect(p.north, closeTo(expected, 1.0));
    expect(p.east, closeTo(0, 1e-6));
  });

  test('easting shrinks by cos(latitude)', () {
    final p = projection.forward(GeoPoint(flagstaff.latitude, flagstaff.longitude + 1));
    final expected = LocalTangentProjection.earthRadiusMeters *
        math.pi /
        180.0 *
        math.cos(flagstaff.latitude * math.pi / 180.0);
    expect(p.east, closeTo(expected, 1.0));
  });

  test('centroid averages positions', () {
    final c = LocalTangentProjection.centroid(const [
      GeoPoint(35.0, -111.0),
      GeoPoint(37.0, -113.0),
    ]);
    expect(c.latitude, closeTo(36.0, 1e-9));
    expect(c.longitude, closeTo(-112.0, 1e-9));
  });
}
