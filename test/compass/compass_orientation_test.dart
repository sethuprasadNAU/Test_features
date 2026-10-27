import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/compass/compass_orientation.dart';
import 'package:tritrack/localization/angles.dart';

// Device axes: +x right, +y top, +z out of screen. World: X east, Y north,
// Z up. At rest the accelerometer points up (+Z world); the geomagnetic field
// points north and down.

double? heading(List<double> m, List<double> a) =>
    CompassOrientation.tiltCompensatedHeadingDegrees(
      mx: m[0], my: m[1], mz: m[2],
      ax: a[0], ay: a[1], az: a[2],
    );

void main() {
  // Field: horizontal (north) component Bh, vertical (down) component Bv.
  const bh = 21.0; // µT north
  const bv = 47.0; // µT down (northern hemisphere)

  group('tilt-compensated heading — flat cardinal orientations', () {
    // Phone flat, screen up: accel = +z.
    final flat = [0.0, 0.0, 9.81];

    test('top pointing north → 0°', () {
      // north = device +y, down = device -z → m = (0, Bh, -Bv)
      expect(heading([0, bh, -bv], flat), closeTo(0, 1e-6));
    });
    test('top pointing east → 90°', () {
      // top=+y is east → north is device -x → m = (-Bh, 0, -Bv)
      expect(heading([-bh, 0, -bv], flat), closeTo(90, 1e-6));
    });
    test('top pointing south → 180°', () {
      // north is device -y → m = (0, -Bh, -Bv)
      expect(heading([0, -bh, -bv], flat), closeTo(180, 1e-6));
    });
    test('top pointing west → 270°', () {
      // north is device +x → m = (Bh, 0, -Bv)
      expect(heading([bh, 0, -bv], flat), closeTo(270, 1e-6));
    });
  });

  test('tilt compensation: pitching the phone up keeps heading at north', () {
    // Start flat facing north, then rotate about device x-axis by θ (pitch).
    for (final thetaDeg in [10.0, 30.0, 60.0, 80.0]) {
      final t = Angles.degToRad(thetaDeg);
      final cos = math.cos(t), sin = math.sin(t);
      // Rotate a=(0,0,1) and m=(0,Bh,-Bv) about x: (x, y c - z s, y s + z c)
      final a = [0.0, -sin, cos];
      final m = [0.0, bh * cos + bv * sin, bh * sin - bv * cos];
      expect(heading(m, a), closeTo(0, 1e-6),
          reason: 'pitch $thetaDeg° should not change heading');
    }
  });

  test('degenerate inputs return null (no crash)', () {
    expect(heading([0, bh, -bv], [0, 0, 0]), isNull); // no gravity
    expect(heading([0, 0, 9.81], [0, 0, 9.81]), isNull); // field ∥ gravity
  });

  group('bubble level', () {
    test('flat phone reads level with zero tilt', () {
      final lvl = BubbleLevel.fromAccelerometer(ax: 0, ay: 0, az: 9.81);
      expect(lvl.tiltMagnitudeDegrees, closeTo(0, 1e-6));
      expect(lvl.isLevel(), isTrue);
      expect(lvl.offsetX, closeTo(0, 1e-9));
      expect(lvl.offsetY, closeTo(0, 1e-9));
    });

    test('30° forward tilt is detected and not level', () {
      final t = Angles.degToRad(30);
      final lvl = BubbleLevel.fromAccelerometer(
          ax: 0, ay: 9.81 * math.sin(t), az: 9.81 * math.cos(t));
      expect(lvl.tiltMagnitudeDegrees, closeTo(30, 1e-4));
      expect(lvl.pitchDegrees, closeTo(30, 1e-4));
      expect(lvl.isLevel(), isFalse);
      expect(lvl.offsetY, greaterThan(0));
    });

    test('small tilt within threshold still counts as level', () {
      final t = Angles.degToRad(2);
      final lvl = BubbleLevel.fromAccelerometer(
          ax: 9.81 * math.sin(t), ay: 0, az: 9.81 * math.cos(t));
      expect(lvl.isLevel(thresholdDegrees: 4), isTrue);
    });
  });
}
