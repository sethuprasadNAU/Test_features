import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// Task 11.41 — the two records that could not be sent and never cleared.
///
/// ## What was observed, and what it turned out to be
///
/// On a Mac and an iPhone signed in as two different people against one LAN
/// server, the Mac showed a permanent red bar reading *"2 records aren't on
/// the server. Tap to see why"*, naming `Tags` and `Users`. No further traffic
/// reached the server and nothing printed on the client, which looked like the
/// rows being held before they were ever sent.
///
/// Two independent defects produce exactly that, and both are asserted here:
///
/// - **[_projectReach]** — the push offered every `Users` and `Tags` row the
///   device held to *every* project, because global tables have no project
///   column and nothing else narrowed them. A device with a second local
///   project offered that project's tag and its owner to this project's
///   server, which refuses what a project does not reach.
/// - **[_holdsThatCanClear]** — a hold was only ever settled by a **successful
///   push**, while a held row is suppressed from every subsequent push. So the
///   one event that could clear it was the one event that could no longer
///   happen, and the bar was permanent whatever caused the original refusal.
///   Including when the server had the row all along.
///
/// The task's leading hypothesis — that a device puts rows it *received* from
/// the server into its own outbound queue — is **disproved** by the last group
/// here, and deliberately kept as a test so it stays disproved.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const otherProjectId = 'proj-2';
  const userId = 'user-1';
  const teammateId = 'user-2';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 8, 27, 12);
  final stamp = DbCodec.encodeUtc(now);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  Map<String, Object?> user(String id) => {
    'user_id': id,
    'first_name': 'Person',
    'last_name': id,
    'email': '$id@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': deviceId,
  };

  Map<String, Object?> project(String id, String owner) => {
    'project_id': id,
    'project_name': 'Project $id',
    'owner_user_id': owner,
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': owner,
    'origin_device_id': deviceId,
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> tag(String id, String by, {String? inProject}) => {
    'tag_id': id,
    // **Task 11.219: a tag belongs to a project.** Which is most of what
    // this file was about — the push had to narrow global tables by
    // reachability because they had no project column, and `Tags` was the
    // one that produced the field symptom. It has one now, so the ordinary
    // scope filter covers it and the reachability half of this file's
    // subject applies only to `Users`.
    'project_id': inProject ?? projectId,
    'lineage_id': id,
    'frequency_mhz': 150.220,
    'tag_name': id,
    'status': 'active',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': by,
    'origin_device_id': deviceId,
  };

  /// A bearing the teammate recorded, as this device would hold it after
  /// importing their shared observation (task 6.3) — their id in both the
  /// author and the audit column, which is what makes it theirs to push and
  /// not this device's.
  Map<String, Object?> theirObservation(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': teammateId,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': teammateId,
    'origin_device_id': 'their-device',
  };

  Future<void> seedOwnProject() async {
    await appDb.raw.insert(Tables.users, user(userId));
    await appDb.raw.insert(Tables.projects, project(projectId, userId));
  }

  /// Every `table/rowKey` the pushes so far have put on the wire.
  Set<String> offeredKeys() => {
    for (final push in transport.pushes)
      for (final entry in push.rows.entries)
        for (final row in entry.value)
          '${entry.key}/${syncRowKey(syncTablesByName[entry.key]!, row)}',
  };

  group('a project only ever offers global rows it reaches', () {
    test(
      "another local project's tag and owner are not offered to this one",
      () async {
        // The device state that produces the field symptom: one project linked
        // to a server, and a second project that has never been published —
        // ordinary for anybody who used the app before signing in, and
        // guaranteed for anybody who has more than one study.
        await seedOwnProject();
        await appDb.raw.insert(Tables.users, user(teammateId));
        await appDb.raw.insert(
          Tables.projects,
          project(otherProjectId, teammateId),
        );
        await appDb.raw.insert(
          Tables.tags,
          tag('tag-of-proj-2', teammateId, inProject: otherProjectId),
        );

        await engine().run(projectId);

        expect(
          offeredKeys(),
          isNot(contains('${Tables.tags}/tag-of-proj-2/$otherProjectId')),
          reason: 'proj-1 offered a tag that belongs to proj-2',
        );
        expect(
          offeredKeys(),
          isNot(contains('${Tables.users}/$teammateId')),
          reason: "proj-1 offered proj-2's owner",
        );
        // And the rows it *does* own still go, so this is a narrowing and not
        // a stoppage.
        expect(offeredKeys(), contains('${Tables.users}/$userId'));
        expect(offeredKeys(), contains('${Tables.projects}/$projectId'));
      },
    );

    test('a tag this project has added is offered', () async {
      await seedOwnProject();
      await appDb.raw.insert(Tables.tags, tag('tag-mine', userId));

      await engine().run(projectId);
      expect(offeredKeys(), contains('${Tables.tags}/tag-mine/$projectId'));
    });

    test("a teammate's own records are never offered at all — task 11.43",
        () async {
      // **This test asserted the opposite until 2026-08-28, and the reversal is
      // the finding.** Task 11.41 wrote here that the narrowing "must not be
      // 'never offer anybody else's row'", because a colleague genuinely on
      // this project is reachable and their row therefore goes up. Reachable
      // was the right answer to the wrong question: it decides what a *pull*
      // delivers. A push has to ask what the server will accept, and the
      // server will not accept a `Users` or `Project_Memberships` row about
      // anybody but the caller from any device, ever — it keeps those records
      // itself, from that person's own sign-in and their own redemption of an
      // invitation.
      //
      // So this offered two rows the server refused every single time, and on
      // a first publish — where nothing pulls first to clear them — that was a
      // permanent-looking "records aren't on the server" warning about records
      // that were never this device's to send. Found on real hardware,
      // 2026-08-27.
      await seedOwnProject();
      await appDb.raw.insert(Tables.users, user(teammateId));
      await appDb.raw.insert(Tables.projectMemberships, {
        'membership_id': 'membership-1',
        'project_id': projectId,
        'user_id': teammateId,
        'join_date': stamp,
        'end_date': null,
        'role': 'contributor',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      });
      // Armed anyway, so a regression that starts offering these rows again
      // fails on the refusal rather than passing quietly.
      transport.refuseRows['${Tables.users}/$teammateId'] =
          SyncRowOutcome.unauthorized;

      final report = await engine().run(projectId);
      expect(offeredKeys(), isNot(contains('${Tables.users}/$teammateId')));
      expect(
        offeredKeys(),
        isNot(contains('${Tables.projectMemberships}/membership-1/$projectId')),
        reason: "a membership row is the server's to write, at redemption",
      );
      expect(report.heldCount, 0);

      // And the device's own identity still goes up, which is the half that
      // must not be lost: a filter that withheld everything would pass the two
      // assertions above and be useless.
      expect(offeredKeys(), contains('${Tables.users}/$userId'));
    });

    test(
      'the count the status line shows is the count the push will offer',
      () async {
        // `pendingRowCount` and the push selection share one predicate, so the
        // narrowing has to reach both or the two numbers disagree — which is
        // the defect the shared predicate was written to prevent.
        await seedOwnProject();
        await appDb.raw.insert(Tables.users, user(teammateId));
        await appDb.raw.insert(
          Tables.projects,
          project(otherProjectId, teammateId),
        );
        await appDb.raw.insert(
          Tables.tags,
          tag('tag-of-proj-2', teammateId, inProject: otherProjectId),
        );

        final pending = await SyncEngine.pendingRowCount(appDb.raw, projectId, userId);
        await engine().run(projectId);
        final offered = transport.pushes.single.rows.values.fold(
          0,
          (sum, rows) => sum + rows.length,
        );
        expect(offered, pending);
      },
    );
  });

  group('a hold is settled by anything that takes the row off the wire', () {
    test(
      'the server delivering the row clears it — the promise the copy makes',
      () async {
        // `HeldRowReason.notPermitted` tells the user, in these words, that a
        // record somebody else made "will arrive from their device when they
        // sync — you do not need to do anything." Before this, that never
        // happened: the pull wrote a receipt and left the hold standing, so
        // the device reported a record as not on the server while holding the
        // server's own copy of it.
        //
        // **The held row is a colleague's bearing and not their `Users` row,
        // which task 11.43 changed.** A device no longer offers a record about
        // somebody else's identity at all, so it can no longer hold one either.
        // A replica of their bearing is the case that survives and the case
        // this promise was written for: field data the server can only get
        // from its author's device, held and explained in the meantime.
        await seedOwnProject();
        await appDb.raw.insert(Tables.users, user(teammateId));
        await appDb.raw.insert(
          Tables.observations,
          theirObservation('obs-replica'),
        );
        transport.seedServerRow(Tables.projects, project(projectId, userId));
        transport.refuseRows['${Tables.observations}/obs-replica/$projectId'] =
            SyncRowOutcome.unauthorized;

        expect((await engine().run(projectId)).heldCount, 1);

        // Now the teammate's own device syncs, which is the resolution the app
        // promised, and this device pulls their row.
        transport.seedServerRow(
          Tables.observations,
          theirObservation('obs-replica'),
        );

        final report = await engine().run(projectId);
        expect(
          report.heldCount,
          0,
          reason: 'the server delivered the row and the bar still said no',
        );
        expect(await SyncHeldRowStore(appDb.raw).held(projectId), isEmpty);
      },
    );

    test('a row this project no longer reaches stops being held', () async {
      // Every hold created before the reachability narrowing existed is of
      // this shape, including the two rows on the Mac this task was opened
      // for. They were never this project's to send, so the claim "this record
      // is not on the server" was never this project's claim to make.
      await seedOwnProject();
      await appDb.raw.insert(Tables.tags, tag('tag-x', userId));
      transport.refuseRows['${Tables.tags}/tag-x/$projectId'] =
          SyncRowOutcome.unauthorized;
      expect((await engine().run(projectId)).heldCount, 1);

      // The tag is moved out of this project — the case where a row this
      // device was holding stops being one it would offer at all. Since task
      // 11.219 that is a change of `project_id` rather than a link being
      // deleted; either way the push no longer reaches it, which is what
      // the hold has to notice.
      await appDb.raw.insert(
        Tables.projects,
        project(otherProjectId, userId),
      );
      await appDb.raw.update(
        Tables.tags,
        {'project_id': otherProjectId},
        where: 'tag_id = ?',
        whereArgs: ['tag-x'],
      );

      expect((await engine().run(projectId)).heldCount, 0);
    });

    test('a row deleted from the device stops being held', () async {
      await seedOwnProject();
      await appDb.raw.insert(Tables.tags, tag('tag-x', userId));
      transport.refuseRows['${Tables.tags}/tag-x/$projectId'] =
          SyncRowOutcome.unauthorized;
      expect((await engine().run(projectId)).heldCount, 1);

      await appDb.raw.delete(
        Tables.tags,
        where: 'tag_id = ?',
        whereArgs: ['tag-x'],
      );

      expect((await engine().run(projectId)).heldCount, 0);
    });

    test('a row that is still genuinely refused stays held', () async {
      // The direction that matters most: reconciliation must not become a way
      // for a real refusal to disappear quietly, which would be finding D-3
      // rebuilt out of the fix for it.
      await seedOwnProject();
      await appDb.raw.insert(Tables.tags, tag('tag-x', userId));
      transport.refuseRows['${Tables.tags}/tag-x/$projectId'] =
          SyncRowOutcome.unauthorized;

      for (var round = 0; round < 3; round++) {
        expect((await engine().run(projectId)).heldCount, 1);
      }
      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.outcomeKey, '${Tables.tags}/tag-x/$projectId');
    });

    test(
      'a hold on a row the server could not even key is left standing',
      () async {
        // An unkeyable hold matches no local row, so every question this
        // reconciliation asks about it answers "not outbound". Resolving it
        // would be the check mistaking its own blindness for good news.
        await seedOwnProject();
        await SyncHeldRowStore.ensureTable(appDb.raw);
        await SyncHeldRowStore(appDb.raw).hold(
          projectId: projectId,
          tableName: Tables.observations,
          rowKey: unkeyableRowKey,
          reason: HeldRowReason.rejected,
          rowUpdatedAt: null,
          at: now,
        );

        expect((await engine().run(projectId)).heldCount, 1);
      },
    );
  });

  group('the leading hypothesis, kept so it stays disproved', () {
    test('a row the server delivered is not offered back to it', () async {
      // Task 11.41 proposed that a device puts rows it received from the
      // server into its own outbound queue, which would mean every device
      // accumulates permanently-held rows for every teammate. It does not:
      // `SyncEngine._recordDeliveredReceipts` accounts for every delivered row
      // as the page commits. Asserted here because the hypothesis was
      // plausible enough to act on, and because nothing else in the suite
      // pins it — every pull test stops after one round.
      await seedOwnProject();
      transport.seedServerRow(Tables.projects, project(projectId, userId));
      transport.seedServerRow(Tables.users, user(teammateId));
      transport.seedServerRow(Tables.tags, tag('tag-theirs', teammateId));

      await engine().run(projectId);
      final afterPull = offeredKeys();
      await engine().run(projectId);

      final reoffered = offeredKeys().difference(afterPull);
      expect(
        reoffered,
        isEmpty,
        reason: 'rows received from the server were pushed back at it',
      );
      expect(
        await SyncEngine.heldRowCount(appDb.raw, projectId),
        0,
        reason: 'a device that only pulled ended up holding rows',
      );
    });
  });
}
