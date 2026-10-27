import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/compass/magnetometer_interference.dart';

void main() {
  test('a normal ~50 µT Earth field reads as no interference', () {
    final a = MagnetometerInterference.assessMagnitude(50);
    expect(a.level, InterferenceLevel.none);
    expect(a.isInterfered, isFalse);
    expect(a.message, isEmpty);
  });

  test('slightly out-of-range field is moderate', () {
    expect(MagnetometerInterference.assessMagnitude(70).level,
        InterferenceLevel.moderate);
    expect(MagnetometerInterference.assessMagnitude(20).level,
        InterferenceLevel.moderate);
  });

  test('a huge field near metal/antenna is severe', () {
    final a = MagnetometerInterference.assessMagnitude(250);
    expect(a.level, InterferenceLevel.severe);
    expect(a.message, contains('interference'));
  });

  test('near-zero field (shielded/broken) is severe', () {
    expect(MagnetometerInterference.assessMagnitude(3).level,
        InterferenceLevel.severe);
  });

  test('in-range but untrusted calibration is moderate', () {
    final a = MagnetometerInterference.assessMagnitude(50,
        calibrationTrusted: false);
    expect(a.level, InterferenceLevel.moderate);
    expect(a.message.toLowerCase(), contains('calibrat'));
  });

  test('magnitude is the vector norm', () {
    expect(MagnetometerInterference.magnitude(3, 4, 0), closeTo(5, 1e-9));
  });

  test('assess() computes magnitude from a vector', () {
    final a = MagnetometerInterference.assess(mx: 30, my: 40, mz: 0);
    expect(a.fieldMagnitudeMicroTesla, closeTo(50, 1e-9));
    expect(a.level, InterferenceLevel.none);
  });
}
