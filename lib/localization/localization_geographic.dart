import 'angles.dart';
import 'coordinate_projection.dart';
import 'lenth_mle.dart';
import 'localization_types.dart';

/// A geographic directional observation: observer position + a true-north
/// bearing to the signal. This is the app-facing input (Observations store
/// `true_north_bearing`); declination has already been applied upstream.
class GeographicObservation {
  const GeographicObservation({
    required this.latitude,
    required this.longitude,
    required this.trueNorthBearingDeg,
    this.id,
    this.positionAccuracyM,
  });

  final double latitude;
  final double longitude;

  /// Bearing to the signal, degrees clockwise from true north.
  final double trueNorthBearingDeg;

  final String? id;
  final double? positionAccuracyM;
}

/// Geographic localization result: the planar [LocalizationResult] with the
/// point unprojected back to lat/lon. Ellipse axes remain in meters;
/// [ellipseRotationDegrees] is the major-axis orientation as a true-north
/// bearing (degrees CW from north), ready for map rendering.
class GeographicLocalizationResult {
  const GeographicLocalizationResult({
    required this.planar,
    required this.projectionOrigin,
    required this.observationCount,
    this.latitude,
    this.longitude,
    this.ellipseSemiMajorMeters,
    this.ellipseSemiMinorMeters,
    this.ellipseRotationDegrees,
  });

  /// The underlying planar result (status, warnings, covariance, κ, etc.).
  final LocalizationResult planar;

  /// Projection origin used (centroid of observers).
  final GeoPoint projectionOrigin;

  /// How many bearings went into the solve — which is what decides *why* an
  /// estimate can have no ellipse (task 11.323): two always cross exactly.
  final int observationCount;

  final double? latitude;
  final double? longitude;

  final double? ellipseSemiMajorMeters;
  final double? ellipseSemiMinorMeters;

  /// Major-axis orientation as a compass bearing (° CW from true north).
  final double? ellipseRotationDegrees;

  LocalizationStatus get status => planar.status;
  List<GeometryWarning> get warnings => planar.warnings;
  bool get hasEstimate => latitude != null && longitude != null;

  /// A point with no ellipse: the solve found the position but could not
  /// measure its uncertainty.
  bool get hasEstimateWithoutEllipse =>
      hasEstimate && ellipseSemiMajorMeters == null;
}

/// Runs the Lenth MLE on geographic observations: projects to a local ENU
/// frame (meters), converts true-north bearings to math angles, solves, and
/// unprojects the estimate back to lat/lon.
abstract final class LenthGeographic {
  static GeographicLocalizationResult solve(
    List<GeographicObservation> observations, {
    LenthConfig config = const LenthConfig(
      // Meters-scale defaults: sub-mm convergence, flag very large ellipses.
      convergenceTolerance: 1e-4,
      coincidentEpsilon: 1.0,
      gdopSizeThreshold: 5000.0,
    ),
  }) {
    final origin = LocalTangentProjection.centroid(
      observations.map((o) => GeoPoint(o.latitude, o.longitude)),
    );
    final projection = LocalTangentProjection(origin);

    final planarObs = <PlanarObservation>[
      for (final o in observations)
        () {
          final p = projection.forward(GeoPoint(o.latitude, o.longitude));
          return PlanarObservation(
            x: p.east,
            y: p.north,
            thetaRad:
                Angles.compassDegreesToMathRadians(o.trueNorthBearingDeg),
            id: o.id,
            positionAccuracyM: o.positionAccuracyM,
          );
        }(),
    ];

    final result = LenthSolver.solve(planarObs, config: config);

    if (!result.hasEstimate) {
      return GeographicLocalizationResult(
        planar: result,
        projectionOrigin: origin,
        observationCount: observations.length,
      );
    }

    final geo = projection.inverse(PlanarPoint(result.x!, result.y!));
    // Convert ellipse major-axis orientation (math angle CCW from east, in the
    // ENU plane) to a compass bearing (CW from north).
    final rotationCompass = result.ellipse == null
        ? null
        : Angles.normalizeDegrees(90.0 - result.ellipse!.rotationDegrees);

    return GeographicLocalizationResult(
      planar: result,
      projectionOrigin: origin,
      observationCount: observations.length,
      latitude: geo.latitude,
      longitude: geo.longitude,
      ellipseSemiMajorMeters: result.ellipse?.semiMajorAxis,
      ellipseSemiMinorMeters: result.ellipse?.semiMinorAxis,
      ellipseRotationDegrees: rotationCompass,
    );
  }
}
