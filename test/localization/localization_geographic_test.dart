import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/angles.dart';
import 'package:tritrack/localization/coordinate_projection.dart';
import 'package:tritrack/localization/localization_geographic.dart';
import 'package:tritrack/localization/localization_types.dart';

/// Computes the true-north bearing from an observer to a target that is exactly
/// consistent with the app's projection, so a noise-free solve recovers the
/// target. (Uses the observers' own centroid as origin, matching the solver.)
double consistentBearing(
  LocalTangentProjection proj,
  GeoPoint observer,
  GeoPoint target,
) {
  final o = proj.forward(observer);
  final t = proj.forward(target);
  final mathRad = math.atan2(t.north - o.north, t.east - o.east);
  return Angles.mathRadiansToCompassDegrees(mathRad);
}

void main() {
  // A target surrounded by four observers near Flagstaff.
  const target = GeoPoint(35.2000, -111.6500);
  const observerPositions = [
    GeoPoint(35.1820, -111.6800),
    GeoPoint(35.2180, -111.6800),
    GeoPoint(35.2180, -111.6200),
    GeoPoint(35.1820, -111.6200),
  ];

  // Origin the solver will use (observer centroid) → build bearings against it.
  final origin = LocalTangentProjection.centroid(observerPositions);
  final projection = LocalTangentProjection(origin);

  test('recovers a surrounded target from consistent bearings', () {
    // Small symmetric perturbation so κ is finite and an ellipse is produced.
    const perturb = [0.4, -0.4, 0.4, -0.4];
    final obs = <GeographicObservation>[
      for (var i = 0; i < observerPositions.length; i++)
        GeographicObservation(
          latitude: observerPositions[i].latitude,
          longitude: observerPositions[i].longitude,
          trueNorthBearingDeg:
              consistentBearing(projection, observerPositions[i], target) +
                  perturb[i],
          id: 'o$i',
        ),
    ];

    final result = LenthGeographic.solve(obs);

    expect(result.status, LocalizationStatus.estimated);
    expect(result.hasEstimate, isTrue);
    // Within ~60 m of the true target despite the perturbation.
    expect(result.latitude, closeTo(target.latitude, 6e-4));
    expect(result.longitude, closeTo(target.longitude, 6e-4));

    // A finite, positive ellipse with a compass-oriented major axis.
    expect(result.ellipseSemiMajorMeters, isNotNull);
    expect(result.ellipseSemiMajorMeters!.isFinite, isTrue);
    expect(result.ellipseSemiMajorMeters!, greaterThan(0));
    expect(result.ellipseRotationDegrees, inInclusiveRange(0, 360));
    expect(result.warnings, isNot(contains(GeometryWarning.highGdop)));
  });

  test('single observation propagates as single-bearing', () {
    final result = LenthGeographic.solve([
      const GeographicObservation(
        latitude: 35.2,
        longitude: -111.65,
        trueNorthBearingDeg: 45,
        id: 'solo',
      ),
    ]);
    expect(result.status, LocalizationStatus.singleBearing);
    expect(result.hasEstimate, isFalse);
  });
}
