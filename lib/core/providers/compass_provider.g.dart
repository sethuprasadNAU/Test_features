// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'compass_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Raw fused heading from the OS compass API. Phase 3 builds the actual
/// sensor-fusion / single-point vs. range-capture logic on top of this and
/// [magnetometerReading]; this provider only establishes where that logic
/// plugs in.

@ProviderFor(compassHeading)
final compassHeadingProvider = CompassHeadingProvider._();

/// Raw fused heading from the OS compass API. Phase 3 builds the actual
/// sensor-fusion / single-point vs. range-capture logic on top of this and
/// [magnetometerReading]; this provider only establishes where that logic
/// plugs in.

final class CompassHeadingProvider
    extends
        $FunctionalProvider<
          AsyncValue<CompassEvent>,
          CompassEvent,
          Stream<CompassEvent>
        >
    with $FutureModifier<CompassEvent>, $StreamProvider<CompassEvent> {
  /// Raw fused heading from the OS compass API. Phase 3 builds the actual
  /// sensor-fusion / single-point vs. range-capture logic on top of this and
  /// [magnetometerReading]; this provider only establishes where that logic
  /// plugs in.
  CompassHeadingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'compassHeadingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$compassHeadingHash();

  @$internal
  @override
  $StreamProviderElement<CompassEvent> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<CompassEvent> create(Ref ref) {
    return compassHeading(ref);
  }
}

String _$compassHeadingHash() => r'17dc7d81f34d5fd33ba8f31808224689b8fa5717';

/// The "this device has produced a real heading at least once" latch, held
/// apart from [CompassAvailable] so that it survives that provider being
/// disposed.
///
/// **Task 11.161.** [CompassAvailable] is `autoDispose`, and the Compass and
/// Record tabs now stop watching it while they are off screen, so it is
/// created afresh each time one of them comes back. Keeping the latch inside
/// it would put a device with a perfectly good compass back on
/// [compassAvailabilityTimeout] probation on every return to the tab — and a
/// slow first sample would then tell somebody holding a compass that this
/// device has not got one. This is `keepAlive` and only ever goes from false
/// to true, so [CompassAvailable]'s own promise — availability latches `true`
/// permanently — stays literally true across a pause.

@ProviderFor(CompassEverHeard)
final compassEverHeardProvider = CompassEverHeardProvider._();

/// The "this device has produced a real heading at least once" latch, held
/// apart from [CompassAvailable] so that it survives that provider being
/// disposed.
///
/// **Task 11.161.** [CompassAvailable] is `autoDispose`, and the Compass and
/// Record tabs now stop watching it while they are off screen, so it is
/// created afresh each time one of them comes back. Keeping the latch inside
/// it would put a device with a perfectly good compass back on
/// [compassAvailabilityTimeout] probation on every return to the tab — and a
/// slow first sample would then tell somebody holding a compass that this
/// device has not got one. This is `keepAlive` and only ever goes from false
/// to true, so [CompassAvailable]'s own promise — availability latches `true`
/// permanently — stays literally true across a pause.
final class CompassEverHeardProvider
    extends $NotifierProvider<CompassEverHeard, bool> {
  /// The "this device has produced a real heading at least once" latch, held
  /// apart from [CompassAvailable] so that it survives that provider being
  /// disposed.
  ///
  /// **Task 11.161.** [CompassAvailable] is `autoDispose`, and the Compass and
  /// Record tabs now stop watching it while they are off screen, so it is
  /// created afresh each time one of them comes back. Keeping the latch inside
  /// it would put a device with a perfectly good compass back on
  /// [compassAvailabilityTimeout] probation on every return to the tab — and a
  /// slow first sample would then tell somebody holding a compass that this
  /// device has not got one. This is `keepAlive` and only ever goes from false
  /// to true, so [CompassAvailable]'s own promise — availability latches `true`
  /// permanently — stays literally true across a pause.
  CompassEverHeardProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'compassEverHeardProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$compassEverHeardHash();

  @$internal
  @override
  CompassEverHeard create() => CompassEverHeard();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$compassEverHeardHash() => r'd02194deed9e3e649d8e1733ab97bd3e8c00f48a';

/// The "this device has produced a real heading at least once" latch, held
/// apart from [CompassAvailable] so that it survives that provider being
/// disposed.
///
/// **Task 11.161.** [CompassAvailable] is `autoDispose`, and the Compass and
/// Record tabs now stop watching it while they are off screen, so it is
/// created afresh each time one of them comes back. Keeping the latch inside
/// it would put a device with a perfectly good compass back on
/// [compassAvailabilityTimeout] probation on every return to the tab — and a
/// slow first sample would then tell somebody holding a compass that this
/// device has not got one. This is `keepAlive` and only ever goes from false
/// to true, so [CompassAvailable]'s own promise — availability latches `true`
/// permanently — stays literally true across a pause.

abstract class _$CompassEverHeard extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Whether the OS compass is usable on this device — capability-based, never
/// `Platform.is*`.
///
/// The phase plan's original design was "null [FlutterCompass.events] or an
/// errored sensor stream ⇒ unavailable," on the assumption that a platform
/// with no `flutter_compass` implementation (macOS today) would signal that
/// one of those two ways. In practice neither happens: `events` is
/// unconditionally non-null (see the package source — only `kIsWeb` special-
/// cases to `Stream.empty()`), and an `EventChannel` with no platform-side
/// handler registered doesn't error either — the engine's `listen` call gets
/// a null reply and the channel implementation silently no-ops. The result
/// is a stream that just sits there forever: no data, no error. The
/// `hasError` check this provider started with is therefore live for a real
/// stream error (kept below) but dead code for the actual macOS case.
///
/// So this also treats "no heading arrived within [compassAvailabilityTimeout]
/// of first watching" as unavailable — which happens to be a reasonable
/// capability check on its own merits: a phone/tablet with no magnetometer
/// exhibits the exact same symptom (`CompassEvent.heading` nullable, no error
/// either), so a timeout is the only way to catch that case too, not just
/// macOS. Once a real (non-null) heading arrives, availability latches
/// `true` permanently, so a momentary calibration blip can't flip it back.

@ProviderFor(CompassAvailable)
final compassAvailableProvider = CompassAvailableProvider._();

/// Whether the OS compass is usable on this device — capability-based, never
/// `Platform.is*`.
///
/// The phase plan's original design was "null [FlutterCompass.events] or an
/// errored sensor stream ⇒ unavailable," on the assumption that a platform
/// with no `flutter_compass` implementation (macOS today) would signal that
/// one of those two ways. In practice neither happens: `events` is
/// unconditionally non-null (see the package source — only `kIsWeb` special-
/// cases to `Stream.empty()`), and an `EventChannel` with no platform-side
/// handler registered doesn't error either — the engine's `listen` call gets
/// a null reply and the channel implementation silently no-ops. The result
/// is a stream that just sits there forever: no data, no error. The
/// `hasError` check this provider started with is therefore live for a real
/// stream error (kept below) but dead code for the actual macOS case.
///
/// So this also treats "no heading arrived within [compassAvailabilityTimeout]
/// of first watching" as unavailable — which happens to be a reasonable
/// capability check on its own merits: a phone/tablet with no magnetometer
/// exhibits the exact same symptom (`CompassEvent.heading` nullable, no error
/// either), so a timeout is the only way to catch that case too, not just
/// macOS. Once a real (non-null) heading arrives, availability latches
/// `true` permanently, so a momentary calibration blip can't flip it back.
final class CompassAvailableProvider
    extends $NotifierProvider<CompassAvailable, bool> {
  /// Whether the OS compass is usable on this device — capability-based, never
  /// `Platform.is*`.
  ///
  /// The phase plan's original design was "null [FlutterCompass.events] or an
  /// errored sensor stream ⇒ unavailable," on the assumption that a platform
  /// with no `flutter_compass` implementation (macOS today) would signal that
  /// one of those two ways. In practice neither happens: `events` is
  /// unconditionally non-null (see the package source — only `kIsWeb` special-
  /// cases to `Stream.empty()`), and an `EventChannel` with no platform-side
  /// handler registered doesn't error either — the engine's `listen` call gets
  /// a null reply and the channel implementation silently no-ops. The result
  /// is a stream that just sits there forever: no data, no error. The
  /// `hasError` check this provider started with is therefore live for a real
  /// stream error (kept below) but dead code for the actual macOS case.
  ///
  /// So this also treats "no heading arrived within [compassAvailabilityTimeout]
  /// of first watching" as unavailable — which happens to be a reasonable
  /// capability check on its own merits: a phone/tablet with no magnetometer
  /// exhibits the exact same symptom (`CompassEvent.heading` nullable, no error
  /// either), so a timeout is the only way to catch that case too, not just
  /// macOS. Once a real (non-null) heading arrives, availability latches
  /// `true` permanently, so a momentary calibration blip can't flip it back.
  CompassAvailableProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'compassAvailableProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$compassAvailableHash();

  @$internal
  @override
  CompassAvailable create() => CompassAvailable();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$compassAvailableHash() => r'b34df39ced913bc1ead6f88852cfe997ec7af9a2';

/// Whether the OS compass is usable on this device — capability-based, never
/// `Platform.is*`.
///
/// The phase plan's original design was "null [FlutterCompass.events] or an
/// errored sensor stream ⇒ unavailable," on the assumption that a platform
/// with no `flutter_compass` implementation (macOS today) would signal that
/// one of those two ways. In practice neither happens: `events` is
/// unconditionally non-null (see the package source — only `kIsWeb` special-
/// cases to `Stream.empty()`), and an `EventChannel` with no platform-side
/// handler registered doesn't error either — the engine's `listen` call gets
/// a null reply and the channel implementation silently no-ops. The result
/// is a stream that just sits there forever: no data, no error. The
/// `hasError` check this provider started with is therefore live for a real
/// stream error (kept below) but dead code for the actual macOS case.
///
/// So this also treats "no heading arrived within [compassAvailabilityTimeout]
/// of first watching" as unavailable — which happens to be a reasonable
/// capability check on its own merits: a phone/tablet with no magnetometer
/// exhibits the exact same symptom (`CompassEvent.heading` nullable, no error
/// either), so a timeout is the only way to catch that case too, not just
/// macOS. Once a real (non-null) heading arrives, availability latches
/// `true` permanently, so a momentary calibration blip can't flip it back.

abstract class _$CompassAvailable extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Raw magnetometer vector (µT), needed for Phase 3's interference detection
/// (expected field magnitude is ~25-65 µT; the fused heading alone doesn't
/// expose this) and for tilt-compensated heading.

@ProviderFor(magnetometerReading)
final magnetometerReadingProvider = MagnetometerReadingProvider._();

/// Raw magnetometer vector (µT), needed for Phase 3's interference detection
/// (expected field magnitude is ~25-65 µT; the fused heading alone doesn't
/// expose this) and for tilt-compensated heading.

final class MagnetometerReadingProvider
    extends
        $FunctionalProvider<
          AsyncValue<MagnetometerEvent>,
          MagnetometerEvent,
          Stream<MagnetometerEvent>
        >
    with
        $FutureModifier<MagnetometerEvent>,
        $StreamProvider<MagnetometerEvent> {
  /// Raw magnetometer vector (µT), needed for Phase 3's interference detection
  /// (expected field magnitude is ~25-65 µT; the fused heading alone doesn't
  /// expose this) and for tilt-compensated heading.
  MagnetometerReadingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'magnetometerReadingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$magnetometerReadingHash();

  @$internal
  @override
  $StreamProviderElement<MagnetometerEvent> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<MagnetometerEvent> create(Ref ref) {
    return magnetometerReading(ref);
  }
}

String _$magnetometerReadingHash() =>
    r'1ea19188564cac90b0cec377f66ce5241c863fc5';

/// Raw accelerometer vector (m/s²), used for the bubble level and for
/// tilt-compensating the magnetic heading.

@ProviderFor(accelerometerReading)
final accelerometerReadingProvider = AccelerometerReadingProvider._();

/// Raw accelerometer vector (m/s²), used for the bubble level and for
/// tilt-compensating the magnetic heading.

final class AccelerometerReadingProvider
    extends
        $FunctionalProvider<
          AsyncValue<AccelerometerEvent>,
          AccelerometerEvent,
          Stream<AccelerometerEvent>
        >
    with
        $FutureModifier<AccelerometerEvent>,
        $StreamProvider<AccelerometerEvent> {
  /// Raw accelerometer vector (m/s²), used for the bubble level and for
  /// tilt-compensating the magnetic heading.
  AccelerometerReadingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'accelerometerReadingProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$accelerometerReadingHash();

  @$internal
  @override
  $StreamProviderElement<AccelerometerEvent> $createElement(
    $ProviderPointer pointer,
  ) => $StreamProviderElement(pointer);

  @override
  Stream<AccelerometerEvent> create(Ref ref) {
    return accelerometerReading(ref);
  }
}

String _$accelerometerReadingHash() =>
    r'805184b219deecf75e61e0ee886310caec649e41';
