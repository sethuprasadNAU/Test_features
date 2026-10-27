import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/scale_bar_math.dart';

void main() {
  group('ScaleBarMath.metersPerPixel', () {
    test('at the equator, zoom 0 matches the standard 156543m/px constant', () {
      expect(ScaleBarMath.metersPerPixel(0, 0), closeTo(156543.03392, 0.01));
    });

    test('doubles the zoom level, halves the resolution', () {
      final z10 = ScaleBarMath.metersPerPixel(0, 10);
      final z11 = ScaleBarMath.metersPerPixel(0, 11);
      expect(z11, closeTo(z10 / 2, 1e-6));
    });

    test('resolution gets finer moving away from the equator (cos(lat) term)', () {
      final atEquator = ScaleBarMath.metersPerPixel(0, 10);
      final at60 = ScaleBarMath.metersPerPixel(60, 10);
      expect(at60, lessThan(atEquator));
      expect(at60, closeTo(atEquator * 0.5, atEquator * 0.01)); // cos(60°) = 0.5
    });
  });

  group('ScaleBarMath.pick', () {
    test('picks a bar that never exceeds the max pixel width', () {
      for (final zoom in [2.0, 8.0, 14.0, 18.0, 21.0]) {
        final spec = ScaleBarMath.pick(latitudeDeg: 35, zoom: zoom, maxWidthPx: 100);
        expect(spec.pixelWidth, lessThanOrEqualTo(100.001));
      }
    });

    test('picks the largest nice value that fits, not just any that fits', () {
      // At a resolution where 100m fits in <=100px but 200m does not.
      final spec = ScaleBarMath.pick(latitudeDeg: 0, zoom: 16, maxWidthPx: 120);
      final mpp = ScaleBarMath.metersPerPixel(0, 16);
      expect(spec.meters / mpp, lessThanOrEqualTo(120.001));
      // The next-larger nice step must NOT have fit (else it should have been chosen).
      final niceSteps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000];
      final nextIndex = niceSteps.indexOf(spec.meters.round()) + 1;
      if (nextIndex < niceSteps.length) {
        expect(niceSteps[nextIndex] / mpp, greaterThan(120));
      }
    });

    test('labels sub-kilometer distances in meters, kilometer+ in km', () {
      expect(ScaleBarMath.pick(latitudeDeg: 0, zoom: 20, maxWidthPx: 100).label, endsWith(' m'));
      expect(ScaleBarMath.pick(latitudeDeg: 0, zoom: 2, maxWidthPx: 100).label, endsWith(' km'));
    });

    test('a whole number of km renders with no decimal point', () {
      // mpp(0, 5) ≈ 4892 m/px, so a 100px budget ≈ 489197m → picks 200000m.
      expect(ScaleBarMath.pick(latitudeDeg: 0, zoom: 5, maxWidthPx: 100).label, '200 km');
      // mpp(0, 2) ≈ 39136 m/px → budget ≈ 3913576m → picks 2000000m.
      expect(ScaleBarMath.pick(latitudeDeg: 0, zoom: 2, maxWidthPx: 100).label, '2000 km');
    });
  });
}
