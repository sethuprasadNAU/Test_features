import 'dart:math' as math;

import 'package:tritrack_sync/tritrack_sync.dart';

/// Formats a WGS84 lat/lon pair for display in the user's chosen
/// [CoordinateFormat] (design doc §12 Project Setup: "biologists and GIS
/// handoffs vary" — decimal degrees / DMS / UTM). Datum is always WGS84,
/// stated explicitly per the technical doc; this never converts datums, only
/// the display representation of the same WGS84 point.
///
/// Display-only: storage always stays decimal-degree lat/lon (schema), so
/// this has no inverse/parse side — screens read `Project.coordinateFormat`
/// (or a per-screen override) and call [format] purely for presentation.
abstract final class CoordinateFormatter {
  /// One combined "lat, lon" string in the requested format.
  static String format(double lat, double lon, CoordinateFormat format) {
    if (format == CoordinateFormat.utm) return _formatUtm(lat, lon);
    return '${formatLat(lat, format)} ${formatLon(lon, format)}';
  }

  /// Latitude alone — for UIs that show lat/lon on separate lines. UTM's
  /// zone/easting/northing triple is not decomposable into independent
  /// lat/lon strings, so callers displaying UTM must use [format] instead;
  /// this throws [ArgumentError] if asked for it.
  static String formatLat(double lat, CoordinateFormat format) {
    switch (format) {
      case CoordinateFormat.dd:
        return '${lat.abs().toStringAsFixed(6)}°${lat >= 0 ? 'N' : 'S'}';
      case CoordinateFormat.dms:
        return '${_dms(lat)}${lat >= 0 ? 'N' : 'S'}';
      case CoordinateFormat.utm:
        throw ArgumentError('UTM has no standalone latitude string; use format(lat, lon, ...).');
    }
  }

  static String formatLon(double lon, CoordinateFormat format) {
    switch (format) {
      case CoordinateFormat.dd:
        return '${lon.abs().toStringAsFixed(6)}°${lon >= 0 ? 'E' : 'W'}';
      case CoordinateFormat.dms:
        return '${_dms(lon)}${lon >= 0 ? 'E' : 'W'}';
      case CoordinateFormat.utm:
        throw ArgumentError('UTM has no standalone longitude string; use format(lat, lon, ...).');
    }
  }

  static String _dms(double decimal) {
    final abs = decimal.abs();
    final deg = abs.floor();
    final minFull = (abs - deg) * 60;
    final min = minFull.floor();
    final sec = (minFull - min) * 60;
    return '$deg°$min\'${sec.toStringAsFixed(1)}"';
  }

  /// WGS84 UTM (Snyder 1987 forward transverse-Mercator series), `k0=0.9996`.
  /// Deliberately does not apply the Norway/Svalbard zone-boundary exceptions
  /// — a wildlife-telemetry study area is never near those latitudes, and the
  /// exceptions would only add untested code paths for a case that can't
  /// occur here. UTM is undefined at the poles; outside ±84°/±80° (where UTM
  /// itself breaks down, handled instead by the UPS system) this returns a
  /// clear message rather than a meaningless number.
  static String _formatUtm(double lat, double lon) {
    if (lat > 84 || lat < -80) {
      return 'UTM undefined above 84°N/below 80°S';
    }

    const a = 6378137.0; // WGS84 semi-major axis (m)
    const eccSq = 0.00669438; // WGS84 first eccentricity squared
    const k0 = 0.9996;

    final latRad = lat * math.pi / 180;
    final lonRad = lon * math.pi / 180;

    final zoneNumber = ((lon + 180) / 6).floor() + 1;
    final lonOriginDeg = (zoneNumber - 1) * 6 - 180 + 3;
    final lonOriginRad = lonOriginDeg * math.pi / 180;

    final eccPrimeSq = eccSq / (1 - eccSq);
    final sinLat = math.sin(latRad);
    final cosLat = math.cos(latRad);
    final tanLat = math.tan(latRad);

    final n = a / math.sqrt(1 - eccSq * sinLat * sinLat);
    final t = tanLat * tanLat;
    final c = eccPrimeSq * cosLat * cosLat;
    final aTerm = cosLat * (lonRad - lonOriginRad);

    final m = a *
        ((1 -
                    eccSq / 4 -
                    3 * eccSq * eccSq / 64 -
                    5 * eccSq * eccSq * eccSq / 256) *
                latRad -
            (3 * eccSq / 8 +
                    3 * eccSq * eccSq / 32 +
                    45 * eccSq * eccSq * eccSq / 1024) *
                math.sin(2 * latRad) +
            (15 * eccSq * eccSq / 256 + 45 * eccSq * eccSq * eccSq / 1024) *
                math.sin(4 * latRad) -
            (35 * eccSq * eccSq * eccSq / 3072) * math.sin(6 * latRad));

    final easting = k0 *
            n *
            (aTerm +
                (1 - t + c) * math.pow(aTerm, 3) / 6 +
                (5 - 18 * t + t * t + 72 * c - 58 * eccPrimeSq) *
                    math.pow(aTerm, 5) /
                    120) +
        500000.0;

    var northing = k0 *
        (m +
            n *
                tanLat *
                (math.pow(aTerm, 2) / 2 +
                    (5 - t + 9 * c + 4 * c * c) * math.pow(aTerm, 4) / 24 +
                    (61 - 58 * t + t * t + 600 * c - 330 * eccPrimeSq) *
                        math.pow(aTerm, 6) /
                        720));
    if (lat < 0) northing += 10000000.0; // southern-hemisphere false northing

    final band = _utmLatitudeBand(lat);
    return '$zoneNumber$band ${easting.round()}mE ${northing.round()}mN';
  }

  /// Standard UTM latitude-band letters, 8° bands from 80°S to 84°N, skipping
  /// I and O (easily confused with 1 and 0).
  static String _utmLatitudeBand(double lat) {
    const bands = 'CDEFGHJKLMNPQRSTUVWXX';
    if (lat < -80 || lat > 84) return '?';
    final index = ((lat + 80) / 8).floor().clamp(0, bands.length - 1);
    return bands[index];
  }
}
