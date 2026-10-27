import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'offline_tile_downloader.dart';

/// Geometry helpers for polygon-shaped offline download regions: point
/// containment, bounding box, area, and tile enumeration. All work in WGS84
/// lat/lon degrees using `latlong2`'s [LatLng] (`latitude`/`longitude`).
///
/// Polygons are treated as implicitly closed (the last vertex is joined back
/// to the first); callers need not repeat the first vertex at the end.
abstract final class GeoPolygon {
  /// Ray-casting point-in-polygon test. Casts a ray east from [point] and
  /// counts edge crossings — odd means inside.
  ///
  /// Edge/vertex behaviour is not specified for the general case (a point
  /// exactly on an edge may report either way depending on floating point);
  /// this is acceptable for coverage math where regions are generously sized.
  static bool pointInPolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    final x = point.longitude;
    final y = point.latitude;
    var inside = false;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude, yi = polygon[i].latitude;
      final xj = polygon[j].longitude, yj = polygon[j].latitude;
      final intersects = ((yi > y) != (yj > y)) &&
          (x < (xj - xi) * (y - yi) / (yj - yi) + xi);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  /// Axis-aligned bounding box (min/max lat & lon) of [polygon].
  static PolygonBounds boundingBox(List<LatLng> polygon) {
    assert(polygon.isNotEmpty, 'polygon must have at least one vertex');
    var minLat = polygon.first.latitude, maxLat = polygon.first.latitude;
    var minLon = polygon.first.longitude, maxLon = polygon.first.longitude;
    for (final p in polygon) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return PolygonBounds(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
    );
  }

  /// Approximate area of [polygon] in square meters via the shoelace formula
  /// on an equirectangular (plate carrée) projection about the polygon's mean
  /// latitude.
  ///
  /// Approximation: longitude degrees are scaled by `cos(meanLat)` so a
  /// degree of longitude and a degree of latitude map to the same metric
  /// distance near the region. This is accurate to a fraction of a percent
  /// for the small (project-sized) extents this app downloads; it is NOT a
  /// geodesic area and degrades for very large or near-polar regions. Used
  /// only for size/estimate display, never for precise measurement.
  static double polygonAreaSqMeters(List<LatLng> polygon) {
    if (polygon.length < 3) return 0;
    const metersPerDegLat = 111320.0;
    var meanLat = 0.0;
    for (final p in polygon) {
      meanLat += p.latitude;
    }
    meanLat /= polygon.length;
    final metersPerDegLon =
        metersPerDegLat * math.cos(meanLat * math.pi / 180.0);

    var sum = 0.0;
    for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].longitude * metersPerDegLon;
      final yi = polygon[i].latitude * metersPerDegLat;
      final xj = polygon[j].longitude * metersPerDegLon;
      final yj = polygon[j].latitude * metersPerDegLat;
      sum += (xj * yi) - (xi * yj);
    }
    return sum.abs() / 2.0;
  }

  /// Center latlng of slippy-map tile ([z],[x],[y]).
  static LatLng tileCenter(int z, int x, int y) => LatLng(
        SlippyMap.tileYToLat(y + 0.5, z),
        SlippyMap.tileXToLon(x + 0.5, z),
      );

  /// Every tile whose center falls inside [polygon], across [zoomLevels].
  ///
  /// Enumerates all tiles across the polygon's bounding box (via
  /// [SlippyMap.tilesForBounds]) and keeps only those whose center latlng is
  /// inside the polygon — the same center-in-polygon rule the DEM store uses,
  /// so tile and DEM coverage agree on what "inside" means.
  static List<TileXY> tilesInPolygon({
    required List<LatLng> polygon,
    required List<int> zoomLevels,
  }) {
    if (polygon.length < 3) return const [];
    final bb = boundingBox(polygon);
    final candidates = SlippyMap.tilesForBounds(
      minLat: bb.minLat,
      minLon: bb.minLon,
      maxLat: bb.maxLat,
      maxLon: bb.maxLon,
      zoomLevels: zoomLevels,
    );
    return candidates
        .where((t) => pointInPolygon(tileCenter(t.z, t.x, t.y), polygon))
        .toList();
  }
}

/// Axis-aligned lat/lon bounding box.
class PolygonBounds {
  const PolygonBounds({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });

  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;
}
