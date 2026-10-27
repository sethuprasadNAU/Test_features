import 'dart:math' as math;

import 'localization_types.dart';

/// A point where two bearing rays cross.
class BearingIntersection {
  const BearingIntersection({
    required this.x,
    required this.y,
    required this.indexA,
    required this.indexB,
  });

  final double x;
  final double y;

  /// Indices (into the input list) of the two observations that produced it.
  final int indexA;
  final int indexB;
}

/// Pairwise intersections of bearing rays — computed independently of the
/// Lenth MLE, for the toggleable "intersections" map layer and as a
/// cross-check on the MLE (their componentwise mean should sit near the MLE
/// for good geometry; Lenth 1981 §1 notes why the mean-of-intersections is not
/// itself a good estimator, but it is a useful visual/QA aid).
///
/// A pair is skipped when its bearings are (near-)parallel or the crossing
/// falls *behind* a ray's origin (rays are directional, not full lines) —
/// controlled by [includeBehind].
abstract final class BearingIntersections {
  static List<BearingIntersection> all(
    List<PlanarObservation> obs, {
    double parallelEpsilon = 1e-9,
    bool includeBehind = false,
  }) {
    final result = <BearingIntersection>[];
    for (var i = 0; i < obs.length; i++) {
      for (var j = i + 1; j < obs.length; j++) {
        final hit = _intersect(
          obs[i], obs[j], parallelEpsilon, includeBehind);
        if (hit != null) {
          result.add(BearingIntersection(
            x: hit.$1, y: hit.$2, indexA: i, indexB: j));
        }
      }
    }
    return result;
  }

  /// Intersection of the two directional rays, or null if (near-)parallel or
  /// (when [includeBehind] is false) the crossing lies behind either origin.
  static (double, double)? _intersect(
    PlanarObservation a,
    PlanarObservation b,
    double eps,
    bool includeBehind,
  ) {
    // Ray a: (a.x,a.y) + t·(cosθa, sinθa); ray b similarly with parameter u.
    final dax = math.cos(a.thetaRad);
    final day = math.sin(a.thetaRad);
    final dbx = math.cos(b.thetaRad);
    final dby = math.sin(b.thetaRad);

    final denom = dax * dby - day * dbx; // cross product of directions
    if (denom.abs() < eps) return null; // parallel / collinear

    final rx = b.x - a.x;
    final ry = b.y - a.y;
    final t = (rx * dby - ry * dbx) / denom;
    final u = (rx * day - ry * dax) / denom;

    if (!includeBehind && (t < 0 || u < 0)) return null; // behind a ray origin

    return (a.x + t * dax, a.y + t * day);
  }

  /// Componentwise mean of a set of intersections, or null if empty.
  static (double, double)? centroid(List<BearingIntersection> points) {
    if (points.isEmpty) return null;
    var sx = 0.0;
    var sy = 0.0;
    for (final p in points) {
      sx += p.x;
      sy += p.y;
    }
    return (sx / points.length, sy / points.length);
  }
}
