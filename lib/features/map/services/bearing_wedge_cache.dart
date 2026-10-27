import 'package:latlong2/latlong.dart' as ll;

import '../../../localization/coordinate_projection.dart';
import 'geo_math.dart';

/// Memoises each bearing's drawn uncertainty wedge, keyed by the observation
/// it belongs to.
///
/// **Why this exists (task 11.131).** The Main Map lets one bearing's drawn
/// length be dragged, live, at finger speed. Every one of those frames is a
/// `setState` on the whole screen, and the wedge layer rebuilds *every*
/// visible bearing's polygon from scratch — 18 points of spherical
/// trigonometry each. With a day's recordings on screen that is the shape of
/// defect task 11.103 found: nothing fails, the frame budget just goes.
///
/// So each wedge is computed once and reused until one of the five inputs
/// that decide its shape actually changes. During a drag exactly one entry's
/// range differs from the last frame, so exactly one wedge is recomputed —
/// which is what [recomputeCount] is for. It is not decoration: it is the
/// only way a test can tell "cached" from "recomputed and identical", and a
/// check that cannot tell those apart is not a check.
class BearingWedgeCache {
  final Map<String, _Entry> _entries = {};

  /// How many wedges this cache has actually computed since it was created.
  /// A cache hit does not advance it.
  int recomputeCount = 0;

  /// The closed wedge polygon for [observationId], recomputed only if any of
  /// the inputs differ from the memoised call.
  List<ll.LatLng> points({
    required String observationId,
    required double latitude,
    required double longitude,
    required double bearingDeg,
    required double halfWidthDeg,
    required double rangeMeters,
  }) {
    final hit = _entries[observationId];
    if (hit != null &&
        hit.latitude == latitude &&
        hit.longitude == longitude &&
        hit.bearingDeg == bearingDeg &&
        hit.halfWidthDeg == halfWidthDeg &&
        hit.rangeMeters == rangeMeters) {
      return hit.points;
    }
    recomputeCount++;
    final computed = [
      for (final p in bearingWedgePoints(
        origin: GeoPoint(latitude, longitude),
        bearingDeg: bearingDeg,
        halfWidthDeg: halfWidthDeg,
        rangeMeters: rangeMeters,
      ))
        ll.LatLng(p.latitude, p.longitude),
    ];
    _entries[observationId] = _Entry(
      latitude: latitude,
      longitude: longitude,
      bearingDeg: bearingDeg,
      halfWidthDeg: halfWidthDeg,
      rangeMeters: rangeMeters,
      points: computed,
    );
    return computed;
  }

  /// Number of memoised wedges currently held.
  int get length => _entries.length;

  void clear() => _entries.clear();
}

class _Entry {
  _Entry({
    required this.latitude,
    required this.longitude,
    required this.bearingDeg,
    required this.halfWidthDeg,
    required this.rangeMeters,
    required this.points,
  });

  final double latitude;
  final double longitude;
  final double bearingDeg;
  final double halfWidthDeg;
  final double rangeMeters;
  final List<ll.LatLng> points;
}
