import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/localization/declination/geomagnetic_field.dart';
import 'package:tritrack/localization/declination/wmm_coefficients.dart';

/// One row of NOAA's official WMM2025 test values.
class _TestRow {
  _TestRow(this.year, this.altKm, this.lat, this.lon, this.d, this.i, this.h,
      this.x, this.y, this.z, this.f);
  final double year, altKm, lat, lon, d, i, h, x, y, z, f;
}

List<_TestRow> _loadTestValues(String path) {
  final rows = <_TestRow>[];
  for (final line in File(path).readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final p = t.split(RegExp(r'\s+')).map(double.parse).toList();
    rows.add(_TestRow(
        p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10]));
  }
  return rows;
}

void main() {
  final coefficients = WmmCoefficients.parse(
      File('assets/wmm/WMM2025.COF').readAsStringSync());
  final calc = GeomagneticFieldCalculator(coefficients);

  test('parses the WMM2025 header and dipole term', () {
    expect(coefficients.epoch, closeTo(2025.0, 1e-9));
    expect(coefficients.modelName, contains('2025'));
    expect(coefficients.nMax, 12);
    // Main dipole g(1,0) ≈ -29351.8 nT for WMM2025.
    expect(coefficients.g[WmmCoefficients.index(1, 0)], closeTo(-29351.8, 0.1));
  });

  group('NOAA official WMM2025 test values (all 118 points)', () {
    final rows = _loadTestValues(
        'CLAUDE_DOCS/WMM2025/WMM2025COF/WMM2025_TestValues.txt');

    test('loaded the reference set', () {
      expect(rows.length, greaterThanOrEqualTo(100));
    });

    test('declination matches NOAA to within 0.01°', () {
      var maxErr = 0.0;
      for (final r in rows) {
        final field = calc.fieldAt(
          latitudeDeg: r.lat,
          longitudeDeg: r.lon,
          decimalYear: r.year,
          heightKm: r.altKm,
        );
        var err = (field.declinationDeg - r.d).abs();
        if (err > 180) err = 360 - err; // seam safety
        if (err > maxErr) maxErr = err;
      }
      expect(maxErr, lessThan(0.01),
          reason: 'max declination error = $maxErr°');
    });

    test('field components X, Y, Z match NOAA to within 0.1 nT', () {
      var maxErr = 0.0;
      for (final r in rows) {
        final field = calc.fieldAt(
          latitudeDeg: r.lat,
          longitudeDeg: r.lon,
          decimalYear: r.year,
          heightKm: r.altKm,
        );
        for (final e in [
          (field.x - r.x).abs(),
          (field.y - r.y).abs(),
          (field.z - r.z).abs(),
        ]) {
          if (e > maxErr) maxErr = e;
        }
      }
      expect(maxErr, lessThan(0.1), reason: 'max X/Y/Z error = $maxErr nT');
    });

    test('inclination, H and F match NOAA', () {
      var maxAngErr = 0.0;
      var maxIntErr = 0.0;
      for (final r in rows) {
        final field = calc.fieldAt(
          latitudeDeg: r.lat,
          longitudeDeg: r.lon,
          decimalYear: r.year,
          heightKm: r.altKm,
        );
        maxAngErr =
            [maxAngErr, (field.inclinationDeg - r.i).abs()].reduce((a, b) => a > b ? a : b);
        maxIntErr = [
          maxIntErr,
          (field.horizontalIntensity - r.h).abs(),
          (field.totalIntensity - r.f).abs()
        ].reduce((a, b) => a > b ? a : b);
      }
      expect(maxAngErr, lessThan(0.01), reason: 'max inclination error');
      expect(maxIntErr, lessThan(0.1), reason: 'max H/F error nT');
    });
  });

  test('Flagstaff declination is ~ +10° EAST (sign-convention guard)', () {
    // The classic silent bug: a sign flip puts every true-north bearing ~20°
    // off. Flagstaff, AZ must read positive (east) ~+10°.
    final field = calc.fieldAt(
      latitudeDeg: 35.1983,
      longitudeDeg: -111.6513,
      decimalYear: 2026.0,
    );
    expect(field.declinationDeg, greaterThan(7));
    expect(field.declinationDeg, lessThan(13));
  });
}
