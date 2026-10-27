import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sensors_plus/sensors_plus.dart';

part 'compass_provider.g.dart';

/// Raw fused heading from the OS compass API. Phase 3 builds the actual
/// sensor-fusion / single-point vs. range-capture logic on top of this and
/// [magnetometerReading]; this provider only establishes where that logic
/// plugs in.
@riverpod
Stream<CompassEvent> compassHeading(Ref ref) {
  final events = FlutterCompass.events;
  if (events == null) {
    throw StateError('Compass sensor unavailable on this device.');
  }
  return events;
}

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
@Riverpod(keepAlive: true)
class CompassEverHeard extends _$CompassEverHeard {
  @override
  bool build() => false;

  void latch() => state = true;
}

/// How long [CompassAvailable] waits for a first real heading before
/// concluding there's no compass. See that class's doc comment for why a
/// timeout is needed at all instead of just checking for an error.
const compassAvailabilityTimeout = Duration(seconds: 2);

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
@riverpod
class CompassAvailable extends _$CompassAvailable {
  @override
  bool build() {
    final everHeard = ref.watch(compassEverHeardProvider);
    // Read the notifier now: this provider is `autoDispose` and can be gone
    // by the time the microtask below runs. The latch is `keepAlive`, so the
    // notifier outlives it.
    final latch = ref.read(compassEverHeardProvider.notifier);

    final heading = ref.watch(compassHeadingProvider);
    if (heading.hasError) return false;
    if (heading.value?.heading != null) {
      // Off the build, because a provider may not write another provider's
      // state while it is building.
      if (!everHeard) Future.microtask(latch.latch);
      return true;
    }
    if (everHeard) return true;

    final timer = Timer(compassAvailabilityTimeout, () {
      if (!ref.read(compassEverHeardProvider)) state = false;
    });
    ref.onDispose(timer.cancel);
    return true;
  }
}

/// Raw magnetometer vector (µT), needed for Phase 3's interference detection
/// (expected field magnitude is ~25-65 µT; the fused heading alone doesn't
/// expose this) and for tilt-compensated heading.
@riverpod
Stream<MagnetometerEvent> magnetometerReading(Ref ref) {
  return magnetometerEventStream();
}

/// Raw accelerometer vector (m/s²), used for the bubble level and for
/// tilt-compensating the magnetic heading.
@riverpod
Stream<AccelerometerEvent> accelerometerReading(Ref ref) {
  return accelerometerEventStream();
}
