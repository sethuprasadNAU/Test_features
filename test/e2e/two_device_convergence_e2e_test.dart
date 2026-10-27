@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// Task 10.17: re-runs 10.15's two-device-same-user scenarios through the
/// actual network path — same `user_id` from two different locally minted
/// device identities, independent `(user, device)` cursors, and no
/// identity churn on a further sync round — rather than against
/// `FakeSyncTransport`, where the two devices' pushes and pulls never
/// actually competed for the same server state.
void main() {
  group('two devices, one person, over real HTTP', skip: e2eSkipReason, () {
    late E2eDevice a;
    late E2eDevice b;
    late String email;
    late String projectId;
    late DateTime now;

    setUp(() async {
      email = randomEmail();
      a = await E2eDevice.create();
      await a.signIn(email, firstName: 'Sam', lastName: 'Ranger');
      b = await E2eDevice.create();
      await b.signIn(email, firstName: 'Sam', lastName: 'Ranger');

      // Captured *after* signing in, so rows written below are dated after the
      // `Users` row sign-in stamps with the real wall-clock time. This used to
      // be load-bearing: a fixed historical `now` sat *before* the push
      // watermark that first row set, and the `updated_at >= watermark`
      // selection then never offered those rows. Task 10.33 removed the
      // watermark — `SyncEngine._collectChangedRows` now selects whatever the
      // server has not confirmed, at any age — and this is kept only because
      // chronological test data reads better.
      now = DateTime.now().toUtc();

      projectId = 'e2e-proj-${randomId()}';
      await seedLocalProject(
        a.db.raw,
        projectId: projectId,
        ownerId: a.userId,
        deviceId: a.deviceId,
        now: now,
      );
      // A owns it locally; this is the publish that puts it on the server, and
      // it has to happen before *either* device syncs. It used not to matter:
      // a sync for a project the server had never seen answered 200-empty,
      // which was Gate C's C-2 existence oracle, so whichever device ran first
      // no-opped harmlessly. That answer is now a refusal, which is also what
      // the app does — `SyncEngine` only ever runs for a project already marked
      // linked, and only publish or join marks one.
      await a.pushOwnUserAndProject(projectId: projectId, now: now);
    });

    // No `tearDown` closing devices here: `E2eDevice.create` registers its
    // own (see its note — a tear-down for a device that was never created is
    // how one failure became two).

    SyncEngine engineFor(E2eDevice device) => SyncEngine(
      db: device.db.raw,
      transport: device.transport(),
      state: device.state,
      deviceId: device.deviceId,
      userId: device.userId,
    );

    test('a device adopts the SAME server user_id, not two accounts', () {
      expect(a.userId, b.userId);
    });

    test(
      'device A\'s observation reaches device B, and device B\'s reaches A',
      () async {
        await a.db.raw.insert(
          Tables.observations,
          observationRow(
            'e2e-obs-a-${randomId()}',
            projectId: projectId,
            userId: a.userId,
            deviceId: a.deviceId,
            now: now,
          ),
        );
        await engineFor(a).run(projectId);

        // B has never seen this project — join it from cursor zero.
        await engineFor(b).run(projectId);
        final onB = await b.db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        expect(onB, hasLength(1));

        await b.db.raw.insert(
          Tables.observations,
          observationRow(
            'e2e-obs-b-${randomId()}',
            projectId: projectId,
            userId: b.userId,
            deviceId: b.deviceId,
            now: now.add(const Duration(minutes: 1)),
          ),
        );
        await engineFor(b).run(projectId);
        await engineFor(a).run(projectId);

        final onA = await a.db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        expect(onA, hasLength(2));
      },
    );

    test('the two devices keep independent cursors — advancing one never '
        'moves the other', () async {
      await engineFor(a).run(projectId);
      await engineFor(b).run(projectId);

      await a.db.raw.insert(
        Tables.observations,
        observationRow(
          'e2e-obs-${randomId()}',
          projectId: projectId,
          userId: a.userId,
          deviceId: a.deviceId,
          now: now,
        ),
      );
      final cursorBBefore = await b.state.cursor(projectId);
      await engineFor(a).run(projectId);
      final cursorBAfter = await b.state.cursor(projectId);

      expect(
        cursorBAfter,
        cursorBBefore,
        reason:
            "A's own sync round must not move B's stored cursor — "
            'they are keyed on (user_id, device_id), not user_id alone',
      );
    });

    test('a settled pair syncing again produces no further churn', () async {
      await a.db.raw.insert(
        Tables.observations,
        observationRow(
          'e2e-obs-${randomId()}',
          projectId: projectId,
          userId: a.userId,
          deviceId: a.deviceId,
          now: now,
        ),
      );
      await engineFor(a).run(projectId);
      await engineFor(b).run(projectId);
      // Each device's `signIn` independently minted its own local `Users`
      // row for the same server identity (each started from an empty
      // local database, so each took the "no local row yet" branch of
      // `ServerIdentityAdopter.adopt`). The two rows carry the same
      // `revision` but different `updated_at`/`origin_device_id`, so the
      // pair's very first exchange has one genuine last-write-wins
      // settling event still owed — whichever pushed later wins, and the
      // other pulls that change in exactly once. That is real convergence
      // behaviour, not the "identity churn" 10.6 warns about (which is
      // *repeated* `user_id` rewriting; this is a one-time reconciliation
      // of one already-shared identity's row content) — so it is settled
      // by one more round each, and only *then* is "no further churn" the
      // right thing to assert.
      await engineFor(a).run(projectId);
      await engineFor(b).run(projectId);

      final again = await engineFor(a).run(projectId);
      final againB = await engineFor(b).run(projectId);

      expect(again.changedAnything, isFalse);
      expect(againB.changedAnything, isFalse);
    });

    test(
      'revision stability: once both devices are synced, a further round '
      'rewrites no user_id and bumps no revision',
      () async {
        // Settle the pair first — see the test above's comment for why one
        // reconciliation round is owed on a brand-new pair's very first
        // exchange.
        await engineFor(a).run(projectId);
        await engineFor(b).run(projectId);
        await engineFor(a).run(projectId);
        await engineFor(b).run(projectId);

        final userBefore = (await a.db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [a.userId],
        )).single;

        // This is exactly what an identity-rename loop looks like: the same
        // user_id rewritten and its revision bumped on every subsequent
        // sync, with no genuine data change driving it.
        await engineFor(a).run(projectId);
        await engineFor(b).run(projectId);
        await engineFor(a).run(projectId);
        await engineFor(b).run(projectId);

        final userAfter = (await a.db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [a.userId],
        )).single;

        expect(userAfter['user_id'], userBefore['user_id']);
        expect(userAfter['revision'], userBefore['revision']);
        expect(userAfter['updated_at'], userBefore['updated_at']);
        expect(
          await a.db.raw.query(Tables.users),
          hasLength(1),
          reason: 'no second Users row should ever appear for one person',
        );
      },
    );

    test(
      'an observation created on the phone is attributed to one person, '
      'not two, once it reaches the laptop',
      () async {
        await a.db.raw.insert(
          Tables.observations,
          observationRow(
            'e2e-obs-phone-${randomId()}',
            projectId: projectId,
            userId: b.userId,
            deviceId: b.deviceId,
            now: now,
          ),
        );
        await engineFor(b).run(projectId);
        await engineFor(a).run(projectId);

        final onA = await a.db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        final authors = onA.map((r) => r['user_id']).toSet();
        expect(
          authors,
          {a.userId},
          reason:
              'a and b share one server user_id; a second, distinct author '
              'id here would mean the phone minted its own identity instead '
              'of adopting the server\'s',
        );
        expect(
          await a.db.raw.query(Tables.users),
          hasLength(1),
          reason: 'the observation must not have dragged in a second Users '
              'row for its author',
        );
      },
    );
  });
}
