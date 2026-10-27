@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/project_publisher.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// Task 11.41 — **two different people**, one project, one server.
///
/// ## The gap this closes
///
/// Every multi-device test in this suite before it signed both devices in with
/// the *same address*, which converges on one `user_id` (task 10.6) — so no
/// row in any of them ever named somebody who was not the caller. That is the
/// entire subject of task 11.24's rule, and it is why a defect that shows up
/// the moment two people share a project survived a full phase of testing and
/// was found by running the app on a Mac and a phone.
///
/// `two_device_convergence_e2e_test.dart` says so in its own first line: *"same
/// `user_id` from two different locally minted device identities"*. This file
/// is the other half.
///
/// ## What running it actually found
///
/// **Run for the first time on 2026-08-27**, against the live stack via
/// `scripts/run_e2e_tests.sh`. The two tests carrying task 11.41's findings —
/// the owner holding nothing after a teammate syncs, and a second project's
/// tag never being offered to this one — **passed on that first run**, against
/// a real server, with two genuinely different accounts. The third failed, and
/// the failure was in this file rather than in the app. Recorded rather than
/// quietly corrected, because "the test I could not run turned out to be
/// wrong" is the useful half of having written it blind.
///
/// Both mistakes were the same mistake: **a device was made to hold a record
/// that referred to something it had never been told about.** SQLite refused
/// each one (`Observations.user_id` and `.project_id` are foreign keys and
/// `PRAGMA foreign_keys` is on), which is the schema being right.
///
/// 1. The owner was given a bearing naming the contributor without the
///    contributor's `Users` row. `SharedObservationImporter` writes both in one
///    transaction precisely because neither is meaningful alone.
/// 2. The contributor was given a bearing in a project it had never pulled.
///    Being approved marks a project linked but writes nothing local; the
///    device holds no `Projects` row until it syncs.
///
/// **A third mistake was mine and is worth more than either.** The first fix
/// for (1) used `ConflictAlgorithm.ignore`, which skips a row violating *any*
/// constraint — so it could not tell "already present" from "this insert was
/// broken", and it silently did the second while looking like the first. The
/// test went on failing with the same message and nothing said why. That is
/// the defect class this whole task is about, written into the test for it.
/// The insert is now guarded by a read, so a failure is loud.
void main() {
  group('two people, one project, over real HTTP', skip: e2eSkipReason, () {
    late E2eDevice owner;
    late E2eDevice contributor;
    late String projectId;
    final now = DateTime.utc(2026, 8, 27, 12);

    setUp(() async {
      owner = await E2eDevice.create();
      await owner.signIn(
        randomEmail(),
        firstName: 'Ada',
        lastName: 'Owner',
      );
      contributor = await E2eDevice.create();
      await contributor.signIn(
        randomEmail(),
        firstName: 'Kim',
        lastName: 'Contributor',
      );

      projectId = 'e2e-proj-${randomId()}';
      await seedLocalProject(
        owner.db.raw,
        projectId: projectId,
        ownerId: owner.userId,
        deviceId: owner.deviceId,
        now: now,
      );
      await ProjectPublisher(
        db: owner.db.raw,
        transport: owner.transport(),
        state: owner.state,
        deviceId: owner.deviceId,
        userId: owner.userId,
      ).publish(projectId, now: now);

      // Two genuinely different accounts on one project — the state no
      // previous test in this suite reached. Through the real join code and a
      // real approval (task 11.81), never a seeded membership row.
      await owner.admit(contributor, projectId: projectId);
      await contributor.state.markProjectLinked(projectId);
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

    test(
      "the owner holds nothing after a teammate's work arrives",
      () async {
        // This is the field scenario, in the order it happened: the phone
        // records bearings and syncs, then the Mac syncs and reports records
        // it cannot send.
        await engineFor(contributor).run(projectId);
        await contributor.db.raw.insert(
          Tables.observations,
          observationRow(
            'e2e-obs-${randomId()}',
            projectId: projectId,
            userId: contributor.userId,
            deviceId: contributor.deviceId,
            now: now,
          ),
        );
        await engineFor(contributor).run(projectId);

        // Three rounds on the owner's device, because the symptom was not
        // "the first sync failed" — it was a red bar that survived every
        // sync after it.
        for (var round = 0; round < 3; round++) {
          final report = await engineFor(owner).run(projectId);
          expect(
            report.heldCount,
            0,
            reason:
                'round $round left the owner holding records it says are not '
                'on the server',
          );
        }

        expect(await SyncHeldRowStore(owner.db.raw).held(projectId), isEmpty);

        // And the teammate's work actually arrived, so the zero above is not
        // zero-because-nothing-happened.
        final observations = await owner.db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        expect(observations, isNotEmpty);
        final users = await owner.db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [contributor.userId],
        );
        expect(
          users,
          hasLength(1),
          reason: "the teammate's Users row should have been delivered",
        );
      },
    );

    test(
      "an unpublished second project's tag is never offered to this one",
      () async {
        // The measured cause. A device holds one `Tags` table for every
        // project it has ever had, and the push offered all of it to whichever
        // project was syncing — so a tag belonging to a local project that was
        // never published went to this project's server, was refused, and
        // stuck.
        final otherProjectId = 'e2e-other-${randomId()}';
        await seedLocalProject(
          owner.db.raw,
          projectId: otherProjectId,
          ownerId: owner.userId,
          deviceId: owner.deviceId,
          now: now,
          name: 'Never published',
        );
        final strayTagId = 'e2e-tag-${randomId()}';
        final stamp = DbCodec.encodeUtc(now);
        await owner.db.raw.insert(Tables.tags, {
          'tag_id': strayTagId,
          'frequency_mhz': 151.500,
          'tag_name': 'Belongs to the other project',
          'date_put_on': stamp,
          'status': 'active',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 0,
          'last_modified_by': owner.userId,
          'origin_device_id': owner.deviceId,
        });
        await owner.db.raw.insert(Tables.projectTags, {
          'project_id': otherProjectId,
          'tag_id': strayTagId,
          'status': 'active',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 0,
          'last_modified_by': owner.userId,
          'origin_device_id': owner.deviceId,
        });

        for (var round = 0; round < 2; round++) {
          expect((await engineFor(owner).run(projectId)).heldCount, 0);
        }
        final held = await SyncHeldRowStore(owner.db.raw).held(projectId);
        expect(
          held.map((h) => h.rowKey),
          isNot(contains(strayTagId)),
          reason:
              "a tag from a project that was never published reached this "
              "project's server and stuck there",
        );
      },
    );

    test(
      'a record naming the teammate is held with a reason, then clears when '
      'their device sends it',
      () async {
        // The legitimate refusal, and the resolution the app promises for it.
        // The owner writes a replica of a record the contributor authored —
        // what importing a shared observation produces (task 6.3) — which
        // task 11.24 correctly refuses from this device.
        final observationId = 'e2e-obs-${randomId()}';
        await engineFor(owner).run(projectId);

        // **The colleague's `Users` row comes with the replica, and this test
        // failed on its first real run for leaving it out.** `Observations`
        // has `user_id TEXT NOT NULL REFERENCES Users(user_id)` and SQLite
        // enforces it (`PRAGMA foreign_keys = ON`), so an observation naming
        // somebody this device has never heard of cannot be written at all —
        // the insert below failed with `FOREIGN KEY constraint failed`.
        //
        // That is the schema being right, not a gap: `SharedObservationImporter`
        // writes the sender's `Users` row *and* their observation in one
        // transaction precisely because neither is meaningful alone. Writing
        // only the observation modelled a state the app cannot reach.
        //
        // Written only if it is not already here, rather than with
        // `ConflictAlgorithm.ignore` — which was the first attempt and was
        // wrong in a way this whole task is about. `INSERT OR IGNORE` skips a
        // row that violates *any* constraint, so it cannot tell "already
        // present" from "this insert was broken", and it silently did the
        // second while looking like the first. A test that cannot distinguish
        // success from its own failure has no business being in this suite.
        final alreadyHere = await owner.db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [contributor.userId],
          limit: 1,
        );
        if (alreadyHere.isEmpty) {
          await owner.db.raw.insert(Tables.users, userRow(contributor, now: now));
        }
        await owner.db.raw.insert(
          Tables.observations,
          observationRow(
            observationId,
            projectId: projectId,
            userId: contributor.userId,
            deviceId: contributor.deviceId,
            now: now,
          ),
        );

        final refused = await engineFor(owner).run(projectId);
        expect(
          refused.heldCount,
          1,
          reason: 'a record naming somebody else must be refused and held',
        );

        // Now the contributor's own device sends its copy — the one entitled
        // to say they made it — and the owner pulls it. Before task 11.41 the
        // hold survived this, so the owner's device reported a record as not
        // on the server while holding the server's own copy of it.
        //
        // The contributor syncs *first*, and that is the second thing running
        // this test for real caught. Being approved marks the project
        // linked but writes nothing local; until this device pulls, it holds
        // no `Projects` row, and `Observations.project_id` is a foreign key —
        // so writing a bearing "in" a project this device has not yet seen
        // fails at the database, exactly as it should.
        await engineFor(contributor).run(projectId);
        await contributor.db.raw.insert(
          Tables.observations,
          observationRow(
            observationId,
            projectId: projectId,
            userId: contributor.userId,
            deviceId: contributor.deviceId,
            now: now,
          ),
        );
        await engineFor(contributor).run(projectId);

        final settled = await engineFor(owner).run(projectId);
        expect(
          settled.heldCount,
          0,
          reason:
              'the record arrived from its author and the warning stayed up',
        );
      },
    );

    test(
      "a colleague's edit stamp on a shared tag is accepted, and their name "
      'on a bearing is still refused — in one push',
      () async {
        // **Task 11.36, the gap task 11.47 left behind.** Every fixture in this
        // suite stamps its rows with the pusher, so no app-side test had ever
        // sent a shared record carrying somebody *else's* edit stamp. Had
        // 11.47 relaxed authorship alongside the audit column — undoing task
        // 11.24, which is the rule that a record naming who made a measurement
        // is only accepted from that person's device — a plain `flutter test`
        // would still have gone green. The server suite covers it, which makes
        // this a gap rather than a hole, and this is the app side of it.
        //
        // Both claims are made of one server, in one request, at one moment,
        // for the reason 11.47's own server test gives: a test that showed only
        // the audit stamp landing would pass just as well against a build that
        // had wrongly relaxed identity columns too.
        //
        // **Three people, not two, and the third is the point.** §4.17 has an
        // older reason to accept a foreign name — clause 2, *"this project
        // already reaches them"* — and a current member satisfies it. Written
        // with the contributor's id on the tag, this test passed against a
        // build with 11.47 deliberately reverted: clause 2 vouched for the
        // name and the relaxation was never consulted. So the tag is stamped
        // by somebody who has never been on this project, which is exactly the
        // person 11.47 is about (the colleague who handed over an archive and
        // moved on) and the only one for whom clause 2 can never come true.
        // The colleague-authored bearing keeps the *contributor*, for the
        // mirror-image reason — see the fixtures' own doc comments.
        final formerColleague = await E2eDevice.create();
        await formerColleague.signIn(
          randomEmail(),
          firstName: 'Jo',
          lastName: 'MovedOn',
        );

        final tagId = 'e2e-tag-${randomId()}';
        final ownBearingId = 'e2e-obs-${randomId()}';
        final colleagueBearingId = 'e2e-obs-${randomId()}';

        final response = await owner.transport().push(
          SyncPushRequest(
            projectId: projectId,
            deviceId: owner.deviceId,
            rows: {
              Tables.tags: [
                tagLastEditedByAFormerColleague(
                  tagId: tagId,
                  projectId: projectId,
                  formerColleagueUserId: formerColleague.userId,
                  deviceId: owner.deviceId,
                  now: now,
                ),
              ],
              Tables.observations: [
                // The owner's own bearing, which cites that tag. This is the
                // row that actually paid the cost when the tag was refused.
                observationRow(
                  ownBearingId,
                  projectId: projectId,
                  userId: owner.userId,
                  deviceId: owner.deviceId,
                  now: now,
                  tagId: tagId,
                ),
                bearingAuthoredByAColleague(
                  colleagueBearingId,
                  projectId: projectId,
                  colleagueUserId: contributor.userId,
                  deviceId: owner.deviceId,
                  now: now,
                  tagId: tagId,
                ),
              ],
            },
          ),
        );

        // Keyed `table/primaryKey` with a composite key joined by `/`, so this
        // matches on the id rather than reconstructing the server's spelling of
        // it — a reconstruction that was wrong would look like a missing row.
        SyncRowOutcome outcomeFor(String table, String id) {
          final matches = [
            for (final entry in response.outcomes.entries)
              if (entry.key.startsWith('$table/') && entry.key.contains(id))
                entry.value,
          ];
          expect(
            matches,
            hasLength(1),
            reason:
                'the server reported ${matches.length} outcomes for $id in '
                '$table; every pushed row gets exactly one, so this is the '
                'test failing to find it rather than a result',
          );
          return matches.single;
        }

        expect(
          outcomeFor(Tables.tags, tagId),
          SyncRowOutcome.inserted,
          reason:
              'who last renamed a tag is an audit name, not a claim about who '
              'a record is about — task 11.47 decided the server takes it, '
              'from somebody this project has never reached and never will',
        );
        expect(
          outcomeFor(Tables.projectTags, tagId),
          SyncRowOutcome.inserted,
          reason: 'and the link row that puts that tag in this project with it',
        );
        expect(
          outcomeFor(Tables.observations, ownBearingId),
          SyncRowOutcome.inserted,
          reason:
              "the harm being guarded against: a note about somebody else's "
              "rename must not keep the pusher's own field data off the "
              'server, which is what refusing the tag above used to do to '
              'every bearing citing it',
        );
        expect(
          outcomeFor(Tables.observations, colleagueBearingId),
          SyncRowOutcome.unauthorized,
          reason:
              'task 11.24 is untouched: a bearing naming the colleague as its '
              'author is only accepted from their device. If this ever reads '
              'inserted, the audit-column relaxation has reached an identity '
              'column and a contributor can sign a measurement with a '
              "colleague's name",
        );
      },
    );
  });
  // ==========================================================================

  group('publishing a project two people have already touched', skip: e2eSkipReason, () {
    // **Task 11.43, found on real hardware 2026-08-27.** The group above
    // publishes *before* the contributor exists, which is the easy order and
    // not the one the field produces. Two people share a project long before
    // anybody sets up a server — that is what the TT1 share payload is for
    // (task 6.3) — so the first publish is normally of a project that already
    // holds a colleague's identity and a replica of their work.
    //
    // Publishing that offered the colleague's `Users` row, which the server
    // refuses from any device but theirs, every time and with no version of
    // "later" in which it would clear. So the very first thing anybody did
    // with a server produced a warning about a record that was never this
    // device's to send.
    late E2eDevice owner;
    late E2eDevice contributor;
    late String projectId;
    final now = DateTime.utc(2026, 8, 28, 9);

    setUp(() async {
      owner = await E2eDevice.create();
      await owner.signIn(randomEmail(), firstName: 'Ada', lastName: 'Owner');
      contributor = await E2eDevice.create();
      await contributor.signIn(
        randomEmail(),
        firstName: 'Kim',
        lastName: 'Contributor',
      );

      projectId = 'e2e-proj-${randomId()}';
      await seedLocalProject(
        owner.db.raw,
        projectId: projectId,
        ownerId: owner.userId,
        deviceId: owner.deviceId,
        now: now,
      );

      // What importing a colleague's shared observation writes: their `Users`
      // row and their bearing, in one transaction, because neither is
      // meaningful alone (`SharedObservationImporter`). This is the state the
      // project is in when it is published for the first time.
      await owner.db.raw.insert(Tables.users, userRow(contributor, now: now));
      await owner.db.raw.insert(
        Tables.observations,
        observationRow(
          'e2e-obs-${randomId()}',
          projectId: projectId,
          userId: contributor.userId,
          deviceId: contributor.deviceId,
          now: now,
        ),
      );
    });

    test(
      "publishing holds nothing about the colleague as a person",
      () async {
        final report = await ProjectPublisher(
          db: owner.db.raw,
          transport: owner.transport(),
          state: owner.state,
          deviceId: owner.deviceId,
          userId: owner.userId,
        ).publish(projectId, now: now);

        final heldTables = report.refused.map((r) => r.tableName).toSet();
        expect(
          heldTables,
          isNot(contains(Tables.users)),
          reason:
              "the colleague's identity record is the server's to keep, not "
              'this device\'s to send — and offering it produced a warning '
              'nobody could act on',
        );
        expect(heldTables, isNot(contains(Tables.userEmails)));
        expect(heldTables, isNot(contains(Tables.projectMemberships)));

        // Their **bearing** is still offered, refused and held, and that is
        // deliberate rather than a leftover: it is field data the server can
        // only get from its author's device, so §4.17 requires the user be
        // told rather than have it silently dropped. It clears when their
        // device sends it — pinned by the third test in the group above.
        expect(
          report.refused.map((r) => r.tableName),
          [Tables.observations],
          reason:
              "a colleague's own bearing is the one thing a first publish "
              'legitimately cannot deliver',
        );
      },
    );

    test(
      'and the colleague is still fully resolvable on the server afterwards',
      () async {
        // The acceptance criterion this task could most easily have got wrong.
        // Withholding a person's identity record is only safe if the server
        // has its own — established here by running the real flow rather than
        // by reading the redemption code.
        await ProjectPublisher(
          db: owner.db.raw,
          transport: owner.transport(),
          state: owner.state,
          deviceId: owner.deviceId,
          userId: owner.userId,
        ).publish(projectId, now: now);

        await owner.admit(contributor, projectId: projectId);
        await contributor.state.markProjectLinked(projectId);

        // The owner pulls, and gets back from the server the two records this
        // device declined to send it.
        await SyncEngine(
          db: owner.db.raw,
          transport: owner.transport(),
          state: owner.state,
          deviceId: owner.deviceId,
          userId: owner.userId,
        ).run(projectId);

        final users = await owner.db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: [contributor.userId],
        );
        expect(
          users,
          hasLength(1),
          reason: 'the server holds its own record of who this person is',
        );
        expect(
          users.single['email'],
          normalizeEmail(contributor.signedInEmail),
          reason:
              'and it is the address the server authenticated, not one '
              'anybody typed',
        );

        final memberships = await owner.db.raw.query(
          Tables.projectMemberships,
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [projectId, contributor.userId],
        );
        expect(
          memberships,
          hasLength(1),
          reason: 'the server wrote the membership itself, at redemption',
        );
        expect(memberships.single['role'], ProjectRole.contributor.db);
      },
    );

    test('and a second sync does not put them back on the wire', () async {
      // Publish and ordinary sync read one rule, so the fix cannot hold on
      // only one of them. Before this, publish withholding a row and the very
      // next push re-offering it would have looked identical to a fix.
      await ProjectPublisher(
        db: owner.db.raw,
        transport: owner.transport(),
        state: owner.state,
        deviceId: owner.deviceId,
        userId: owner.userId,
      ).publish(projectId, now: now);

      SyncEngine engine() => SyncEngine(
        db: owner.db.raw,
        transport: owner.transport(),
        state: owner.state,
        deviceId: owner.deviceId,
        userId: owner.userId,
      );
      for (var round = 0; round < 3; round++) {
        final report = await engine().run(projectId);
        expect(
          report.heldCount,
          1,
          reason:
              'round $round: the colleague\'s bearing and nothing else — a '
              'higher number means an identity record came back',
        );
      }
      final held = await SyncHeldRowStore(owner.db.raw).held(projectId);
      expect(held.map((h) => h.tableName).toSet(), {Tables.observations});
    });
  });
}
