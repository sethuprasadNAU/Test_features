import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/services/geo_polygon.dart';

void main() {
  // A unit square from (0,0) to (1,1) in (lat, lon).
  final square = [
    const LatLng(0, 0),
    const LatLng(0, 1),
    const LatLng(1, 1),
    const LatLng(1, 0),
  ];

  group('pointInPolygon', () {
    test('point clearly inside', () {
      expect(GeoPolygon.pointInPolygon(const LatLng(0.5, 0.5), square), isTrue);
    });

    test('point clearly outside', () {
      expect(GeoPolygon.pointInPolygon(const LatLng(2, 2), square), isFalse);
      expect(GeoPolygon.pointInPolygon(const LatLng(0.5, -1), square), isFalse);
    });

    test('degenerate polygon (<3 vertices) is never inside', () {
      expect(
        GeoPolygon.pointInPolygon(
          const LatLng(0, 0),
          [const LatLng(0, 0), const LatLng(1, 1)],
        ),
        isFalse,
      );
    });

    test('concave polygon: point in the notch is outside', () {
      // A square with a V-notch cut into the top-middle. (lat vertical, lon
      // horizontal). The notch dips down to (lat 1, lon 2).
      final notched = [
        const LatLng(0, 0),
        const LatLng(0, 4),
        const LatLng(2, 4),
        const LatLng(1, 2), // notch apex
        const LatLng(2, 0),
      ];
      // Inside the solid lower body.
      expect(GeoPolygon.pointInPolygon(const LatLng(0.5, 2), notched), isTrue);
      // Up in the notch (above the apex) — outside.
      expect(GeoPolygon.pointInPolygon(const LatLng(1.8, 2), notched), isFalse);
    });
  });

  group('boundingBox', () {
    test('returns min/max lat & lon', () {
      final bb = GeoPolygon.boundingBox([
        const LatLng(1, 2),
        const LatLng(-3, 5),
        const LatLng(4, -1),
      ]);
      expect(bb.minLat, -3);
      expect(bb.maxLat, 4);
      expect(bb.minLon, -1);
      expect(bb.maxLon, 5);
    });
  });

  group('polygonAreaSqMeters', () {
    test('1° square near the equator is ~111km x 111km', () {
      final area = GeoPolygon.polygonAreaSqMeters(square);
      // ~111.32 km lat * ~111.32 km lon at mean lat 0.5° -> ~1.239e10 m^2.
      expect(area, closeTo(1.239e10, 1e8));
    });

    test('winding direction does not matter (abs)', () {
      final reversed = square.reversed.toList();
      expect(
        GeoPolygon.polygonAreaSqMeters(reversed),
        closeTo(GeoPolygon.polygonAreaSqMeters(square), 1),
      );
    });
  });

  group('tilesInPolygon', () {
    test('rectangle keeps only tiles whose centers are inside', () {
      // A small box in Arizona; compare against the raw bbox tile count.
      final box = [
        const LatLng(35.10, -111.70),
        const LatLng(35.10, -111.60),
        const LatLng(35.20, -111.60),
        const LatLng(35.20, -111.70),
      ];
      final tiles = GeoPolygon.tilesInPolygon(polygon: box, zoomLevels: [12]);
      expect(tiles, isNotEmpty);
      // Every returned tile's center must be inside the polygon.
      for (final t in tiles) {
        expect(
          GeoPolygon.pointInPolygon(
            GeoPolygon.tileCenter(t.z, t.x, t.y),
            box,
          ),
          isTrue,
        );
      }
    });

    test('concave polygon excludes tiles in the notch', () {
      final chevron = [
        const LatLng(35.0, -112.0),
        const LatLng(35.0, -111.6),
        const LatLng(35.1, -111.8),
        const LatLng(35.2, -111.6),
        const LatLng(35.2, -112.0),
      ];
      final tiles =
          GeoPolygon.tilesInPolygon(polygon: chevron, zoomLevels: [13]);
      for (final t in tiles) {
        expect(
          GeoPolygon.pointInPolygon(
              GeoPolygon.tileCenter(t.z, t.x, t.y), chevron),
          isTrue,
        );
      }
      // A concave region must yield fewer tiles than its bounding box.
      final bboxTiles = GeoPolygon.tilesInPolygon(
        polygon: [
          const LatLng(35.0, -112.0),
          const LatLng(35.0, -111.6),
          const LatLng(35.2, -111.6),
          const LatLng(35.2, -112.0),
        ],
        zoomLevels: [13],
      );
      expect(tiles.length, lessThan(bboxTiles.length));
    });
  });
}
