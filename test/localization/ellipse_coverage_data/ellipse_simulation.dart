import 'dart:math' as math;

import 'package:tritrack/localization/lenth_mle.dart';
import 'package:tritrack/localization/localization_types.dart';

/// **The simulation behind task 11.323's coverage table, in one place** so the
/// measurement (`ellipse_coverage_simulation_test.dart`) and the guide's data
/// files (`ellipse_coverage_data_test.dart`) cannot come to use two different
/// ones — task 11.336. Nothing here is the app; it drives the app's solver.
///
/// ## How a run is set up
///
/// - **The animal** is at the origin of a plane in meters (x east, y north).
/// - **Stations**, *n* of them, each at a random direction inside a 180° arc
///   on one side of the animal (stations along a road, not a ring around it)
///   and a random distance of 500–2,000 m.
/// - **Each bearing** is the true direction from station to animal plus an
///   error drawn from a von Mises distribution whose concentration matches a
///   circular standard deviation of 5°, 10° or 15°.
/// - **The app's own solver** (`LenthSolver.solve`, with the meters
///   configuration the app uses) estimates the point, κ and the covariance.
/// - **Covered** means the true point is inside the ellipse: its Mahalanobis
///   distance squared under the returned covariance is at most the scale `k`.
///
/// **The draw order is part of the contract.** One generator is shared by all
/// cells and each station draws its direction, then its distance, then its
/// bearing error; changing that changes every number. The chi-square column
/// reproduces task 11.323's table to the digit, which is how the instrument
/// is checked.

const simulationRuns = 2000;
const simulationCounts = [3, 4, 5, 6, 8, 10];
const simulationSpreadsDeg = [5.0, 10.0, 15.0];

/// Task 11.323's seed.
const simulationSeed = 11323;

/// The geographic wrapper's meters configuration (`LenthGeographic.solve`).
const appConfig = LenthConfig(
  convergenceTolerance: 1e-4,
  coincidentEpsilon: 1.0,
  gdopSizeThreshold: 5000.0,
);

/// −2 ln(0.05): the chi-square(2) 95% quantile the app scales the ellipse by.
final chiSquare95 = -2.0 * math.log(0.05);

/// The upper-[p] quantile of F(2, m). With 2 numerator degrees of freedom the
/// distribution function has a closed form, P(F ≤ x) = 1 − (1 + 2x/m)^(−m/2),
/// so the inverse is exact: x = (m/2)·((1 − p)^(−2/m) − 1).
double fQuantile2(double p, int m) =>
    (m / 2.0) * (math.pow(1.0 - p, -2.0 / m) - 1.0);

/// One station, with the error its bearing was given.
typedef SimulatedStation = ({
  double x,
  double y,
  double trueThetaRad,
  double errorRad,
});

/// Draws [n] stations and their bearings, in the contract's order.
List<SimulatedStation> drawStations(math.Random random, int n, double kappa) {
  final stations = <SimulatedStation>[];
  for (var i = 0; i < n; i++) {
    final direction = -math.pi / 2 + random.nextDouble() * math.pi;
    final distance = 500 + random.nextDouble() * 1500;
    final x = distance * math.cos(direction);
    final y = distance * math.sin(direction);
    final toAnimal = math.atan2(-y, -x);
    stations.add((
      x: x,
      y: y,
      trueThetaRad: toAnimal,
      errorRad: vonMises(random, kappa),
    ));
  }
  return stations;
}

List<PlanarObservation> observationsFor(List<SimulatedStation> stations) => [
      for (final s in stations)
        PlanarObservation(
          x: s.x,
          y: s.y,
          thetaRad: s.trueThetaRad + s.errorRad,
        ),
    ];

/// Coverage counts for one cell, all from the same runs.
typedef CoverageCell = ({
  int runs,
  int noEllipse,
  int chiCovered,
  int fCovered,
  int fTimesNCovered,
  int trueKappaCovered,
}) ;

extension CoverageCellRates on CoverageCell {
  /// Runs that gave an ellipse — what every rate is a fraction of.
  int get used => runs - noEllipse;
  double get chi => chiCovered / used;
  double get f => fCovered / used;
  double get fTimesN => fTimesNCovered / used;
  double get trueKappa => trueKappaCovered / used;
}

/// Every cell of the table: *n* in [simulationCounts], spread in
/// [simulationSpreadsDeg].
///
/// Four coverages per cell: chi-square (the app); F (task 11.334's scale,
/// **not shipped**); F × n/(n−2) (11.334's **diagnostic, not cited, not
/// shipped**); and chi-square with the true κ (the instrument's own check).
/// The guide's data files use only the first and the last.
Map<(int, double), CoverageCell> coverageCells() {
  final random = math.Random(simulationSeed);
  final cells = <(int, double), CoverageCell>{};
  for (final n in simulationCounts) {
    final twoF = 2 * fQuantile2(0.95, n - 2);
    for (final sdDeg in simulationSpreadsDeg) {
      final kappa = kappaForCircularSd(sdDeg);
      var chi = 0;
      var f = 0;
      var fTimesN = 0;
      var trueKappa = 0;
      var noEllipse = 0;
      for (var run = 0; run < simulationRuns; run++) {
        final stations = drawStations(random, n, kappa);
        final r = LenthSolver.solve(
          observationsFor(stations),
          config: appConfig,
        );
        final cov = r.covariance;
        if (!r.hasEstimate || cov == null || r.kappa == null) {
          noEllipse++;
          continue;
        }
        final d2 = mahalanobisSquared(-r.x!, -r.y!, cov);
        if (d2 <= chiSquare95) chi++;
        if (d2 <= twoF) f++;
        if (d2 <= twoF * n / (n - 2)) fTimesN++;
        // Covariance ∝ 1/κ: with the true κ it is cov · κ̂/κ, so the
        // distance squared scales by κ/κ̂.
        if (d2 * kappa / r.kappa! <= chiSquare95) trueKappa++;
      }
      cells[(n, sdDeg)] = (
        runs: simulationRuns,
        noEllipse: noEllipse,
        chiCovered: chi,
        fCovered: f,
        fTimesNCovered: fTimesN,
        trueKappaCovered: trueKappa,
      );
    }
  }
  return cells;
}

double mahalanobisSquared(double dx, double dy, EstimateCovariance q) {
  final det = q.xx * q.yy - q.xy * q.xy;
  return (q.yy * dx * dx - 2 * q.xy * dx * dy + q.xx * dy * dy) / det;
}

/// The von Mises κ whose circular standard deviation √(−2 ln A(κ)) is
/// [sdDeg], found by bisection on A(κ) = I₁(κ)/I₀(κ).
double kappaForCircularSd(double sdDeg) {
  final sd = sdDeg * math.pi / 180;
  final targetA = math.exp(-sd * sd / 2);
  var lo = 1e-6;
  var hi = 1e5;
  for (var i = 0; i < 200; i++) {
    final mid = math.sqrt(lo * hi);
    if (_besselRatio(mid) < targetA) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return math.sqrt(lo * hi);
}

/// A(κ) = I₁(κ)/I₀(κ), by the series ratio for moderate κ and the
/// asymptotic expansion for large κ.
double _besselRatio(double k) {
  if (k > 50) {
    return 1 - 1 / (2 * k) - 1 / (8 * k * k) - 1 / (8 * k * k * k);
  }
  var i0 = 0.0;
  var i1 = 0.0;
  var term = 1.0; // (k/2)^(2m) / (m!)^2
  for (var m = 0; m < 200; m++) {
    if (m > 0) term *= (k / 2) * (k / 2) / (m * m);
    i0 += term;
    i1 += term * (k / 2) / (m + 1);
  }
  return i1 / i0;
}

/// One draw from a von Mises distribution with mean 0 and concentration
/// [kappa] — Best & Fisher (1979), the standard rejection sampler.
double vonMises(math.Random random, double kappa) {
  final tau = 1 + math.sqrt(1 + 4 * kappa * kappa);
  final rho = (tau - math.sqrt(2 * tau)) / (2 * kappa);
  final r = (1 + rho * rho) / (2 * rho);
  while (true) {
    final u1 = random.nextDouble();
    final z = math.cos(math.pi * u1);
    final f = (1 + r * z) / (r + z);
    final c = kappa * (r - f);
    final u2 = random.nextDouble();
    if (c * (2 - c) - u2 > 0 || math.log(c / u2) + 1 - c >= 0) {
      final u3 = random.nextDouble();
      return (u3 > 0.5 ? 1 : -1) * math.acos(f);
    }
  }
}
