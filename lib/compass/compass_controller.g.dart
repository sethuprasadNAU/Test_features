// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compass_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(CompassController)
final compassControllerProvider = CompassControllerProvider._();

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
final class CompassControllerProvider
    extends $NotifierProvider<CompassController, CompassReading> {
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
  CompassControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'compassControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$compassControllerHash();

  @$internal
  @override
  CompassController create() => CompassController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(CompassReading value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<CompassReading>(value),
    );
  }
}

String _$compassControllerHash() => r'5f91141302c9b37dfdd3777529f06e12fb5dece9';

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

abstract class _$CompassController extends $Notifier<CompassReading> {
  CompassReading build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<CompassReading, CompassReading>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<CompassReading, CompassReading>,
              CompassReading,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
