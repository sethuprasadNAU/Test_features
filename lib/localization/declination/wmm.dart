import 'package:flutter/services.dart' show rootBundle;

import 'geomagnetic_field.dart';
import 'wmm_coefficients.dart';

/// App-facing magnetic-declination service.
///
/// Loads the embedded WMM coefficient asset once and answers declination
/// queries for a given position and **observation date** (not "today" — WMM
/// drifts, so bearings recorded last season must use that season's field; the
/// technical doc is explicit about this). The coefficient asset is swappable:
/// dropping a newer `WMM****.COF` into `assets/wmm/` and pointing [assetPath]
/// at it updates the model without code changes.
class WmmService {
  WmmService._(this._calculator, this.model);

  final GeomagneticFieldCalculator _calculator;

  /// The loaded coefficient set (exposes epoch / validity / model name).
  final WmmCoefficients model;

  static const defaultAssetPath = 'assets/wmm/WMM2025.COF';

  /// Loads and parses the coefficient asset. Call once (e.g. behind a
  /// keep-alive provider) and reuse.
  static Future<WmmService> load({String assetPath = defaultAssetPath}) async {
    final text = await rootBundle.loadString(assetPath);
    final coefficients = WmmCoefficients.parse(text);
    return WmmService._(GeomagneticFieldCalculator(coefficients), coefficients);
  }

  /// Builds a service from already-parsed coefficients (for tests / injection).
  factory WmmService.fromCoefficients(WmmCoefficients coefficients) =>
      WmmService._(GeomagneticFieldCalculator(coefficients), coefficients);

  /// Magnetic declination (° east positive) at a position for an observation
  /// [date]. Add [declinationDegrees] to a magnetic bearing to get a
  /// true-north bearing.
  double declinationDegrees({
    required double latitude,
    required double longitude,
    required DateTime date,
    double heightKm = 0,
  }) {
    return fieldAt(
      latitude: latitude,
      longitude: longitude,
      date: date,
      heightKm: heightKm,
    ).declinationDeg;
  }

  /// Full geomagnetic field for a position/date.
  GeomagneticField fieldAt({
    required double latitude,
    required double longitude,
    required DateTime date,
    double heightKm = 0,
  }) {
    return _calculator.fieldAt(
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      decimalYear: decimalYear(date),
      heightKm: heightKm,
    );
  }

  /// Converts magnetic bearing → true-north bearing using the field for the
  /// observation's own date. Returned in [0, 360).
  double magneticToTrueNorth({
    required double magneticBearingDeg,
    required double latitude,
    required double longitude,
    required DateTime date,
  }) {
    final d = declinationDegrees(
        latitude: latitude, longitude: longitude, date: date);
    final t = (magneticBearingDeg + d) % 360.0;
    return t < 0 ? t + 360.0 : t;
  }

  /// Whether [date] falls within the model's ~5-year validity window. Outside
  /// it, results are extrapolated and the app should prompt for a newer model.
  bool isDateInValidRange(DateTime date) {
    final y = decimalYear(date);
    return y >= model.epoch && y <= model.validUntil;
  }

  /// Fractional (decimal) year, e.g. 2026-07-02 → ~2026.5.
  static double decimalYear(DateTime date) {
    final utc = date.toUtc();
    final year = utc.year;
    final startOfYear = DateTime.utc(year);
    final startOfNextYear = DateTime.utc(year + 1);
    final elapsed = utc.difference(startOfYear).inSeconds;
    final total = startOfNextYear.difference(startOfYear).inSeconds;
    return year + elapsed / total;
  }
}
