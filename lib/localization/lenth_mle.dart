import 'dart:math' as math;

import 'angles.dart';
import 'localization_types.dart';

/// Tunable thresholds and stopping criteria for [LenthSolver]. Defaults suit
/// the paper's worked example (planar units ~1–10); the geographic wrapper
/// overrides the unit-dependent ones (tolerance, GDOP size) for meters.
class LenthConfig {
  const LenthConfig({
    this.maxIterations = 200,
    this.convergenceTolerance = 1e-7,
    this.coincidentEpsilon = 1e-9,
    this.nearParallelDegrees = 2.0,
    this.singularEpsilon = 1e-12,
    this.gdopAxisRatioThreshold = 10.0,
    this.gdopSizeThreshold,
    this.positionAccuracyFlagMeters = 20.0,
    this.confidence = 0.95,
  });

  /// Iteration cap for the fixed-point solve.
  final int maxIterations;

  /// Convergence tolerance on the coordinate step (solver units).
  final double convergenceTolerance;

  /// Max pairwise observer separation below which observers are "coincident".
  final double coincidentEpsilon;

  /// Angular spread (°) below which bearings are treated as near-parallel.
  final double nearParallelDegrees;

  /// |det| below which a 2×2 system is treated as singular.
  final double singularEpsilon;

  /// Ellipse major/minor ratio above which geometry is flagged high-GDOP.
  final double gdopAxisRatioThreshold;

  /// Optional absolute semi-major-axis size (solver units) above which
  /// geometry is flagged high-GDOP. Null disables the size check.
  final double? gdopSizeThreshold;

  /// position_accuracy_m above which an observation is flagged.
  final double positionAccuracyFlagMeters;

  /// Coverage the returned ellipse axes are scaled to.
  final double confidence;
}

/// One step of the solver's search, as it happened — task 11.336. For the
/// guide's pictures of how the estimate is found; the solver does not read it.
class LenthStep {
  const LenthStep({
    required this.number,
    required this.fromX,
    required this.fromY,
    required this.fullStepX,
    required this.fullStepY,
    required this.fraction,
    required this.toX,
    required this.toY,
    required this.sumCosine,
    required this.converged,
    required this.rejected,
  });

  /// 1 for the first step.
  final int number;

  /// Where the estimate stood before the step.
  final double fromX, fromY;

  /// Where Eq. 2.6 pointed — the whole step.
  final double fullStepX, fullStepY;

  /// How much of the whole step was taken: 1 when all of it, 1/2, 1/4, … when
  /// it was **shortened** because the whole step made the fit worse.
  final double fraction;

  /// Where the estimate stood afterward (the same as `from` when [rejected]).
  final double toX, toY;

  /// Σ cos(θᵢ − μᵢ) at `to` — the fit the solver is maximizing, up to the
  /// constant factor κ, which does not move the maximum.
  final double sumCosine;

  /// Whether the whole step was smaller than the convergence tolerance, which
  /// ends the search (the last step of a converged solve).
  final bool converged;

  /// Whether no shortening made the fit better, so the solver stopped without
  /// moving (it then reports `didNotConverge`).
  final bool rejected;

  bool get shortened => fraction < 1;
}

/// A record of one [LenthSolver.solve] call, filled in when the caller passes
/// one — task 11.336. Pure observation: **passing a trace changes no result**
/// (`lenth_mle_test.dart` pins that), it only keeps what the solver already
/// computed so a picture of the search need not re-implement it.
class LenthTrace {
  /// Where the search began: the least-squares intersection of the bearing
  /// lines.
  double? startX, startY, startSumCosine;

  final List<LenthStep> steps = [];

  /// The mean cosine of the leftover angles at the estimate — the number κ is
  /// computed from — and each bearing's leftover angle θᵢ − μᵢ in radians, in
  /// the order the observations were given, in (−π, π].
  double? meanCosine;
  List<double> leftoverAnglesRad = const [];
}

/// Lenth (1981) maximum-likelihood source-location estimator for the "clean
/// data" (unidirectional, unbiased) case, with the paper's iterative linear
/// solution (Eq. 2.6), von Mises concentration estimate (§2, Eq. 2.10 intent),
/// and covariance/uncertainty ellipse (Eqs. 2.7–2.9).
///
/// Pure and planar: it takes [PlanarObservation]s in consistent units and
/// returns a [LocalizationResult] that never carries NaN/inf — every
/// degenerate geometry is guarded before it can divide by zero.
abstract final class LenthSolver {
  static LocalizationResult solve(
    List<PlanarObservation> observations, {
    LenthConfig config = const LenthConfig(),
    LenthTrace? trace,
  }) {
    final n = observations.length;
    if (n == 0) {
      return const LocalizationResult(
        status: LocalizationStatus.refused,
        warnings: [GeometryWarning.noObservations],
      );
    }
    if (n == 1) {
      // Cannot triangulate — the caller renders the single bearing as a ray.
      return const LocalizationResult(
        status: LocalizationStatus.singleBearing,
        warnings: [GeometryWarning.singleBearing],
      );
    }

    // --- Guard: coincident observers (no baseline). ---
    if (_maxPairwiseDistance(observations) < config.coincidentEpsilon) {
      return const LocalizationResult(
        status: LocalizationStatus.refused,
        warnings: [GeometryWarning.coincidentObservers],
      );
    }

    // --- Guard: near-parallel bearings (ill-conditioned intersection). ---
    final bearingSpreadDeg = _bearingSpreadDegrees(observations);
    final nearParallel = bearingSpreadDeg < config.nearParallelDegrees;

    // Precompute per-observation trig constants.
    final s = List<double>.filled(n, 0);
    final c = List<double>.filled(n, 0);
    final z = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      s[i] = math.sin(observations[i].thetaRad);
      c[i] = math.cos(observations[i].thetaRad);
      z[i] = s[i] * observations[i].x - c[i] * observations[i].y;
    }

    // --- Starting estimate: least-squares bearing-line intersection ---
    // (Eq. 2.6 with the asterisks dropped, i.e. all d_i = 1).
    final start = _solveLinear(
      _sum(n, (i) => s[i] * s[i]),
      -_sum(n, (i) => c[i] * s[i]),
      _sum(n, (i) => s[i] * c[i]),
      -_sum(n, (i) => c[i] * c[i]),
      _sum(n, (i) => s[i] * z[i]),
      _sum(n, (i) => c[i] * z[i]),
      config.singularEpsilon,
    );
    if (start == null) {
      // Degenerate starting geometry (e.g. exactly parallel bearings).
      return LocalizationResult(
        status: LocalizationStatus.refused,
        warnings: [
          if (nearParallel) GeometryWarning.nearParallel,
          GeometryWarning.nearSingular,
        ],
      );
    }

    // --- Iterate Eq. 2.6 to the MLE ---
    //
    // **Each Eq. 2.6 step is taken only as far as it makes the estimate more
    // likely (task 11.323).** Applied as a plain fixed-point step it can
    // overshoot and cycle: five field bearings with a 47° outlier wandered
    // for 1,000 steps without settling, and the point it stopped at was
    // about 390 m from the maximum-likelihood point and less likely. Lenth's
    // own example never needs the halving — every full step there already
    // raises the likelihood — so its answer and step count are unchanged.
    //
    // Convergence is judged on the **full** step: a point Eq. 2.6 maps to
    // itself is the MLE the paper defines, whereas a short halved step would
    // only say the search had slowed down.
    var x = start.$1;
    var y = start.$2;
    var logLik = _logLikelihood(observations, x, y);
    if (trace != null) {
      trace.startX = x;
      trace.startY = y;
      trace.startSumCosine = logLik;
    }
    var iterations = 0;
    var converged = false;
    for (var iter = 0; iter < config.maxIterations; iter++) {
      iterations = iter + 1;
      final step = _iterate(observations, s, c, z, x, y, config.singularEpsilon);
      if (step == null) {
        return LocalizationResult(
          status: LocalizationStatus.refused,
          warnings: [
            if (nearParallel) GeometryWarning.nearParallel,
            GeometryWarning.nearSingular,
          ],
        );
      }
      final dx = step.$1 - x;
      final dy = step.$2 - y;
      if (dx.abs() < config.convergenceTolerance &&
          dy.abs() < config.convergenceTolerance) {
        trace?.steps.add(LenthStep(
          number: iterations,
          fromX: x,
          fromY: y,
          fullStepX: step.$1,
          fullStepY: step.$2,
          fraction: 1.0,
          toX: step.$1,
          toY: step.$2,
          sumCosine: _logLikelihood(observations, step.$1, step.$2),
          converged: true,
          rejected: false,
        ));
        x = step.$1;
        y = step.$2;
        converged = true;
        break;
      }
      var fraction = 1.0;
      var nextX = step.$1;
      var nextY = step.$2;
      var nextLogLik = _logLikelihood(observations, nextX, nextY);
      for (var halving = 0;
          halving < _maxStepHalvings && nextLogLik < logLik;
          halving++) {
        fraction /= 2;
        nextX = x + fraction * dx;
        nextY = y + fraction * dy;
        nextLogLik = _logLikelihood(observations, nextX, nextY);
      }
      // No step along Eq. 2.6's direction improves the fit: stop here, and
      // say so with `didNotConverge` rather than move somewhere worse.
      if (nextLogLik < logLik) {
        trace?.steps.add(LenthStep(
          number: iterations,
          fromX: x,
          fromY: y,
          fullStepX: step.$1,
          fullStepY: step.$2,
          fraction: fraction,
          toX: x,
          toY: y,
          sumCosine: logLik,
          converged: false,
          rejected: true,
        ));
        break;
      }
      trace?.steps.add(LenthStep(
        number: iterations,
        fromX: x,
        fromY: y,
        fullStepX: step.$1,
        fullStepY: step.$2,
        fraction: fraction,
        toX: nextX,
        toY: nextY,
        sumCosine: nextLogLik,
        converged: false,
        rejected: false,
      ));
      x = nextX;
      y = nextY;
      logLik = nextLogLik;
    }

    final warnings = <GeometryWarning>[
      if (nearParallel) GeometryWarning.nearParallel,
      if (!converged) GeometryWarning.didNotConverge,
    ];

    // --- Concentration κ and covariance (Eqs. 2.7–2.10) at the MLE ---
    final concentration = _estimateConcentration(observations, x, y);
    if (trace != null) {
      trace.meanCosine = concentration.meanCosine;
      trace.leftoverAnglesRad = concentration.leftoverAnglesRad;
    }
    final cov = _covariance(
      observations, s, c, x, y, concentration.kappa, config.singularEpsilon);

    final flagged = <String>[
      for (final o in observations)
        if (o.id != null &&
            o.positionAccuracyM != null &&
            o.positionAccuracyM! > config.positionAccuracyFlagMeters)
          o.id!,
    ];
    if (flagged.isNotEmpty) warnings.add(GeometryWarning.largePositionUncertainty);

    if (cov == null) {
      // Information matrix not usable — return the point without an ellipse.
      warnings.add(GeometryWarning.nearSingular);
      return LocalizationResult(
        status: LocalizationStatus.estimated,
        x: x,
        y: y,
        kappa: concentration.kappa,
        meanResultantLength: concentration.meanResultant,
        iterations: iterations,
        warnings: warnings,
        flaggedObservationIds: flagged,
      );
    }

    final ellipse = _ellipseFromCovariance(cov, config.confidence);
    if (ellipse.axisRatio > config.gdopAxisRatioThreshold ||
        (config.gdopSizeThreshold != null &&
            ellipse.semiMajorAxis > config.gdopSizeThreshold!)) {
      warnings.add(GeometryWarning.highGdop);
    }

    return LocalizationResult(
      status: LocalizationStatus.estimated,
      x: x,
      y: y,
      ellipse: ellipse,
      covariance: cov,
      kappa: concentration.kappa,
      meanResultantLength: concentration.meanResultant,
      iterations: iterations,
      warnings: warnings,
      flaggedObservationIds: flagged,
    );
  }

  // One iteration of Eq. 2.6 using current (x, y).
  static (double, double)? _iterate(
    List<PlanarObservation> obs,
    List<double> s,
    List<double> c,
    List<double> z,
    double x,
    double y,
    double eps,
  ) {
    var a11 = 0.0, a12 = 0.0, a21 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;
    for (var i = 0; i < obs.length; i++) {
      final u = x - obs[i].x;
      final v = y - obs[i].y;
      final d2 = u * u + v * v;
      final d3 = d2 * math.sqrt(d2);
      if (d3 == 0) return null; // estimate sits exactly on an observer
      final sStar = v / d3;
      final cStar = u / d3;
      a11 += s[i] * sStar;
      a12 += -c[i] * sStar;
      a21 += s[i] * cStar;
      a22 += -c[i] * cStar;
      b1 += sStar * z[i];
      b2 += cStar * z[i];
    }
    return _solveLinear(a11, a12, a21, a22, b1, b2, eps);
  }

  /// How many times an Eq. 2.6 step may be halved looking for one that does
  /// not lower the likelihood — 2⁻³⁰ of a step is far below any tolerance.
  static const _maxStepHalvings = 30;

  // The von Mises log-likelihood up to constants and the factor κ, which
  // does not move the maximum: Σ cos(θᵢ − μᵢ(x, y)).
  static double _logLikelihood(
    List<PlanarObservation> obs,
    double x,
    double y,
  ) {
    var total = 0.0;
    for (final o in obs) {
      total += math.cos(math.atan2(y - o.y, x - o.x) - o.thetaRad);
    }
    return total;
  }

  // κ = A^{-1}(C), C = mean cos(residual); von Mises concentration.
  static ({
    double kappa,
    double meanResultant,
    double meanCosine,
    List<double> leftoverAnglesRad,
  }) _estimateConcentration(
    List<PlanarObservation> obs,
    double x,
    double y,
  ) {
    var sumCos = 0.0;
    var sumSin = 0.0;
    final leftover = <double>[];
    for (final o in obs) {
      final muHat = math.atan2(y - o.y, x - o.x); // bearing observer→estimate
      final residual = Angles.shortestDifferenceRadians(muHat, o.thetaRad);
      leftover.add(residual);
      sumCos += math.cos(residual);
      sumSin += math.sin(residual);
    }
    final n = obs.length;
    final c = sumCos / n;
    final meanResultant = math.sqrt(sumCos * sumCos + sumSin * sumSin) / n;
    return (
      kappa: _besselRatioInverse(c),
      meanResultant: meanResultant,
      meanCosine: c,
      leftoverAnglesRad: leftover,
    );
  }

  // Covariance = (κ · Î)^{-1}, with Î the symmetrized information matrix of
  // Eqs. 2.8–2.9 evaluated at the MLE. Returns null if not usably invertible.
  static EstimateCovariance? _covariance(
    List<PlanarObservation> obs,
    List<double> s,
    List<double> c,
    double x,
    double y,
    double kappa,
    double eps,
  ) {
    if (kappa <= 0 || !kappa.isFinite) return null;
    var ixx = 0.0, iyy = 0.0, ixy = 0.0;
    for (var i = 0; i < obs.length; i++) {
      final u = x - obs[i].x;
      final v = y - obs[i].y;
      final d2 = u * u + v * v;
      final d3 = d2 * math.sqrt(d2);
      if (d3 == 0) return null;
      final sStar = v / d3;
      final cStar = u / d3;
      ixx += s[i] * sStar; // Σ s_i s_i*  ≈ Σ v²/d⁴
      iyy += c[i] * cStar; // Σ c_i c_i*  ≈ Σ u²/d⁴
      // Off-diagonal of the observed information is I_xy = −L_xy ≈ −κ·Σ uv/d⁴;
      // the symmetrized (Eq. 2.8) sum ½(s_i c* + c_i s*) ≈ Σ uv/d⁴, hence the
      // leading minus. (A sign slip here flips the ellipse tilt / correlation.)
      ixy += -0.5 * (s[i] * cStar + c[i] * sStar);
    }
    ixx *= kappa;
    iyy *= kappa;
    ixy *= kappa;
    final det = ixx * iyy - ixy * ixy;
    // Relative singularity test (see _solveLinear): the information matrix
    // scales with κ/d², so judge |det| against the squared matrix norm.
    final scale = math.max(ixx.abs(), math.max(iyy.abs(), ixy.abs()));
    if (scale == 0 || !det.isFinite || det.abs() < eps * scale * scale) {
      return null;
    }
    // Inverse of the 2×2 information matrix → covariance.
    final qxx = iyy / det;
    final qyy = ixx / det;
    final qxy = -ixy / det;
    if (![qxx, qyy, qxy].every((v) => v.isFinite)) return null;
    if (qxx < 0 || qyy < 0) return null; // not positive-definite
    return EstimateCovariance(xx: qxx, yy: qyy, xy: qxy);
  }

  static UncertaintyEllipse _ellipseFromCovariance(
    EstimateCovariance q,
    double confidence,
  ) {
    final a = q.xx;
    final b = q.xy;
    final c = q.yy;
    final half = (a + c) / 2.0;
    final diff = math.sqrt(((a - c) / 2.0) * ((a - c) / 2.0) + b * b);
    final lambda1 = half + diff; // larger eigenvalue
    final lambda2 = math.max(half - diff, 0.0); // clamp tiny-negative
    final scale = _chiSquare2dof(confidence);
    final semiMajor = math.sqrt(lambda1 * scale);
    final semiMinor = math.sqrt(lambda2 * scale);
    final rotation = 0.5 * math.atan2(2 * b, a - c); // CCW from +x, radians
    return UncertaintyEllipse(
      semiMajorAxis: semiMajor,
      semiMinorAxis: semiMinor,
      rotationDegrees: Angles.radToDeg(rotation),
      confidence: confidence,
    );
  }

  // --- small numeric helpers ---

  static double _sum(int n, double Function(int) f) {
    var acc = 0.0;
    for (var i = 0; i < n; i++) {
      acc += f(i);
    }
    return acc;
  }

  static (double, double)? _solveLinear(
    double a11,
    double a12,
    double a21,
    double a22,
    double b1,
    double b2,
    double relEps,
  ) {
    final det = a11 * a22 - a12 * a21;
    // Relative singularity test: the matrix scale depends on the coordinate
    // magnitude (entries ~1/d²), so an ABSOLUTE threshold would wrongly flag a
    // well-conditioned meters-scale system as singular. Compare |det| to the
    // squared matrix norm instead — this is scale-invariant.
    final scale = math.max(a11.abs(), math.max(a12.abs(),
        math.max(a21.abs(), a22.abs())));
    if (scale == 0 || !det.isFinite || det.abs() < relEps * scale * scale) {
      return null;
    }
    final x = (b1 * a22 - a12 * b2) / det;
    final y = (a11 * b2 - b1 * a21) / det;
    if (!x.isFinite || !y.isFinite) return null;
    return (x, y);
  }

  static double _maxPairwiseDistance(List<PlanarObservation> obs) {
    var maxD = 0.0;
    for (var i = 0; i < obs.length; i++) {
      for (var j = i + 1; j < obs.length; j++) {
        final dx = obs[i].x - obs[j].x;
        final dy = obs[i].y - obs[j].y;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d > maxD) maxD = d;
      }
    }
    return maxD;
  }

  // Angular spread of the bearing directions (°): 0 when all identical, larger
  // when bearings point in diverse directions. Uses the mean resultant length
  // (R̄≈1 ⇒ near-parallel). Bearings are treated as full directions (not axial).
  static double _bearingSpreadDegrees(List<PlanarObservation> obs) {
    final bearingsDeg =
        obs.map((o) => Angles.mathRadiansToCompassDegrees(o.thetaRad));
    final r = Angles.meanResultantLength(bearingsDeg);
    // Map R̄∈[0,1] to a spread angle proxy: circular standard deviation
    // sqrt(-2 ln R̄) in radians → degrees. R̄→1 ⇒ spread→0 (parallel).
    if (r >= 1.0) return 0.0;
    if (r <= 0.0) return 180.0;
    final circStdRad = math.sqrt(-2.0 * math.log(r));
    return Angles.radToDeg(circStdRad);
  }

  // A^{-1}(C): invert the von Mises mean-resultant function A(κ)=I₁(κ)/I₀(κ).
  // Standard Fisher (1993) piecewise approximation — accurate and the same
  // quantity Lenth (1981) Eq. 2.10 approximates.
  static double _besselRatioInverse(double c) {
    if (c <= 0) return 0;
    if (c >= 1) return double.infinity;
    if (c < 0.53) {
      return c * (2.0 + c * c + 5.0 * c * c * c * c / 6.0);
    } else if (c < 0.85) {
      return -0.4 + 1.39 * c + 0.43 / (1.0 - c);
    } else {
      return 1.0 / (c * c * c - 4.0 * c * c + 3.0 * c);
    }
  }

  // χ² quantile with 2 dof for a coverage probability p: −2 ln(1−p).
  static double _chiSquare2dof(double p) => -2.0 * math.log(1.0 - p);
}
