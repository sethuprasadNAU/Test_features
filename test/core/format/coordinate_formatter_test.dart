import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/format/coordinate_formatter.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('CoordinateFormatter — decimal degrees', () {
    test('formats hemisphere letters from sign, six decimal places', () {
      expect(CoordinateFormatter.format(35.5, -111.75, CoordinateFormat.dd),
          '35.500000°N 111.750000°W');
      expect(CoordinateFormatter.format(-35.5, 111.75, CoordinateFormat.dd),
          '35.500000°S 111.750000°E');
    });

    test('zero is treated as the northern/eastern hemisphere', () {
      expect(CoordinateFormatter.format(0, 0, CoordinateFormat.dd),
          '0.000000°N 0.000000°E');
    });
  });

  group('CoordinateFormatter — DMS', () {
    test('exact half/quarter degrees convert to clean minutes/seconds', () {
      // 0.5° = 30', 0.75° = 45' — chosen to be exact to avoid float noise.
      expect(CoordinateFormatter.format(35.5, -111.75, CoordinateFormat.dms),
          '35°30\'0.0"N 111°45\'0.0"W');
    });

    test('a value with a seconds component round-trips through the split', () {
      // 10°15'36" = 10 + 15/60 + 36/3600 = 10.26 exactly.
      final s = CoordinateFormatter.formatLat(10.26, CoordinateFormat.dms);
      expect(s, '10°15\'36.0"N');
    });
  });

  group('CoordinateFormatter — UTM', () {
    test('at a zone\'s exact central meridian, easting is exactly 500000m', () {
      // Zone 12's central meridian is -111° (verified: -180 + 6*11 + 3 = -111).
      for (final lat in [0.0, 20.0, 45.0, -30.0]) {
        final s = CoordinateFormatter.format(lat, -111.0, CoordinateFormat.utm);
        final easting = int.parse(RegExp(r'(\d+)mE').firstMatch(s)!.group(1)!);
        expect(easting, closeTo(500000, 1), reason: 'lat=$lat: $s');
      }
    });

    test('on the equator, northing is exactly 0 (northern-hemisphere branch)', () {
      final s = CoordinateFormatter.format(0.0, -111.0, CoordinateFormat.utm);
      final northing = int.parse(RegExp(r'(\d+)mN').firstMatch(s)!.group(1)!);
      expect(northing, 0);
      expect(s, startsWith('12N ')); // band for lat=0 in the 8°-band scheme
    });

    test('zone number follows the standard 6°-wide numbering', () {
      // zone = floor((lon+180)/6)+1
      int zoneOf(double lon) {
        final s = CoordinateFormatter.format(10, lon, CoordinateFormat.utm);
        return int.parse(RegExp(r'^(\d+)').firstMatch(s)!.group(1)!);
      }

      expect(zoneOf(-180.0), 1);
      expect(zoneOf(-174.000001), 1);
      expect(zoneOf(-173.999999), 2);
      expect(zoneOf(0.0), 31);
      expect(zoneOf(179.999), 60);
    });

    test('southern hemisphere gets the 10,000,000m false-northing offset', () {
      final s = CoordinateFormatter.format(-33.75, 151.21, CoordinateFormat.utm);
      final northing = int.parse(RegExp(r'(\d+)mN').firstMatch(s)!.group(1)!);
      // A mid-southern-latitude point must land north of the 10,000,000m
      // offset minus its distance from the equator (~3,740,000m for -33.75°),
      // i.e. comfortably above 6,000,000m — well clear of a northern-hemisphere
      // value, which would be under ~4,000,000m at this latitude.
      expect(northing, greaterThan(6000000));
    });

    test('outside ±84°/±80° UTM is undefined, not a bogus number', () {
      expect(CoordinateFormatter.format(85, 0, CoordinateFormat.utm),
          contains('undefined'));
      expect(CoordinateFormatter.format(-81, 0, CoordinateFormat.utm),
          contains('undefined'));
      // 84°N itself is still valid (inclusive boundary).
      expect(CoordinateFormatter.format(84, 0, CoordinateFormat.utm),
          isNot(contains('undefined')));
    });

    test('formatLat/formatLon reject UTM — it has no standalone component', () {
      expect(() => CoordinateFormatter.formatLat(10, CoordinateFormat.utm),
          throwsArgumentError);
      expect(() => CoordinateFormatter.formatLon(10, CoordinateFormat.utm),
          throwsArgumentError);
    });
  });
}
