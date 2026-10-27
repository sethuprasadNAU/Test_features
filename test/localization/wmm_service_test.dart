import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/declination/wmm.dart';
import 'package:tritrack/localization/declination/wmm_coefficients.dart';

void main() {
  final service = WmmService.fromCoefficients(
    WmmCoefficients.parse(File('assets/wmm/WMM2025.COF').readAsStringSync()),
  );

  group('decimalYear', () {
    test('Jan 1 is the whole year', () {
      expect(WmmService.decimalYear(DateTime.utc(2026, 1, 1)),
          closeTo(2026.0, 1e-6));
    });
    test('~mid-year is ~.5', () {
      expect(WmmService.decimalYear(DateTime.utc(2026, 7, 2, 12)),
          closeTo(2026.5, 0.01));
    });
  });

  test('magneticToTrueNorth adds the (positive/east) Flagstaff declination', () {
    // Flagstaff D ≈ +10° E, so a magnetic bearing of 100° reads ~110° true.
    final trueBearing = service.magneticToTrueNorth(
      magneticBearingDeg: 100,
      latitude: 35.1983,
      longitude: -111.6513,
      date: DateTime.utc(2026, 7, 16),
    );
    expect(trueBearing, greaterThan(107));
    expect(trueBearing, lessThan(113));
  });

  test('magneticToTrueNorth wraps across the 0/360 seam', () {
    final t = service.magneticToTrueNorth(
      magneticBearingDeg: 355,
      latitude: 35.1983,
      longitude: -111.6513,
      date: DateTime.utc(2026, 7, 16),
    );
    // 355 + ~10 = ~365 → ~5°.
    expect(t, inInclusiveRange(0, 10));
  });

  test('validity window tracks the model epoch', () {
    expect(service.isDateInValidRange(DateTime.utc(2026, 6, 1)), isTrue);
    expect(service.isDateInValidRange(DateTime.utc(2019, 6, 1)), isFalse);
    expect(service.isDateInValidRange(DateTime.utc(2031, 6, 1)), isFalse);
  });
}
