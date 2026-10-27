import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/format/pulse_rate_format.dart';
import 'package:tritrack/core/providers/pulse_rate_unit_provider.dart';

import '../../support/fake_shared_preferences.dart';

/// **Beats per minute is what is stored; seconds per pulse is what may be
/// shown — task 11.187.**
///
/// Michael, 2026-09-07: *"I thought they were in pulses per second. Keep them
/// stored as bpm but still allow users to toggle to see them in
/// seconds-per-pulse."*
///
/// The property worth protecting is the one that made this feature cheap: **no
/// stored number is ever in another unit**, so the schema migration for pulse
/// modes had no arithmetic in it and two devices set to different units still
/// agree about every collar.
void main() {
  group('the conversion', () {
    test("Michael's two defaults read as the seconds he was thinking of", () {
      // "'Normal' at 1 pulse per second and Mortality at 2 pulses per second."
      expect(pulseRateIn(60, PulseRateUnit.secondsPerPulse), 1);
      expect(pulseRateIn(120, PulseRateUnit.secondsPerPulse), 0.5);
      expect(pulseRateIn(60, PulseRateUnit.bpm), 60);
    });

    test('it round-trips', () {
      for (final bpm in [40.0, 52.0, 60.0, 90.0, 120.0, 180.0]) {
        final seconds = pulseRateIn(bpm, PulseRateUnit.secondsPerPulse);
        expect(
          pulseRateToBpm(seconds, PulseRateUnit.secondsPerPulse),
          closeTo(bpm, 1e-9),
          reason: '$bpm bpm did not survive a trip through seconds',
        );
      }
    });

    test('null stays null, so "not recorded" keeps its own branch', () {
      expect(pulseRateIn(null, PulseRateUnit.bpm), isNull);
      expect(pulseRateIn(null, PulseRateUnit.secondsPerPulse), isNull);
      expect(formatPulseRate(null, PulseRateUnit.bpm), isNull);
      // The placeholder form, for a caller that wants a cell filled.
      expect(formatPulseRateValue(null, PulseRateUnit.bpm), '—');
    });

    test('a rate of zero prints nothing rather than "Infinity"', () {
      // `NumericBound.positiveMeasurement` refuses zero on the wire, so this is
      // the belt to that braces: a value that reached a screen through some
      // path that did not validate must not put "Infinity s/pulse" in front of
      // a person.
      expect(pulseRateIn(0, PulseRateUnit.secondsPerPulse), isNull);
      expect(formatPulseRate(0, PulseRateUnit.secondsPerPulse), isNull);
    });
  });

  group('the printed form', () {
    test('trailing zeros are trimmed, because the two units want different '
        'precision', () {
      expect(formatPulseRate(60, PulseRateUnit.bpm), '60 bpm');
      expect(formatPulseRate(52.5, PulseRateUnit.bpm), '52.5 bpm');
      expect(formatPulseRate(60, PulseRateUnit.secondsPerPulse), '1 s/pulse');
      expect(formatPulseRate(120, PulseRateUnit.secondsPerPulse), '0.5 s/pulse');
      expect(formatPulseRate(40, PulseRateUnit.secondsPerPulse), '1.5 s/pulse');
    });

    test('a fixed precision would have been wrong for both units', () {
      // Stated as a test because it is the reason the trimming exists: two
      // decimals makes 60 bpm read "60.00", and none makes half a second read
      // "0" or "1".
      expect(formatPulseRateValue(60, PulseRateUnit.bpm), isNot(contains('.')));
      expect(formatPulseRateValue(120, PulseRateUnit.secondsPerPulse), '0.5');
    });
  });

  group('the preference', () {
    setUp(installFakeSharedPreferences);

    test('it defaults to the unit the number actually is', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(pulseRateUnitSettingProvider.future),
        PulseRateUnit.bpm,
        reason:
            'A person who has never chosen should be shown the number as it is '
            'kept, not in a unit nobody picked.',
      );
    });

    test('it is remembered across a restart', () async {
      final first = ProviderContainer();
      await first.read(pulseRateUnitSettingProvider.future);
      await first
          .read(pulseRateUnitSettingProvider.notifier)
          .set(PulseRateUnit.secondsPerPulse);
      first.dispose();

      // A second container over the same fake preferences is what a relaunch
      // looks like from this layer: every provider is built again from
      // whatever is on disk.
      final second = ProviderContainer();
      addTearDown(second.dispose);
      expect(
        await second.read(pulseRateUnitSettingProvider.future),
        PulseRateUnit.secondsPerPulse,
        reason:
            'The choice was made once and the app forgot it on the next '
            'launch, which is exactly the "remembered everywhere" Michael '
            'asked for not happening.',
      );
    });

    test('the synchronous read is the stored unit while the preference is '
        'still loading, never a blank', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Read before the future has resolved: a screen must not blank a rate
      // for the frame it takes to load a preference, and must not show one in
      // a unit nobody chose either.
      expect(container.read(pulseRateUnitProvider), PulseRateUnit.bpm);
    });
  });
}
