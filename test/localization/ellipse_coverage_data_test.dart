import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'ellipse_coverage_data/ellipse_coverage_data.dart';

/// **The guide's ellipse figures read two committed files; this keeps them
/// equal to what the app's solver produces** — task 11.336.
///
/// ```
/// flutter test test/localization/ellipse_coverage_data_test.dart \
///     --dart-define=WRITE_ELLIPSE_COVERAGE_DATA=true
/// ```
///
/// regenerates `ellipse_coverage_data/coverage_chi_square.csv` and
/// `ellipse_coverage_data/worked_examples.json` (and the same command twice
/// writes identical files). Run without the flag, the test fails when a
/// committed file differs from what the solver now gives — so a change to the
/// solver, κ or the ellipse cannot leave the guide's pictures describing the
/// old app. The files are the **chi-square** scale only, the one the app
/// uses; 11.334's F columns are in `ellipse_coverage_simulation_test.dart`.
const _write = bool.fromEnvironment('WRITE_ELLIPSE_COVERAGE_DATA');

/// −2 ln(0.05), the chi-square(2) 95% quantile (5.99146…).
final _chi95 = -2.0 * math.log(0.05);

const _dir = 'test/localization/ellipse_coverage_data';
const _regenerate = 'flutter test test/localization/ellipse_coverage_data_test'
    '.dart --dart-define=WRITE_ELLIPSE_COVERAGE_DATA=true';

void main() {
  final csv = buildCoverageCsv();
  final json = buildWorkedExamplesJson();

  group('committed files', () {
    for (final (name, built) in [
      ('coverage_chi_square.csv', csv),
      ('worked_examples.json', json),
    ]) {
      test('$name is what the solver gives now', () {
        final file = File('$_dir/$name');
        if (_write) {
          file.writeAsStringSync(built);
          return;
        }
        expect(
          file.existsSync(),
          isTrue,
          reason: '$name is not committed; generate it with:\n$_regenerate',
        );
        expect(
          file.readAsStringSync(),
          built,
          reason: '$name differs from what the app\'s solver now produces. '
              'If the change was meant, regenerate it with:\n$_regenerate',
        );
      });
    }
  });

  group('the table', () {
    final rows = csv.trim().split('\n');

    test('has the chi-square columns and no F column', () {
      expect(
        rows.first,
        'bearings,spread_sd_deg,runs,fixes_with_ellipse,no_ellipse,'
        'covered_chi_square,coverage_chi_square,'
        'covered_chi_square_true_kappa,coverage_chi_square_true_kappa',
      );
      expect(rows.length - 1, 18, reason: '6 counts × 3 spreads');
    });

    // The instrument's own check: these are task 11.323's published cells, and
    // 11.334 reproduced them to the digit. A change to the simulation's draw
    // order or to the solver moves them.
    test("reproduces task 11.323's cells", () {
      Map<String, String> cell(int n, int sd) {
        final header = rows.first.split(',');
        final values =
            rows.skip(1).firstWhere((r) => r.startsWith('$n,$sd,')).split(',');
        return {for (var i = 0; i < header.length; i++) header[i]: values[i]};
      }

      String pct(Map<String, String> c) =>
          (double.parse(c['coverage_chi_square']!) * 100).toStringAsFixed(1);
      expect(pct(cell(3, 5)), '42.0');
      expect(pct(cell(3, 15)), '39.5');
      expect(pct(cell(10, 5)), '85.6');
      expect(cell(3, 15)['no_ellipse'], '142');
    });
  });

  group('the six worked examples', () {
    final document = jsonDecode(json) as Map<String, dynamic>;
    final examples = (document['examples'] as List).cast<Map<String, dynamic>>();

    test('are 3, 5 and 10 bearings at 5° and 15°', () {
      expect(
        [for (final e in examples) (e['bearings'], e['bearing_spread_sd_deg'])],
        [(3, 5.0), (3, 15.0), (5, 5.0), (5, 15.0), (10, 5.0), (10, 15.0)],
      );
    });

    test('include one where the ellipse misses and one where it contains', () {
      final outcomes = [for (final e in examples) e['covered_by_95_ellipse']];
      expect(outcomes, contains(true));
      expect(outcomes, contains(false));
    });

    for (final e in examples) {
      test('${e['id']} is consistent with itself', () {
        final covariance = e['covariance_m2'] as Map<String, dynamic>;
        final ellipses = e['ellipses'] as Map<String, dynamic>;
        final oneSd = ellipses['one_sd'] as Map<String, dynamic>;
        final ninetyFive = ellipses['ninety_five'] as Map<String, dynamic>;
        final estimate = e['estimate'] as Map<String, dynamic>;
        final path = e['solver_path'] as Map<String, dynamic>;
        final steps = (path['steps'] as List).cast<Map<String, dynamic>>();
        final stations = (e['stations'] as List).cast<Map<String, dynamic>>();
        final kappa = e['kappa'] as Map<String, dynamic>;

        // 95% is the 1-SD ellipse scaled by √(chi-square 95%), the same way round.
        expect(
          ninetyFive['semi_major_m'] as double,
          closeTo((oneSd['semi_major_m'] as double) * math.sqrt(_chi95), 1e-4),
        );
        expect(ninetyFive['scale_k'], closeTo(_chi95, 1e-6));
        expect(oneSd['scale_k'], 1.0);
        // The covariance gives the 1-SD axes: the larger eigenvalue.
        final xx = covariance['xx'] as double;
        final yy = covariance['yy'] as double;
        final xy = covariance['xy'] as double;
        final lambda1 = (xx + yy) / 2 +
            math.sqrt(math.pow((xx - yy) / 2, 2) + xy * xy);
        expect(oneSd['semi_major_m'] as double,
            closeTo(math.sqrt(lambda1), 1e-4));

        // Covered means the true point is inside the 95% ellipse.
        expect(
          (e['true_point_mahalanobis_squared'] as double) <= _chi95,
          e['covered_by_95_ellipse'],
        );

        // The path: as many steps as the solver took, the last one whole and
        // converged, and it ends where the estimate is.
        expect(steps.length, estimate['iterations']);
        expect(steps.last['converged'], isTrue);
        expect(steps.last['fraction'], 1.0);
        final end = steps.last['to'] as Map<String, dynamic>;
        expect(end['x_m'], estimate['x_m']);
        expect(end['y_m'], estimate['y_m']);
        // Each step starts where the one before ended.
        for (var i = 1; i < steps.length; i++) {
          expect(steps[i]['from'], steps[i - 1]['to']);
        }
        // A step is marked shortened exactly when it took less than the whole.
        expect(
          path['shortened_steps'],
          [
            for (final s in steps)
              if ((s['fraction'] as double) < 1.0) s['number'],
          ],
        );
        // The search only ever improves the fit.
        for (var i = 1; i < steps.length; i++) {
          expect(
            steps[i]['sum_cosine'] as double,
            greaterThanOrEqualTo((steps[i - 1]['sum_cosine'] as double) - 1e-6),
          );
        }

        // κ's input: the mean cosine of the leftover angles on the stations.
        final cosines = [
          for (final s in stations)
            math.cos(s['leftover_angle_math_rad'] as double),
        ];
        expect(
          cosines.reduce((a, b) => a + b) / cosines.length,
          closeTo(kappa['mean_cosine'] as double, 1e-5),
        );
        expect(stations.length, e['bearings']);
      });
    }
  });
}
