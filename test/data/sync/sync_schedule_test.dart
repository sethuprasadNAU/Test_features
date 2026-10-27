import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 1, 12);

  group('automatic attempts', () {
    test('a device that has never synced may attempt immediately', () {
      expect(const SyncSchedule().shouldAttemptAt(t0), isTrue);
    });

    test('a recent success suppresses another attempt', () {
      // Field use foregrounds the app constantly, moving between the map and
      // the record screen; each of those must not mean a round trip.
      final schedule = const SyncSchedule().recordSuccess(t0);
      expect(
        schedule.shouldAttemptAt(t0.add(const Duration(minutes: 1))),
        isFalse,
      );
      expect(schedule.shouldAttemptAt(t0.add(minimumInterval)), isTrue);
    });

    test('"Only when I ask" means never automatic', () {
      final schedule = const SyncSchedule().withFrequency(
        SyncFrequency.onlyWhenIAsk,
      );
      expect(schedule.automaticEnabled, isFalse);
      expect(
        schedule.shouldAttemptAt(t0.add(const Duration(days: 7))),
        isFalse,
      );
      // No next attempt to time, rather than one timed very far away.
      expect(schedule.currentBackoff, isNull);
    });
  });

  group('the frequency the user picked', () {
    test('the default is the recommended one, and it is automatic', () {
      expect(const SyncSchedule().frequency, defaultSyncFrequency);
      expect(defaultSyncFrequency, SyncFrequency.everyFifteenMinutes);
      expect(const SyncSchedule().automaticEnabled, isTrue);
    });

    test('each choice is exactly the gap it is named for', () {
      final cases = {
        SyncFrequency.everyForeground: Duration.zero,
        SyncFrequency.everyFifteenMinutes: const Duration(minutes: 15),
        SyncFrequency.hourly: const Duration(hours: 1),
      };
      for (final entry in cases.entries) {
        final schedule = const SyncSchedule()
            .withFrequency(entry.key)
            .recordSuccess(t0);
        if (entry.value > Duration.zero) {
          expect(
            schedule.shouldAttemptAt(
              t0.add(entry.value - const Duration(seconds: 1)),
            ),
            isFalse,
            reason: '${entry.key.label}: due before its own interval',
          );
        }
        expect(
          schedule.shouldAttemptAt(t0.add(entry.value)),
          isTrue,
          reason: '${entry.key.label}: not due after its own interval',
        );
      }
    });

    test(
      '"Every time I open it" gives up the fifteen-minute floor, knowingly',
      () {
        // Offered deliberately (task 11.59) — but the floor `minimumInterval`
        // exists for is genuinely gone, and this is where that is written
        // down rather than discovered.
        final schedule = const SyncSchedule()
            .withFrequency(SyncFrequency.everyForeground)
            .recordSuccess(t0);
        expect(
          schedule.shouldAttemptAt(t0.add(const Duration(seconds: 1))),
          isTrue,
        );
      },
    );

    test('a stored setting survives a round trip through its id', () {
      for (final f in SyncFrequency.values) {
        expect(SyncFrequency.fromId(f.id), f);
      }
      // Whatever a future build wrote, an unreadable value must land on the
      // shipped default — never on "off", which would stop syncing for
      // somebody who never asked for that.
      expect(
        SyncFrequency.fromId('something-a-later-build-wrote'),
        defaultSyncFrequency,
      );
      expect(SyncFrequency.fromId(null), defaultSyncFrequency);
    });

    test('every choice is a distinct id and a distinct label', () {
      expect(
        SyncFrequency.values.map((f) => f.id).toSet(),
        hasLength(SyncFrequency.values.length),
      );
      expect(
        SyncFrequency.values.map((f) => f.label).toSet(),
        hasLength(SyncFrequency.values.length),
      );
    });

    test('the words the sync bar has to say are these words', () {
      // `SyncStatusBanner` states this setting on the bar rather than showing
      // "N records waiting to sync" while nothing is going to happen. It
      // reads the label from here, and this is the label.
      expect(SyncFrequency.onlyWhenIAsk.label, 'Only when I ask');
    });
  });

  group('backoff', () {
    test('grows with consecutive failures rather than retrying tightly', () {
      // A device in a dead zone must not spend its battery rediscovering that.
      // Read at the one frequency with no interval of its own, so the curve
      // itself is what is being measured rather than the clamp below it.
      var schedule = const SyncSchedule()
          .withFrequency(SyncFrequency.everyForeground)
          .recordFailure(t0);
      final first = schedule.currentBackoff;
      schedule = schedule.recordFailure(t0);
      final second = schedule.currentBackoff;
      schedule = schedule.recordFailure(t0);
      final third = schedule.currentBackoff;

      expect(first, initialBackoff);
      expect(second, greaterThan(first!));
      expect(third, greaterThan(second!));
    });

    test('never retries more often than the frequency the user chose', () {
      // **The setting is a ceiling on how often this app reaches out**
      // (task 11.59). The backoff curve starts at one minute, which was free
      // when fifteen minutes was the only cadence; under "Hourly" it would
      // have meant an attempt every minute for as long as a server stayed
      // unreachable — the control promising less than the code does.
      for (final f in SyncFrequency.values.where((f) => f.isAutomatic)) {
        var schedule = const SyncSchedule().withFrequency(f);
        for (var i = 0; i < 8; i++) {
          schedule = schedule.recordFailure(t0);
          expect(
            schedule.currentBackoff,
            greaterThanOrEqualTo(f.interval!),
            reason:
                '${f.label}: attempt ${i + 1} came sooner than the '
                'setting allows',
          );
        }
      }
    });

    test('caps rather than growing without bound', () {
      var schedule = const SyncSchedule();
      for (var i = 0; i < 40; i++) {
        schedule = schedule.recordFailure(t0);
      }
      expect(schedule.currentBackoff, maximumBackoff);
    });

    test('a cap of hours, not never — an all-day dead zone still retries', () {
      expect(maximumBackoff, lessThanOrEqualTo(const Duration(hours: 4)));
    });

    test('an attempt inside the backoff window is refused', () {
      final schedule = const SyncSchedule()
          .withFrequency(SyncFrequency.everyForeground)
          .recordFailure(t0);
      expect(
        schedule.shouldAttemptAt(t0.add(const Duration(seconds: 5))),
        isFalse,
      );
      expect(schedule.shouldAttemptAt(t0.add(initialBackoff)), isTrue);
    });

    test('one success clears an accumulated backoff', () {
      var schedule = const SyncSchedule();
      for (var i = 0; i < 6; i++) {
        schedule = schedule.recordFailure(t0);
      }
      expect(schedule.consecutiveFailures, 6);
      schedule = schedule.recordSuccess(t0);
      expect(schedule.consecutiveFailures, 0);
      expect(schedule.currentBackoff, minimumInterval);
    });
  });

  group('terminal failures stop rather than back off', () {
    test('a revoked session stops automatic attempts', () {
      // Backoff means "try later"; later will not fix a revoked session, and
      // retrying a rejected request forever is the wrong shape.
      final schedule = const SyncSchedule().recordFailure(
        t0,
        terminalReason: 'unauthorized',
      );
      expect(schedule.stoppedReason, 'unauthorized');
      expect(
        schedule.shouldAttemptAt(t0.add(const Duration(days: 7))),
        isFalse,
      );
    });

    test('a success also clears a stop', () {
      final schedule = const SyncSchedule()
          .recordFailure(t0, terminalReason: 'unauthorized')
          .recordSuccess(t0);
      expect(schedule.stoppedReason, isNull);
    });
  });

  /// **Task 11.124's first item — the pattern that makes adding a field
  /// dangerous, removed before the field was added.**
  ///
  /// `SyncSchedule`'s five rebuild methods each listed all five fields by
  /// hand. Nothing failed when one was left out: the dropped field silently
  /// became its constructor default, and here the calm defaults are *no
  /// failures* and *not stopped*. That is the third instance of this shape in
  /// the sync subsystem — `SyncStatus` had it twice (tasks 11.96, 11.116,
  /// 11.117), where the silent default meant *healthy*.
  ///
  /// **These tests are written as properties of the rebuild rather than of
  /// today's five fields**, so a sixth field added later is covered by them
  /// without anybody remembering to come back.
  group('rebuilding carries every field (task 11.124)', () {
    /// A schedule with every field set to something other than its default,
    /// so a dropped field shows up as a reversion rather than as a value that
    /// happens to match.
    final populated = const SyncSchedule()
        .withFrequency(SyncFrequency.hourly)
        .recordFailure(t0, terminalReason: 'unauthorized')
        .copyWith(lastSuccessAt: t0.subtract(const Duration(hours: 3)));

    void expectSame(SyncSchedule a, SyncSchedule b, String what) {
      expect(a.frequency, b.frequency, reason: '$what dropped frequency');
      expect(
        a.lastAttemptAt,
        b.lastAttemptAt,
        reason: '$what dropped lastAttemptAt',
      );
      expect(
        a.lastSuccessAt,
        b.lastSuccessAt,
        reason: '$what dropped lastSuccessAt',
      );
      expect(
        a.consecutiveFailures,
        b.consecutiveFailures,
        reason: '$what dropped consecutiveFailures',
      );
      expect(
        a.stoppedReason,
        b.stoppedReason,
        reason: '$what dropped stoppedReason',
      );
    }

    test('copyWith with no arguments changes nothing at all', () {
      expectSame(populated.copyWith(), populated, 'copyWith()');
    });

    test('changing the frequency carries the failure state with it — the '
        'shape that put a week-old failure back on a calm bar', () {
      final next = populated.withFrequency(SyncFrequency.everyForeground);
      expect(next.frequency, SyncFrequency.everyForeground);
      expect(next.consecutiveFailures, populated.consecutiveFailures);
      expect(next.stoppedReason, 'unauthorized');
      expect(next.lastSuccessAt, populated.lastSuccessAt);
      expect(next.lastAttemptAt, populated.lastAttemptAt);
    });

    test('recording an attempt moves only the attempt time', () {
      final at = t0.add(const Duration(minutes: 30));
      final next = populated.recordAttempt(at);
      expect(next.lastAttemptAt, at);
      expect(next.frequency, populated.frequency);
      expect(next.lastSuccessAt, populated.lastSuccessAt);
      expect(next.consecutiveFailures, populated.consecutiveFailures);
      expect(next.stoppedReason, populated.stoppedReason);
    });

    test('an ordinary failure keeps the frequency and the last success, and '
        'clears a previous terminal stop', () {
      final at = t0.add(const Duration(minutes: 30));
      final next = populated.recordFailure(at);
      expect(next.frequency, populated.frequency);
      expect(next.lastSuccessAt, populated.lastSuccessAt);
      expect(next.consecutiveFailures, populated.consecutiveFailures + 1);
      expect(
        next.stoppedReason,
        isNull,
        reason:
            'null means "not terminal", which is a value to write rather than '
            'one to leave alone — the hand-written rebuild did the same',
      );
    });

    test('a success keeps the frequency the person chose', () {
      final at = t0.add(const Duration(minutes: 30));
      final next = populated.recordSuccess(at);
      expect(next.frequency, SyncFrequency.hourly);
      expect(next.lastAttemptAt, at);
      expect(next.lastSuccessAt, at);
      expect(next.consecutiveFailures, 0);
      expect(next.stoppedReason, isNull);
    });

    test('copyWith can set a nullable field to null, which `??` alone could '
        'not express', () {
      expect(populated.copyWith(stoppedReason: null).stoppedReason, isNull);
      expect(populated.copyWith(lastSuccessAt: null).lastSuccessAt, isNull);
      // And omitting it still means "leave it alone", which is the other half
      // of what the sentinel buys.
      expect(populated.copyWith().stoppedReason, 'unauthorized');
    });
  });
}
