import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/sync/remembered_sync_failure.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **The words a field tech reads for each sync state, and how severe each
/// one is.**
///
/// ## Where this came from
///
/// Finding D-3's second half was that the *server* behaved correctly and the
/// app said the opposite, and §8 noted there was no widget test for the sync
/// bar or for `SyncStatusScreen` at all — the same blind spot that put the
/// sign-in bug on a real phone with 700+ tests passing. So these assert the
/// sentences rather than the enum.
///
/// This was `sync_status_banner_test.dart` until task 11.189 replaced the bar
/// with an icon. **Every sentence it asserted is asserted here**; what
/// changed is that these are now plain assertions on
/// [SyncStatusPresentation], with no widget pumped at all, because the
/// sentences moved into a class that owns nothing but them. That is strictly
/// better for what this file is for: it can no longer pass or fail for a
/// reason to do with layout, a fake clock or a provider container.
///
/// The two things it *cannot* see, and where they are covered instead: that
/// the icon renders and is absent when no server is configured
/// (`sync_status_icon_test.dart`), and that the dismiss control has a home
/// (`sync_status_screen_test.dart`).
void main() {
  SyncStatusPresentation of(SyncStatus status) =>
      SyncStatusPresentation.of(status);

  test('a clean sync reports synced, and is the only green', () {
    final p = of(
      SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
      ),
    );

    expect(p.message, contains('Synced'));
    expect(p.icon, Icons.cloud_done_outlined);
    expect(p.severity, SyncSeverity.healthy);
    expect(p.glyph, Icons.check_circle);
  });

  test('a held record is never presented as synced', () {
    // The exact state §7 caught: a refused row, and a green "Synced just
    // now."
    final p = of(
      SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
        heldCount: 1,
      ),
    );

    expect(p.message, isNot(contains('Synced')));
    expect(p.message, "1 record isn't on the server. Tap to see why.");
    expect(p.icon, Icons.warning_amber_rounded);
    // **A fault, not a warning.** This is the one state that means a primary
    // record exists on this device and nowhere else, and nothing about the
    // icon may read as "a bit behind" when it means "your data is stranded."
    expect(p.severity, SyncSeverity.fault);
    expect(p.glyph, Icons.error);
  });

  test('the count is plural when it should be', () {
    final p = of(
      SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
        heldCount: 3,
      ),
    );

    expect(p.message, "3 records aren't on the server. Tap to see why.");
  });

  group('a remembered failure says so, and stays as severe (task 11.116)', () {
    /// A failure this device wrote down and has not tried since — what
    /// `SyncController.build` restores after a restart or a provider rebuild.
    SyncStatus remembering(SyncFailureCause cause, int failures) => SyncStatus(
      schedule: const SyncSchedule(),
      // `lastFailure` deliberately null: this session has not attempted
      // anything, which is precisely what makes the failure a remembered one.
      remembered: RememberedSyncFailure(
        cause: cause,
        consecutiveFailures: failures,
        recordedAt: DateTime.now().toUtc().subtract(const Duration(days: 3)),
      ),
      lastSuccessAt: DateTime.now().toUtc().subtract(const Duration(days: 3)),
    );

    test('the state does not go calm after a restart', () {
      // **The finding.** Before this the surface rendered from in-memory
      // state alone, so a device that had been refused three times read
      // "Synced 3 days ago" the moment the app came back.
      final p = of(remembering(SyncFailureCause.serverRejected, 3));

      expect(p.message, contains("Sync isn't working"));
      expect(p.message, isNot(contains('Synced 3 days ago')));
      expect(p.severity, SyncSeverity.fault);
    });

    test('and it says this app has not tried since', () {
      // The decision this task made in writing: show the failure, and show
      // that it has not been re-tested, because "the server is refusing us"
      // and "the server was refusing us when we last tried" lead to different
      // choices about walking half a mile for signal.
      final p = of(remembering(SyncFailureCause.serverRejected, 3));

      expect(p.message, contains('not retried since'));
      expect(p.message, contains('Last tried 3 days ago'));
    });

    test('a live failure carries no such clause', () {
      // The other half. A round that just ran and failed *is* current, and
      // saying it had not been re-tested would be false in the other
      // direction.
      final p = of(
        SyncStatus(
          schedule: const SyncSchedule(consecutiveFailures: 3),
          lastError: 'server_error',
          lastFailure: SyncFailureCause.serverRejected,
          remembered: RememberedSyncFailure(
            cause: SyncFailureCause.serverRejected,
            consecutiveFailures: 3,
            recordedAt: DateTime.now().toUtc(),
          ),
        ),
      );

      expect(p.message, contains("Sync isn't working"));
      expect(p.message, isNot(contains('not retried since')));
    });

    test('the severity is not softened along with the tense', () {
      // A rejected certificate remembered is still a rejected certificate:
      // the words gain a clause, and the state, colour and icon do not
      // change. Downgrading it would be discarding the evidence slowly.
      final p = of(remembering(SyncFailureCause.certificateRejected, 1));

      expect(p.message, contains('Not a network problem'));
      expect(p.icon, Icons.gpp_bad);
      expect(p.severity, SyncSeverity.fault);
      expect(p.message, contains('not retried since'));
    });

    test('and never while a round is actually in flight', () {
      // "Syncing…" and "not retried since" are contradictory sentences, and
      // the round about to finish is the re-test the clause exists to say has
      // not happened yet.
      final p = of(
        SyncStatus(
          schedule: const SyncSchedule(),
          running: true,
          remembered: RememberedSyncFailure(
            cause: SyncFailureCause.serverRejected,
            consecutiveFailures: 3,
            recordedAt: DateTime.now().toUtc(),
          ),
        ),
      );

      expect(p.message, contains('Syncing'));
      expect(p.message, isNot(contains('not retried since')));
      // A round in flight is not a verdict, so it is neither green nor amber.
      expect(p.severity, SyncSeverity.quiet);
      expect(p.glyph, Icons.sync);
    });
  });

  test('a held record outranks merely being offline', () {
    // Offline is transient and expected; a refused record is permanent and
    // needs a decision. Reporting the transient one would bury the other.
    final p = of(
      SyncStatus(
        schedule: const SyncSchedule(),
        lastError: 'unreachable',
        lastFailure: SyncFailureCause.unreachable,
        heldCount: 1,
        lastSuccessAt: DateTime.now().toUtc(),
      ),
    );

    expect(p.message, contains("isn't on the server"));
    expect(p.message, isNot(contains('Offline')));
  });

  test('repeated failure still outranks a held record', () {
    // A device getting nothing through has the more urgent message, and the
    // held record is still reported on the status screen either way.
    final p = of(
      SyncStatus(
        schedule: const SyncSchedule(consecutiveFailures: 4),
        lastError: 'unreachable',
        lastFailure: SyncFailureCause.unreachable,
        heldCount: 1,
      ),
    );

    expect(p.message, contains("Sync isn't working"));
  });

  test('a record the pull discarded gets its own sentence, not "Synced"', () {
    // Found on real hardware 2026-08-27. The pull threw away the merge
    // report, so a round that discarded a record the server sent was
    // indistinguishable from a clean one — and the bar said "Synced."
    final p = of(
      const SyncStatus(schedule: SyncSchedule(), droppedOnArrivalCount: 2),
    );

    expect(p.message, contains('2 records the server sent could not be read'));
    expect(p.message, isNot(contains('Synced')));
    // A warning rather than a fault: nothing is lost. The records are safe on
    // the server and on whoever wrote them; this device simply does not have
    // them, and the usual fix is updating the app.
    expect(p.severity, SyncSeverity.warning);
    expect(p.glyph, Icons.warning_amber_rounded);
  });

  group('when automatic sync is off, it says so', () {
    // **Task 11.59's acceptance line, and it is not a nicety.** Turning
    // automatic sync off is legitimate — satellite billing is the case task
    // 10.8 named — but a device quietly not syncing while showing "3 records
    // waiting to sync" is telling somebody it is about to do something it
    // never will. Three tasks running have removed exactly that silence from
    // this surface; the new setting must not put it back.
    const off = SyncSchedule(frequency: SyncFrequency.onlyWhenIAsk);

    test('records waiting say what they are waiting for', () {
      final p = of(
        SyncStatus(
          schedule: off,
          lastSuccessAt: DateTime.now().toUtc(),
          pendingCount: 3,
        ),
      );

      expect(p.message, contains('3 records waiting'));
      // In those words, because they are the words on the control that put
      // the device in this state.
      expect(p.message, contains('Only when I ask'));
      // "waiting to sync" is the sentence that reads as *about to*.
      expect(p.message, isNot(contains('waiting to sync')));
      expect(p.icon, Icons.sync_disabled);
    });

    test('and it says so even with nothing waiting', () {
      final p = of(
        SyncStatus(schedule: off, lastSuccessAt: DateTime.now().toUtc()),
      );

      expect(p.message, contains('Synced'));
      expect(p.message, contains('Only when I ask'));
    });

    test('an offline device with it off says both', () {
      final p = of(
        SyncStatus(
          schedule: off,
          lastFailure: SyncFailureCause.unreachable,
          lastSuccessAt: DateTime.now().toUtc(),
        ),
      );

      expect(p.message, contains('Offline'));
      expect(p.message, contains('Only when I ask'));
      // **Offline is not a warning.** Being out of signal is the normal
      // condition of this app in the field, and an amber icon for it would
      // cry wolf on every field day.
      expect(p.severity, SyncSeverity.quiet);
      expect(p.glyph, Icons.cloud_off);
    });

    test('with it on, nothing is said about the setting', () {
      // The note is for the state that needs explaining, not a permanent
      // fixture on a surface whose whole value is being glanceable.
      final p = of(
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc(),
          pendingCount: 3,
        ),
      );

      expect(p.message, contains('3 records waiting to sync'));
      expect(p.message, isNot(contains('Only when I ask')));
    });
  });

  group('staleness (task 11.114)', () {
    test('over 24 hours with records waiting is a fault, with a count', () {
      final p = of(
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt:
              DateTime.now().toUtc().subtract(const Duration(hours: 25)),
          pendingCount: 47,
        ),
      );

      expect(p.message, contains('47 records are only on this device'));
      expect(p.message, isNot(contains('Synced')));
      expect(p.severity, SyncSeverity.fault);
    });

    test('the same staleness with nothing pending is a warning', () {
      final p = of(
        SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt:
              DateTime.now().toUtc().subtract(const Duration(hours: 25)),
        ),
      );

      expect(p.message, contains("You may be missing teammates' records"));
      expect(p.severity, SyncSeverity.warning);
    });
  });

  test('a held record outranks a discarded one', () {
    // Both messages are true; the held record is the one that means a
    // primary record exists in exactly one place.
    final p = of(
      SyncStatus(
        schedule: const SyncSchedule(),
        heldCount: 1,
        droppedOnArrivalCount: 1,
        lastSuccessAt: DateTime.now().toUtc(),
      ),
    );

    expect(p.message, contains("isn't on the server"));
  });

  /// **The severity collapse, over every state, in one place.**
  ///
  /// Task 11.189's brief: `healthy` is the only green, and being offline is
  /// not a warning. Both are single sentences and both are easy to break by
  /// adding a state, so they are asserted over the whole enum rather than
  /// state by state — a new `SyncHealth` value arrives here as a failure
  /// naming itself, on top of the compile error in the switch.
  group('the collapse from thirteen states to four severities', () {
    /// A status in each health state, reached where possible the way the app
    /// reaches it. `running` is not a `SyncHealth` value — it is a flag that
    /// outranks all of them — so it is listed separately below.
    final byHealth = <SyncHealth, SyncStatus>{
      SyncHealth.healthy: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
      ),
      SyncHealth.offline: SyncStatus(
        schedule: const SyncSchedule(),
        lastFailure: SyncFailureCause.unreachable,
        lastSuccessAt: DateTime.now().toUtc(),
      ),
      SyncHealth.rowsRefused: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc(),
        heldCount: 1,
      ),
      SyncHealth.recordsMissing: const SyncStatus(
        schedule: SyncSchedule(),
        droppedOnArrivalCount: 1,
      ),
      SyncHealth.serverAddressRefused: const SyncStatus(
        schedule: SyncSchedule(),
        unavailable: SyncUnavailable.serverAddressRefused,
      ),
      SyncHealth.certificateRejected: const SyncStatus(
        schedule: SyncSchedule(),
        lastFailure: SyncFailureCause.certificateRejected,
      ),
      SyncHealth.versionRefused: const SyncStatus(
        schedule: SyncSchedule(),
        lastFailure: SyncFailureCause.refusedWithRemedy,
      ),
      SyncHealth.sessionEnded: const SyncStatus(
        schedule: SyncSchedule(),
        lastFailure: SyncFailureCause.sessionEnded,
      ),
      SyncHealth.membershipEnded: const SyncStatus(
        schedule: SyncSchedule(),
        unavailable: SyncUnavailable.leftProject,
      ),
      SyncHealth.accessRefused: const SyncStatus(
        schedule: SyncSchedule(),
        lastFailure: SyncFailureCause.accessRefused,
      ),
      SyncHealth.broken: const SyncStatus(
        schedule: SyncSchedule(consecutiveFailures: 4),
        lastFailure: SyncFailureCause.unreachable,
      ),
      SyncHealth.staleRecordsPending: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt:
            DateTime.now().toUtc().subtract(const Duration(hours: 25)),
        pendingCount: 1,
      ),
      SyncHealth.staleNothingPending: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt:
            DateTime.now().toUtc().subtract(const Duration(hours: 25)),
      ),
    };

    test('every state is reachable from this fixture set', () {
      // **A derivation that cannot find its subject must refuse.** If a
      // fixture stops producing the state it is filed under, the assertions
      // below would silently be about a different state — twice, agreeing
      // with themselves.
      expect(
        byHealth.keys.toSet(),
        SyncHealth.values.toSet(),
        reason: 'a state was added to SyncHealth without a fixture here',
      );
      for (final entry in byHealth.entries) {
        expect(
          entry.value.health,
          entry.key,
          reason: 'the fixture filed under ${entry.key} actually produces '
              '${entry.value.health}, so every assertion about ${entry.key} '
              'below is about the wrong state',
        );
      }
    });

    test('healthy is the only green', () {
      for (final entry in byHealth.entries) {
        expect(
          of(entry.value).severity == SyncSeverity.healthy,
          entry.key == SyncHealth.healthy,
          reason: '${entry.key} is '
              '${of(entry.value).severity == SyncSeverity.healthy ? '' : 'not '}'
              'green, and it should be the other way round. A green tick is a '
              'claim that a sync succeeded; every state but healthy is one '
              'where it did not.',
        );
      }
      // And a round in flight is not green either — nothing has succeeded
      // yet, which is the whole meaning of "in flight".
      expect(
        of(const SyncStatus(schedule: SyncSchedule(), running: true)).severity,
        isNot(SyncSeverity.healthy),
      );
    });

    test('offline is not a warning, and neither is a round in flight', () {
      expect(of(byHealth[SyncHealth.offline]!).severity, SyncSeverity.quiet);
      expect(
        of(const SyncStatus(schedule: SyncSchedule(), running: true)).severity,
        SyncSeverity.quiet,
      );
    });

    test('every state has a sentence, and it is not the same sentence', () {
      final messages = {
        for (final entry in byHealth.entries) entry.key: of(entry.value).message,
      };
      for (final entry in messages.entries) {
        expect(entry.value.trim(), isNotEmpty, reason: '${entry.key} says '
            'nothing, so the icon it draws is a colour with no explanation '
            'behind it');
      }
      expect(
        messages.values.toSet(),
        hasLength(messages.length),
        reason: 'two states share a sentence, so the tap-through cannot tell '
            'somebody which one they are in: $messages',
      );
    });

    test('the three verdict severities each have their own shape', () {
      // Roughly one man in twelve cannot tell this amber from this red, so
      // the shape has to carry the verdict too.
      final glyphs = {
        for (final s in SyncSeverity.values) s: ?s.verdictGlyph,
      };
      expect(glyphs.keys, hasLength(3));
      expect(glyphs.values.toSet(), hasLength(3));
      expect(SyncSeverity.quiet.verdictGlyph, isNull);
    });

    test('the four severities each have their own colour', () {
      expect(
        SyncSeverity.values.map((s) => s.color).toSet(),
        hasLength(SyncSeverity.values.length),
      );
    });
  });

  /// **Task 11.319 item 3.** *Project deleted* is one of five refusals that
  /// share the `versionRefused` state, and the state was always a fault.
  /// This one is not: an owner destroyed the project on the server, the
  /// sentence itself says the records on this device are kept, and its
  /// nearest neighbor, *no longer on this project*, is gray for the same
  /// reason — somebody decided it, nothing is broken. Only the code says
  /// which of the five a status is, so that is what these read.
  group('a project deleted on the server is not drawn as a fault '
      '(task 11.319)', () {
    SyncStatus refused(String code, {bool remembered = false}) => SyncStatus(
      schedule: const SyncSchedule(),
      lastFailure: remembered ? null : SyncFailureCause.refusedWithRemedy,
      lastError: remembered ? null : code,
      remembered: remembered
          ? RememberedSyncFailure(
              cause: SyncFailureCause.refusedWithRemedy,
              consecutiveFailures: 1,
              recordedAt: DateTime.now().toUtc(),
              stoppedReason: code,
            )
          : null,
    );

    test('it is gray, like the state beside it', () {
      final destroyed = of(refused(syncRefusalProjectDestroyed));
      final left = of(
        const SyncStatus(
          schedule: SyncSchedule(),
          unavailable: SyncUnavailable.leftProject,
        ),
      );

      expect(destroyed.severity, SyncSeverity.quiet);
      expect(destroyed.color, left.color);
    });

    test('it is still gray after a restart, when only the durable record '
        'survives', () {
      expect(
        of(refused(syncRefusalProjectDestroyed, remembered: true)).severity,
        SyncSeverity.quiet,
      );
    });

    test('the other four refusals in that state are still faults', () {
      for (final code in [
        syncRefusalSchemaVersion,
        syncRefusalProtocolVersion,
        syncRefusalCursorTooOld,
        syncRefusalRateLimited,
      ]) {
        expect(
          of(refused(code)).severity,
          SyncSeverity.fault,
          reason: '$code was drawn as a fault before this task and nothing '
              'about it was meant to change',
        );
      }
    });
  });
}
