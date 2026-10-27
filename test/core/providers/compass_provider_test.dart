import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/compass_provider.dart';

/// Task 5.2's capability-based compass-availability check, tested directly
/// against `compassHeadingProvider` overrides rather than the real
/// `flutter_compass` plugin — see that provider's doc comment for why a
/// timeout is needed at all (in practice `FlutterCompass.events` is never
/// null and an unimplemented platform's `EventChannel` never errors either,
/// it just never emits).
///
/// Plain `test()`, not `testWidgets`: these need real `Timer`s to actually
/// elapse (`compassAvailabilityTimeout` is 2 real seconds), which only
/// works on the real Dart event loop — `testWidgets`' fake-async pump loop
/// doesn't advance real timers just by calling `pump()`.
void main() {
  ProviderContainer makeContainer(Stream<CompassEvent> Function(Ref) heading) {
    final container = ProviderContainer(
      overrides: [compassHeadingProvider.overrideWith(heading)],
    );
    // Keep the provider alive across the test (it's autoDispose) and drive
    // its rebuilds as the overridden stream emits.
    container.listen(compassAvailableProvider, (_, _) {});
    return container;
  }

  test('a stream that throws at construction (simulating a null events getter) is unavailable immediately', () {
    final container = makeContainer((ref) => throw StateError('no compass'));
    addTearDown(container.dispose);

    expect(container.read(compassAvailableProvider), isFalse);
  });

  test('a stream that errors after starting is unavailable', () async {
    final controller = StreamController<CompassEvent>();
    final container = makeContainer((ref) => controller.stream);
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.addError(StateError('sensor failure'));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(compassAvailableProvider), isFalse);
  });

  test('a stream that promptly reports a real heading is available', () async {
    final controller = StreamController<CompassEvent>();
    final container = makeContainer((ref) => controller.stream);
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(CompassEvent.fromList([45.0, 45.0, 5.0]));
    await Future<void>.delayed(Duration.zero);

    expect(container.read(compassAvailableProvider), isTrue);
  });

  test('a stream that never emits becomes unavailable once the timeout elapses', () async {
    final controller = StreamController<CompassEvent>();
    final container = makeContainer((ref) => controller.stream);
    addTearDown(container.dispose);
    addTearDown(controller.close);

    // Optimistic before the timeout — a silent stream isn't yet known-bad.
    expect(container.read(compassAvailableProvider), isTrue);

    await Future<void>.delayed(compassAvailabilityTimeout + const Duration(milliseconds: 300));

    expect(container.read(compassAvailableProvider), isFalse);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('once a real heading arrives, availability latches true even if the stream goes silent again', () async {
    final controller = StreamController<CompassEvent>();
    final container = makeContainer((ref) => controller.stream);
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(CompassEvent.fromList([200.0, 200.0, 3.0]));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(compassAvailableProvider), isTrue);

    // No further events — if the timeout logic re-armed, this would flip
    // back to unavailable; it must not.
    await Future<void>.delayed(compassAvailabilityTimeout + const Duration(milliseconds: 300));

    expect(container.read(compassAvailableProvider), isTrue);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
