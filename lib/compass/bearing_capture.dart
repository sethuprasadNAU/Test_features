import '../localization/angles.dart';

/// Which capture mode produced a bearing.
enum CaptureMode { singlePoint, rangeCapture }

/// A bearing captured from the compass, in **magnetic** degrees (true-north
/// conversion happens at save time via the WMM for the observation's date).
class CapturedBearing {
  const CapturedBearing({
    required this.magneticBearingDeg,
    required this.uncertaintyDeg,
    required this.method,
    this.magneticStartDeg,
    this.magneticEndDeg,
    this.ambiguousSweep = false,
  });

  final double magneticBearingDeg;

  /// Symmetric ± uncertainty (°). For range capture this is the half-sweep;
  /// for single point it is the configured default (10–15°).
  final double uncertaintyDeg;

  final CaptureMode method;

  /// Sweep endpoints, present only for range capture.
  final double? magneticStartDeg;
  final double? magneticEndDeg;

  /// True if a range sweep was ≥180° (rotation direction ambiguous — the
  /// midpoint is unreliable and the UI should warn).
  final bool ambiguousSweep;

  /// True-north bearing for a given magnetic declination (° east positive),
  /// normalized to [0, 360).
  double trueNorthBearingDeg(double declinationDeg) =>
      Angles.normalizeDegrees(magneticBearingDeg + declinationDeg);
}

/// Drives single-point vs. range-capture bearing acquisition. Pure and
/// synchronous — the UI/controller feeds it the current compass heading on
/// each user action; all angle math goes through the circular-statistics
/// module so a sweep across north is handled correctly.
class BearingCaptureController {
  BearingCaptureController({this.defaultUncertaintyDeg = 12.0});

  /// Default ± uncertainty for a single-point capture (doc: 10–15°).
  double defaultUncertaintyDeg;

  CaptureMode mode = CaptureMode.singlePoint;
  double? _rangeStartDeg;

  /// Switches mode and clears any in-progress range sweep.
  void setMode(CaptureMode newMode) {
    mode = newMode;
    _rangeStartDeg = null;
  }

  bool get isRangeStarted => _rangeStartDeg != null;
  double? get rangeStartDeg => _rangeStartDeg;

  /// Captures a single-point bearing from the current [headingDeg].
  CapturedBearing captureSinglePoint(
    double headingDeg, {
    double? uncertaintyDeg,
  }) {
    return CapturedBearing(
      magneticBearingDeg: Angles.normalizeDegrees(headingDeg),
      uncertaintyDeg: uncertaintyDeg ?? defaultUncertaintyDeg,
      method: CaptureMode.singlePoint,
    );
  }

  /// Marks the start of a range sweep at the current [headingDeg].
  void markRangeStart(double headingDeg) {
    _rangeStartDeg = Angles.normalizeDegrees(headingDeg);
  }

  /// Marks the end of a range sweep, returning the resolved bearing (midpoint
  /// ± half-sweep), or null if no start was marked. Clears the in-progress
  /// sweep on success.
  CapturedBearing? markRangeEnd(double headingDeg) {
    final start = _rangeStartDeg;
    if (start == null) return null;
    final end = Angles.normalizeDegrees(headingDeg);
    final resolved = rangeCaptureBearing(start, end);
    final captured = CapturedBearing(
      magneticBearingDeg: resolved.midpointDegrees,
      uncertaintyDeg: resolved.halfWidthDegrees,
      method: CaptureMode.rangeCapture,
      magneticStartDeg: start,
      magneticEndDeg: end,
      ambiguousSweep: rangeCaptureIsAmbiguous(start, end),
    );
    _rangeStartDeg = null;
    return captured;
  }

  /// Abandons an in-progress range sweep.
  void cancelRange() => _rangeStartDeg = null;
}
