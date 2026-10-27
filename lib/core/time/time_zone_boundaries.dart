import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// **Which time zone covers a place, offline** (task 11.331).
///
/// A project's time zone defaults to the zone at the center of its area — the
/// center's own zone, a sea zone if the center is at sea, **never the nearest
/// land** (Michael, 2026-10-06: an ocean study site may be far from any land).
/// The boundaries ship inside the app as `assets/time_zones/boundaries.bin`,
/// built by `scripts/time_zone_boundaries/build.sh` from timezone-boundary-
/// builder release 2026d (OpenStreetMap data, ODbL), simplified so that no
/// edge moves more than 100 m. That script names the source, its checksum and
/// how to update it; `encode.py` beside it documents the byte format read
/// here.
///
/// **About 4.0 MB in the app**, measured when it was built. Only a small index
/// is parsed up front — each polygon's zone, bounding box and where its points
/// start — and a polygon's points are decoded only when a looked-up place
/// falls inside its box, so the lookup costs milliseconds and holds no decoded
/// world in memory.
///
/// **What 100 m of simplification costs, said rather than discovered:** a
/// center within about 100 m of a zone line may be given the neighbor's zone.
/// The creator sees the zone in plain words and can change it, which is the
/// control for that; the Navajo Nation's line inside Arizona is the case the
/// tests hold.
class TimeZoneBoundaries {
  TimeZoneBoundaries._(this._bytes, this.zoneNames, this._polygons);

  /// Where the app bundle carries the data.
  static const assetPath = 'assets/time_zones/boundaries.bin';

  /// Loads the bundled boundaries. Throws if the asset is missing or is not
  /// in the format this reader knows.
  static Future<TimeZoneBoundaries> load() async {
    final data = await rootBundle.load(assetPath);
    return TimeZoneBoundaries.parse(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static Future<TimeZoneBoundaries>? _shared;

  /// The bundled boundaries, loaded once per app run and only when something
  /// actually needs a place's zone. A failed load is not cached, so the next
  /// caller tries again.
  static Future<TimeZoneBoundaries> shared() =>
      _shared ??= load().catchError((Object e) {
        _shared = null;
        throw e;
      });

  /// Reads the index of [bytes] (see `encode.py` for the format).
  factory TimeZoneBoundaries.parse(Uint8List bytes) {
    final reader = _Reader(bytes);
    if (bytes.length < 5 ||
        bytes[0] != 0x54 || // T
        bytes[1] != 0x54 || // T
        bytes[2] != 0x5A || // Z
        bytes[3] != 0x42) {
      // B
      throw const FormatException('not a time-zone boundary file');
    }
    reader.offset = 4;
    final version = reader.byte();
    if (version != 1) {
      throw FormatException('unknown boundary file version $version');
    }
    final names = List<String>.generate(reader.varint(), (_) {
      final length = reader.varint();
      final name = String.fromCharCodes(
        bytes.sublist(reader.offset, reader.offset + length),
      );
      reader.offset += length;
      return name;
    });
    final polygons = List<_Polygon>.generate(reader.varint(), (_) {
      final zone = reader.varint();
      final minLon = reader.zigzag();
      final minLat = reader.zigzag();
      final maxLon = reader.zigzag();
      final maxLat = reader.zigzag();
      final length = reader.varint();
      final start = reader.offset;
      reader.offset += length;
      return _Polygon(zone, minLon, minLat, maxLon, maxLat, start);
    });
    return TimeZoneBoundaries._(bytes, List.unmodifiable(names), polygons);
  }

  final Uint8List _bytes;

  /// Every zone name the data uses, sorted — land zones and the `Etc/GMT±N`
  /// sea zones.
  final List<String> zoneNames;

  final List<_Polygon> _polygons;

  /// The zone covering [latitude], [longitude] — land, territorial water, or
  /// open sea. Falls back to the sea zone for the longitude when no polygon
  /// claims the point (a point exactly on an edge can belong to neither
  /// neighbor), so it always answers.
  String zoneAt(double latitude, double longitude) {
    final x = (longitude * 10000).round();
    final y = (latitude * 10000).round();
    for (final polygon in _polygons) {
      if (x < polygon.minLon ||
          x > polygon.maxLon ||
          y < polygon.minLat ||
          y > polygon.maxLat) {
        continue;
      }
      if (_contains(polygon, x, y)) return zoneNames[polygon.zone];
    }
    return seaZoneFor(longitude);
  }

  /// Even-odd test over every ring of [polygon] at once, which handles its
  /// holes without telling outer rings from inner ones.
  bool _contains(_Polygon polygon, int x, int y) {
    final reader = _Reader(_bytes)..offset = polygon.start;
    var inside = false;
    final rings = reader.varint();
    for (var r = 0; r < rings; r++) {
      final count = reader.varint();
      var px = 0, py = 0;
      var firstX = 0, firstY = 0, prevX = 0, prevY = 0;
      for (var i = 0; i < count; i++) {
        px += reader.zigzag();
        py += reader.zigzag();
        if (i == 0) {
          firstX = px;
          firstY = py;
        } else if (_crosses(prevX, prevY, px, py, x, y)) {
          inside = !inside;
        }
        prevX = px;
        prevY = py;
      }
      if (count > 0 && _crosses(prevX, prevY, firstX, firstY, x, y)) {
        inside = !inside;
      }
    }
    return inside;
  }

  static bool _crosses(int x1, int y1, int x2, int y2, int x, int y) {
    if ((y1 > y) == (y2 > y)) return false;
    final atY = x1 + (x2 - x1) * (y - y1) / (y2 - y1);
    return x < atY;
  }

  /// The nautical zone for [longitude]: 15 degrees wide, centered on
  /// multiples of 15. **The sign is inverted in the name** — `Etc/GMT+7` is
  /// UTC−7 — which is why no screen shows this name raw.
  static String seaZoneFor(double longitude) {
    var hours = (longitude / 15).round();
    if (hours > 12) hours = 12;
    if (hours < -12) hours = -12;
    if (hours == 0) return 'Etc/GMT';
    return hours > 0 ? 'Etc/GMT-$hours' : 'Etc/GMT+${-hours}';
  }
}

/// The zone at [latitude], [longitude], or null when the bundled boundaries
/// cannot be read.
Future<String?> zoneAtPlace(double latitude, double longitude) async {
  try {
    final boundaries = await TimeZoneBoundaries.shared();
    return boundaries.zoneAt(latitude, longitude);
  } catch (_) {
    return null;
  }
}

class _Polygon {
  const _Polygon(
    this.zone,
    this.minLon,
    this.minLat,
    this.maxLon,
    this.maxLat,
    this.start,
  );

  final int zone;
  final int minLon, minLat, maxLon, maxLat;
  final int start;
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int byte() => bytes[offset++];

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = bytes[offset++];
      result |= (b & 0x7F) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  int zigzag() {
    final v = varint();
    return (v >> 1) ^ -(v & 1);
  }
}
