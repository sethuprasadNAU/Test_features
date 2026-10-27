import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/time/time_zone_boundaries.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.331 — a project's zone defaults to the zone at the center of its
/// area, read offline from the boundaries the app ships.
///
/// Read straight from the file the app bundles, so a rebuilt asset is what is
/// tested.
void main() {
  late TimeZoneBoundaries boundaries;

  setUpAll(() {
    boundaries = TimeZoneBoundaries.parse(
      File(TimeZoneBoundaries.assetPath).readAsBytesSync(),
    );
  });

  test('the bundled data adds under 15 MB to the app (it was 4.0 MB when '
      'built from release 2026d)', () {
    final bytes = File(TimeZoneBoundaries.assetPath).lengthSync();
    expect(bytes, lessThan(15 * 1000 * 1000));
  });

  test('every zone the data names is one the tz database can read', () {
    final unknown = [
      for (final name in boundaries.zoneNames)
        if (!FieldTimeZone.isKnown(name)) name,
    ];
    expect(unknown, isEmpty);
    expect(boundaries.zoneNames.length, greaterThan(250));
  });

  group('places, each named for why it is here', () {
    final cases = <(String, double, double, String)>[
      ('Phoenix — Arizona keeps no daylight saving', 33.45, -112.07,
          'America/Phoenix'),
      ('Flagstaff — still Arizona time', 35.20, -111.65, 'America/Phoenix'),
      ('Window Rock — the Navajo Nation keeps daylight saving inside Arizona',
          35.67, -109.05, 'America/Denver'),
      ('Tuba City — Navajo Nation, western side', 36.13, -111.24,
          'America/Denver'),
      ('Kykotsmovi — the Hopi Reservation, inside the Navajo Nation, does not',
          35.87, -110.62, 'America/Phoenix'),
      ('Ponui Island, New Zealand', -36.87, 175.17, 'Pacific/Auckland'),
      ('London', 51.50, -0.12, 'Europe/London'),
      ('Santa Monica Bay — territorial water is the coast\'s zone', 33.95,
          -118.60, 'America/Los_Angeles'),
      ('The middle of the Pacific — a sea zone, not the nearest land', 0.0,
          -150.0, 'Etc/GMT+10'),
      ('The middle of the Atlantic', 30.0, -40.0, 'Etc/GMT+3'),
    ];
    for (final (why, lat, lon, zone) in cases) {
      test(why, () => expect(boundaries.zoneAt(lat, lon), zone));
    }
  });

  test('the sea zone for a longitude has the inverted sign of its name', () {
    expect(TimeZoneBoundaries.seaZoneFor(-105), 'Etc/GMT+7');
    expect(TimeZoneBoundaries.seaZoneFor(150), 'Etc/GMT-10');
    expect(TimeZoneBoundaries.seaZoneFor(3), 'Etc/GMT');
    expect(TimeZoneBoundaries.seaZoneFor(179.9), 'Etc/GMT-12');
    expect(
      FieldTimeZone.offsetAt('Etc/GMT+7', DateTime.utc(2026, 7, 1)),
      const Duration(hours: -7),
    );
  });

  test('a file that is not boundary data is refused, not misread', () {
    expect(
      () => TimeZoneBoundaries.parse(Uint8List.fromList([1, 2, 3, 4, 5, 6])),
      throwsFormatException,
    );
  });
}
