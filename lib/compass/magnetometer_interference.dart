import 'dart:math' as math;

/// How trustworthy the current magnetic heading is.
enum InterferenceLevel {
  /// Field magnitude within the expected Earth range and calibration OK.
  none,

  /// Field magnitude somewhat outside the expected range, or calibration is
  /// low/unknown — treat the heading with caution.
  moderate,

  /// Field magnitude far from Earth's — a nearby ferrous mass or magnet
  /// (vehicle, antenna) is corrupting the reading; do not trust the compass.
  severe,
}

/// Assessment of magnetometer interference for a single reading.
class InterferenceAssessment {
  const InterferenceAssessment({
    required this.level,
    required this.fieldMagnitudeMicroTesla,
    required this.message,
  });

  final InterferenceLevel level;
  final double fieldMagnitudeMicroTesla;

  /// Human-readable explanation for the warning banner (empty when [none]).
  final String message;

  bool get isInterfered => level != InterferenceLevel.none;
}

/// Detects likely magnetometer interference, the normal hazard in the field:
/// the user holds a metal Yagi/H-antenna, often beside a vehicle, while
/// reading the phone compass. Earth's total field is ~25–65 µT everywhere; a
/// magnitude far outside that means a local ferrous/magnetic source is
/// dominating and the heading is untrustworthy. This is a primary reason
/// manual bearing entry stays first-class.
abstract final class MagnetometerInterference {
  /// Expected bounds of Earth's total-field magnitude (µT).
  static const expectedMinMicroTesla = 25.0;
  static const expectedMaxMicroTesla = 65.0;

  /// Beyond these looser bounds, interference is judged severe.
  static const severeLowMicroTesla = 15.0;
  static const severeHighMicroTesla = 90.0;

  static double magnitude(double mx, double my, double mz) =>
      math.sqrt(mx * mx + my * my + mz * mz);

  /// Assess from a raw magnetometer vector (µT). [calibrationTrusted] can be
  /// wired from platform calibration status when available; a false/unknown
  /// value nudges an in-range reading to [InterferenceLevel.moderate] so a
  /// stale calibration still surfaces.
  static InterferenceAssessment assess({
    required double mx,
    required double my,
    required double mz,
    bool? calibrationTrusted,
  }) {
    final mag = magnitude(mx, my, mz);
    return assessMagnitude(mag, calibrationTrusted: calibrationTrusted);
  }

  static InterferenceAssessment assessMagnitude(
    double mag, {
    bool? calibrationTrusted,
  }) {
    if (mag < severeLowMicroTesla || mag > severeHighMicroTesla) {
      return InterferenceAssessment(
        level: InterferenceLevel.severe,
        fieldMagnitudeMicroTesla: mag,
        message: 'Strong magnetic interference (${mag.toStringAsFixed(0)} µT). '
            'Step away from the antenna, vehicle, or metal — or enter the '
            'bearing manually.',
      );
    }
    if (mag < expectedMinMicroTesla || mag > expectedMaxMicroTesla) {
      return InterferenceAssessment(
        level: InterferenceLevel.moderate,
        fieldMagnitudeMicroTesla: mag,
        message: 'Magnetic field (${mag.toStringAsFixed(0)} µT) is outside the '
            'expected range. Move away from metal and recalibrate.',
      );
    }
    if (calibrationTrusted == false) {
      return InterferenceAssessment(
        level: InterferenceLevel.moderate,
        fieldMagnitudeMicroTesla: mag,
        message: 'Compass calibration is low. Calibrate (figure-8) before '
            'capturing a bearing.',
      );
    }
    return InterferenceAssessment(
      level: InterferenceLevel.none,
      fieldMagnitudeMicroTesla: mag,
      message: '',
    );
  }
}
