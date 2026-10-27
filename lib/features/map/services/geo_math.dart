import 'dart:math' as math;

import '../../../localization/coordinate_projection.dart';

/// **The farthest a bearing is ever drawn: 40 km.**
///
/// A field report, not a calculation: Michael has watched trackers pick up
/// a collar's VHF tag at around 35 km in good conditions from elevation —
/// a mountain top down into a valley — and set this ceiling at 40 km,
/// task 11.87. (An earlier version of this constant reasoned its way to
/// 20 km from a handheld Yagi's typical ground-to-ground range and was
/// explicitly flagged as the number it could defend rather than one
/// anybody had measured; the field report supersedes it. Don't re-derive
/// 20 km from the equipment spec and think this is a regression.) Past it,
/// a line is not information.
///
/// Read by the Main Map as the ceiling for a dragged bearing, and by the
/// Record screen's *Take on map* (task 11.315) as the length every line is
/// drawn at — one number, so the two maps cannot disagree about how far a
/// bearing can mean anything.
const double kMaxBearingRangeMeters = 40000;

/// Standard great-circle "destination point given start, bearing, distance"
/// formula — used to draw a bearing ray as a real polyline on the live map
/// (unlike the Phase 4 schematic plot, which worked in a shared local plane,
/// a real map has no single shared origin, so each ray is projected from its
/// own observer point).
GeoPoint destinationPoint(
  GeoPoint start,
  double bearingDeg,
  double distanceMeters,
) {
  const r = LocalTangentProjection.earthRadiusMeters;
  final startLat = start.latitude.isFinite
      ? start.latitude.clamp(-90.0, 90.0)
      : 0.0;
  final startLon = start.longitude.isFinite ? start.longitude : 0.0;
  final safeBearing = bearingDeg.isFinite ? bearingDeg : 0.0;
  final safeDistance = distanceMeters.isFinite ? distanceMeters : 0.0;

  final lat1 = startLat * math.pi / 180.0;
  final lon1 = startLon * math.pi / 180.0;
  final brng = safeBearing * math.pi / 180.0;
  final d = safeDistance / r;

  final asinArg =
      (math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(brng))
          .clamp(-1.0, 1.0);
  final lat2 = math.asin(asinArg);
  final lon2 = lon1 +
      math.atan2(
        math.sin(brng) * math.sin(d) * math.cos(lat1),
        math.cos(d) - math.sin(lat1) * math.sin(lat2),
      );

  final resultLat = lat2 * 180.0 / math.pi;
  final resultLon = lon2 * 180.0 / math.pi;
  return GeoPoint(
    resultLat.isFinite ? resultLat.clamp(-90.0, 90.0) : startLat,
    resultLon.isFinite ? resultLon : startLon,
  );
}

/// Samples an uncertainty-ellipse boundary as geographic points, ready to draw
/// as a `flutter_map` polygon. Axes are meters; [rotationCompassDeg] is the
/// major-axis orientation as a true-north bearing (° CW from N, as
/// `GeographicLocalizationResult.ellipseRotationDegrees` reports it). Points
/// are built in a local ENU frame centered on [center] then unprojected — the
/// same tangent-plane assumption the Lenth solve already relies on.
List<GeoPoint> ellipsePolygonPoints({
  required GeoPoint center,
  required double semiMajorMeters,
  required double semiMinorMeters,
  required double rotationCompassDeg,
  int segments = 48,
}) {
  final projection = LocalTangentProjection(center);
  final beta = rotationCompassDeg * math.pi / 180.0;
  final sinB = math.sin(beta);
  final cosB = math.cos(beta);
  final points = <GeoPoint>[];
  for (var i = 0; i < segments; i++) {
    final t = 2 * math.pi * i / segments;
    final major = semiMajorMeters * math.cos(t);
    final minor = semiMinorMeters * math.sin(t);
    // Major axis along the compass bearing (E: sinβ, N: cosβ); minor axis 90°
    // clockwise from it (E: cosβ, N: -sinβ).
    final east = major * sinB + minor * cosB;
    final north = major * cosB - minor * sinB;
    points.add(projection.inverse(PlanarPoint(east, north)));
  }
  return points;
}

/// Samples a translucent "uncertainty wedge" for a bearing measurement: the
/// filled circular sector from [origin] spanning [bearingDeg] ± [halfWidthDeg]
/// out to [rangeMeters], as a closed polygon ready to draw as a `flutter_map`
/// `Polygon`. The ring is `origin → arc(bearing−half … bearing+half) → origin`
/// (the polygon fill closes the last edge back to the origin), so the sector
/// visually fans out from the point where the bearing was measured.
List<GeoPoint> bearingWedgePoints({
  required GeoPoint origin,
  required double bearingDeg,
  required double halfWidthDeg,
  required double rangeMeters,
  int segments = 16,
}) {
  final points = <GeoPoint>[origin];
  final startBearing = bearingDeg - halfWidthDeg;
  final sweep = halfWidthDeg * 2.0;
  final steps = segments < 1 ? 1 : segments;
  for (var i = 0; i <= steps; i++) {
    points.add(destinationPoint(origin, startBearing + sweep * i / steps, rangeMeters));
  }
  return points;
}

/// Great-circle distance (meters) and initial bearing (° CW from true north)
/// from [a] to [b] — the inverse of [destinationPoint]. Used by the Main
/// Map's point-to-point measure tool (design doc "Map Furniture": "distance +
/// bearing between two tapped points"). Uses the full spherical formula
/// (haversine + initial-bearing), not [LocalTangentProjection]'s tangent-plane
/// approximation, since a user can tap two points spanning the whole project
/// extent — well beyond the few-km range that approximation is valid for.
({double distanceMeters, double bearingDeg}) distanceAndBearing(
  GeoPoint a,
  GeoPoint b,
) {
  const r = LocalTangentProjection.earthRadiusMeters;
  final aLat = a.latitude.isFinite ? a.latitude.clamp(-90.0, 90.0) : 0.0;
  final aLon = a.longitude.isFinite ? a.longitude : 0.0;
  final bLat = b.latitude.isFinite ? b.latitude.clamp(-90.0, 90.0) : 0.0;
  final bLon = b.longitude.isFinite ? b.longitude : 0.0;

  final lat1 = aLat * math.pi / 180.0;
  final lat2 = bLat * math.pi / 180.0;
  final dLat = (bLat - aLat) * math.pi / 180.0;
  final dLon = (bLon - aLon) * math.pi / 180.0;

  final sinHalfDLat = math.sin(dLat / 2);
  final sinHalfDLon = math.sin(dLon / 2);
  final h = sinHalfDLat * sinHalfDLat +
      math.cos(lat1) * math.cos(lat2) * sinHalfDLon * sinHalfDLon;
  final distance = 2 * r * math.asin(math.sqrt(h.clamp(0.0, 1.0)));

  final bearing = math.atan2(
    math.sin(dLon) * math.cos(lat2),
    math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon),
  );
  final bearingDeg = (bearing * 180.0 / math.pi + 360.0) % 360.0;

  return (
    distanceMeters: distance.isFinite ? distance : 0.0,
    bearingDeg: bearingDeg.isFinite ? bearingDeg : 0.0,
  );
}

/// Shared "1.23 km" / "850 m" distance label, used anywhere a live distance
/// is shown (measure tool, navigation line/banner, compass distance).
String formatDistanceMeters(double meters) => meters >= 1000
    ? '${(meters / 1000).toStringAsFixed(2)} km'
    : '${meters.toStringAsFixed(0)} m';
