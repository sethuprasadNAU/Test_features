// Draws the figures on the theory page (docs/how-the-estimate-is-calculated.md)
// from the data the app itself wrote, and refuses to draw them if its own
// arithmetic disagrees with the app's.
//
// Usage, from the repository root:
//
//   dart website/tools/theory_figures.dart           write website/static/figures/
//   dart website/tools/theory_figures.dart --check   fail if a committed figure differs
//   dart website/tools/theory_figures.dart --verify-only   only the check against the app
//
// **Where the numbers come from (task /w-36).** Task 11.336 committed the app's
// own numbers for six worked fixes and the coverage table, in
// test/localization/ellipse_coverage_data/ (its README names every field).
// This script reads them. Where a picture needs something the files do not
// hold — a likelihood surface, a simulated fix that is not one of the six, a
// fix drawn to show geometry — it computes it here, with a copy of the app's
// method written out below. **That copy is checked against the app before
// anything is drawn:** it must reproduce each worked example's search path,
// estimate, kappa, covariance and ellipse to the tolerances in `_verify`, and
// the whole coverage simulation (36,000 fixes, task 11.323's seed) to the
// count. If the app's solver changes, 11.336's data test fails first; if this
// copy drifts from the data, this script fails. Either way no figure is
// drawn from a method the app does not use.
//
// **Nothing here runs in a reader's browser.** Each figure is an SVG file the
// `fig` and `anim` shortcodes inline into the page, colored by the site's own
// CSS variables (style.css, "Theory figures") so one file serves the light and
// dark themes. Animations are CSS keyframes inside the SVG; each has a still
// version (`<name>-steps.svg`) for print, the PDF, and readers who ask for
// reduced motion.
//
// No dependencies beyond the Dart SDK, like the rest of website/tools.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

final Uri _toolsDir = Platform.script.resolve('.');
final String _repo = Directory.fromUri(_toolsDir.resolve('../..')).path;
final String _dataDir = '${_repo}test/localization/ellipse_coverage_data';
final String _outDir = '${_repo}website/static/figures';
final String _solverTest = '${_repo}test/localization/lenth_mle_test.dart';

Future<void> main(List<String> args) async {
  final check = args.contains('--check');
  final examples = _loadExamples();
  final coverage = _loadCoverage();

  _verify(examples, coverage);
  if (args.contains('--verify-only')) return;

  final figures = <String, String>{
    'bearing-fan': _figBearingFan(),
    ..._figHillBuild(examples['n3_sd15']!),
    ..._figSolver(examples['n10_sd15']!),
    'solver-shortened': _figSolverShortened(),
    'residual-angles': _figResiduals(examples['n3_sd15']!, examples['n10_sd15']!),
    'chi-square-scale': _figChiSquareScale(),
    'hill-to-ellipse': _figHillToEllipse(examples['n3_sd15']!),
    'geometry': _figGeometry(),
    ..._figCoverageBuild(),
    'coverage-by-bearings': _figCoverageChart(coverage),
    'worked-examples': _figWorkedExamples(examples['n3_sd15']!, examples['n5_sd15']!),
  };

  Directory(_outDir).createSync(recursive: true);
  final stale = <String>[];
  for (final entry in figures.entries) {
    final file = File('$_outDir/${entry.key}.svg');
    final text = '${entry.value}\n';
    if (check) {
      if (!file.existsSync() ||
          _comparable(file.readAsStringSync()) != _comparable(text)) {
        stale.add(entry.key);
      }
    } else {
      file.writeAsStringSync(text);
    }
  }
  final extra = Directory(_outDir)
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.svg'))
      .map((n) => n.substring(0, n.length - 4))
      .where((n) => !figures.containsKey(n))
      .toList();
  if (check) {
    if (stale.isNotEmpty || extra.isNotEmpty) {
      stderr.writeln('theory_figures: the committed figures are not what the '
          'script draws now.');
      for (final s in stale) {
        stderr.writeln('  differs or missing: website/static/figures/$s.svg');
      }
      for (final s in extra) {
        stderr.writeln('  no longer drawn: website/static/figures/$s.svg');
      }
      stderr.writeln('Run `dart website/tools/theory_figures.dart`, look at '
          'every figure that changed, and commit them.');
      exit(1);
    }
    stdout.writeln('theory_figures: ${figures.length} figures match what the script '
        'draws, and its copy of the method matches the app.');
  } else {
    for (final s in extra) {
      File('$_outDir/$s.svg').deleteSync();
    }
    stdout.writeln('theory_figures: wrote ${figures.length} figures to '
        'website/static/figures/'
        '${extra.isEmpty ? '' : ' and removed ${extra.join(', ')}'}.');
  }
}

/// A figure compared for `--check`. Each embedded PNG is replaced by its
/// decoded pixels: zlib's compressed bytes may differ between machines while
/// the picture does not.
String _comparable(String svg) => svg.replaceAllMapped(
      RegExp(r'data:image/png;base64,([A-Za-z0-9+/=]+)'),
      (m) => 'pixels:${base64.encode(_pngPixels(base64.decode(m[1]!)))}',
    );

List<int> _pngPixels(List<int> png) {
  final idat = <int>[];
  var i = 8;
  while (i < png.length) {
    final len = (png[i] << 24) | (png[i + 1] << 16) | (png[i + 2] << 8) | png[i + 3];
    final type = String.fromCharCodes(png.sublist(i + 4, i + 8));
    if (type == 'IDAT') idat.addAll(png.sublist(i + 8, i + 8 + len));
    i += 12 + len;
  }
  return zlib.decode(idat);
}

// ---------------------------------------------------------------------------
// The app's method, written out again (lib/localization/lenth_mle.dart)
// ---------------------------------------------------------------------------

class Obs {
  const Obs(this.x, this.y, this.theta);

  /// From a compass bearing in degrees, as the worked examples store it.
  Obs.compass(this.x, this.y, double bearingDeg)
      : theta = (90 - bearingDeg) * math.pi / 180;
  final double x, y;

  /// Math angle: radians counterclockwise from east.
  final double theta;
}

class Step {
  Step(this.fromX, this.fromY, this.fullX, this.fullY, this.fraction, this.toX,
      this.toY, this.sumCos, {this.converged = false, this.rejected = false});
  final double fromX, fromY, fullX, fullY, fraction, toX, toY, sumCos;
  final bool converged, rejected;
  bool get shortened => fraction < 1;
}

class Cov {
  const Cov(this.xx, this.yy, this.xy);
  final double xx, yy, xy;
  Cov scaled(double s) => Cov(xx * s, yy * s, xy * s);
}

class Ellipse {
  const Ellipse(this.a, this.b, this.rotDeg);

  /// Semi-major and semi-minor axes, meters; major axis counterclockwise
  /// from east, degrees.
  final double a, b, rotDeg;
}

/// χ²(2) 95% point, −2 ln 0.05: the app's scale.
final double chi95 = -2 * math.log(0.05);

Ellipse ellipseOf(Cov q, double k) {
  final half = (q.xx + q.yy) / 2;
  final diff = math.sqrt(math.pow((q.xx - q.yy) / 2, 2) + q.xy * q.xy);
  final l1 = half + diff;
  final l2 = math.max(half - diff, 0.0);
  return Ellipse(math.sqrt(l1 * k), math.sqrt(l2 * k),
      0.5 * math.atan2(2 * q.xy, q.xx - q.yy) * 180 / math.pi);
}

double mahalanobis2(double dx, double dy, Cov q) {
  final det = q.xx * q.yy - q.xy * q.xy;
  return (q.yy * dx * dx - 2 * q.xy * dx * dy + q.xx * dy * dy) / det;
}

class Fix {
  double startX = 0, startY = 0, startSumCos = 0;
  final steps = <Step>[];
  double? x, y;
  double kappa = 0, meanCos = 0;
  List<double> leftovers = const [];
  Cov? cov;
  bool converged = false;
  bool get hasEllipse => x != null && cov != null;
  Ellipse ellipse(double k) => ellipseOf(cov!, k);
}

/// Σ cos(θᵢ − μᵢ(x, y)): the fit, the height of the likelihood "hill" up to
/// the factor κ.
double sumCos(List<Obs> obs, double x, double y) {
  var t = 0.0;
  for (final o in obs) {
    t += math.cos(math.atan2(y - o.y, x - o.x) - o.theta);
  }
  return t;
}

(double, double)? _solve2(double a11, double a12, double a21, double a22,
    double b1, double b2, double eps) {
  final det = a11 * a22 - a12 * a21;
  final scale =
      math.max(a11.abs(), math.max(a12.abs(), math.max(a21.abs(), a22.abs())));
  if (scale == 0 || !det.isFinite || det.abs() < eps * scale * scale) {
    return null;
  }
  final x = (b1 * a22 - a12 * b2) / det;
  final y = (a11 * b2 - b1 * a21) / det;
  if (!x.isFinite || !y.isFinite) return null;
  return (x, y);
}

double _sum(int n, double Function(int) f) {
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    acc += f(i);
  }
  return acc;
}

/// Fisher's (1993) approximation to the inverse of A(κ) = I₁(κ)/I₀(κ).
///
/// **Only the last branch (c ≥ 0.85) is checked against the app.** Every
/// worked example and every simulated fix has a mean cosine above 0.85, so a
/// mistake in the first two branches would not turn `_verify` red (watched:
/// changing 0.43 to 0.44 left it green, 2026-10-08). No figure draws a fix
/// that reaches them.
double kappaFromMeanCos(double c) {
  if (c <= 0) return 0;
  if (c >= 1) return double.infinity;
  if (c < 0.53) return c * (2.0 + c * c + 5.0 * c * c * c * c / 6.0);
  if (c < 0.85) return -0.4 + 1.39 * c + 0.43 / (1.0 - c);
  return 1.0 / (c * c * c - 4.0 * c * c + 3.0 * c);
}

/// Lenth's (1981) maximum-likelihood estimate, as the app computes it with its
/// meters settings (stop when a whole step moves both coordinates < 0.1 mm;
/// at most 200 steps; halve a step that lowers the fit).
Fix solve(List<Obs> obs, {double tol = 1e-4, double eps = 1e-12}) {
  final n = obs.length;
  final fix = Fix();
  final s = [for (final o in obs) math.sin(o.theta)];
  final c = [for (final o in obs) math.cos(o.theta)];
  final z = [for (var i = 0; i < n; i++) s[i] * obs[i].x - c[i] * obs[i].y];
  final start = _solve2(
    _sum(n, (i) => s[i] * s[i]),
    -_sum(n, (i) => c[i] * s[i]),
    _sum(n, (i) => s[i] * c[i]),
    -_sum(n, (i) => c[i] * c[i]),
    _sum(n, (i) => s[i] * z[i]),
    _sum(n, (i) => c[i] * z[i]),
    eps,
  );
  if (start == null) return fix;
  var x = start.$1, y = start.$2;
  var fit = sumCos(obs, x, y);
  fix
    ..startX = x
    ..startY = y
    ..startSumCos = fit;
  for (var iter = 0; iter < 200; iter++) {
    var a11 = 0.0, a12 = 0.0, a21 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;
    var onObserver = false;
    for (var i = 0; i < n; i++) {
      final u = x - obs[i].x, v = y - obs[i].y;
      final d2 = u * u + v * v;
      final d3 = d2 * math.sqrt(d2);
      if (d3 == 0) onObserver = true;
      final sS = v / d3, cS = u / d3;
      a11 += s[i] * sS;
      a12 += -c[i] * sS;
      a21 += s[i] * cS;
      a22 += -c[i] * cS;
      b1 += sS * z[i];
      b2 += cS * z[i];
    }
    final step = onObserver ? null : _solve2(a11, a12, a21, a22, b1, b2, eps);
    if (step == null) return fix..x = null;
    final dx = step.$1 - x, dy = step.$2 - y;
    if (dx.abs() < tol && dy.abs() < tol) {
      fix.steps.add(Step(x, y, step.$1, step.$2, 1, step.$1, step.$2,
          sumCos(obs, step.$1, step.$2),
          converged: true));
      x = step.$1;
      y = step.$2;
      fix.converged = true;
      break;
    }
    var fraction = 1.0;
    var nx = step.$1, ny = step.$2;
    var nfit = sumCos(obs, nx, ny);
    for (var h = 0; h < 30 && nfit < fit; h++) {
      fraction /= 2;
      nx = x + fraction * dx;
      ny = y + fraction * dy;
      nfit = sumCos(obs, nx, ny);
    }
    if (nfit < fit) {
      fix.steps.add(
          Step(x, y, step.$1, step.$2, fraction, x, y, fit, rejected: true));
      break;
    }
    fix.steps.add(Step(x, y, step.$1, step.$2, fraction, nx, ny, nfit));
    x = nx;
    y = ny;
    fit = nfit;
  }
  fix
    ..x = x
    ..y = y;
  // κ from the leftover angles at the estimate.
  var sumC = 0.0;
  final left = <double>[];
  for (final o in obs) {
    final mu = math.atan2(y - o.y, x - o.x);
    var r = (o.theta - mu) % (2 * math.pi);
    if (r > math.pi) r -= 2 * math.pi;
    if (r <= -math.pi) r += 2 * math.pi;
    left.add(r);
    sumC += math.cos(r);
  }
  fix
    ..meanCos = sumC / n
    ..leftovers = left
    ..kappa = kappaFromMeanCos(sumC / n);
  fix.cov = covarianceAt(obs, x, y, fix.kappa, eps: eps);
  return fix;
}

/// (κ Î)⁻¹ with Î from Lenth's Eqs. 2.8–2.9 at (x, y).
Cov? covarianceAt(List<Obs> obs, double x, double y, double kappa,
    {double eps = 1e-12}) {
  if (kappa <= 0 || !kappa.isFinite) return null;
  var ixx = 0.0, iyy = 0.0, ixy = 0.0;
  for (final o in obs) {
    final s = math.sin(o.theta), c = math.cos(o.theta);
    final u = x - o.x, v = y - o.y;
    final d2 = u * u + v * v;
    final d3 = d2 * math.sqrt(d2);
    if (d3 == 0) return null;
    final sS = v / d3, cS = u / d3;
    ixx += s * sS;
    iyy += c * cS;
    ixy += -0.5 * (s * cS + c * sS);
  }
  ixx *= kappa;
  iyy *= kappa;
  ixy *= kappa;
  final det = ixx * iyy - ixy * ixy;
  final scale = math.max(ixx.abs(), math.max(iyy.abs(), ixy.abs()));
  if (scale == 0 || !det.isFinite || det.abs() < eps * scale * scale) {
    return null;
  }
  final q = Cov(iyy / det, ixx / det, -ixy / det);
  if (![q.xx, q.yy, q.xy].every((v) => v.isFinite)) return null;
  if (q.xx < 0 || q.yy < 0) return null;
  return q;
}

// --- The simulation (test/localization/ellipse_coverage_data/ellipse_simulation.dart)

const _simRuns = 2000;
const _simCounts = [3, 4, 5, 6, 8, 10];
const _simSpreads = [5.0, 10.0, 15.0];
const _simSeed = 11323;

double besselRatio(double k) {
  if (k > 50) return 1 - 1 / (2 * k) - 1 / (8 * k * k) - 1 / (8 * k * k * k);
  var i0 = 0.0, i1 = 0.0, term = 1.0;
  for (var m = 0; m < 200; m++) {
    if (m > 0) term *= (k / 2) * (k / 2) / (m * m);
    i0 += term;
    i1 += term * (k / 2) / (m + 1);
  }
  return i1 / i0;
}

/// κ whose circular standard deviation √(−2 ln A(κ)) is [sdDeg].
double kappaForSd(double sdDeg) {
  final sd = sdDeg * math.pi / 180;
  final target = math.exp(-sd * sd / 2);
  var lo = 1e-6, hi = 1e5;
  for (var i = 0; i < 200; i++) {
    final mid = math.sqrt(lo * hi);
    if (besselRatio(mid) < target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return math.sqrt(lo * hi);
}

/// The circular standard deviation, degrees, of a von Mises with [kappa].
double sdForKappa(double kappa) =>
    math.sqrt(-2 * math.log(besselRatio(kappa))) * 180 / math.pi;

double vonMises(math.Random r, double kappa) {
  final tau = 1 + math.sqrt(1 + 4 * kappa * kappa);
  final rho = (tau - math.sqrt(2 * tau)) / (2 * kappa);
  final rr = (1 + rho * rho) / (2 * rho);
  while (true) {
    final z = math.cos(math.pi * r.nextDouble());
    final f = (1 + rr * z) / (rr + z);
    final c = kappa * (rr - f);
    final u2 = r.nextDouble();
    if (c * (2 - c) - u2 > 0 || math.log(c / u2) + 1 - c >= 0) {
      return (r.nextDouble() > 0.5 ? 1 : -1) * math.acos(f);
    }
  }
}

List<Obs> drawFix(math.Random r, int n, double kappa) => [
      for (var i = 0; i < n; i++)
        () {
          final dir = -math.pi / 2 + r.nextDouble() * math.pi;
          final dist = 500 + r.nextDouble() * 1500;
          final x = dist * math.cos(dir), y = dist * math.sin(dir);
          return Obs(x, y, math.atan2(-y, -x) + vonMises(r, kappa));
        }(),
    ];

class SimCell {
  int runs = 0, noEllipse = 0, covered = 0, coveredTrueKappa = 0;

  /// The first fixes of this cell, kept for the picture of coverage.
  final first = <(List<Obs>, Fix)>[];
}

/// Task 11.323's simulation, in its exact draw order, so it gives the app's
/// fixes and the app's counts.
Map<(int, double), SimCell> simulate({int keep = 0}) {
  final r = math.Random(_simSeed);
  final cells = <(int, double), SimCell>{};
  for (final n in _simCounts) {
    for (final sd in _simSpreads) {
      final kappa = kappaForSd(sd);
      final cell = SimCell();
      for (var run = 0; run < _simRuns; run++) {
        final obs = drawFix(r, n, kappa);
        final fix = solve(obs);
        cell.runs++;
        if (!fix.hasEllipse) {
          cell.noEllipse++;
          continue;
        }
        final d2 = mahalanobis2(-fix.x!, -fix.y!, fix.cov!);
        if (d2 <= chi95) cell.covered++;
        if (d2 * kappa / fix.kappa <= chi95) cell.coveredTrueKappa++;
        if (cell.first.length < keep) cell.first.add((obs, fix));
      }
      cells[(n, sd)] = cell;
    }
  }
  return cells;
}

// ---------------------------------------------------------------------------
// The app's data, and the check that this copy agrees with it
// ---------------------------------------------------------------------------

class Example {
  Example(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  int get n => json['bearings'] as int;
  double get sd => (json['bearing_spread_sd_deg'] as num).toDouble();
  double get trueKappa => (json['true_kappa'] as num).toDouble();
  List<Map<String, dynamic>> get stations =>
      (json['stations'] as List).cast<Map<String, dynamic>>();
  List<Obs> get obs => [
        for (final s in stations)
          Obs.compass(_d(s['x_m']), _d(s['y_m']), _d(s['bearing_compass_deg'])),
      ];
  double get estX => _d(json['estimate']['x_m']);
  double get estY => _d(json['estimate']['y_m']);
  double get kappa => _d(json['kappa']['value']);
  Cov get cov => Cov(_d(json['covariance_m2']['xx']),
      _d(json['covariance_m2']['yy']), _d(json['covariance_m2']['xy']));
  Map<String, dynamic> get e95 =>
      json['ellipses']['ninety_five'] as Map<String, dynamic>;
  Map<String, dynamic> get e1 => json['ellipses']['one_sd'] as Map<String, dynamic>;
  bool get covered => json['covered_by_95_ellipse'] as bool;
  double get cellCoverage => _d(json['this_cells_coverage_chi_square']);
}

double _d(Object? v) => (v as num).toDouble();

Map<String, Example> _loadExamples() {
  final j = jsonDecode(File('$_dataDir/worked_examples.json').readAsStringSync())
      as Map<String, dynamic>;
  return {
    for (final e in (j['examples'] as List).cast<Map<String, dynamic>>())
      e['id'] as String: Example(e),
  };
}

class CoverageRow {
  CoverageRow(this.n, this.sd, this.runs, this.withEllipse, this.covered,
      this.coverage, this.coveredTrue, this.coverageTrue);
  final int n, runs, withEllipse, covered, coveredTrue;
  final double sd, coverage, coverageTrue;
}

List<CoverageRow> _loadCoverage() {
  final lines = File('$_dataDir/coverage_chi_square.csv').readAsLinesSync();
  final head = lines.first.split(',');
  int col(String name) {
    final i = head.indexOf(name);
    if (i < 0) throw StateError('coverage_chi_square.csv has no column $name');
    return i;
  }

  return [
    for (final l in lines.skip(1).where((l) => l.trim().isNotEmpty))
      () {
        final f = l.split(',');
        return CoverageRow(
          int.parse(f[col('bearings')]),
          double.parse(f[col('spread_sd_deg')]),
          int.parse(f[col('runs')]),
          int.parse(f[col('fixes_with_ellipse')]),
          int.parse(f[col('covered_chi_square')]),
          double.parse(f[col('coverage_chi_square')]),
          int.parse(f[col('covered_chi_square_true_kappa')]),
          double.parse(f[col('coverage_chi_square_true_kappa')]),
        );
      }(),
  ];
}

/// The cells the coverage animation draws from: their first fixes, from the
/// same simulation that is checked against the app's counts below.
late final Map<(int, double), SimCell> _sim;

void _fail(String what) {
  stderr.writeln('theory_figures: this script disagrees with the app, so it '
      'draws nothing.\n  $what\nThe app\'s numbers are in '
      'test/localization/ellipse_coverage_data/; the method copied here is '
      'lib/localization/lenth_mle.dart.');
  exit(1);
}

void _near(String what, double got, double want, double tol,
    {bool relative = false}) {
  final err = relative ? (got - want).abs() / want.abs() : (got - want).abs();
  if (!(err <= tol)) {
    _fail('$what: this script gets $got, the app wrote $want '
        '(${relative ? 'relative ' : ''}tolerance $tol).');
  }
}

/// The tolerances. The data files round to 6 decimals, so positions are
/// compared to a millimeter and ratios to one part in ten thousand; a real
/// difference in method shows up far above both.
void _verify(Map<String, Example> examples, List<CoverageRow> coverage) {
  for (final id in ['n3_sd5', 'n3_sd15', 'n5_sd5', 'n5_sd15', 'n10_sd5', 'n10_sd15']) {
    final e = examples[id];
    if (e == null) _fail('worked_examples.json has no example $id');
    final ex = e!;
    _near('$id: true kappa', kappaForSd(ex.sd), ex.trueKappa, 1e-5, relative: true);
    final fix = solve(ex.obs);
    final path = ex.json['solver_path'] as Map<String, dynamic>;
    _near('$id: start x', fix.startX, _d(path['start']['x_m']), 1e-3);
    _near('$id: start y', fix.startY, _d(path['start']['y_m']), 1e-3);
    final steps = (path['steps'] as List).cast<Map<String, dynamic>>();
    if (steps.length != fix.steps.length) {
      _fail('$id: ${fix.steps.length} solver steps here, ${steps.length} in the app');
    }
    for (var i = 0; i < steps.length; i++) {
      _near('$id: step ${i + 1} x', fix.steps[i].toX, _d(steps[i]['to']['x_m']), 1e-3);
      _near('$id: step ${i + 1} y', fix.steps[i].toY, _d(steps[i]['to']['y_m']), 1e-3);
      _near('$id: step ${i + 1} fraction', fix.steps[i].fraction,
          _d(steps[i]['fraction']), 0);
      _near('$id: step ${i + 1} fit', fix.steps[i].sumCos,
          _d(steps[i]['sum_cosine']), 1e-6);
    }
    _near('$id: estimate x', fix.x!, ex.estX, 1e-3);
    _near('$id: estimate y', fix.y!, ex.estY, 1e-3);
    _near('$id: mean cosine', fix.meanCos, _d(ex.json['kappa']['mean_cosine']), 1e-6);
    _near('$id: kappa', fix.kappa, ex.kappa, 1e-4, relative: true);
    for (var i = 0; i < ex.n; i++) {
      _near('$id: station ${i + 1} leftover angle', fix.leftovers[i],
          _d(ex.stations[i]['leftover_angle_math_rad']), 1e-6);
    }
    _near('$id: covariance xx', fix.cov!.xx, ex.cov.xx, 1e-4, relative: true);
    _near('$id: covariance yy', fix.cov!.yy, ex.cov.yy, 1e-4, relative: true);
    _near('$id: covariance xy', fix.cov!.xy, ex.cov.xy, 1e-4, relative: true);
    final e95 = fix.ellipse(chi95), e1 = fix.ellipse(1);
    _near('$id: 95% semi-major', e95.a, _d(ex.e95['semi_major_m']), 1e-3);
    _near('$id: 95% semi-minor', e95.b, _d(ex.e95['semi_minor_m']), 1e-3);
    _near('$id: 95% rotation', e95.rotDeg,
        _d(ex.e95['major_axis_rotation_ccw_from_east_deg']), 1e-3);
    _near('$id: 1-SD semi-major', e1.a, _d(ex.e1['semi_major_m']), 1e-3);
    _near('$id: 1-SD semi-minor', e1.b, _d(ex.e1['semi_minor_m']), 1e-3);
    _near('$id: chi-square scale', chi95, _d(ex.e95['scale_k']), 1e-6);
    final m2 = mahalanobis2(-fix.x!, -fix.y!, fix.cov!);
    _near('$id: true point distance', m2,
        _d(ex.json['true_point_mahalanobis_squared']), 1e-4, relative: true);
    if ((m2 <= chi95) != ex.covered) _fail('$id: covered disagrees');
  }

  // The coverage table, cell by cell, to the count.
  _sim = simulate(keep: 30);
  for (final row in coverage) {
    final cell = _sim[(row.n, row.sd)];
    if (cell == null) _fail('no simulated cell for ${row.n} bearings, ${row.sd}°');
    final c = cell!;
    final what = '${row.n} bearings at ${row.sd}°';
    if (c.runs != row.runs ||
        c.runs - c.noEllipse != row.withEllipse ||
        c.covered != row.covered ||
        c.coveredTrueKappa != row.coveredTrue) {
      _fail('$what: here ${c.runs - c.noEllipse} with an ellipse, ${c.covered} '
          'covered, ${c.coveredTrueKappa} with the true kappa; the app wrote '
          '${row.withEllipse}, ${row.covered}, ${row.coveredTrue}.');
    }
  }
  if (coverage.length != _sim.length) {
    _fail('coverage_chi_square.csv has ${coverage.length} rows, the '
        'simulation ${_sim.length} cells');
  }

  // The fix the app's own tests pin as one where a step was shortened.
  final shortened = solve(_shortenedFixFromTest());
  if (!shortened.steps.any((s) => s.shortened && !s.rejected)) {
    _fail('the shortened-step fix in lenth_mle_test.dart takes no shortened '
        'step here');
  }
  stdout.writeln('theory_figures: the method here reproduces the app: 6 worked '
      'examples (path, estimate, kappa, covariance, ellipses), all '
      '${coverage.length} coverage cells to the count, and the shortened step.');
}

/// `shortenedFix` from lenth_mle_test.dart, read from the test rather than
/// copied, so the picture shows the fix the test pins.
List<Obs> _shortenedFixFromTest() {
  final src = File(_solverTest).readAsStringSync();
  final block =
      RegExp(r'final shortenedFix = \[(.*?)\];', dotAll: true).firstMatch(src);
  if (block == null) _fail('lenth_mle_test.dart no longer has `shortenedFix`');
  final fixes = RegExp(r'fix\(\s*([-0-9.e]+),\s*([-0-9.e]+),\s*([-0-9.e]+),?\s*\)')
      .allMatches(block![1]!)
      .map((m) => Obs(double.parse(m[1]!), double.parse(m[2]!), double.parse(m[3]!)))
      .toList();
  if (fixes.length < 3) _fail('could not read `shortenedFix`\'s bearings');
  return fixes;
}

// ---------------------------------------------------------------------------
// Drawing: SVG, colored by the site's CSS (style.css, "Theory figures")
// ---------------------------------------------------------------------------
//
// Classes, one color per quantity across the whole page:
//   b / bf / tb   a bearing (blue)            e / ef / te   the estimate (red)
//   k / kf / tk   the spread, κ (magenta)     l / lf / tl   the ellipse (green)
//   g / gf / t    ink                         m / mf / tm   muted ink
//   hill          the likelihood, as shading in the ink color

/// A number for an SVG attribute: one decimal, no trailing ".0".
String _n(double v) {
  final s = v.toStringAsFixed(1);
  final t = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  return t == '-0' ? '0' : t;
}

/// Thousands with a comma, as the page writes them.
String _int(num v) {
  final s = v.round().abs().toString();
  final out = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String _svg(String id, double w, double h, String body, {String style = ''}) =>
    '<svg xmlns="http://www.w3.org/2000/svg" class="tf" id="$id" '
    'viewBox="0 0 ${_n(w)} ${_n(h)}" aria-hidden="true" focusable="false">'
    '${style.isEmpty ? '' : '<style>$style</style>'}$body</svg>';

String _ln(double x1, double y1, double x2, double y2, String cls,
        {double w = 1.5, String? dash, double? opacity}) =>
    '<line x1="${_n(x1)}" y1="${_n(y1)}" x2="${_n(x2)}" y2="${_n(y2)}" '
    'class="$cls" stroke-width="$w"${dash == null ? '' : ' stroke-dasharray="$dash"'}'
    '${opacity == null ? '' : ' opacity="$opacity"'}/>';

String _circ(double cx, double cy, double r, String cls, {double w = 1.5}) =>
    '<circle cx="${_n(cx)}" cy="${_n(cy)}" r="${_n(r)}" class="$cls" stroke-width="$w"/>';

String _path(String d, String cls,
        {double w = 1.5, String? dash, String extra = ''}) =>
    '<path d="$d" class="$cls" stroke-width="$w"'
    '${dash == null ? '' : ' stroke-dasharray="$dash"'}$extra/>';

/// [body] may hold `<tspan>` markup. Every label in this file is written
/// here, with no `&` or `<` in it, so nothing is escaped.
String _text(double x, double y, String body,
        {String cls = 't', String anchor = 'start', double? size, bool bold = false}) =>
    '<text x="${_n(x)}" y="${_n(y)}" class="$cls"'
    '${anchor == 'start' ? '' : ' text-anchor="$anchor"'}'
    '${size == null ? '' : ' font-size="${_n(size)}"'}'
    '${bold ? ' font-weight="600"' : ''}>$body</text>';

String _span(String cls, String s) => '<tspan class="$cls">$s</tspan>';

/// An ellipse centered on (cx, cy) in pixels, its major axis [rotDeg]
/// counterclockwise from east (the screen's y runs down, hence the sign).
String _ell(double cx, double cy, double rx, double ry, double rotDeg,
        String cls, {double w = 2, String? dash}) =>
    '<ellipse cx="${_n(cx)}" cy="${_n(cy)}" rx="${_n(rx)}" ry="${_n(ry)}" '
    'transform="rotate(${_n(-rotDeg)} ${_n(cx)} ${_n(cy)})" class="$cls" '
    'stroke-width="$w" fill="none"${dash == null ? '' : ' stroke-dasharray="$dash"'}/>';

/// Where a bearing was taken: a small triangle.
String _station(double x, double y, {double s = 6}) =>
    '<path d="M${_n(x)} ${_n(y - s)}L${_n(x + s * 0.9)} ${_n(y + s * 0.6)}'
    'L${_n(x - s * 0.9)} ${_n(y + s * 0.6)}Z" class="gf"/>';

/// The animal's true position: a five-pointed star, ringed in the page color
/// so it reads over the shading.
String _star(double x, double y, {double r = 7, bool hollow = false}) {
  final pts = <String>[];
  for (var i = 0; i < 10; i++) {
    final rr = i.isEven ? r : r * 0.45;
    final a = -math.pi / 2 + i * math.pi / 5;
    pts.add('${_n(x + rr * math.cos(a))} ${_n(y + rr * math.sin(a))}');
  }
  return '<path d="M${pts.join('L')}Z" class="${hollow ? 'bg g' : 'gf bgs'}" '
      'stroke-width="${hollow ? 1.5 : 1.2}" stroke-linejoin="round"/>';
}

/// The estimate: a red dot ringed in the page color.
String _est(double x, double y, {double r = 4.5}) =>
    _circ(x, y, r, 'ef bgs', w: 1.5);

String _arrow(double x1, double y1, double x2, double y2, String cls,
    {double w = 2, String? dash, double head = 7}) {
  final a = math.atan2(y2 - y1, x2 - x1);
  final len = math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));
  final h = math.min(head, len * 0.6);
  final bx = x2 - h * math.cos(a), by = y2 - h * math.sin(a);
  final p1x = bx + h * 0.45 * math.sin(a), p1y = by - h * 0.45 * math.cos(a);
  final p2x = bx - h * 0.45 * math.sin(a), p2y = by + h * 0.45 * math.cos(a);
  final fill = cls.split(' ').first;
  return '${_ln(x1, y1, bx, by, cls, w: w, dash: dash)}'
      '<path d="M${_n(x2)} ${_n(y2)}L${_n(p1x)} ${_n(p1y)}L${_n(p2x)} ${_n(p2y)}Z" '
      'class="${fill}f"/>';
}

/// A map in meters drawn into a pixel rectangle, north up, one scale.
class View {
  View(this.cx, this.cy, this.mPerPx, this.px0, this.py0, this.pw, this.ph);

  /// The smallest scale that fits [pts] (meters) into the rectangle, with
  /// [margin] pixels to spare on every side.
  factory View.fit(List<(double, double)> pts, double px0, double py0,
      double pw, double ph, {double margin = 14}) {
    final xs = pts.map((p) => p.$1), ys = pts.map((p) => p.$2);
    final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    final s = math.max((maxX - minX) / (pw - 2 * margin),
        (maxY - minY) / (ph - 2 * margin));
    return View((minX + maxX) / 2, (minY + maxY) / 2, s, px0, py0, pw, ph);
  }

  final double cx, cy, mPerPx, px0, py0, pw, ph;
  double sx(double x) => px0 + pw / 2 + (x - cx) / mPerPx;
  double sy(double y) => py0 + ph / 2 - (y - cy) / mPerPx;
  double mx(double px) => cx + (px - px0 - pw / 2) * mPerPx;
  double my(double py) => cy - (py - py0 - ph / 2) * mPerPx;
  double px(double meters) => meters / mPerPx;

  String clip(String id) =>
      '<clipPath id="$id"><rect x="${_n(px0)}" y="${_n(py0)}" '
      'width="${_n(pw)}" height="${_n(ph)}"/></clipPath>';

  String frame() => '<rect x="${_n(px0)}" y="${_n(py0)}" width="${_n(pw)}" '
      'height="${_n(ph)}" class="rule" fill="none" stroke-width="1"/>';

  /// Whether a bearing's line, from where it was taken outward, passes
  /// through the view (Liang–Barsky clipping of the ray to the rectangle).
  bool crosses(Obs o) {
    final x0 = mx(px0), x1 = mx(px0 + pw), y0 = my(py0 + ph), y1 = my(py0);
    final dx = math.cos(o.theta), dy = math.sin(o.theta);
    var lo = 0.0, hi = double.infinity;
    for (final (p, q) in [
      (-dx, o.x - x0), (dx, x1 - o.x), (-dy, o.y - y0), (dy, y1 - o.y),
    ]) {
      if (p == 0) {
        if (q < 0) return false;
      } else {
        final r = q / p;
        if (p < 0) {
          lo = math.max(lo, r);
        } else {
          hi = math.min(hi, r);
        }
      }
    }
    return lo <= hi;
  }

  /// A bearing drawn from where it was taken, off the edge of the view.
  String ray(Obs o, {double w = 1.6, double? opacity}) => _ln(
      sx(o.x), sy(o.y), sx(o.x + 50000 * math.cos(o.theta)),
      sy(o.y + 50000 * math.sin(o.theta)), 'b', w: w, opacity: opacity);

  String ellipse(double x, double y, Ellipse e, String cls,
          {double w = 2, String? dash}) =>
      _ell(sx(x), sy(y), px(e.a), px(e.b), e.rotDeg, cls, w: w, dash: dash);

  /// A scale bar about [target] pixels long, at the bottom left.
  String scaleBar({double target = 70}) {
    final raw = target * mPerPx;
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final nice = [1, 2, 2.5, 5, 10]
        .map((f) => f * mag)
        .reduce((a, b) => (a - raw).abs() < (b - raw).abs() ? a : b);
    final len = px(nice), x = px0 + 8, y = py0 + ph - 9;
    final label = nice >= 1000 ? '${_n(nice / 1000)} km' : '${_int(nice)} m';
    return _ln(x, y, x + len, y, 'g', w: 2) +
        _ln(x, y - 4, x, y + 1, 'g', w: 1.5) +
        _ln(x + len, y - 4, x + len, y + 1, 'g', w: 1.5) +
        _text(x + len + 5, y + 4, label, cls: 't halo', size: 11.5);
  }

  /// "N" with an arrow, top right.
  String north() {
    final x = px0 + pw - 13, y = py0 + 9;
    return _arrow(x, y + 22, x, y, 'g', w: 1.5, head: 6) +
        _text(x, y + 34, 'N', cls: 't halo', anchor: 'middle', size: 11.5);
  }

  /// Relative likelihood rel(x, y) ∈ [0, 1] drawn as shading: a grayscale
  /// PNG used as a mask over a rectangle of the ink color, so the same file
  /// reads on a light page and a dark one.
  String hill(String id, double Function(double, double) rel,
      {int res = 120, double maxAlpha = 0.55}) {
    final w = res, h = (res * ph / pw).round();
    final pixels = <int>[];
    for (var j = 0; j < h; j++) {
      pixels.add(0); // PNG filter byte: none
      for (var i = 0; i < w; i++) {
        final x = mx(px0 + (i + 0.5) * pw / w), y = my(py0 + (j + 0.5) * ph / h);
        final v = rel(x, y).clamp(0.0, 1.0);
        pixels.add((255 * maxAlpha * v).round());
      }
    }
    final uri = 'data:image/png;base64,${base64.encode(_png(w, h, pixels))}';
    final box = 'x="${_n(px0)}" y="${_n(py0)}" width="${_n(pw)}" height="${_n(ph)}"';
    return '<mask id="$id" maskUnits="userSpaceOnUse" $box>'
        '<image href="$uri" $box preserveAspectRatio="none"/></mask>'
        '<rect $box class="hill" mask="url(#$id)"/>';
  }

  /// The line where rel(x, y) = [level], by marching squares.
  String contour(double Function(double, double) rel, double level,
      String cls, {int res = 140, double w = 1, String? dash}) {
    final nx = res, ny = (res * ph / pw).round();
    final gx = [for (var i = 0; i <= nx; i++) px0 + i * pw / nx];
    final gy = [for (var j = 0; j <= ny; j++) py0 + j * ph / ny];
    final v = [
      for (var j = 0; j <= ny; j++)
        [for (var i = 0; i <= nx; i++) rel(mx(gx[i]), my(gy[j])) - level],
    ];
    final d = StringBuffer();
    (double, double) lerp(double xa, double ya, double va, double xb, double yb,
        double vb) {
      final t = va / (va - vb);
      return (xa + t * (xb - xa), ya + t * (yb - ya));
    }

    for (var j = 0; j < ny; j++) {
      for (var i = 0; i < nx; i++) {
        final a = v[j][i], b = v[j][i + 1], c = v[j + 1][i + 1], e = v[j + 1][i];
        final pts = <(double, double)>[];
        if ((a > 0) != (b > 0)) pts.add(lerp(gx[i], gy[j], a, gx[i + 1], gy[j], b));
        if ((b > 0) != (c > 0)) {
          pts.add(lerp(gx[i + 1], gy[j], b, gx[i + 1], gy[j + 1], c));
        }
        if ((c > 0) != (e > 0)) {
          pts.add(lerp(gx[i + 1], gy[j + 1], c, gx[i], gy[j + 1], e));
        }
        if ((e > 0) != (a > 0)) pts.add(lerp(gx[i], gy[j + 1], e, gx[i], gy[j], a));
        for (var k = 0; k + 1 < pts.length; k += 2) {
          d.write('M${_n(pts[k].$1)} ${_n(pts[k].$2)}'
              'L${_n(pts[k + 1].$1)} ${_n(pts[k + 1].$2)}');
        }
      }
    }
    return _path(d.toString(), cls, w: w, dash: dash, extra: ' fill="none"');
  }
}

// --- A minimal PNG writer: 8-bit grayscale, no interlace.

final List<int> _crcTable = List.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];

List<int> _chunk(String type, List<int> data) {
  final body = [...type.codeUnits, ...data];
  return [..._u32(data.length), ...body, ..._u32(_crc(body))];
}

List<int> _png(int w, int h, List<int> rows) => [
      137, 80, 78, 71, 13, 10, 26, 10,
      ..._chunk('IHDR', [..._u32(w), ..._u32(h), 8, 0, 0, 0, 0]),
      ..._chunk('IDAT', ZLibCodec(level: 9).encode(rows)),
      ..._chunk('IEND', []),
    ];

// --- Animation: each frame is a group shown for its slice of a loop.

/// CSS for frames `.f0` … shown over [spans] (start, end) seconds of a loop
/// [total] seconds long; an end of null keeps the frame to the loop's end.
/// A frame that stays fades in over 0.3 s; one that is replaced switches at
/// once. Readers who ask for reduced motion get the still
/// version instead (style.css), and this keeps the last state if not.
String _frames(String id, List<(double, double?)> spans, double total) {
  String pc(double t) => (100 * t / total).clamp(0, 100).toStringAsFixed(3);
  final css = StringBuffer();
  for (var k = 0; k < spans.length; k++) {
    final (a, b) = spans[k];
    final name = '$id-f$k';
    css.write('#$id .f$k{opacity:0;animation:$name ${_n(total)}s linear infinite}');
    if (b == null) {
      // Builds up and stays: fades in, holds to the end of the loop.
      final fadeIn = math.max(0.0, a - 0.3);
      css.write('@keyframes $name{0%,${pc(fadeIn)}%{opacity:0}${pc(a)}%{opacity:1}'
          '99.5%{opacity:1}100%{opacity:0}}');
    } else {
      // Replaced by the next frame: switches at once, so two frames (or two
      // counts) are never seen on top of each other.
      css.write('@keyframes $name{0%{opacity:0}${pc(a)}%{opacity:0}'
          '${pc(a + 0.02)}%{opacity:1}${pc(b)}%{opacity:1}'
          '${pc(b + 0.02)}%,100%{opacity:0}}');
    }
    final last = b == null;
    css.write('@media (prefers-reduced-motion:reduce){#$id .f$k{animation:none;'
        'opacity:${last ? 1 : 0}}}');
  }
  return css.toString();
}

String _g(int k, String body) => '<g class="f$k">$body</g>';

// ---------------------------------------------------------------------------
// The figures, in the order the page uses them
// ---------------------------------------------------------------------------

const double _w = 360; // every figure is drawn for a phone's width

/// Step 1. One bearing as a fan of likely directions, at three spreads: a
/// wedge whose shading at each angle is the von Mises density there (scaled
/// to each wedge's own peak, so the wide one is still visible), and under it
/// that density as a curve, on one vertical scale for all three, so the
/// narrow curve stands tall and the wide one low over the same area. The
/// wedge says nothing about distance, so it fades out at the top rather than
/// ending.
String _figBearingFan() {
  final body = StringBuffer();
  const r = 105.0, sy = 122.0, colW = 118.0;
  const plotHalf = 52.0, plotDeg = 40.0, base = 252.0, plotH = 72.0;
  const fade = 22.0; // the wedge's last pixels fade, so it has no far end
  const guides = [-20.0, -10.0, 10.0, 20.0];
  const spreads = [5.0, 10.0, 15.0];
  final kappas = [for (final sd in spreads) kappaForSd(sd)];
  // The density of an error ε (radians), per radian.
  double density(double kappa, double eps) =>
      math.exp(kappa * math.cos(eps)) / (2 * math.pi * _besselI0(kappa));
  final peak = density(kappas.first, 0); // the tallest curve sets the scale
  for (final (i, sd) in spreads.indexed) {
    final cx = 60.0 + 120 * i;
    final kappa = kappas[i];

    // The wedge: a grayscale mask over a rectangle of the bearing color.
    const res = 2; // mask pixels per drawing unit
    final x0 = cx - colW / 2, y0 = sy - r;
    final w = (colW * res).round(), h = (r * res).round();
    final pixels = <int>[];
    for (var j = 0; j < h; j++) {
      pixels.add(0); // PNG filter byte: none
      for (var k = 0; k < w; k++) {
        final dx = x0 + (k + 0.5) / res - cx, dy = sy - (y0 + (j + 0.5) / res);
        final d = math.sqrt(dx * dx + dy * dy);
        final phi = math.atan2(dx, dy);
        var v = d > r || dy <= 0 ? 0.0 : math.exp(kappa * (math.cos(phi) - 1));
        if (d > r - fade) v *= ((r - d) / fade).clamp(0.0, 1.0);
        pixels.add((255 * 0.6 * v).round());
      }
    }
    final uri = 'data:image/png;base64,${base64.encode(_png(w, h, pixels))}';
    final box = 'x="${_n(x0)}" y="${_n(y0)}" width="${_n(colW)}" height="${_n(r)}"';
    body.write('<mask id="fan-mask-$i" maskUnits="userSpaceOnUse" $box>'
        '<image href="$uri" $box preserveAspectRatio="none"/></mask>'
        '<rect $box class="bf" mask="url(#fan-mask-$i)"/>');

    // Guides at 10° and 20° either side, on the wedge and on the curve, so
    // the widths can be read and the two matched.
    for (final g in guides) {
      final a = g * math.pi / 180;
      body
        ..write(_ln(cx, sy, cx + r * math.sin(a), sy - r * math.cos(a), 'm',
            w: 0.8, dash: '2 3'))
        ..write(_ln(cx + g / plotDeg * plotHalf, base,
            cx + g / plotDeg * plotHalf, base - plotH, 'm',
            w: 0.8, dash: '2 3'));
    }
    if (i == 0) {
      // 10° above its guide's end, 20° beside its own, so they do not touch.
      final a10 = 10 * math.pi / 180, a20 = 20 * math.pi / 180;
      body
        ..write(_text(cx + r * math.sin(a10), sy - r - 5, '10°',
            cls: 'tm', anchor: 'middle', size: 10.5))
        ..write(_text(cx + r * math.sin(a20) + 3, sy - r * math.cos(a20) + 4,
            '20°', cls: 'tm', size: 10.5));
    }
    body
      ..write(_ln(cx, sy, cx, sy - r, 'b', w: 2))
      ..write(_station(cx, sy + 4))
      ..write(_text(cx, sy + 24, 'scatter ${_n(sd)}°', anchor: 'middle'))
      ..write(_text(cx, sy + 41,
          '${_span('tk', 'κ')} = ${kappa < 50 ? _n(kappa) : _int(kappa)}',
          anchor: 'middle'));

    // The curve: the same density against the error, −40° to +40°.
    final pts = <String>[];
    for (var deg = -plotDeg; deg <= plotDeg; deg += 0.5) {
      final y = base - plotH * density(kappa, deg * math.pi / 180) / peak;
      pts.add('${_n(cx + deg / plotDeg * plotHalf)} ${_n(y)}');
    }
    body
      ..write(_path('M${_n(cx - plotHalf)} ${_n(base)}L${pts.join('L')}'
          'L${_n(cx + plotHalf)} ${_n(base)}Z', 'bf',
          w: 0, extra: ' fill-opacity="0.22"'))
      ..write(_path('M${pts.join('L')}', 'b', w: 1.5))
      ..write(_ln(cx - plotHalf, base, cx + plotHalf, base, 'm', w: 1));
    for (final g in [-20.0, 0.0, 20.0]) {
      body.write(_text(cx + g / plotDeg * plotHalf, base + 13,
          g == 0 ? '0°' : '${g < 0 ? '−' : '+'}${_n(g.abs())}°',
          cls: 'tm', anchor: 'middle', size: 10));
    }
  }
  return _svg('fig-bearing-fan', _w, 268, body.toString());
}

/// I₀(κ), the modified Bessel function of the first kind, by its series.
/// Good to double precision for the κ this file draws (up to about 130).
double _besselI0(double k) {
  var sum = 0.0, term = 1.0;
  for (var m = 0; m < 400; m++) {
    if (m > 0) term *= (k / 2) * (k / 2) / (m * m);
    sum += term;
    if (m > k && term < sum * 1e-17) break;
  }
  return sum;
}

/// Likelihood of the bearings at (x, y), relative to [peak]: the "hill",
/// exp(κ (Σ cos(θᵢ − μᵢ) − peak)).
double Function(double, double) _rel(List<Obs> obs, double kappa, double peak) =>
    (x, y) => math.exp(kappa * (sumCos(obs, x, y) - peak));

/// Step 2. Each bearing a ridge; the ridges multiply into one hill.
Map<String, String> _figHillBuild(Example ex) {
  final obs = ex.obs, kappa = ex.trueKappa;
  final fix = solve(obs);
  // Checked: the top of the drawn hill is the app's estimate. Whatever κ is,
  // the highest point of exp(κ Σ cos) is where Σ cos is highest.
  final peak = sumCos(obs, fix.x!, fix.y!);
  for (final (dx, dy) in [(5.0, 0.0), (-5.0, 0.0), (0.0, 5.0), (0.0, -5.0)]) {
    if (sumCos(obs, fix.x! + dx, fix.y! + dy) > peak) {
      _fail('hill-build: the estimate is not the top of the hill');
    }
  }
  final pts = [
    for (final o in obs) (o.x, o.y),
    (0.0, 0.0),
    (fix.x!, fix.y!),
    (-450.0, -950.0),
  ];

  String panel(View v, String id, int upto, {bool small = false}) {
    final b = StringBuffer();
    if (upto > 0) {
      final some = obs.sublist(0, upto);
      final top = upto == obs.length ? peak : upto.toDouble();
      b.write(v.hill('$id-h$upto', _rel(some, kappa, top), res: small ? 80 : 120));
    }
    b.write('<g clip-path="url(#$id-clip)">');
    for (final (i, o) in obs.indexed) {
      b.write(v.ray(o, w: upto == 0 || i < upto ? 1.8 : 1, opacity: i < upto || upto == 0 ? null : 0.35));
    }
    b.write('</g>');
    for (final (i, o) in obs.indexed) {
      b
        ..write(_station(v.sx(o.x), v.sy(o.y)))
        ..write(_text(v.sx(o.x) - 9, v.sy(o.y) + 4, '${i + 1}', cls: 't halo', anchor: 'end', size: 12));
    }
    if (upto == obs.length) {
      b
        ..write(_star(v.sx(0), v.sy(0)))
        ..write(_text(v.sx(0) - 9, v.sy(0) + 4, 'animal', cls: 't halo', anchor: 'end', size: 12))
        ..write(_est(v.sx(fix.x!), v.sy(fix.y!)))
        ..write(_text(v.sx(fix.x!) + 8, v.sy(fix.y!) - 8,
            small ? _span('te', 'estimate') : 'top: ${_span('te', 'the estimate')}',
            cls: 't halo', size: 12));
    }
    return b.toString();
  }

  const titles = [
    'Three bearings',
    'Bearing 1 alone: a ridge along its line',
    '× bearing 2: high only where both are',
    '× bearing 3: one hill, and its top',
  ];
  const short = ['1 · three bearings', '2 · bearing 1 alone', '3 · × bearing 2', '4 · × bearing 3'];

  // The animation.
  final v = View.fit(pts, 10, 30, 340, 380);
  final live = StringBuffer(v.clip('hb-clip'));
  final spans = <(double, double?)>[(0, 2.6), (2.6, 5.2), (5.2, 7.8), (7.8, null)];
  for (var k = 0; k <= obs.length; k++) {
    live.write(_g(k, panel(v, 'hb', k) + _text(10, 20, titles[k], bold: true)));
  }
  live
    ..write(v.scaleBar())
    ..write(v.north());
  final anim = _svg('fig-hill-build', _w, 420, live.toString(),
      style: _frames('fig-hill-build', spans, 12));

  // The still version, for print: the four frames as small multiples.
  final still = StringBuffer();
  for (var k = 0; k <= obs.length; k++) {
    final col = k % 2, row = k ~/ 2;
    final x0 = 4.0 + col * 178, y0 = 6.0 + row * 222;
    final pv = View.fit(pts, x0, y0 + 18, 172, 196, margin: 8);
    still
      ..write(pv.clip('hbs$k-clip'))
      ..write(panel(pv, 'hbs$k', k, small: true))
      ..write(pv.frame())
      ..write(_text(x0, y0 + 12, short[k], bold: true, size: 12));
  }
  return {
    'hill-build': anim,
    'hill-build-steps': _svg('fig-hill-build-steps', _w, 450, still.toString()),
  };
}

/// Step 3. The search climbing the hill: the app's own path, step by step.
Map<String, String> _figSolver(Example ex) {
  final obs = ex.obs;
  final fix = solve(obs); // checked in _verify against the app's path
  final kappa = fix.kappa, peak = sumCos(obs, fix.x!, fix.y!);
  final rel = _rel(obs, kappa, peak);
  final path = [(fix.startX, fix.startY), for (final s in fix.steps) (s.toX, s.toY)];
  final pts = [...path, for (final s in fix.steps) (s.fullX, s.fullY)];

  String scene(View v, String id, {required bool animate}) {
    final b = StringBuffer(v.clip('$id-clip'))
      ..write(v.hill('$id-h', rel, res: 110))
      ..write(v.contour(rel, 0.25, 'm', w: 0.8))
      ..write(v.contour(rel, 0.5, 'm', w: 0.8))
      ..write(v.contour(rel, 0.75, 'm', w: 0.8))
      ..write('<g clip-path="url(#$id-clip)">');
    for (final o in obs) {
      b.write(v.ray(o, w: 1, opacity: 0.55));
    }
    b.write('</g>');
    final spans = <(double, double?)>[];
    var t = 0.4;
    var k = 0;
    String put(String s) {
      if (!animate) return s;
      spans.add((t, null));
      return _g(k++, s);
    }

    final sx0 = v.sx(fix.startX), sy0 = v.sy(fix.startY);
    b.write(put(_circ(sx0, sy0, 5, 'e bg', w: 2) +
        _text(sx0 + 8, sy0 + 16, 'start', cls: 't halo', size: 12)));
    var shown = 0;
    for (final (i, s) in fix.steps.indexed) {
      final x1 = v.sx(s.fromX), y1 = v.sy(s.fromY);
      final x2 = v.sx(s.toX), y2 = v.sy(s.toY);
      final len = math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));
      if (len < 4) break;
      t += 1.1;
      shown = i + 1;
      final mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
      // The step's number sits beside its middle, on the side away from the
      // previous step, so successive labels do not collide.
      final nx = -(y2 - y1) / len, ny = (x2 - x1) / len;
      final side = i.isEven ? 1 : -1;
      b.write(put(_arrow(x1, y1, x2, y2, 'e', w: 2) +
          (len < 50
              ? ''
              : _text(mx + side * nx * 11, my + side * ny * 11 + 4, '${i + 1}',
                  cls: 'te halo', anchor: 'middle', size: 12, bold: true))));
    }
    t += 1.2;
    final ex2 = v.sx(fix.x!), ey2 = v.sy(fix.y!);
    final rest = fix.steps.length - shown;
    b.write(put(_est(ex2, ey2) +
        _text(ex2, ey2 - 16, 'top: ${_span('te', 'the estimate')}',
            cls: 't halo', anchor: 'middle', size: 12) +
        _text(v.px0, v.py0 + v.ph + 16,
            'Steps ${shown + 1}–${fix.steps.length}: $rest more, each too small to see.',
            cls: 'tm', size: 11.5)));
    final crossing = obs.where(v.crosses).length;
    b
      ..write(_text(v.px0, v.py0 + v.ph + 32,
          'A close-up of the hilltop: $crossing of the ${obs.length} bearing '
          'lines cross it.',
          cls: 'tm', size: 11.5))
      ..write(v.frame())
      ..write(v.scaleBar())
      ..write(v.north());
    if (animate) {
      return _svg('fig-$id', _w, v.py0 + v.ph + 40, b.toString(),
          style: _frames('fig-$id', spans, t + 4));
    }
    return _svg('fig-$id', _w, v.py0 + v.ph + 40, b.toString());
  }

  final v = View.fit(pts, 10, 6, 340, 300, margin: 26);
  return {
    'solver': scene(v, 'solver', animate: true),
    'solver-steps': scene(v, 'solver-steps', animate: false),
  };
}

/// Step 3, the safeguard: a step that would have gone downhill is halved.
/// The fix is the one lenth_mle_test.dart pins for exactly this.
String _figSolverShortened() {
  final obs = _shortenedFixFromTest();
  final fix = solve(obs);
  final j = fix.steps.indexWhere((s) => s.shortened && !s.rejected);
  final s = fix.steps[j];
  final peak = sumCos(obs, fix.x!, fix.y!);
  final rel = _rel(obs, fix.kappa, peak);
  // Checked: the whole step lands lower than where it started, and the half
  // step higher. That is the rule the picture illustrates.
  final fromFit = sumCos(obs, s.fromX, s.fromY);
  final fullFit = sumCos(obs, s.fullX, s.fullY);
  if (!(fullFit < fromFit && s.sumCos >= fromFit)) {
    _fail('solver-shortened: the halved step is not the one the rule describes');
  }
  final pts = [
    (fix.startX, fix.startY),
    for (final st in fix.steps.take(j + 1)) ...[(st.toX, st.toY), (st.fullX, st.fullY)],
    (fix.x!, fix.y!),
  ];
  final v = View.fit(pts, 10, 6, 340, 260, margin: 30);
  final b = StringBuffer(v.clip('ss-clip'))
    ..write(v.hill('ss-h', rel, res: 110))
    ..write(v.contour(rel, 0.25, 'm', w: 0.8))
    ..write(v.contour(rel, 0.5, 'm', w: 0.8))
    ..write(v.contour(rel, 0.75, 'm', w: 0.8))
    ..write('<g clip-path="url(#ss-clip)">');
  for (final o in obs) {
    b.write(v.ray(o, w: 1, opacity: 0.55));
  }
  b.write('</g>');
  for (final st in fix.steps.take(j)) {
    b.write(_arrow(v.sx(st.fromX), v.sy(st.fromY), v.sx(st.toX), v.sy(st.toY), 'e', w: 1.5));
  }
  for (final st in fix.steps.skip(j + 1)) {
    b.write(_arrow(v.sx(st.fromX), v.sy(st.fromY), v.sx(st.toX), v.sy(st.toY), 'e', w: 1.5));
  }
  final fx = v.sx(s.fromX), fy = v.sy(s.fromY);
  final wx = v.sx(s.fullX), wy = v.sy(s.fullY);
  final hx = v.sx(s.toX), hy = v.sy(s.toY);
  b
    ..write(_arrow(fx, fy, wx, wy, 'm', w: 1.5, dash: '4 3'))
    ..write(_circ(wx, wy, 4.5, 'g bg', w: 1.5))
    ..write(_text(wx + 8, wy + 4, 'whole step: lower', cls: 't halo', size: 12))
    ..write(_arrow(fx, fy, hx, hy, 'e', w: 2.5))
    ..write(_text(hx + 8, hy + 14, 'half a step: higher', cls: 'te halo', size: 12))
    ..write(_circ(v.sx(fix.startX), v.sy(fix.startY), 5, 'e bg', w: 2))
    ..write(_est(v.sx(fix.x!), v.sy(fix.y!)))
    ..write(_text(v.sx(fix.x!) - 9, v.sy(fix.y!) + 4, 'top: ${_span('te', 'the estimate')}',
        cls: 't halo', anchor: 'end', size: 12))
    ..write(v.frame())
    ..write(v.scaleBar())
    ..write(v.north());
  return _svg('fig-solver-shortened', _w, 272, b.toString());
}

/// Step 4. κ comes from the residuals (the data files call them leftover
/// angles), and with few bearings they are smaller than the true errors.
String _figResiduals(Example few, Example many) {
  const x0 = 36.0, x1 = 334.0, lim = 40.0;
  double ax(double deg) => x0 + (deg + lim) / (2 * lim) * (x1 - x0);
  final b = StringBuffer();
  // Legend.
  b
    ..write(_circ(14, 13, 4.5, 'g bg', w: 1.5))
    ..write(_text(24, 17, 'true error (known only in a simulation)', size: 12))
    ..write(_circ(14, 31, 4.5, 'kf', w: 0))
    ..write(_text(24, 35, '${_span('tk', 'residual')}: bearing vs. line to ${_span('te', 'estimate')}', size: 12));
  var y = 62.0;
  final rowsTop = y;
  for (final ex in [few, many]) {
    final fix = solve(ex.obs);
    final equiv = sdForKappa(fix.kappa);
    b
      ..write(_text(4, y, '${ex.n} bearings, true scatter ${_n(ex.sd)}° '
          '(${_span('tk', 'κ')} = ${_n(ex.trueKappa)})', bold: true, size: 12))
      ..write(_text(4, y + 16, '${_span('tk', 'κ')} from the residuals = '
          '${fix.kappa < 100 ? _n(fix.kappa) : _int(fix.kappa)}, as if the scatter were '
          '${_n(equiv)}°', size: 12));
    y += 30;
    for (final (i, s) in ex.stations.indexed) {
      final err = _d(s['bearing_error_compass_deg']);
      final left = _d(s['leftover_angle_deg']);
      b
        ..write(_text(x0 - 8, y + 4, '${i + 1}', cls: 'tm', anchor: 'end', size: 11))
        ..write(_ln(ax(err), y, ax(left), y, 'm', w: 1))
        ..write(_circ(ax(err), y, 4.5, 'g bg', w: 1.5))
        ..write(_circ(ax(left), y, 4.5, 'kf', w: 0));
      y += 15;
    }
    y += 22;
  }
  final bottom = y - 22;
  // Axis: zero line, ticks, label.
  b.write(_ln(ax(0), rowsTop + 22, ax(0), bottom, 'm', w: 1, dash: '3 3'));
  for (final t in [-40.0, -20.0, 0.0, 20.0, 40.0]) {
    b
      ..write(_ln(ax(t), bottom + 2, ax(t), bottom + 7, 'g', w: 1))
      ..write(_text(ax(t), bottom + 20, '${t > 0 ? '+' : ''}${_n(t)}°',
          anchor: 'middle', size: 11.5));
  }
  b
    ..write(_ln(x0, bottom + 2, x1, bottom + 2, 'g', w: 1))
    ..write(_text((x0 + x1) / 2, bottom + 38,
        'angle from the true line, degrees (clockwise is +)',
        cls: 'tm', anchor: 'middle', size: 11.5));
  return _svg('fig-residual-angles', _w, bottom + 46, b.toString());
}

/// Step 5. The hill's shape becomes the ellipse; and the same hill with the
/// real κ.
String _figHillToEllipse(Example ex) {
  final obs = ex.obs;
  final fix = solve(obs);
  final peak = sumCos(obs, fix.x!, fix.y!);
  final e1 = fix.ellipse(1), e95 = fix.ellipse(chi95);
  final trueCov = fix.cov!.scaled(fix.kappa / ex.trueKappa);
  final eTrue = ellipseOf(trueCov, chi95);
  final ex0 = fix.x!, ey0 = fix.y!;
  // Checked: the 95% ellipse is close to where the hill falls to 5% of its
  // height, exp(−5.991/2). The ellipse is an oval fitted to the hill's top
  // (Lenth's Eq. 2.9), and the real hill is lopsided along its long axis, so
  // "close", not equal: for this example the hill's height at the ellipse's
  // four ends is 1.7% and 6.6% (long axis) and 5.6% (short axis). The bound
  // below, 1–10%, is what the page's sentence rests on.
  final rad = e95.rotDeg * math.pi / 180;
  for (final (along, len) in [(0.0, e95.a), (math.pi / 2, e95.b)]) {
    for (final sign in [1.0, -1.0]) {
      final x = ex0 + sign * len * math.cos(rad + along);
      final y = ey0 + sign * len * math.sin(rad + along);
      final h = math.exp(fix.kappa * (sumCos(obs, x, y) - peak));
      if (h < 0.01 || h > 0.1) {
        _fail('hill-to-ellipse: the 95% ellipse is not near the hill\'s 5% '
            'line (height $h at its edge)');
      }
    }
  }
  final b = StringBuffer();
  // Panel A: the app's hill and its ellipses.
  final ptsA = [
    for (final s in [1.0, -1.0]) ...[
      (ex0 + s * e95.a * math.cos(rad), ey0 + s * e95.a * math.sin(rad)),
      (ex0 - s * e95.b * math.sin(rad), ey0 + s * e95.b * math.cos(rad)),
    ],
  ];
  final va = View.fit(ptsA, 10, 40, 340, 230, margin: 40);
  final relA = _rel(obs, fix.kappa, peak);
  final ax = va.sx(ex0), ay = va.sy(ey0);
  final ca = math.cos(rad), sa = math.sin(rad);
  b
    ..write(_text(4, 14, 'The app\'s hill: ${_span('tk', 'κ')} from the residuals = ${_int(fix.kappa)}', bold: true, size: 12.5))
    ..write(_text(4, 31, 'The green oval approximates the hill.', cls: 'tm', size: 12))
    ..write(va.hill('he-a', relA, res: 120))
    ..write(va.contour(relA, math.exp(-chi95 / 2), 'm', w: 1, dash: '2 2'))
    ..write(va.ellipse(ex0, ey0, e1, 'l', w: 1.6, dash: '5 3'))
    ..write(va.ellipse(ex0, ey0, e95, 'l', w: 2.2))
    ..write(_ln(ax, ay, ax + va.px(e95.a) * ca, ay - va.px(e95.a) * sa, 'l', w: 1.4))
    ..write(_ln(ax, ay, ax - va.px(e95.b) * sa, ay - va.px(e95.b) * ca, 'l', w: 1.4))
    ..write(_text(ax + va.px(e95.a) * ca * 0.55 + 4, ay - va.px(e95.a) * sa * 0.55 + 14,
        '${_span('tl', 'a')} = ${_int(e95.a)} m', cls: 't halo', size: 12))
    ..write(_text(ax - va.px(e95.b) * sa - 4, ay - va.px(e95.b) * ca - 6,
        '${_span('tl', 'b')} = ${_int(e95.b)} m', cls: 't halo', anchor: 'end', size: 12))
    ..write(_est(ax, ay))
    ..write(va.frame())
    ..write(va.scaleBar())
    ..write(_text(4, va.py0 + va.ph + 17,
        '${_span('tl', '- - -')} 1 standard deviation   ${_span('tl', '——')} 95%, 2.45 times larger',
        size: 11.5))
    ..write(_text(4, va.py0 + va.ph + 33,
        '${_span('tm', '·····')} the hill\'s own 95% outline (5% of its top)', size: 11.5));
  // Panel B: the same bearings, the hill with the real κ.
  final top = va.py0 + va.ph + 52;
  final radT = eTrue.rotDeg * math.pi / 180;
  final ptsB = [
    (0.0, 0.0),
    for (final s in [1.0, -1.0]) ...[
      (ex0 + s * eTrue.a * math.cos(radT), ey0 + s * eTrue.a * math.sin(radT)),
      (ex0 - s * eTrue.b * math.sin(radT), ey0 + s * eTrue.b * math.cos(radT)),
    ],
  ];
  final vb = View.fit(ptsB, 10, top + 40, 340, 230, margin: 16);
  final relB = _rel(obs, ex.trueKappa, peak);
  final inApp = mahalanobis2(-ex0, -ey0, fix.cov!) <= chi95;
  final inTrue = mahalanobis2(-ex0, -ey0, trueCov) <= chi95;
  if (inApp || !inTrue) {
    _fail('hill-to-ellipse: this example was chosen because the app\'s ellipse '
        'misses and the real-κ one contains the animal; that is no longer so');
  }
  b
    ..write(_text(4, top + 14, 'The same bearings with the true ${_span('tk', 'κ')} = ${_n(ex.trueKappa)}',
        bold: true, size: 12.5))
    ..write(_text(4, top + 31, 'A wider hill, a bigger ellipse.', cls: 'tm', size: 12))
    ..write(vb.hill('he-b', relB, res: 120))
    ..write(vb.ellipse(ex0, ey0, eTrue, 'l', w: 2.2))
    ..write(vb.ellipse(ex0, ey0, e95, 'l', w: 1.4, dash: '3 2'))
    ..write(_est(vb.sx(ex0), vb.sy(ey0)))
    ..write(_star(vb.sx(0), vb.sy(0)))
    ..write(_text(vb.sx(0) - 10, vb.sy(0) + 5, 'animal', cls: 't halo', anchor: 'end', size: 12))
    ..write(vb.frame())
    ..write(vb.scaleBar())
    ..write(_text(4, vb.py0 + vb.ph + 17,
        '${_span('tl', '- - -')} the app\'s 95% ellipse: misses the animal ✗', size: 11.5))
    ..write(_text(4, vb.py0 + vb.ph + 33,
        '${_span('tl', '——')} 95% with the true ${_span('tk', 'κ')}: contains it ✓', size: 11.5));
  return _svg('fig-hill-to-ellipse', _w, vb.py0 + vb.ph + 40, b.toString());
}

/// Step 5, why 2.45: in one direction ±1 standard deviation holds 68% of a
/// normal distribution and ±1.96 holds 95%; in two directions the
/// one-standard-deviation circle holds only 39%, and 95% needs 2.45, the
/// square root of chi-square's 95% point with two degrees of freedom. The
/// percentages are computed here, not typed.
String _figChiSquareScale() {
  final b = StringBuffer();
  double phi(double z) => math.exp(-z * z / 2) / math.sqrt(2 * math.pi);
  // Φ(z) − Φ(−z) by Simpson's rule: the share of a normal within ±z.
  double within1d(double z) {
    const m = 2000;
    final h = 2 * z / m;
    var sum = phi(-z) + phi(z);
    for (var i = 1; i < m; i++) {
      sum += (i.isOdd ? 4 : 2) * phi(-z + i * h);
    }
    return sum * h / 3;
  }

  // The share of a two-dimensional normal within radius r: 1 − e^(−r²/2).
  double within2d(double r) => 1 - math.exp(-r * r / 2);
  const z95 = 1.959964;
  final r95 = math.sqrt(chi95);
  String pc(double v) => '${(100 * v).round()}%';
  if (pc(within1d(1)) != '68%' || pc(within1d(z95)) != '95%' ||
      pc(within2d(1)) != '39%' || pc(within2d(r95)) != '95%') {
    _fail('chi-square-scale: the shares no longer round to 68, 95, 39 and 95%');
  }

  // Left: one direction.
  const lx0 = 8.0, lx1 = 172.0, base = 176.0, h = 118.0, zl = 3.2;
  double lx(double z) => (lx0 + lx1) / 2 + z / zl * (lx1 - lx0) / 2;
  double ly(double z) => base - h * phi(z) / phi(0);
  String area(double z) {
    final pts = [
      for (var t = -z; t <= z + 1e-9; t += z / 60) '${_n(lx(t))} ${_n(ly(t))}',
    ];
    return 'M${_n(lx(-z))} ${_n(base)}L${pts.join('L')}L${_n(lx(z))} ${_n(base)}Z';
  }

  final curve = [
    for (var t = -zl; t <= zl + 1e-9; t += 0.05) '${_n(lx(t))} ${_n(ly(t))}',
  ];
  b
    ..write(_text(4, 14, 'One direction', bold: true, size: 12.5))
    ..write(_text(4, 30, 'a bell curve', cls: 'tm', size: 12))
    ..write(_path(area(z95), 'lf', w: 0, extra: ' fill-opacity="0.18"'))
    ..write(_path(area(1), 'lf', w: 0, extra: ' fill-opacity="0.22"'))
    ..write(_path('M${curve.join('L')}', 'm', w: 1.5))
    ..write(_ln(lx0, base, lx1, base, 'm', w: 1));
  for (final sgn in [-1.0, 1.0]) {
    b
      ..write(_ln(lx(sgn), base, lx(sgn), ly(sgn), 'l', w: 1.6, dash: '5 3'))
      ..write(_ln(lx(sgn * z95), base, lx(sgn * z95), ly(sgn * z95), 'l', w: 2));
  }
  b
    ..write(_text(lx(0), ly(0) + 46, pc(within1d(1)), anchor: 'middle', size: 12, bold: true))
    ..write(_text(lx(0), base + 15, '±1', cls: 'tm', anchor: 'middle', size: 11))
    ..write(_text(lx(z95), base + 15, '1.96', cls: 'tm', anchor: 'middle', size: 11))
    ..write(_text(lx(-z95), base + 15, '−1.96', cls: 'tm', anchor: 'middle', size: 11))
    ..write(_text(4, base + 36, '${_span('tl', '- - -')} ±1 SD: ${pc(within1d(1))}', size: 11.5))
    ..write(_text(4, base + 52, '${_span('tl', '——')} ±1.96 SD: ${pc(within1d(z95))}', size: 11.5));

  // Right: two directions, east and north, in standard deviations.
  final v = View(0, 0, 3.3 / 80, 192, 40, 160, 160);
  b
    ..write(_text(188, 14, 'Two directions', bold: true, size: 12.5))
    ..write(_text(188, 30, 'east and north together', cls: 'tm', size: 12))
    ..write(v.hill('cs-h', (x, y) => math.exp(-(x * x + y * y) / 2), res: 100))
    ..write(_circ(v.sx(0), v.sy(0), v.px(1), 'l', w: 1.6)
        .replaceFirst('/>', ' stroke-dasharray="5 3" fill="none"/>'))
    ..write(_circ(v.sx(0), v.sy(0), v.px(r95), 'l', w: 2)
        .replaceFirst('/>', ' fill="none"/>'))
    ..write(_text(v.sx(0), v.sy(0) + 4, pc(within2d(1)), cls: 't halo', anchor: 'middle', size: 12, bold: true))
    ..write(_text(188, base + 36, '${_span('tl', '- - -')} 1 SD: ${pc(within2d(1))}', size: 11.5))
    ..write(_text(188, base + 52, '${_span('tl', '——')} 2.45 SD: ${pc(within2d(r95))}', size: 11.5));
  return _svg('fig-chi-square-scale', _w, base + 60, b.toString());
}

/// Step 6. The same bearing errors from well-spread and from nearly parallel
/// stations. Both ellipses use the same spread (10°), as if it were known,
/// so that only the geometry differs.
String _figGeometry() {
  final kappa = kappaForSd(10);
  const errors = [5.0, -4.0, 3.0];
  List<Obs> stations(List<double> compassFromAnimal, List<double> dist) => [
        for (var i = 0; i < 3; i++)
          () {
            final a = compassFromAnimal[i] * math.pi / 180;
            final x = dist[i] * math.sin(a), y = dist[i] * math.cos(a);
            final toward = (compassFromAnimal[i] + 180) % 360;
            return Obs.compass(x, y, toward + errors[i]);
          }(),
      ];
  final spread = stations([30, 150, 270], [1000, 1000, 1000]);
  final parallel = stations([75, 90, 105], [1000, 1000, 1000]);
  final b = StringBuffer();
  final panels = [
    (spread, 'Bearings from around the animal'),
    (parallel, 'Bearings all from one side'),
  ];
  // One scale for both, so the ellipses can be compared by eye.
  final all = <(double, double)>[(0, 0)];
  final fixes = <(Fix, Ellipse)>[];
  for (final (obs, _) in panels) {
    final f = solve(obs);
    final e = ellipseOf(covarianceAt(obs, f.x!, f.y!, kappa)!, chi95);
    fixes.add((f, e));
    final r = e.rotDeg * math.pi / 180;
    all
      ..addAll([for (final o in obs) (o.x, o.y)])
      ..addAll([
        for (final s in [1.0, -1.0]) (f.x! + s * e.a * math.cos(r), f.y! + s * e.a * math.sin(r)),
      ]);
  }
  var top = 0.0;
  for (final (i, (obs, title)) in panels.indexed) {
    final (f, e) = fixes[i];
    final v = View.fit(all, 10, top + 22, 340, 230, margin: 24);
    b
      ..write(_text(4, top + 14, title, bold: true, size: 12.5))
      ..write(v.clip('geo$i-clip'))
      ..write('<g clip-path="url(#geo$i-clip)">');
    for (final o in obs) {
      b.write(v.ray(o, w: 1.6));
    }
    b.write('</g>');
    for (final o in obs) {
      b.write(_station(v.sx(o.x), v.sy(o.y)));
    }
    b
      ..write(v.ellipse(f.x!, f.y!, e, 'l', w: 2.2))
      ..write(_est(v.sx(f.x!), v.sy(f.y!)))
      ..write(_star(v.sx(0), v.sy(0), r: 6))
      ..write(_text(v.px0 + 6, v.py0 + 16,
          '95%: ${_span('tl', 'a')} = ${_int(e.a)} m, ${_span('tl', 'b')} = ${_int(e.b)} m',
          cls: 't halo', size: 12))
      ..write(v.frame())
      ..write(v.scaleBar());
    top = v.py0 + v.ph + 14;
  }
  return _svg('fig-geometry', _w, top - 8, b.toString());
}

/// Step 7. Many simulated fixes, each marked by whether its 95% ellipse
/// contains the animal. These are the first fixes of the app's own
/// simulation (task 11.323's seed), reproduced in _verify to the count.
Map<String, String> _figCoverageBuild() {
  const perGrid = 24, cols = 6, tile = 56.0, gx0 = 12.0;
  const cells = [(3, 10.0), (10, 10.0)];
  final spans = <(double, double?)>[];
  const dt = 0.33, start = 0.6;
  final total = start + perGrid * dt + 4.5;

  String build({required bool animate}) {
    final b = StringBuffer();
    var k = 0;
    var top = 0.0;
    String put(String s, double t, [double? end]) {
      if (!animate) return end == null ? s : '';
      spans.add((t, end));
      return _g(k++, s);
    }

    for (final (n, sd) in cells) {
      final fixes = _sim[(n, sd)]!.first.take(perGrid).toList();
      var hits = 0;
      final y0 = top + 40;
      b.write(_text(4, top + 15, '$n bearings, scatter ${_n(sd)}°', bold: true, size: 12.5));
      for (final (i, (_, fix)) in fixes.indexed) {
        final col = i % cols, row = i ~/ cols;
        final tx = gx0 + col * tile, ty = y0 + row * tile;
        final e = fix.ellipse(chi95);
        final hit = mahalanobis2(-fix.x!, -fix.y!, fix.cov!) <= chi95;
        if (hit) hits++;
        // Each tile has its own scale: the ellipse and the animal fill it.
        final cx = (fix.x! + 0) / 2, cy = (fix.y! + 0) / 2;
        final half = math.sqrt(fix.x! * fix.x! + fix.y! * fix.y!) / 2 + e.a;
        final v = View(cx, cy, half / (tile / 2 - 8), tx, ty, tile - 4, tile - 4);
        final cell = StringBuffer()
          ..write('<rect x="${_n(tx)}" y="${_n(ty)}" width="${_n(tile - 4)}" '
              'height="${_n(tile - 4)}" rx="4" class="rule" fill="none" stroke-width="1"/>')
          ..write(v.ellipse(fix.x!, fix.y!, e, 'l', w: 1.8, dash: hit ? null : '3 2'))
          ..write(_est(v.sx(fix.x!), v.sy(fix.y!), r: 2.6))
          ..write(_star(v.sx(0), v.sy(0), r: 5))
          ..write(_text(tx + tile - 8, ty + 13, hit ? '✓' : '✗',
              cls: hit ? 't' : 'tm', anchor: 'end', size: 12, bold: true));
        b.write(put(cell.toString(), start + i * dt));
      }
      // The running count.
      for (var i = 0; i <= fixes.length; i++) {
        final shown = fixes.take(i).where((p) =>
            mahalanobis2(-p.$2.x!, -p.$2.y!, p.$2.cov!) <= chi95).length;
        final t = i == 0 ? 0.0 : start + (i - 1) * dt;
        final end = i == fixes.length ? null : start + i * dt;
        final label = 'contain the animal: $shown of $i';
        if (!animate && i != fixes.length) continue;
        b.write(put(_text(_w - 4, top + 15, label, anchor: 'end', size: 12.5), t, end));
      }
      if (hits == 0) _fail('coverage-build: no hits drawn');
      top = y0 + (perGrid / cols).ceil() * tile + 6;
    }
    final c3 = _sim[cells[0]]!, c10 = _sim[cells[1]]!;
    double pct(SimCell c) => 100 * c.covered / (c.runs - c.noEllipse);
    b
      ..write(_text(4, top + 12,
          'In ${_int(_simRuns)} such fixes each, the app\'s ellipse contained the',
          size: 12))
      ..write(_text(4, top + 28,
          'animal ${pct(c3).round()}% of the time with 3 bearings, ${pct(c10).round()}% with 10.',
          size: 12))
      ..write(_text(4, top + 48,
          '${_span('tl', '——')} contains ✓   ${_span('tl', '- - -')} misses ✗   '
          '${_span('te', '●')} estimate   ★ animal', cls: 'tm', size: 11.5))
      ..write(_text(4, top + 64, 'Each square has its own scale.', cls: 'tm', size: 11.5));
    final id = animate ? 'fig-coverage-build' : 'fig-coverage-build-steps';
    return _svg(id, _w, top + 70, b.toString(),
        style: animate ? _frames(id, spans, total) : '');
  }

  return {
    'coverage-build': build(animate: true),
    'coverage-build-steps': build(animate: false),
  };
}

/// Item 2's figure: coverage against the number of bearings, from the app's
/// committed table.
String _figCoverageChart(List<CoverageRow> rows) {
  const x0 = 46.0, x1 = 316.0, y0 = 44.0, y1 = 250.0, lo = 30.0, hi = 100.0;
  double ax(num n) => x0 + (n - 3) / 7 * (x1 - x0);
  double ay(double pct) => y1 - (pct - lo) / (hi - lo) * (y1 - y0);
  final b = StringBuffer();
  // The caution's range: five bearings or fewer.
  b
    ..write('<rect x="${_n(ax(3) - 10)}" y="${_n(y0)}" width="${_n(ax(5.5) - ax(3) + 10)}" '
        'height="${_n(y1 - y0)}" class="mf" fill-opacity="0.12"/>')
    ..write(_text(ax(3) - 6, y1 - 8, 'the app cautions', cls: 'tm', size: 11));
  for (final g in [40.0, 60.0, 80.0, 100.0]) {
    b
      ..write(_ln(x0 - 10, ay(g), x1, ay(g), 'rule', w: 1))
      ..write(_text(x0 - 14, ay(g) + 4, '${_n(g)}%', cls: 'tm', anchor: 'end', size: 11));
  }
  b
    ..write(_ln(x0 - 10, ay(95), x1 + 4, ay(95), 'g', w: 1.2, dash: '6 3'))
    ..write(_text(x1 + 6, ay(95) + 4, '95%', size: 11.5, bold: true));
  // The real-κ reference: the range across the three spreads.
  final ns = rows.map((r) => r.n).toSet().toList()..sort();
  final band = <String>[];
  for (final n in ns) {
    band.add('${_n(ax(n))} ${_n(ay(100 * rows.where((r) => r.n == n).map((r) => r.coverageTrue).reduce(math.max)))}');
  }
  for (final n in ns.reversed) {
    band.add('${_n(ax(n))} ${_n(ay(100 * rows.where((r) => r.n == n).map((r) => r.coverageTrue).reduce(math.min)))}');
  }
  final trueLo = rows.map((r) => r.coverageTrue).reduce(math.min);
  final trueHi = rows.map((r) => r.coverageTrue).reduce(math.max);
  b
    ..write('<path d="M${band.join('L')}Z" class="mf" fill-opacity="0.28"/>')
    ..write(_text(ax(6) - 14, ay(90.2) + 15,
        'with the true ${_span('tk', 'κ')}: ${(100 * trueLo).round()}–${(100 * trueHi).round()}%',
        cls: 't halo', size: 11.5));
  final dashes = <double, String?>{5.0: null, 10.0: '6 3', 15.0: '2 3'};
  for (final sd in [5.0, 10.0, 15.0]) {
    final pts = rows.where((r) => r.sd == sd).toList()..sort((a, c) => a.n.compareTo(c.n));
    b.write(_path(
        'M${pts.map((r) => '${_n(ax(r.n))} ${_n(ay(100 * r.coverage))}').join('L')}', 'l',
        w: 2, dash: dashes[sd], extra: ' fill="none"'));
    for (final r in pts) {
      final x = ax(r.n), y = ay(100 * r.coverage);
      b.write(sd == 5
          ? _circ(x, y, 3.5, 'lf bgs', w: 1)
          : sd == 10
              ? '<rect x="${_n(x - 3.2)}" y="${_n(y - 3.2)}" width="6.4" height="6.4" class="lf bgs" stroke-width="1"/>'
              : '<path d="M${_n(x)} ${_n(y - 4.2)}L${_n(x + 4)} ${_n(y + 3)}L${_n(x - 4)} ${_n(y + 3)}Z" class="lf bgs" stroke-width="1"/>');
    }
  }
  // Legend, above the plot: the three spreads.
  var lx = 4.0;
  b.write(_text(lx, 16, 'bearing scatter:', cls: 'tm', size: 11.5));
  lx += 96;
  for (final sd in [5.0, 10.0, 15.0]) {
    b
      ..write(_ln(lx, 12, lx + 26, 12, 'l', w: 2, dash: dashes[sd]))
      ..write(_text(lx + 30, 16, '${_n(sd)}°', size: 11.5));
    lx += 66;
  }
  b.write(_text(4, 34, 'Share of the app\'s 95% ellipses that contain the animal', size: 12, bold: true));
  for (final n in ns) {
    b
      ..write(_ln(ax(n), y1, ax(n), y1 + 5, 'g', w: 1))
      ..write(_text(ax(n), y1 + 18, '$n', anchor: 'middle', size: 11.5));
  }
  b
    ..write(_ln(x0 - 10, y1, x1, y1, 'g', w: 1))
    ..write(_text((x0 + x1) / 2, y1 + 36, 'bearings in the estimate', cls: 'tm', anchor: 'middle', size: 11.5));
  return _svg('fig-coverage-by-bearings', _w, y1 + 44, b.toString());
}

/// Item 2's worked examples: one ellipse that misses the animal, one that
/// contains it, both exactly as the app computed them.
String _figWorkedExamples(Example miss, Example hit) {
  final b = StringBuffer();
  var top = 0.0;
  for (final (i, ex) in [miss, hit].indexed) {
    final obs = ex.obs;
    final e = ellipseOf(ex.cov, chi95);
    final r = e.rotDeg * math.pi / 180;
    final pts = [
      for (final o in obs) (o.x, o.y),
      (-120.0, 0.0), // room for the word "animal" left of the star
      for (final sgn in [1.0, -1.0]) ...[
        (ex.estX + sgn * e.a * math.cos(r), ex.estY + sgn * e.a * math.sin(r)),
        (ex.estX - sgn * e.b * math.sin(r), ex.estY + sgn * e.b * math.cos(r)),
      ],
    ];
    final v = View.fit(pts, 10, top + 40, 340, 250, margin: 26);
    final verdict = ex.covered ? 'contains the animal' : 'misses the animal';
    b
      ..write(_text(4, top + 14, '${ex.n} bearings, ${_n(ex.sd)}° scatter: the ellipse $verdict',
          bold: true, size: 12))
      ..write(_text(4, top + 31,
          'Usual at ${ex.n} bearings: ${(100 * ex.cellCoverage).round()}% of ellipses contain the animal.',
          cls: 'tm', size: 12))
      ..write(v.clip('we$i-clip'))
      ..write('<g clip-path="url(#we$i-clip)">');
    for (final o in obs) {
      b.write(v.ray(o, w: 1.6));
    }
    b.write('</g>');
    for (final o in obs) {
      b.write(_station(v.sx(o.x), v.sy(o.y)));
    }
    b
      ..write(v.ellipse(ex.estX, ex.estY, e, 'l', w: 2.2, dash: ex.covered ? null : '4 2'))
      ..write(_est(v.sx(ex.estX), v.sy(ex.estY)))
      ..write(_star(v.sx(0), v.sy(0)))
      ..write(_text(v.sx(0) - 10, v.sy(0) + 5, 'animal', cls: 't halo', anchor: 'end', size: 12))
      // The label goes on the side of the dot away from the animal.
      ..write(_text(v.sx(ex.estX) + 8,
          v.sy(ex.estY) + (v.sy(0) < v.sy(ex.estY) ? 16 : -8),
          _span('te', 'estimate'), cls: 't halo', size: 12))
      ..write(v.frame())
      ..write(v.scaleBar())
      ..write(v.north());
    top = v.py0 + v.ph + 16;
  }
  return _svg('fig-worked-examples', _w, top - 10, b.toString());
}
