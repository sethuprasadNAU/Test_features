import 'package:flutter_test/flutter_test.dart';

import 'ellipse_coverage_data/ellipse_simulation.dart';

/// **How often the 95% ellipse contains the animal, with few bearings —
/// chi-square and F side by side. A measurement; it changes nothing.**
///
/// Task 11.323 item 2 measured the app's chi-square ellipse. Task 11.334 was
/// to scale it by 2·F(2, n−2) instead, with this simulation as its acceptance
/// test (F at 92–97% for 4–10 bearings at 5° and 10°). **F missed** (86–92%),
/// so 11.334 stopped as its brief says and the app still scales by
/// chi-square. This file keeps the measurement that stopped it.
///
/// ## How the run is set up
///
/// (The simulation itself now lives in
/// `ellipse_coverage_data/ellipse_simulation.dart`, shared with the guide's
/// data files — task 11.336. The description is kept here.)
///
/// - **The animal** is at the origin of a plane in meters (x east, y north).
/// - **Stations**, [simulationRuns] times per cell: *n* of them, each at a random
///   direction inside a 180° arc on one side of the animal (stations along a
///   road, not a ring around it) and a random distance of 500–2,000 m.
/// - **Each bearing** is the true direction from station to animal plus an
///   error drawn from a von Mises distribution whose concentration matches a
///   circular standard deviation of 5°, 10° or 15°.
/// - **The app's own solver** (`LenthSolver.solve`, with the meters
///   configuration the app uses) estimates the point, κ and the covariance.
/// - **Covered** means the true point is inside the ellipse: its Mahalanobis
///   distance squared under the returned covariance is at most the scale `k`.
///
/// Four coverages per cell, all from the **same runs**:
///
/// 1. **chi-square**: `k` = 5.991, the scale the app uses;
/// 2. **F**: `k` = 2·F(2, n−2; 0.95), the scale 11.334 was to ship;
/// 3. **F × n/(n−2)** — **a diagnostic, not cited and not shipped.** The F
///    region is exact when the scatter is estimated as the residual sum of
///    squares over n − 2; the app's κ (Lenth's Eq. 2.10 and Fisher's
///    approximation alike) averages over n, so for small residuals it is too
///    large by about n/(n−2), and the region with it too small by the same
///    factor. This column measures that explanation. It may be what the LOAS
///    manual calls "Adjusted F", whose definition the manual does not give;
///    and
/// 4. **chi-square with the true κ**: the chi-square ellipse rescaled by κ̂/κ
///    (the covariance is proportional to 1/κ). This is the instrument's own
///    check: it sits near 95% when κ is known, so the gap between it and (1)
///    is the cost of estimating κ from the same bearings, and its own shortfall
///    at 15° is the straight-line approximation in Lenth's Eqs. 2.7–2.9.
///
/// A run where the solver returns no ellipse is counted apart, not as a miss.
///
/// The seed and the layouts are task 11.323's, so the chi-square column
/// reproduces that task's table exactly. The table is printed; the only
/// assertions are on the instrument and on the F quantile.
void main() {
  test('95% ellipse coverage with 3 to 10 bearings: chi-square and F', () {
    final cells = coverageCells();

    // ignore: avoid_print
    print([
      '',
      '=== Task 11.334 — 95% ellipse coverage, $simulationRuns runs per cell ===',
      'Each cell: chi-square (the app) / F (not shipped) / '
          'F × n/(n−2) (diagnostic) [chi-square with the true κ].',
      '| Bearings | SD 5° | SD 10° | SD 15° |',
      '|---|---|---|---|',
      for (final n in simulationCounts)
        '| $n | ${[
          for (final sd in simulationSpreadsDeg)
            () {
              final c = cells[(n, sd)]!;
              return '${_pct(c.chi)} / ${_pct(c.f)} / ${_pct(c.fTimesN)} '
                  '[${_pct(c.trueKappa)}]'
                  '${c.noEllipse == 0 ? '' : ' (${c.noEllipse} no ellipse)'}';
            }(),
        ].join(' | ')} |',
      '=== end ===',
      '',
    ].join('\n'));

    // The instrument's check, not a claim about the app: with ten tight
    // bearings and κ known, a sound simulation lands near the nominal 95%.
    // **Only at 5°.** With wider spreads the true-κ coverage falls too (to
    // about 92% at 15° with ten bearings), because the ellipse is a
    // straight-line approximation (Lenth's Eqs. 2.7–2.9) that gets rougher as
    // the bearings widen — a property of the method, not of the simulation.
    expect(
      cells[(10, 5.0)]!.trueKappa,
      inInclusiveRange(0.93, 0.97),
      reason: 'with 10 bearings at SD 5° and the true κ the coverage is '
          '${_pct(cells[(10, 5.0)]!.trueKappa)}, far from 95% — the '
          'simulation, not the app, is suspect',
    );
  });

  // The F quantile is computed from a closed form, so it is checked against a
  // published table: the 5% upper critical values for 2 numerator degrees of
  // freedom in the NIST/SEMATECH e-Handbook of Statistical Methods, section
  // 1.3.6.7.3, "Upper Critical Values of the F Distribution" (read
  // 2026-10-07), to the three decimals it prints. Watched red with F(2, 8)
  // mistyped as the table's F(2, 9).
  test('F(2, m) at 0.95 matches the NIST table to its printed precision', () {
    const nist95 = <int, double>{
      1: 199.500,
      2: 19.000,
      3: 9.552,
      4: 6.944,
      5: 5.786,
      6: 5.143,
      7: 4.737,
      8: 4.459,
      9: 4.256,
      10: 4.103,
      20: 3.493,
      30: 3.316,
      50: 3.183,
      100: 3.087,
    };
    for (final entry in nist95.entries) {
      expect(
        fQuantile2(0.95, entry.key),
        closeTo(entry.value, 0.0005),
        reason: 'F(2, ${entry.key})',
      );
    }
    // And 2·F(2, m) tends to the chi-square(2) quantile as m grows.
    expect(2 * fQuantile2(0.95, 100000), closeTo(chiSquare95, 0.001));
  });
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
