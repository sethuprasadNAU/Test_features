import '../localization/angles.dart';
import 'compass_orientation.dart';
import 'magnetometer_interference.dart';

/// A single fused compass reading for the compass screen: the tilt-compensated
/// magnetic heading, the bubble level, an interference assessment, and (when
/// the current position is known) the declination needed to show true north.
///
/// Immutable and free of plugin/stream dependencies so it is testable; the
/// Riverpod controller builds it from the live sensor streams.
class CompassReading {
  const CompassReading({
    required this.magneticHeadingDeg,
    required this.level,
    required this.interference,
    this.declinationDeg,
    this.computedDeclinationDeg,
    this.isDeclinationManual = false,
  });

  /// Tilt-compensated magnetic heading (° CW from magnetic north), or null if
  /// the sensors can't currently yield a heading (degenerate geometry).
  final double? magneticHeadingDeg;

  final BubbleLevel level;
  final InterferenceAssessment interference;

  /// Effective declination (° east positive) used for [trueHeadingDeg] — the
  /// manual override if one is active, otherwise the WMM-computed value.
  final double? declinationDeg;

  /// The WMM location/date-computed declination (° east positive), kept
  /// separately so the UI can show it as the reference even while a manual
  /// override is in effect. Null until the fix/model are ready.
  final double? computedDeclinationDeg;

  /// Whether [declinationDeg] comes from a user's manual override rather than
  /// the computed model — drives the "manual declination" note in the UI.
  final bool isDeclinationManual;

  /// Neutral placeholder before the first sensor sample (no heading yet, level
  /// flat, no interference verdict) — avoids showing a spurious "0 µT severe
  /// interference" warning at startup.
  static const CompassReading initial = CompassReading(
    magneticHeadingDeg: null,
    level: BubbleLevel(
      pitchDegrees: 0,
      rollDegrees: 0,
      tiltMagnitudeDegrees: 0,
      offsetX: 0,
      offsetY: 0,
    ),
    interference: InterferenceAssessment(
      level: InterferenceLevel.none,
      fieldMagnitudeMicroTesla: 0,
      message: '',
    ),
  );

  double get fieldMagnitudeMicroTesla =>
      interference.fieldMagnitudeMicroTesla;

  /// True-north heading = magnetic + declination, or null if either is unknown.
  double? get trueHeadingDeg {
    final m = magneticHeadingDeg;
    final d = declinationDeg;
    if (m == null || d == null) return null;
    return Angles.normalizeDegrees(m + d);
  }

  /// Whether a bearing captured right now should be trusted (heading present,
  /// no severe interference). The UI keeps manual entry available regardless.
  bool get isHeadingReliable =>
      magneticHeadingDeg != null &&
      interference.level != InterferenceLevel.severe;

  CompassReading copyWith({
    double? magneticHeadingDeg,
    BubbleLevel? level,
    InterferenceAssessment? interference,
    double? declinationDeg,
    double? computedDeclinationDeg,
    bool? isDeclinationManual,
  }) {
    return CompassReading(
      magneticHeadingDeg: magneticHeadingDeg ?? this.magneticHeadingDeg,
      level: level ?? this.level,
      interference: interference ?? this.interference,
      declinationDeg: declinationDeg ?? this.declinationDeg,
      computedDeclinationDeg: computedDeclinationDeg ?? this.computedDeclinationDeg,
      isDeclinationManual: isDeclinationManual ?? this.isDeclinationManual,
    );
  }
}
