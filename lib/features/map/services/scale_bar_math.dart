import 'dart:math' as math;

/// The chosen scale-bar length for one render: a "nice" round distance and
/// the pixel width it occupies at the current zoom/latitude.
class ScaleBarSpec {
  const ScaleBarSpec({required this.meters, required this.pixelWidth, required this.label});
  final double meters;
  final double pixelWidth;
  final String label;
}

/// Pure math behind the Main Map scale bar (design doc "Map Furniture":
/// "Scale bar, north arrow, live coordinate readout"). Separated from the
/// widget so the "nice round number" picking logic is unit-testable without
/// a live `FlutterMap`.
abstract final class ScaleBarMath {
  /// Standard Web-Mercator ground resolution formula (meters per pixel at a
  /// given zoom/latitude, assuming 256px tiles) — the same formula underlying
  /// virtually every slippy-map scale bar. Resolution is coarsest at the
  /// equator and finer toward the poles (Mercator's east-west stretch).
  /// Web Mercator is undefined past this latitude — clamping keeps
  /// `cos(latitude)` from approaching 0 (which would send this formula's
  /// result toward infinity) if the camera ever reports a more extreme
  /// value than that (e.g. transiently, before a [CameraConstraint] settles
  /// it back within range).
  static const maxLatitudeDeg = 85.05112878;

  static double metersPerPixel(double latitudeDeg, double zoom) {
    final clampedLat = latitudeDeg.isFinite
        ? latitudeDeg.clamp(-maxLatitudeDeg, maxLatitudeDeg)
        : 0.0;
    final safeZoom = zoom.isFinite ? zoom : 0.0;
    final value =
        156543.03392 * math.cos(clampedLat * math.pi / 180.0) / math.pow(2, safeZoom);
    return value.isFinite ? value : 156543.03392;
  }

  /// Round, human-friendly distances a cartographic scale bar steps through.
  static const List<double> _niceMeters = [
    1, 2, 5, 10, 20, 50, 100, 200, 500,
    1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000, 2000000, //
  ];

  /// Picks the largest "nice" distance whose on-screen width fits within
  /// [maxWidthPx], for the given [latitudeDeg]/[zoom].
  static ScaleBarSpec pick({
    required double latitudeDeg,
    required double zoom,
    double maxWidthPx = 100,
  }) {
    final mpp = metersPerPixel(latitudeDeg, zoom);
    var chosen = _niceMeters.first;
    for (final m in _niceMeters) {
      if (m / mpp > maxWidthPx) break;
      chosen = m;
    }
    final pixelWidth = chosen / mpp;
    final label = chosen >= 1000
        ? '${_trimZero(chosen / 1000)} km'
        : '${chosen.round()} m';
    return ScaleBarSpec(meters: chosen, pixelWidth: pixelWidth, label: label);
  }

  static String _trimZero(double km) =>
      km == km.roundToDouble() ? km.round().toString() : km.toStringAsFixed(1);
}
