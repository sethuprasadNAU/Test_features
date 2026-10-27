import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/angles.dart';
import 'package:tritrack/localization/lenth_mle.dart';
import 'package:tritrack/localization/localization_types.dart';

/// Builds an observation from Lenth's map coordinates + compass reading.
PlanarObservation obs(double x, double y, double compassDeg, {String? id}) {
  return PlanarObservation(
    x: x,
    y: y,
    thetaRad: Angles.compassDegreesToMathRadians(compassDeg),
    id: id,
  );
}

// Lenth (1981) Table 1. Observation 6 (5.6, 9.0) had "no reading".
final sevenCleanObservations = <PlanarObservation>[
  obs(9.0, 3.2, 234, id: '1'),
  obs(9.4, 5.5, 215, id: '2'),
  obs(9.95, 9.05, 196, id: '3'),
  obs(8.7, 8.7, 193, id: '4'),
  obs(8.07, 9.7, 188, id: '5'),
  obs(4.4, 8.9, 160, id: '7'),
  obs(1.85, 5.25, 118, id: '8'),
];

void main() {
  group('Lenth (1981) worked example — 7 clean bearings (Table 1 & 2)', () {
    final result = LenthSolver.solve(sevenCleanObservations);

    test('reproduces the published MLE (7.23, 1.98)', () {
      expect(result.status, LocalizationStatus.estimated);
      expect(result.x, closeTo(7.23, 0.01));
      expect(result.y, closeTo(1.98, 0.01));
    });

    test('converges quickly (paper: 7 iterations)', () {
      expect(result.iterations, lessThanOrEqualTo(15));
      expect(result.warnings, isNot(contains(GeometryWarning.didNotConverge)));
    });

    test('reproduces the published standard errors and correlation', () {
      // Table 2, row "7 MLE": SE(x)=.156, SE(y)=.156, Corr=.664.
      final cov = result.covariance!;
      expect(cov.seX, closeTo(0.156, 0.01));
      expect(cov.seY, closeTo(0.156, 0.01));
      expect(cov.correlation, closeTo(0.664, 0.03));
    });

    // **Task 11.334: pinned to the last digit**, so that a change to how far
    // out the ellipse is drawn — the only thing that task or its follow-up
    // may move — cannot move the point, the step count, κ or the covariance
    // (and so the standard errors). Recorded from the solver as 11.323 left
    // it, and watched red with the covariance scaled by mistake. Held to
    // 1e-12 rather than exact equality only because another machine's sine
    // and cosine may differ in the last bit; any real change is far larger.
    test("Lenth's point, κ and covariance are pinned exactly", () {
      expect(result.x, closeTo(7.22847385857548, 1e-12));
      expect(result.y, closeTo(1.9808380697967223, 1e-12));
      expect(result.iterations, 8);
      expect(result.kappa, closeTo(395.5161182622481, 1e-12));
      final cov = result.covariance!;
      expect(cov.xx, closeTo(0.02423093147816738, 1e-12));
      expect(cov.yy, closeTo(0.024302091900249016, 1e-12));
      expect(cov.xy, closeTo(0.016112751889332644, 1e-12));
    });

    test('produces a finite, sensible uncertainty ellipse', () {
      final e = result.ellipse!;
      expect(e.semiMajorAxis.isFinite, isTrue);
      expect(e.semiMinorAxis.isFinite, isTrue);
      expect(e.semiMajorAxis, greaterThanOrEqualTo(e.semiMinorAxis));
      expect(e.semiMajorAxis, greaterThan(0));
      expect(result.warnings, isNot(contains(GeometryWarning.highGdop)));
    });

    test('estimate is close to the true target (7.5, 2.2)', () {
      final dx = result.x! - 7.5;
      final dy = result.y! - 2.2;
      final dist = (dx * dx + dy * dy);
      // Paper reports distance .349 → squared ≈ .122.
      expect(dist, lessThan(0.2));
    });
  });

  group('Lenth (1981) — 8 bearings with a westerly reflection outlier', () {
    // Table 2, row "8 MLE": adding obs 6 = 250° pulls the MLE to (5.87, 1.13).
    final eight = [...sevenCleanObservations, obs(5.6, 9.0, 250, id: '6')];
    final result = LenthSolver.solve(eight);

    test('reproduces the published outlier-pulled MLE (5.87, 1.13)', () {
      expect(result.x, closeTo(5.87, 0.05));
      expect(result.y, closeTo(1.13, 0.05));
    });

    test('the degraded geometry inflates the ellipse (still finite)', () {
      // SE jumps to ~1.49/1.73 (vs .156) — much larger than the clean fit.
      expect(result.covariance!.seX, greaterThan(1.0));
      expect(result.ellipse!.semiMajorAxis.isFinite, isTrue);
    });
  });

  group('degenerate geometry — must warn, never NaN/crash', () {
    test('N=0 refuses with noObservations', () {
      final r = LenthSolver.solve(const []);
      expect(r.status, LocalizationStatus.refused);
      expect(r.warnings, contains(GeometryWarning.noObservations));
    });

    test('N=1 returns single-bearing (ray only), no estimate', () {
      final r = LenthSolver.solve([obs(0, 0, 90)]);
      expect(r.status, LocalizationStatus.singleBearing);
      expect(r.hasEstimate, isFalse);
      expect(r.ellipse, isNull);
    });

    test('coincident observers refuse (no baseline)', () {
      final r = LenthSolver.solve([
        obs(5, 5, 90),
        obs(5, 5, 200),
      ]);
      expect(r.status, LocalizationStatus.refused);
      expect(r.warnings, contains(GeometryWarning.coincidentObservers));
    });

    test('near-parallel bearings are flagged and never produce NaN', () {
      final r = LenthSolver.solve([
        obs(0, 0, 90.0),
        obs(0, 10, 90.05), // almost the same direction
      ]);
      expect(r.warnings, contains(GeometryWarning.nearParallel));
      // Whatever the outcome, nothing is NaN/inf.
      if (r.hasEstimate) {
        expect(r.x!.isFinite, isTrue);
        expect(r.y!.isFinite, isTrue);
      }
      final e = r.ellipse;
      if (e != null) {
        expect(e.semiMajorAxis.isFinite, isTrue);
        expect(e.semiMinorAxis.isFinite, isTrue);
      }
    });

    test('exactly parallel bearings refuse without NaN', () {
      final r = LenthSolver.solve([
        obs(0, 0, 90),
        obs(0, 10, 90),
      ]);
      expect(r.hasEstimate && (r.x!.isNaN || r.y!.isNaN), isFalse);
    });

    test('high-GDOP one-sided geometry is flagged', () {
      // Three observers nearly in a line, all south of the target, bearings
      // nearly parallel → large elongated ellipse.
      final r = LenthSolver.solve([
        obs(0, 0, 1),
        obs(1, 0, 0.5),
        obs(2, 0, 0),
      ]);
      if (r.status == LocalizationStatus.estimated && r.ellipse != null) {
        expect(
          r.hasWarning(GeometryWarning.highGdop) ||
              r.hasWarning(GeometryWarning.nearParallel),
          isTrue,
        );
        expect(r.ellipse!.semiMajorAxis.isFinite, isTrue);
      }
    });

    test('large position accuracy is flagged', () {
      final flagged = [
        PlanarObservation(
            x: 9.0,
            y: 3.2,
            thetaRad: Angles.compassDegreesToMathRadians(234),
            id: 'noisy',
            positionAccuracyM: 45),
        obs(1.85, 5.25, 118, id: 'clean'),
        obs(4.4, 8.9, 160, id: 'clean2'),
      ];
      final r = LenthSolver.solve(flagged);
      expect(r.flaggedObservationIds, contains('noisy'));
      expect(r.warnings, contains(GeometryWarning.largePositionUncertainty));
    });
  });

  // **Task 11.323 item 4.** The screenshot fixture's five bearings on Sage
  // (`integration_test/screenshots/seed.dart`, projected to meters about
  // their centroid) carried *"Solver did not fully converge"*. They have a
  // single, well-defined maximum-likelihood point — a 5 m grid search finds
  // it — but Eq. 2.6 applied as a plain fixed-point step overshoots on this
  // geometry and wanders: 200 steps, 1,000 steps, never settling, and the
  // point it stopped at was about 390 m from the maximum and less likely.
  group('a geometry where the plain Eq. 2.6 step overshoots', () {
    final sage = <PlanarObservation>[
      obs(-997.1, -311.3, 62.6, id: 'sage-1'),
      obs(555.7, -478.1, 345.6, id: 'sage-2'),
      obs(800.9, 1523.4, 258.6, id: 'sage-3'),
      obs(-1324.0, 22.2, 76.6, id: 'sage-4'),
      obs(964.4, -756.1, 326.6, id: 'sage-5'),
    ];

    double logLikelihood(double x, double y) {
      var total = 0.0;
      for (final o in sage) {
        total += math.cos(math.atan2(y - o.y, x - o.x) - o.thetaRad);
      }
      return total;
    }

    test('converges, to the most likely point', () {
      final r = LenthSolver.solve(
        sage,
        config: const LenthConfig(
          convergenceTolerance: 1e-4,
          coincidentEpsilon: 1.0,
        ),
      );
      expect(r.status, LocalizationStatus.estimated);
      expect(r.warnings, isNot(contains(GeometryWarning.didNotConverge)));

      var best = double.negativeInfinity;
      for (var x = -1000.0; x <= 1500; x += 5) {
        for (var y = 0.0; y <= 2500; y += 5) {
          best = math.max(best, logLikelihood(x, y));
        }
      }
      expect(
        logLikelihood(r.x!, r.y!),
        greaterThanOrEqualTo(best - 1e-6),
        reason: 'the estimate is less likely than a point on a 5 m grid',
      );
    });
  });

  // **Task 11.336: the solver can keep a record of its search, for the
  // guide's pictures, and keeping it changes nothing.** `trace:` is read-only
  // observation; these pin that, and that the record says what happened.
  group('a trace of the search (task 11.336)', () {
    void expectSameResult(LocalizationResult a, LocalizationResult b) {
      expect(a.status, b.status);
      expect(a.x, b.x);
      expect(a.y, b.y);
      expect(a.iterations, b.iterations);
      expect(a.kappa, b.kappa);
      expect(a.meanResultantLength, b.meanResultantLength);
      expect(a.covariance?.xx, b.covariance?.xx);
      expect(a.covariance?.yy, b.covariance?.yy);
      expect(a.covariance?.xy, b.covariance?.xy);
      expect(a.ellipse?.semiMajorAxis, b.ellipse?.semiMajorAxis);
      expect(a.ellipse?.semiMinorAxis, b.ellipse?.semiMinorAxis);
      expect(a.ellipse?.rotationDegrees, b.ellipse?.rotationDegrees);
      expect(a.warnings, b.warnings);
    }

    // Two real fixes from the coverage simulation (task 11.323's seed), in
    // which the solver cut its step back. Stations in meters, then the
    // reading in math radians; three bearings, 5° of scatter.
    PlanarObservation fix(double x, double y, double theta) =>
        PlanarObservation(x: x, y: y, thetaRad: theta);
    final shortenedFix = [
      fix(183.84819160592323, -800.840121168913, 1.9055085109375325),
      fix(588.1554711817604, -1093.22556628226, 1.9734710152006765),
      fix(459.87470295454796, 1201.6950281711938, -1.797247571548528),
    ];
    final stalledFix = [
      fix(857.0978091056135, -839.0453969308645, 2.423368742926966),
      fix(567.4444966038308, -556.2038339727509, 2.2960484239381533),
      fix(412.5400985207046, -376.2416193284153, 2.3352430658102),
    ];
    const meters = LenthConfig(
      convergenceTolerance: 1e-4,
      coincidentEpsilon: 1.0,
      gdopSizeThreshold: 5000.0,
    );

    test('passing one changes no result', () {
      for (final (observations, config) in [
        (sevenCleanObservations, const LenthConfig()),
        (
          [...sevenCleanObservations, obs(5.6, 9.0, 250, id: '6')],
          const LenthConfig(),
        ),
        (shortenedFix, meters),
        (stalledFix, meters),
      ]) {
        expectSameResult(
          LenthSolver.solve(observations, config: config),
          LenthSolver.solve(observations, config: config, trace: LenthTrace()),
        );
      }
    });

    test("Lenth's example takes 8 whole steps and ends where it ends", () {
      final trace = LenthTrace();
      final r = LenthSolver.solve(sevenCleanObservations, trace: trace);
      expect(trace.steps, hasLength(r.iterations));
      expect(trace.steps.where((s) => s.shortened), isEmpty,
          reason: 'every full step in Lenth\'s example already helps');
      expect(trace.steps.last.converged, isTrue);
      expect(trace.steps.last.toX, r.x);
      expect(trace.steps.last.toY, r.y);
      for (var i = 1; i < trace.steps.length; i++) {
        expect(trace.steps[i].fromX, trace.steps[i - 1].toX);
        expect(trace.steps[i].fromY, trace.steps[i - 1].toY);
      }
    });

    test('κ comes from the mean cosine of the leftover angles it records', () {
      final trace = LenthTrace();
      final r = LenthSolver.solve(sevenCleanObservations, trace: trace);
      expect(trace.leftoverAnglesRad, hasLength(7));
      final meanCosine = trace.leftoverAnglesRad
              .map(math.cos)
              .reduce((a, b) => a + b) /
          7;
      expect(trace.meanCosine, closeTo(meanCosine, 1e-15));
      // And κ is a function of it alone, so two fixes with the same mean
      // cosine would share a κ: here, κ is large because it is near 1.
      expect(trace.meanCosine!, greaterThan(0.99));
      expect(r.kappa, closeTo(395.5161182622481, 1e-12));
    });

    test('a shortened step is marked, with how much of it was taken', () {
      final trace = LenthTrace();
      final r = LenthSolver.solve(shortenedFix, config: meters, trace: trace);
      final shortened = trace.steps.where((s) => s.shortened).toList();
      expect(shortened, isNotEmpty);
      expect(shortened.every((s) => s.fraction == 0.5), isTrue);
      expect(trace.steps, hasLength(r.iterations));
      for (final s in shortened) {
        // Halfway between where it started and where Eq. 2.6 pointed.
        expect(s.toX, closeTo(s.fromX + 0.5 * (s.fullStepX - s.fromX), 1e-9));
        expect(s.toY, closeTo(s.fromY + 0.5 * (s.fullStepY - s.fromY), 1e-9));
      }
      // The fit never gets worse along the way it took.
      var fit = trace.startSumCosine!;
      for (final s in trace.steps) {
        expect(s.sumCosine, greaterThanOrEqualTo(fit - 1e-12));
        fit = s.sumCosine;
      }
    });

    test('a step that cannot improve the fit is recorded as rejected', () {
      final trace = LenthTrace();
      final r = LenthSolver.solve(stalledFix, config: meters, trace: trace);
      expect(r.warnings, contains(GeometryWarning.didNotConverge));
      expect(trace.steps, hasLength(1));
      final step = trace.steps.single;
      expect(step.rejected, isTrue);
      expect(step.converged, isFalse);
      expect(step.toX, step.fromX);
      expect(step.toY, step.fromY);
      expect(r.x, trace.startX, reason: 'the estimate stayed at the start');
    });
  });
}
