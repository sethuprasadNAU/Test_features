import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/providers/compass_provider.dart';
import '../core/providers/gps_provider.dart';
import '../localization/declination/declination_override_provider.dart';
import '../localization/declination/wmm_provider.dart';
import 'compass_orientation.dart';
import 'compass_reading.dart';
import 'magnetometer_interference.dart';

part 'compass_controller.g.dart';

/// Fuses the raw accelerometer + magnetometer streams into a live
/// [CompassReading]: tilt-compensated magnetic heading, bubble level, and
/// interference assessment. When the current GPS fix and the WMM model are
/// both available it also fills in declination so the UI can show true north.
///
/// Heading itself comes from the OS-calibrated compass ([compassHeadingProvider],
/// backed by `flutter_compass`/`CLLocationManager` on iOS) rather than the raw
/// magnetometer: real magnetometers carry a constant hard/soft-iron bias
/// (phone case magnets, camera, speaker) that only the OS's calibration
/// routine corrects for, and using the raw tilt-compensated reading directly
/// produced a compass stuck tens of degrees off true. The raw magnetometer
/// vector is still read for interference detection (it needs field
/// *magnitude*, which the fused heading alone doesn't expose), and the raw
/// accelerometer still drives the bubble level.
///
/// This is glue over the pure, unit-tested logic in `compass_orientation.dart`
/// and `magnetometer_interference.dart`; the compass screen (Phase 3, Sonnet)
/// watches this and never touches sensors directly.
@riverpod
class CompassController extends _$CompassController {
  AccelerometerEvent? _acc;
  MagnetometerEvent? _mag;
  double? _calibratedHeadingDeg;

  @override
  CompassReading build() {
    ref.listen(accelerometerReadingProvider, (_, next) {
      final v = next.value;
      if (v != null) {
        _acc = v;
        _recompute();
      }
    });
    ref.listen(magnetometerReadingProvider, (_, next) {
      final v = next.value;
      if (v != null) {
        _mag = v;
        _recompute();
      }
    });
    ref.listen(compassHeadingProvider, (_, next) {
      final heading = next.value?.heading;
      if (heading != null) {
        _calibratedHeadingDeg = heading;
        _recompute();
      }
    });
    // Declination depends on GPS/WMM resolving, not on a new sensor sample —
    // without these listeners "True north" stays a hyphen until the next
    // accelerometer/magnetometer event happens to fire after the fix lands.
    ref.listen(gpsPositionProvider, (_, _) => _recompute());
    ref.listen(wmmServiceProvider, (_, _) => _recompute());
    // A manual declination override changes true north without any new sensor
    // sample, so recompute when it's set/cleared.
    ref.listen(declinationOverrideProvider, (_, _) => _recompute());
    return CompassReading.initial;
  }

  void _recompute() {
    final acc = _acc;
    final mag = _mag;

    final level = acc == null
        ? state.level
        : BubbleLevel.fromAccelerometer(ax: acc.x, ay: acc.y, az: acc.z);
    final interference = mag == null
        ? state.interference
        : MagnetometerInterference.assess(mx: mag.x, my: mag.y, mz: mag.z);

    final heading = _calibratedHeadingDeg ??
        (acc != null && mag != null
            ? CompassOrientation.tiltCompensatedHeadingDegrees(
                mx: mag.x,
                my: mag.y,
                mz: mag.z,
                ax: acc.x,
                ay: acc.y,
                az: acc.z,
              )
            : state.magneticHeadingDeg);

    final computed = _computedDeclination();
    final manual = ref.read(declinationOverrideProvider).value;
    state = CompassReading(
      magneticHeadingDeg: heading,
      level: level,
      interference: interference,
      // Effective declination drives true north: the manual override wins when
      // set, otherwise the computed value.
      declinationDeg: manual ?? computed,
      computedDeclinationDeg: computed,
      isDeclinationManual: manual != null,
    );
  }

  /// WMM declination for the current position/date, or null if the fix or
  /// model isn't ready yet (compass still shows magnetic in that case).
  double? _computedDeclination() {
    final wmm = ref.read(wmmServiceProvider).value;
    final position = ref.read(gpsPositionProvider).value;
    if (wmm == null || position == null) return null;
    return wmm.declinationDegrees(
      latitude: position.latitude,
      longitude: position.longitude,
      date: DateTime.now(),
    );
  }
}
