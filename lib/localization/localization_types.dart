import 'dart:math' as math;

/// A single directional bearing for the planar Lenth solver.
///
/// Coordinates are planar in consistent units (meters in the app, after
/// projection; arbitrary map units in the paper's worked example). [thetaRad]
/// is a math-convention angle (radians CCW from the +x/east axis) — convert
/// compass/true-north bearings with `Angles.compassDegreesToMathRadians`
/// before constructing.
class PlanarObservation {
  const PlanarObservation({
    required this.x,
    required this.y,
    required this.thetaRad,
    this.id,
    this.positionAccuracyM,
  });

  final double x;
  final double y;
  final double thetaRad;

  /// Optional identifier, echoed into diagnostics (e.g. flagged observations).
  final String? id;

  /// Optional GPS horizontal accuracy (m). Lenth assumes known observer
  /// positions; a large value is flagged so the user knows the true error is
  /// understated.
  final double? positionAccuracyM;
}

/// Why an estimate is degraded or was refused. Surfaced to the UI so the user
/// understands *why* geometry is poor and can reposition — never a silent bad
/// fix. See Lenth (1981) §2 (diagonal dominance / "one side" problem) and the
/// technical doc's degenerate-geometry checklist.
enum GeometryWarning {
  /// Only one bearing — cannot triangulate; render the ray only.
  singleBearing,

  /// No bearings supplied.
  noObservations,

  /// All observer positions coincide (no baseline) — no triangulation info.
  coincidentObservers,

  /// Bearings are (nearly) parallel — intersection ill-conditioned.
  nearParallel,

  /// A linear system in the solve/covariance was (near-)singular; result
  /// clamped/refused rather than emitting NaN/inf.
  nearSingular,

  /// Poor geometry (high GDOP): ellipse very large and/or highly elongated.
  highGdop,

  /// One or more observations have large position uncertainty; the reported
  /// error understates the true error (Lenth assumes exact observer positions).
  largePositionUncertainty,

  /// The solver hit its iteration cap without fully converging.
  didNotConverge,
}

/// Overall outcome of a localization attempt.
enum LocalizationStatus {
  /// A point estimate (and, where computable, an ellipse) was produced.
  estimated,

  /// Exactly one bearing — only a ray can be drawn.
  singleBearing,

  /// Geometry too degenerate to estimate (see [LocalizationResult.warnings]).
  refused,
}

/// Uncertainty ellipse from the MLE covariance. Axes are in the solver's
/// coordinate units (meters in the app); [rotationDegrees] is CCW from the
/// +x/east axis. [confidence] is the coverage the axes are scaled to
/// (e.g. 0.95); the underlying 1σ covariance is in [LocalizationResult].
class UncertaintyEllipse {
  const UncertaintyEllipse({
    required this.semiMajorAxis,
    required this.semiMinorAxis,
    required this.rotationDegrees,
    required this.confidence,
  });

  final double semiMajorAxis;
  final double semiMinorAxis;
  final double rotationDegrees;
  final double confidence;

  /// Elongation (major/minor); large values indicate poor geometry.
  double get axisRatio =>
      semiMinorAxis <= 0 ? double.infinity : semiMajorAxis / semiMinorAxis;
}

/// 1σ covariance of the estimate, `[[xx, xy], [xy, yy]]`, plus the derived
/// standard errors and correlation (these are what Lenth's Table 2 reports,
/// so they are the primary validation surface).
class EstimateCovariance {
  const EstimateCovariance({
    required this.xx,
    required this.yy,
    required this.xy,
  });

  final double xx;
  final double yy;
  final double xy;

  double get seX => math.sqrt(xx);
  double get seY => math.sqrt(yy);
  double get correlation {
    final denom = seX * seY;
    return denom == 0 ? 0 : xy / denom;
  }
}

/// Full result of a localization attempt. Immutable; never contains NaN/inf —
/// degenerate inputs yield [LocalizationStatus.refused] (or `singleBearing`)
/// with explanatory [warnings] instead.
class LocalizationResult {
  const LocalizationResult({
    required this.status,
    this.x,
    this.y,
    this.ellipse,
    this.covariance,
    this.kappa,
    this.meanResultantLength,
    this.iterations = 0,
    this.warnings = const [],
    this.flaggedObservationIds = const [],
  });

  final LocalizationStatus status;

  /// Estimated location (planar units); null when refused / single-bearing.
  final double? x;
  final double? y;

  final UncertaintyEllipse? ellipse;
  final EstimateCovariance? covariance;

  /// Estimated von Mises concentration (higher = tighter bearings).
  final double? kappa;

  /// Mean resultant length of the bearing residuals at the solution
  /// (agreement measure, [0, 1]).
  final double? meanResultantLength;

  final int iterations;
  final List<GeometryWarning> warnings;
  final List<String> flaggedObservationIds;

  bool get hasEstimate => x != null && y != null;
  bool hasWarning(GeometryWarning w) => warnings.contains(w);

  LocalizationResult copyWith({
    UncertaintyEllipse? ellipse,
    EstimateCovariance? covariance,
    double? kappa,
    double? meanResultantLength,
    List<GeometryWarning>? warnings,
    List<String>? flaggedObservationIds,
  }) {
    return LocalizationResult(
      status: status,
      x: x,
      y: y,
      ellipse: ellipse ?? this.ellipse,
      covariance: covariance ?? this.covariance,
      kappa: kappa ?? this.kappa,
      meanResultantLength: meanResultantLength ?? this.meanResultantLength,
      iterations: iterations,
      warnings: warnings ?? this.warnings,
      flaggedObservationIds: flaggedObservationIds ?? this.flaggedObservationIds,
    );
  }
}
