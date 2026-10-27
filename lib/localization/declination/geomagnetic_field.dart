import 'dart:math' as math;

import 'wmm_coefficients.dart';

/// The geomagnetic field at a point/time, in the local geodetic frame (nT),
/// with the derived angles. [declinationDeg] (positive east) is what converts
/// magnetic bearings to true north.
class GeomagneticField {
  const GeomagneticField({
    required this.x,
    required this.y,
    required this.z,
    required this.declinationDeg,
    required this.inclinationDeg,
    required this.horizontalIntensity,
    required this.totalIntensity,
  });

  /// North (X), East (Y), Down (Z) components, nT.
  final double x;
  final double y;
  final double z;

  /// Declination D (° east of true north) and inclination I (° down).
  final double declinationDeg;
  final double inclinationDeg;

  /// Horizontal (H) and total (F) intensity, nT.
  final double horizontalIntensity;
  final double totalIntensity;
}

/// World Magnetic Model spherical-harmonic synthesis.
///
/// Implements the standard WMM algorithm (Chulliat et al., NOAA): time-adjust
/// the Gauss coefficients to the observation's decimal year, convert geodetic
/// coordinates to geocentric spherical, evaluate the field via Schmidt
/// semi-normalized associated Legendre functions, and rotate the result back
/// to the geodetic frame. Validated against NOAA's official WMM2025 test
/// values (see test/localization/wmm_test.dart).
///
/// The declination sign convention is the WMM standard: **positive = east**.
/// (Flagstaff, AZ is ~ +10° E — a sign flip here would throw every true-north
/// bearing off by ~20°, so this is validated explicitly.)
class GeomagneticFieldCalculator {
  GeomagneticFieldCalculator(this.coefficients);

  final WmmCoefficients coefficients;

  // WGS84 ellipsoid (km) and the WMM geomagnetic reference radius (km).
  static const double _wgs84A = 6378.137;
  static const double _wgs84F = 1.0 / 298.257223563;
  static const double _geomagneticRadius = 6371.2;
  static double get _e2 => _wgs84F * (2.0 - _wgs84F);

  /// Computes the field at geodetic [latitudeDeg]/[longitudeDeg], height
  /// [heightKm] above the WGS84 ellipsoid, for [decimalYear].
  GeomagneticField fieldAt({
    required double latitudeDeg,
    required double longitudeDeg,
    required double decimalYear,
    double heightKm = 0,
  }) {
    final nMax = coefficients.nMax;
    final size = (nMax + 1) * (nMax + 2) ~/ 2;

    // --- Time-adjust coefficients to the observation year. ---
    final dt = decimalYear - coefficients.epoch;
    final g = List<double>.filled(size, 0);
    final h = List<double>.filled(size, 0);
    for (var i = 0; i < size; i++) {
      g[i] = coefficients.g[i] + dt * coefficients.gDot[i];
      h[i] = coefficients.h[i] + dt * coefficients.hDot[i];
    }

    // --- Geodetic → geocentric spherical. ---
    final phi = latitudeDeg * math.pi / 180.0;
    final lambda = longitudeDeg * math.pi / 180.0;
    final sinPhi = math.sin(phi);
    final cosPhi = math.cos(phi);
    final rc = _wgs84A / math.sqrt(1.0 - _e2 * sinPhi * sinPhi);
    final p = (rc + heightKm) * cosPhi;
    final zc = (rc * (1.0 - _e2) + heightKm) * sinPhi;
    final r = math.sqrt(p * p + zc * zc);
    final sinPhiG = zc / r; // sin(geocentric latitude)
    final cosPhiG = p / r;
    final phiG = math.atan2(zc, p);

    // --- Schmidt semi-normalized Legendre P(sinPhiG) and dP/dφ_g. ---
    final pcup = List<double>.filled(size, 0);
    final dpcup = List<double>.filled(size, 0);
    _legendre(pcup, dpcup, sinPhiG, nMax);

    // --- Relative radius powers (a/r)^(n+2). ---
    final relPow = List<double>.filled(nMax + 1, 0);
    final ratio = _geomagneticRadius / r;
    relPow[0] = ratio * ratio; // n=0 → (a/r)^2 (unused in the n≥1 sum)
    for (var n = 1; n <= nMax; n++) {
      relPow[n] = relPow[n - 1] * ratio;
    }

    // Precompute cos(mλ), sin(mλ).
    final cosM = List<double>.filled(nMax + 1, 0);
    final sinM = List<double>.filled(nMax + 1, 0);
    for (var m = 0; m <= nMax; m++) {
      cosM[m] = math.cos(m * lambda);
      sinM[m] = math.sin(m * lambda);
    }

    // --- Summation in the geocentric frame. ---
    var bx = 0.0; // north
    var by = 0.0; // east
    var bz = 0.0; // down
    for (var n = 1; n <= nMax; n++) {
      for (var m = 0; m <= n; m++) {
        final i = WmmCoefficients.index(n, m);
        final gh = g[i] * cosM[m] + h[i] * sinM[m];
        bz -= relPow[n] * gh * (n + 1) * pcup[i];
        by += relPow[n] * (g[i] * sinM[m] - h[i] * cosM[m]) * m * pcup[i];
        bx -= relPow[n] * gh * dpcup[i];
      }
    }
    // East component carries a 1/cos(φ_g) factor (finite away from the poles).
    if (cosPhiG.abs() > 1e-10) {
      by = by / cosPhiG;
    }

    // --- Rotate geocentric → geodetic (X, Z rotate; Y unchanged). ---
    final psi = phiG - phi;
    final cosPsi = math.cos(psi);
    final sinPsi = math.sin(psi);
    final xGeo = bx * cosPsi - bz * sinPsi;
    final zGeo = bx * sinPsi + bz * cosPsi;
    final yGeo = by;

    final hIntensity = math.sqrt(xGeo * xGeo + yGeo * yGeo);
    final fIntensity = math.sqrt(hIntensity * hIntensity + zGeo * zGeo);
    final declination = math.atan2(yGeo, xGeo) * 180.0 / math.pi;
    final inclination = math.atan2(zGeo, hIntensity) * 180.0 / math.pi;

    return GeomagneticField(
      x: xGeo,
      y: yGeo,
      z: zGeo,
      declinationDeg: declination,
      inclinationDeg: inclination,
      horizontalIntensity: hIntensity,
      totalIntensity: fIntensity,
    );
  }

  /// Schmidt semi-normalized associated Legendre functions and their
  /// derivatives w.r.t. geodetic-ish latitude, per the NOAA reference
  /// recursion. [x] = sin(geocentric latitude). Fills [pcup]/[dpcup] flat by
  /// index n(n+1)/2 + m.
  static void _legendre(
    List<double> pcup,
    List<double> dpcup,
    double x,
    int nMax,
  ) {
    pcup[0] = 1.0;
    dpcup[0] = 0.0;
    final z = math.sqrt((1.0 - x) * (1.0 + x)); // cos(geocentric latitude)

    // Gauss-normalized functions via recursion.
    for (var n = 1; n <= nMax; n++) {
      for (var m = 0; m <= n; m++) {
        final i = WmmCoefficients.index(n, m);
        if (n == m) {
          final i1 = WmmCoefficients.index(n - 1, m - 1);
          pcup[i] = z * pcup[i1];
          dpcup[i] = z * dpcup[i1] + x * pcup[i1];
        } else if (n == 1 && m == 0) {
          final i1 = WmmCoefficients.index(n - 1, m);
          pcup[i] = x * pcup[i1];
          dpcup[i] = x * dpcup[i1] - z * pcup[i1];
        } else {
          // n > 1, n != m
          final i1 = WmmCoefficients.index(n - 2, m);
          final i2 = WmmCoefficients.index(n - 1, m);
          if (m > n - 2) {
            pcup[i] = x * pcup[i2];
            dpcup[i] = x * dpcup[i2] - z * pcup[i2];
          } else {
            final k = ((n - 1) * (n - 1) - m * m) /
                ((2 * n - 1) * (2 * n - 3)).toDouble();
            pcup[i] = x * pcup[i2] - k * pcup[i1];
            dpcup[i] = x * dpcup[i2] - z * pcup[i2] - k * dpcup[i1];
          }
        }
      }
    }

    // Gauss-normalized → Schmidt quasi-normalized ratios.
    final schmidt = List<double>.filled(pcup.length, 0);
    schmidt[0] = 1.0;
    for (var n = 1; n <= nMax; n++) {
      final i = WmmCoefficients.index(n, 0);
      final i1 = WmmCoefficients.index(n - 1, 0);
      schmidt[i] = schmidt[i1] * (2 * n - 1) / n;
      for (var m = 1; m <= n; m++) {
        final im = WmmCoefficients.index(n, m);
        final im1 = WmmCoefficients.index(n, m - 1);
        schmidt[im] = schmidt[im1] *
            math.sqrt(((n - m + 1) * (m == 1 ? 2 : 1)) / (n + m).toDouble());
      }
    }

    // Apply Schmidt normalization; negate dP so it is the derivative w.r.t.
    // latitude (NOAA convention used by the summation above).
    for (var n = 1; n <= nMax; n++) {
      for (var m = 0; m <= n; m++) {
        final i = WmmCoefficients.index(n, m);
        pcup[i] *= schmidt[i];
        dpcup[i] = -dpcup[i] * schmidt[i];
      }
    }
  }
}
