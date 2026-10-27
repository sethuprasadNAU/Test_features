import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/geo_math.dart';
import 'package:tritrack/localization/coordinate_projection.dart';

void main() {
  group('destinationPoint / distanceAndBearing round-trip', () {
    test('destinationPoint then distanceAndBearing recovers bearing and distance', () {
      const start = GeoPoint(35.19, -111.62);
      const bearing = 63.0;
      const distance = 2500.0;

      final dest = destinationPoint(start, bearing, distance);
      final result = distanceAndBearing(start, dest);

      expect(result.distanceMeters, closeTo(distance, 0.5));
      expect(result.bearingDeg, closeTo(bearing, 0.01));
    });

    test('round-trips across a bearing that crosses the 0/360 seam', () {
      const start = GeoPoint(35.19, -111.62);
      const bearing = 355.0;
      const distance = 1000.0;

      final dest = destinationPoint(start, bearing, distance);
      final result = distanceAndBearing(start, dest);

      expect(result.distanceMeters, closeTo(distance, 0.5));
      expect(result.bearingDeg, closeTo(bearing, 0.01));
    });
  });

  group('distanceAndBearing — known references', () {
    test('one degree of latitude north is ~111.2 km, bearing 0 (due north)', () {
      const a = GeoPoint(35.0, -111.0);
      const b = GeoPoint(36.0, -111.0);
      final result = distanceAndBearing(a, b);
      expect(result.distanceMeters, closeTo(111195, 500));
      expect(result.bearingDeg, closeTo(0, 0.1));
    });

    test('due east along the equator: bearing 90', () {
      const a = GeoPoint(0.0, 0.0);
      const b = GeoPoint(0.0, 1.0);
      final result = distanceAndBearing(a, b);
      expect(result.bearingDeg, closeTo(90, 0.1));
    });

    test('due south: bearing 180', () {
      const a = GeoPoint(35.0, -111.0);
      const b = GeoPoint(34.0, -111.0);
      final result = distanceAndBearing(a, b);
      expect(result.bearingDeg, closeTo(180, 0.1));
    });

    test('due west: bearing 270', () {
      const a = GeoPoint(35.0, -111.0);
      const b = GeoPoint(35.0, -112.0);
      final result = distanceAndBearing(a, b);
      expect(result.bearingDeg, closeTo(270, 0.5));
    });

    test('identical points have zero distance and a defined (non-NaN) bearing', () {
      const p = GeoPoint(35.0, -111.0);
      final result = distanceAndBearing(p, p);
      expect(result.distanceMeters, closeTo(0, 1e-6));
      expect(result.bearingDeg.isNaN, isFalse);
    });
  });
}
