import 'dart:math' as math;

import '../localization/angles.dart';

/// Device-frame sensor-fusion math for the compass. Pure functions over raw
/// accelerometer/magnetometer vectors (device axes: +x right, +y top of
/// screen, +z out of the screen toward the user), so they are fully testable
/// against synthetic orientations without a device.
///
/// Heading is computed with **tilt compensation** (using gravity from the
/// accelerometer), so the reading stays correct when the phone is not held
/// flat — a naive `atan2(my, mx)` drifts badly with tilt. This is the
/// "sensor fusion" the field posture demands (users rarely hold the phone
/// level while sighting along an antenna).
abstract final class CompassOrientation {
  /// Tilt-compensated compass heading (° CW from magnetic north) of the
  /// device's +y axis (top edge). Returns null if the inputs are degenerate
  /// (zero acceleration, or magnetic field parallel to gravity — no horizontal
  /// reference).
  ///
  /// Method: build the world axes in the device frame — up = â (normalized
  /// accelerometer), east = m × up, north = up × east — then read the heading
  /// of the device +y axis as atan2(east·ŷ, north·ŷ).
  static double? tiltCompensatedHeadingDegrees({
    required double mx,
    required double my,
    required double mz,
    required double ax,
    required double ay,
    required double az,
  }) {
    final aNorm = math.sqrt(ax * ax + ay * ay + az * az);
    if (aNorm == 0) return null;
    final ux = ax / aNorm, uy = ay / aNorm, uz = az / aNorm;

    // east = m × up
    var ex = my * uz - mz * uy;
    var ey = mz * ux - mx * uz;
    var ez = mx * uy - my * ux;
    final eNorm = math.sqrt(ex * ex + ey * ey + ez * ez);
    if (eNorm < 1e-9) return null; // field parallel to gravity
    ex /= eNorm;
    ey /= eNorm;
    ez /= eNorm;

    // north = up × east (components in device frame)
    final ny = uz * ex - ux * ez;

    // Heading of the device +y axis: how far east-of-north it points.
    final heading = math.atan2(ey, ny) * 180.0 / math.pi;
    return Angles.normalizeDegrees(heading);
  }
}

/// Bubble-level state derived from the accelerometer. When the phone is flat
/// (screen up) the tilt is ~0 and [offsetX]/[offsetY] (the horizontal
/// components of the "up" direction) are ~0 — drive a bubble graphic directly
/// from those.
class BubbleLevel {
  const BubbleLevel({
    required this.pitchDegrees,
    required this.rollDegrees,
    required this.tiltMagnitudeDegrees,
    required this.offsetX,
    required this.offsetY,
  });

  /// Front/back tilt (° about the device x-axis).
  final double pitchDegrees;

  /// Left/right tilt (° about the device y-axis).
  final double rollDegrees;

  /// Total tilt from flat (° between "up" and the screen normal).
  final double tiltMagnitudeDegrees;

  /// Normalized horizontal offset of the up-vector (bubble position), each in
  /// roughly [-1, 1]; (0, 0) when perfectly level.
  final double offsetX;
  final double offsetY;

  /// Whether the phone is level within [thresholdDegrees].
  bool isLevel({double thresholdDegrees = 4.0}) =>
      tiltMagnitudeDegrees <= thresholdDegrees;

  factory BubbleLevel.fromAccelerometer({
    required double ax,
    required double ay,
    required double az,
  }) {
    final n = math.sqrt(ax * ax + ay * ay + az * az);
    if (n == 0) {
      return const BubbleLevel(
        pitchDegrees: 0,
        rollDegrees: 0,
        tiltMagnitudeDegrees: 0,
        offsetX: 0,
        offsetY: 0,
      );
    }
    final ux = ax / n, uy = ay / n, uz = az / n;
    final clampedUz = uz.clamp(-1.0, 1.0);
    final tilt = math.acos(clampedUz) * 180.0 / math.pi;
    final pitch = math.atan2(uy, uz) * 180.0 / math.pi;
    final roll = math.atan2(ux, uz) * 180.0 / math.pi;
    return BubbleLevel(
      pitchDegrees: pitch,
      rollDegrees: roll,
      tiltMagnitudeDegrees: tilt,
      offsetX: ux,
      offsetY: uy,
    );
  }
}
