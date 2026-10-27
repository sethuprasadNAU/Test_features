import 'dart:math' as math;

/// A planar point in the local tangent frame: meters east (+x) / north (+y)
/// of the projection origin.
class PlanarPoint {
  const PlanarPoint(this.east, this.north);
  final double east;
  final double north;
}

/// A geographic point (WGS84 degrees).
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

/// Local tangent-plane (equirectangular) projection about a reference point,
/// converting WGS84 lat/lon ⇄ local ENU meters.
///
/// Lenth (1981) works in a plane and explicitly assumes observers are "close
/// enough together that the effect of the curvature of the earth is
/// negligible." This projection realizes that assumption: it is accurate to
/// well under a meter over the few-km extents of a telemetry session, which is
/// far finer than bearing error. It is *not* a general-purpose projection for
/// large areas.
class LocalTangentProjection {
  LocalTangentProjection(this.origin)
      : _cosLat0 = math.cos(_deg2rad(origin.latitude));

  /// Projection origin — typically the centroid of the observer positions.
  final GeoPoint origin;
  final double _cosLat0;

  /// Mean Earth radius (m). Curvature-of-the-earth error over a session's
  /// extent is negligible relative to bearing uncertainty, so the mean radius
  /// (vs. ellipsoidal radii of curvature) is more than sufficient.
  static const earthRadiusMeters = 6371008.8;

  static double _deg2rad(double d) => d * math.pi / 180.0;
  static double _rad2deg(double r) => r * 180.0 / math.pi;

  PlanarPoint forward(GeoPoint p) {
    final east = earthRadiusMeters *
        _deg2rad(p.longitude - origin.longitude) *
        _cosLat0;
    final north = earthRadiusMeters * _deg2rad(p.latitude - origin.latitude);
    return PlanarPoint(east, north);
  }

  GeoPoint inverse(PlanarPoint p) {
    final lat = origin.latitude + _rad2deg(p.north / earthRadiusMeters);
    final lon = origin.longitude +
        _rad2deg(p.east / (earthRadiusMeters * _cosLat0));
    return GeoPoint(lat, lon);
  }

  /// Centroid of a set of geographic points, a good projection origin.
  static GeoPoint centroid(Iterable<GeoPoint> points) {
    var sumLat = 0.0;
    var sumLon = 0.0;
    var n = 0;
    for (final p in points) {
      sumLat += p.latitude;
      sumLon += p.longitude;
      n++;
    }
    if (n == 0) return const GeoPoint(0, 0);
    return GeoPoint(sumLat / n, sumLon / n);
  }
}
