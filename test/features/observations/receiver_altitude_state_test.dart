import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/observations/providers/receiver_altitude_provider.dart';

import '../../support/fake_shared_preferences.dart';

/// Task 11.67 — the four-hour rule as a function of two timestamps, and the
/// notifier's promise that a lapsed value is never resurrected.
///
/// **The part that is a defect if built naively** is the timer: at four hours
/// and a minute the value must go, and it must not go silently. So the rule
/// is asserted in both directions — in force at 3h59, cleared at 4h01 — and
/// the clearing is asserted to leave the number behind for the screen to say.
void main() {
  final t0 = DateTime.utc(2026, 9, 12, 8, 0);
  const inForce = ReceiverAltitudeState(aglMetres: 300);

  group('the four-hour rule is rolling from the last record', () {
    test('holds the value inside the window', () {
      final s = inForce.copyWith(lastRecordUtc: t0);
      final later = s.resolve(t0.add(const Duration(hours: 3, minutes: 59)));
      expect(later.aglMetres, 300);
      expect(later.noticeOwed, isFalse);
    });

    test('exactly four hours is still inside it', () {
      final s = inForce.copyWith(lastRecordUtc: t0);
      expect(s.resolve(t0.add(kReceiverAltitudeWindow)).aglMetres, 300);
    });

    test('clears the value after the window and keeps the number for the '
        'notice', () {
      final s = inForce.copyWith(lastRecordUtc: t0);
      final later = s.resolve(t0.add(const Duration(hours: 4, minutes: 1)));
      expect(later.aglMetres, 0);
      expect(later.isAboveGround, isFalse);
      expect(later.noticeOwed, isTrue);
      expect(later.clearedFromMetres, 300);
      expect(later.lastRecordUtc, isNull);
    });

    test('a ground value never lapses and never owes a notice', () {
      const ground = ReceiverAltitudeState();
      final later = ground.resolve(t0.add(const Duration(days: 30)));
      expect(identical(later, ground), isTrue);
    });

    test('a record saved moves the clock, so a working flight keeps the '
        'value across more than four hours of flying', () {
      var s = inForce.copyWith(lastRecordUtc: t0);
      // A bearing every three hours for twelve hours: never four apart.
      for (var h = 3; h <= 12; h += 3) {
        final now = t0.add(Duration(hours: h));
        s = s.resolve(now);
        expect(s.aglMetres, 300, reason: 'still in force at +$h h');
        s = s.copyWith(lastRecordUtc: now);
      }
    });

    test('survives a round trip through JSON, timestamps and all', () {
      final s = ReceiverAltitudeState(
        aglMetres: 300,
        lastRecordUtc: t0,
        clearedFromMetres: null,
        unit: AltitudeUnit.feet,
        reference: AltitudeReference.msl,
      );
      final back = ReceiverAltitudeState.fromJson(s.toJson());
      expect(back.aglMetres, 300);
      expect(back.lastRecordUtc, t0);
      expect(back.unit, AltitudeUnit.feet);
      expect(back.reference, AltitudeReference.msl);
      // And the lapse still computes off the restored clock — which is what
      // makes surviving a restart honest rather than merely convenient.
      expect(
        back.resolve(t0.add(const Duration(hours: 5))).clearedFromMetres,
        300,
      );
    });
  });

  group('units', () {
    test('feet go in and come out through 0.3048 m, and the store is metres',
        () {
      expect(AltitudeUnit.feet.toMetres(1000), closeTo(304.8, 1e-9));
      expect(AltitudeUnit.feet.fromMetres(304.8), closeTo(1000, 1e-9));
      expect(AltitudeUnit.metres.toMetres(300), 300);
      expect(formatAltitude(300, AltitudeUnit.metres), '300 m');
      expect(formatAltitude(300, AltitudeUnit.feet), '984 ft');
    });
  });

  group('the notifier', () {
    setUp(installFakeSharedPreferences);

    test('a save after the window has run out does not resurrect the value',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(receiverAltitudeSettingProvider.notifier);
      await container.read(receiverAltitudeSettingProvider.future);

      // Set five hours ago, nothing recorded since.
      final fiveHoursAgo = DateTime.now().subtract(const Duration(hours: 5));
      await notifier.setAglMetres(300, now: fiveHoursAgo);

      // **`recordSaved` on its own, with no `resolveNow` first.** The save
      // path does call `resolveNow` before it, but the guarantee tested here
      // is the notifier's, not the caller's: if `recordSaved` started from
      // the *stored* state it would move the clock forward on a value that
      // had already lapsed, and the aircraft altitude would come back from
      // the dead with nobody told. Watched going red with the resolve
      // removed from `_current` (2026-09-12).
      await notifier.recordSaved();

      final after = container.read(receiverAltitudeProvider);
      expect(after.aglMetres, 0);
      // The notice was owed until one record was saved; one has been.
      expect(after.noticeOwed, isFalse);
    });

    test('a restart after the window owes the notice, not the value',
        () async {
      // First run: set the value with a clock five hours in the past.
      final first = ProviderContainer();
      await first.read(receiverAltitudeSettingProvider.future);
      await first
          .read(receiverAltitudeSettingProvider.notifier)
          .setAglMetres(
            250,
            now: DateTime.now().subtract(const Duration(hours: 5)),
          );
      first.dispose();

      // Second run reads the same preferences back.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      final loaded = await second.read(receiverAltitudeSettingProvider.future);
      expect(loaded.aglMetres, 0);
      expect(loaded.clearedFromMetres, 250);
    });

    test('the person clearing it owes nothing', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(receiverAltitudeSettingProvider.notifier);
      await container.read(receiverAltitudeSettingProvider.future);
      await notifier.setAglMetres(300);
      await notifier.clear();
      final s = container.read(receiverAltitudeProvider);
      expect(s.aglMetres, 0);
      expect(s.noticeOwed, isFalse);
    });
  });
}
