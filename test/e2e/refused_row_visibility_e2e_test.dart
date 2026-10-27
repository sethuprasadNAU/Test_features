@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/held_row_details.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// The check task 10.25 wrote into its own acceptance criteria and that three
/// remediation tasks (10.28, 10.34, 10.35) each deferred to "the next device
/// session": **a real server refusing a real replica, and the app saying
/// something useful about it.**
///
/// Everything guarding finding D-3 today runs against `FakeSyncTransport`
/// (`sync_engine_test.dart`) or against a hand-built widget tree
/// (`sync_status_screen_test.dart`). Both are good tests of their own layer and
/// neither can fail if the *server* stops refusing, or if the client stops
/// recognising a refusal it does receive. 10.25's standing warning is that this
/// is a code-review blind spot by construction — the server behaviour can be
/// correct and tested while the app still presents it as a silent nothing, and
/// that is exactly how the sign-in bug reached a real phone with 700+ tests
/// green.
///
/// So this drives the **real `SyncEngine` against the real server** and asserts
/// on what a user would be shown. It does not render pixels: a `flutter test`
/// process is not a phone, and the last mile — that the sentence reads right at
/// a glance, in the workflow, on a small screen — still needs a human with a
/// device. What it does close is everything up to that: that a genuine
/// server-side refusal produces a held row, a non-zero held count, and the
/// client-authored explanation, through the same code path the app runs.
void main() {
  group('a server-refused row is visible, not silently lost', skip: e2eSkipReason, () {
    late E2eDevice device;
    late String projectId;
    late DateTime now;

    setUp(() async {
      device = await E2eDevice.create();
      await device.signIn(randomEmail());
      now = DateTime.now().toUtc();
      projectId = 'e2e-held-${randomId()}';
      await seedLocalProject(
        device.db.raw,
        projectId: projectId,
        ownerId: device.userId,
        deviceId: device.deviceId,
        now: now,
      );
    });


    SyncEngine engineFor(E2eDevice d) => SyncEngine(
      db: d.db.raw,
      transport: d.transport(),
      state: d.state,
      deviceId: d.deviceId,
      userId: d.userId,
    );

    test(
      'importing a colleague\'s shared observation is held and explained, '
      'not dropped while the app reports a clean sync',
      () async {
        // Settle this device's own rows first, so the only thing the round
        // below can be refused for is the replica.
        await engineFor(device).run(projectId);

        // Phase 6.3's faithful replica, as `SharedObservationImporter` writes
        // it: a local `Users` row for the colleague who sent the payload, and
        // an observation attributed to them, both carrying the *sender's*
        // clock verbatim. That colleague is not a member of this project, so
        // task 10.20's row-naming invariant — as 10.29 extended it — is
        // correct to refuse both, and this is the ordinary intended workflow
        // that produces the refusal rather than an attack.
        final colleagueId = 'e2e-colleague-${randomId()}';
        final observationId = 'e2e-replica-${randomId()}';
        final senderClock = now.subtract(const Duration(days: 3));
        await device.db.raw.insert(
          Tables.users,
          colleagueRow(colleagueId, now: senderClock),
        );
        await device.db.raw.insert(
          Tables.observations,
          observationRow(
            observationId,
            projectId: projectId,
            userId: colleagueId,
            deviceId: 'their-device',
            now: senderClock,
          ),
        );

        final report = await engineFor(device).run(projectId);

        // 1. The server really did refuse it — this is the live half. If the
        //    server ever stops refusing, this fails here rather than passing
        //    against a fake that was told to deny.
        final store = SyncHeldRowStore(device.db.raw);
        final held = await store.held(projectId);
        expect(
          held.map((r) => r.rowKey),
          contains(contains(observationId)),
          reason: 'the replica should be recorded as held by the real server',
        );

        // 2. The record still exists locally, unchanged. D-3 was silent
        //    *loss*; the row surviving is the whole point.
        final stored = await device.db.raw.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: [observationId],
        );
        expect(stored, hasLength(1));
        expect(stored.single['user_id'], colleagueId);

        // 3. Nothing may report a clean sync while a row is held.
        expect(await store.heldCount(projectId), greaterThan(0));

        // 4. The user is told why, in client-authored copy — never
        //    server-supplied text (§4.13).
        final reasons = held.map((r) => r.reason).toSet();
        expect(reasons, contains(HeldRowReason.notPermitted));
        //    And what the *screen* would show for this real refusal, resolved
        //    the way the screen resolves it. Asserted here rather than against
        //    a fixed sentence because task 11.41 moved the copy out of the
        //    enum: it now reads the record, so a real server's real refusal is
        //    the only place the copy can be checked end to end.
        final details = await HeldRowDetails.resolve(
          device.db.raw,
          projectId: projectId,
          currentUserId: device.userId,
          held: held,
        );
        final shown = details.firstWhere(
          (d) => d.held.rowKey.contains(observationId),
        );
        expect(
          shown.recordLabel,
          isNot(equals(Tables.observations)),
          reason: 'the card must name the record, not its table',
        );
        expect(shown.heldBy, isNotEmpty);
        expect(shown.whatYouCanDo, isNotEmpty);
        expect(
          '${shown.heldBy} ${shown.whatYouCanDo}'.toLowerCase(),
          isNot(contains('unauthorized')),
          reason: 'no wire status code reaches a person',
        );

        // 5. And the refusal is not reported as a successful application.
        expect(
          report.applied,
          lessThan(report.pushed),
          reason: 'a refused row must not be counted as applied',
        );
      },
    );

    test('a held row is re-offered after the user asks to retry', () async {
      await engineFor(device).run(projectId);

      final colleagueId = 'e2e-colleague-${randomId()}';
      final observationId = 'e2e-replica-${randomId()}';
      final senderClock = now.subtract(const Duration(days: 3));
      await device.db.raw.insert(
        Tables.users,
        colleagueRow(colleagueId, now: senderClock),
      );
      await device.db.raw.insert(
        Tables.observations,
        observationRow(
          observationId,
          projectId: projectId,
          userId: colleagueId,
          deviceId: 'their-device',
          now: senderClock,
        ),
      );
      await engineFor(device).run(projectId);

      final store = SyncHeldRowStore(device.db.raw);
      final beforeRetry = await store.held(projectId);
      final target = beforeRetry.firstWhere(
        (r) => r.rowKey.contains(observationId),
      );

      // A second round with no retry must NOT re-offer it — "held, explained
      // and retryable", not "retried forever", which is the deviation 10.28
      // recorded against its own acceptance wording.
      final quiet = await engineFor(device).run(projectId);
      expect(
        quiet.pushed,
        0,
        reason: 'a held row is suppressed until the user releases it',
      );

      // Releasing it offers it again — and the server, unchanged, refuses it
      // again. The row stays held rather than silently disappearing.
      await store.release(
        projectId: projectId,
        tableName: target.tableName,
        rowKey: target.rowKey,
      );
      final retried = await engineFor(device).run(projectId);
      expect(retried.pushed, greaterThan(0));
      expect(await store.heldCount(projectId), greaterThan(0));
    });
  });
}

/// A `Users` row for someone who is not this device's signed-in user — the
/// local replica `SharedObservationImporter` writes for the colleague named in
/// a `TT1:` payload (task 6.3). The harness's own `userRow` takes an
/// `E2eDevice`, which is the wrong shape here: the whole point is a person the
/// server has never associated with this project.
Map<String, Object?> colleagueRow(
  String userId, {
  required DateTime now,
}) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'user_id': userId,
    'first_name': 'Ada',
    'last_name': 'Colleague',
    'email': 'ada-$userId@example.org',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'their-device',
  };
}
