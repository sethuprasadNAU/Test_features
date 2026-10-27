import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/angles.dart';

void main() {
  group('normalization', () {
    test('normalizeDegrees wraps into [0, 360)', () {
      expect(Angles.normalizeDegrees(370), closeTo(10, 1e-9));
      expect(Angles.normalizeDegrees(-10), closeTo(350, 1e-9));
      expect(Angles.normalizeDegrees(360), closeTo(0, 1e-9));
      expect(Angles.normalizeDegrees(0), closeTo(0, 1e-9));
    });
  });

  group('shortest difference across the 0/360 seam', () {
    test('350 -> 10 is +20 (clockwise), not -340', () {
      expect(Angles.shortestDifferenceDegrees(350, 10), closeTo(20, 1e-9));
    });
    test('10 -> 350 is -20', () {
      expect(Angles.shortestDifferenceDegrees(10, 350), closeTo(-20, 1e-9));
    });
    test('opposite bearings differ by 180', () {
      expect(Angles.shortestDifferenceDegrees(0, 180).abs(), closeTo(180, 1e-9));
    });
  });

  group('compass <-> math conversion (Lenth §1)', () {
    test('north (0° compass) maps to +90° math (points +y)', () {
      expect(Angles.compassDegreesToMathRadians(0),
          closeTo(Angles.degToRad(90), 1e-12));
    });
    test('east (90° compass) maps to 0 rad (points +x)', () {
      expect(Angles.compassDegreesToMathRadians(90), closeTo(0, 1e-12));
    });
    test('round-trips', () {
      for (final b in [0.0, 37.0, 90.0, 145.0, 234.0, 359.0]) {
        final round = Angles.mathRadiansToCompassDegrees(
            Angles.compassDegreesToMathRadians(b));
        expect(round, closeTo(b, 1e-9), reason: 'bearing $b');
      }
    });
  });

  group('circular mean', () {
    test('mean of 350 and 10 is 0, not 180', () {
      // Compare circularly: 0° ≡ 360°.
      final m = Angles.circularMeanDegrees([350, 10])!;
      expect(Angles.shortestDifferenceDegrees(m, 0).abs(), lessThan(1e-9));
    });
    test('mean of 10 and 50 is 30', () {
      expect(Angles.circularMeanDegrees([10, 50]), closeTo(30, 1e-9));
    });
    test('diametrically opposed bearings return null (undefined mean)', () {
      expect(Angles.circularMeanDegrees([0, 180]), isNull);
    });
    test('empty returns null', () {
      expect(Angles.circularMeanDegrees(const []), isNull);
    });
  });

  group('mean resultant length', () {
    test('identical bearings give R̄ = 1', () {
      expect(Angles.meanResultantLength([45, 45, 45]), closeTo(1, 1e-9));
    });
    test('opposed bearings give R̄ = 0', () {
      expect(Angles.meanResultantLength([0, 180]), closeTo(0, 1e-9));
    });
  });

  group('range capture (the signature 350->10 case)', () {
    test('350 -> 10 sweep yields 0° ± 10°', () {
      final r = rangeCaptureBearing(350, 10);
      expect(r.midpointDegrees, closeTo(0, 1e-9));
      expect(r.halfWidthDegrees, closeTo(10, 1e-9));
    });
    test('10 -> 350 sweep also yields 0° ± 10°', () {
      final r = rangeCaptureBearing(10, 350);
      expect(r.midpointDegrees, closeTo(0, 1e-9));
      expect(r.halfWidthDegrees, closeTo(10, 1e-9));
    });
    test('140 -> 150 yields 145° ± 5°', () {
      final r = rangeCaptureBearing(140, 150);
      expect(r.midpointDegrees, closeTo(145, 1e-9));
      expect(r.halfWidthDegrees, closeTo(5, 1e-9));
    });
    test('a ~180° sweep is flagged ambiguous', () {
      expect(rangeCaptureIsAmbiguous(0, 180), isTrue);
      expect(rangeCaptureIsAmbiguous(350, 10), isFalse);
    });
  });
}
