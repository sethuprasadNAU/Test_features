import 'dart:math' as math;

/// Circular statistics for all bearing/angle math.
///
/// **Every** bearing operation in the app must go through here rather than
/// plain linear arithmetic. Linear averaging breaks across the 0/360 seam:
/// a sweep from 350° to 10° must yield a midpoint of 0° (± 10°), not 180°.
/// These helpers use shortest-arc / resultant-vector (von Mises) handling so
/// the seam is respected everywhere.
///
/// Convention: bearings are compass degrees (0° = north, 90° = east,
/// clockwise). Math angles are radians CCW from the +x (east) axis. Use
/// [compassDegreesToMathRadians] / [mathRadiansToCompassDegrees] to convert
/// at the boundary; the Lenth solver works entirely in math radians.
abstract final class Angles {
  static const _twoPi = 2 * math.pi;

  static double degToRad(double deg) => deg * math.pi / 180.0;
  static double radToDeg(double rad) => rad * 180.0 / math.pi;

  /// Normalizes degrees to [0, 360).
  static double normalizeDegrees(double deg) {
    final r = deg % 360.0;
    return r < 0 ? r + 360.0 : r;
  }

  /// Normalizes radians to [0, 2π).
  static double normalizeRadians(double rad) {
    final r = rad % _twoPi;
    return r < 0 ? r + _twoPi : r;
  }

  /// Signed shortest angular difference `to - from`, in (-180, 180].
  /// Positive = clockwise (increasing compass) from `from` to `to`.
  static double shortestDifferenceDegrees(double from, double to) {
    final diff = normalizeDegrees(to - from);
    return diff > 180.0 ? diff - 360.0 : diff;
  }

  /// Signed shortest angular difference `to - from`, in (-π, π].
  static double shortestDifferenceRadians(double from, double to) {
    var diff = (to - from) % _twoPi;
    if (diff > math.pi) diff -= _twoPi;
    if (diff <= -math.pi) diff += _twoPi;
    return diff;
  }

  /// Compass bearing (deg CW from north) → math angle (rad CCW from east).
  /// θ = (π/180)(90° − compass), matching Lenth (1981) §1.
  static double compassDegreesToMathRadians(double compassDeg) =>
      degToRad(90.0 - compassDeg);

  /// Math angle (rad CCW from east) → compass bearing (deg CW from north).
  static double mathRadiansToCompassDegrees(double mathRad) =>
      normalizeDegrees(90.0 - radToDeg(mathRad));

  /// Circular mean of compass bearings (degrees), via the resultant vector
  /// atan2(Σsin, Σcos). Returns a value in [0, 360). Returns null if the
  /// resultant length is ~0 (directions cancel — mean is undefined), so
  /// callers can decide how to handle an indeterminate average rather than
  /// getting a meaningless number.
  static double? circularMeanDegrees(Iterable<double> bearingsDeg) {
    var sumSin = 0.0;
    var sumCos = 0.0;
    var n = 0;
    for (final b in bearingsDeg) {
      final r = degToRad(b);
      sumSin += math.sin(r);
      sumCos += math.cos(r);
      n++;
    }
    if (n == 0) return null;
    if (_resultantIsZero(sumSin, sumCos, n)) return null;
    return normalizeDegrees(radToDeg(math.atan2(sumSin, sumCos)));
  }

  /// Mean resultant length R̄ ∈ [0, 1] of a set of bearings — a concentration
  /// measure (1 = perfectly aligned, 0 = uniformly spread). Useful for
  /// spread/agreement diagnostics.
  static double meanResultantLength(Iterable<double> bearingsDeg) {
    var sumSin = 0.0;
    var sumCos = 0.0;
    var n = 0;
    for (final b in bearingsDeg) {
      final r = degToRad(b);
      sumSin += math.sin(r);
      sumCos += math.cos(r);
      n++;
    }
    if (n == 0) return 0.0;
    return math.sqrt(sumSin * sumSin + sumCos * sumCos) / n;
  }

  static bool _resultantIsZero(double sumSin, double sumCos, int n) {
    final r = math.sqrt(sumSin * sumSin + sumCos * sumCos) / n;
    return r < 1e-12;
  }
}

/// Result of resolving an angular-range sweep (compass °) into a single
/// bearing with symmetric uncertainty. Produced by [rangeCaptureBearing].
class RangeCaptureBearing {
  const RangeCaptureBearing({
    required this.midpointDegrees,
    required this.halfWidthDegrees,
  });

  /// Center of the swept arc (compass °, [0, 360)) — the bearing to store.
  final double midpointDegrees;

  /// Half the swept arc width (°) — the ± uncertainty to store.
  final double halfWidthDegrees;
}

/// Resolves an angular-range capture (user taps Start, sweeps through the
/// signal peak, taps End) into a midpoint bearing ± half-width, using
/// circular math so a sweep across north reads correctly (350°→10° ⇒ 0° ±10°,
/// never 180°).
///
/// The sweep is taken as the **minor** arc between start and end (antenna beam
/// widths are well under 180°). A sweep of ≥180° is ambiguous (which way did
/// the user rotate?) and is reported via [isAmbiguous] with the minor-arc
/// interpretation still returned, so callers can warn rather than trust it.
RangeCaptureBearing rangeCaptureBearing(double startDeg, double endDeg) {
  final signed = Angles.shortestDifferenceDegrees(startDeg, endDeg);
  final midpoint = Angles.normalizeDegrees(startDeg + signed / 2.0);
  final halfWidth = signed.abs() / 2.0;
  return RangeCaptureBearing(
    midpointDegrees: midpoint,
    halfWidthDegrees: halfWidth,
  );
}

/// Whether a start→end sweep is too wide (≥180°) to disambiguate rotation
/// direction, making the minor-arc midpoint unreliable.
bool rangeCaptureIsAmbiguous(double startDeg, double endDeg) {
  return Angles.shortestDifferenceDegrees(startDeg, endDeg).abs() >= 180.0 - 1e-9;
}
