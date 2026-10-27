import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// **Task 11.60 — a removed member's device learns it was removed, and can
/// then get rid of its copy.**
///
/// ## The state this closes
///
/// An owner removes somebody. Every request that device makes about the
/// project is refused, *including the pull that would have carried the news*,
/// so the device goes on believing it is a member: an amber "the server is
/// refusing access", records it can never send, and a Delete control that does
/// nothing — because the exemption that lets a departed member delete their
/// own copy reads the **local** membership rows. Task 11.57 measured it; the
/// route out was to press Leave first, and nothing anywhere said so.
///
/// Michael decided on 2026-08-29 that the server tells them instead
/// (Security Model §4.27). What is asserted here is the client half of that,
/// end to end through the real [SyncEngine] against a fake transport that
/// answers exactly as the server now does — see
/// `FakeSyncTransport.closedMembershipProjects`.
///
/// ## The two orderings, and why both are here
///
/// The device may or may not have records waiting when it finds out, and the
/// two take **different routes through `run()`**:
///
/// - **Nothing pending** — no push request is made at all, so the pull runs on
///   the ordinary path and the round *succeeds*. The status has to become "not
///   on this project" out of a `200`, which is not where anybody would look
///   for it.
/// - **Something pending** — the push is refused and used to throw before the
///   pull could ask anything. That is the field case, because somebody who has
///   been recording all day is exactly who has rows waiting.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  const membershipId = 'membership-1';
  final now = DateTime.utc(2026, 8, 1, 12);
  final removedAt = DateTime.utc(2026, 8, 2, 12);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport()..sessionUserId = userId;
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    await _seedLocalProject(appDb, now: now);
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  Map<String, Object?> membership({
    required String? endDate,
    required int revision,
    String modifiedBy = userId,
  }) => {
    'membership_id': membershipId,
    'project_id': projectId,
    'user_id': userId,
    'join_date': DbCodec.encodeUtc(now),
    'end_date': endDate,
    'role': 'contributor',
    'created_at': DbCodec.encodeUtc(now),
    'updated_at': endDate ?? DbCodec.encodeUtc(now),
    'deleted_at': null,
    'revision': revision,
    'last_modified_by': modifiedBy,
    'origin_device_id': deviceId,
  };

  Future<Map<String, Object?>?> localMembership() async {
    final rows = await appDb.raw.query(
      Tables.projectMemberships,
      where: 'membership_id = ?',
      whereArgs: [membershipId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// **The state a real device is in before any of this: on the project, and
  /// having synced at least once.**
  ///
  /// Reached by actually syncing rather than by writing the row here, and that
  /// matters more than it looks: a membership row inserted straight into the
  /// database has no receipt, so it is *pending*, so every round pushes it —
  /// and the "nothing pending" ordering below would be unreachable while
  /// appearing to be tested. The way this row really arrives is a pull.
  Future<void> joinAndSync() async {
    transport.seedServerRow(
      Tables.projectMemberships,
      membership(endDate: null, revision: 0),
    );
    // **Rounds until two in a row offer nothing**, rather than until the first
    // one does, and the reason is worth keeping. A global row becomes
    // offerable only once the project *reaches* the person it names, and the
    // row that makes this project reach them is the membership row the first
    // pull delivers — so round one pushes nothing, and round two pushes their
    // `Users` row. Stopping at the first quiet round leaves a row pending, and
    // "nothing pending" below would then be quietly testing the other
    // ordering. A device in the field settles the same way, over minutes.
    var quiet = 0;
    for (var round = 0; round < 6 && quiet < 2; round++) {
      final report = await engine().run(projectId);
      quiet = report.pushed == 0 ? quiet + 1 : 0;
    }
    expect(
      quiet,
      2,
      reason:
          'the fixture never settled, so "nothing pending" below would not be '
          'true and the test would be measuring the other ordering',
    );
    expect(
      (await localMembership())?['end_date'],
      isNull,
      reason: 'the fixture did not put this device on the project',
    );
  }

  /// The server's copy after an owner removed them: the same row, stint
  /// closed, stamped by the owner. Only the disclosure can deliver it, because
  /// every other request about this project is refused from here on.
  void seedRemovalOnServer() {
    transport
      ..seedServerRow(
        Tables.projectMemberships,
        membership(
          endDate: DbCodec.encodeUtc(removedAt),
          revision: 1,
          modifiedBy: 'user-owner',
        ),
      )
      ..closedMembershipProjects.add(projectId)
      ..ackedCursors.clear();
  }

  Map<String, Object?> observation(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': DbCodec.encodeUtc(now),
    'timestamp_utc': DbCodec.encodeUtc(now),
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'notes': 'a bearing that will never leave this device',
    'created_at': DbCodec.encodeUtc(now),
    'updated_at': DbCodec.encodeUtc(now),
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
  };

  group('a device that has been removed from a project', () {
    test(
      'with nothing pending, learns from the pull and the round succeeds',
      () async {
        await joinAndSync();
        seedRemovalOnServer();
        await engine().run(projectId);

        final stored = await localMembership();
        expect(
          stored?['end_date'],
          isNotNull,
          reason:
              'the device still believes it is a member, so it will go on '
              'showing "the server is refusing access" and offering a delete '
              'control that does nothing',
        );
        expect(
          stored?['last_modified_by'],
          'user-owner',
          reason:
              'the row was rewritten rather than merged — the copy that lands '
              'here must be the one the server holds, or this device and the '
              'server disagree about it forever',
        );
      },
    );

    test('and never acknowledges the page that told it', () async {
      await joinAndSync();
      seedRemovalOnServer();
      final pullsBefore = transport.pullCalls;

      await engine().run(projectId);

      expect(
        transport.ackedCursors,
        isEmpty,
        reason:
            'ack is a write and is refused for a closed stint, so acking here '
            'throws away the page that had just been committed — which is why '
            'the disclosure hands the cursor straight back',
      );
      expect(
        transport.pullCalls - pullsBefore,
        1,
        reason:
            'a page that returns rows without moving the cursor was requested '
            'more than once, which is a device asking forever for the same '
            'answer',
      );
    });

    test(
      'with records waiting, the refused push no longer buries the answer',
      () async {
        await joinAndSync();
        await appDb.raw.insert(Tables.observations, observation('obs-1'));
        seedRemovalOnServer();

        // **The round still fails, and that is correct.** The push genuinely
        // was refused; a report of success would claim a field record reached
        // a server it did not.
        await expectLater(
          engine().run(projectId),
          throwsA(
            isA<SyncTransportException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );

        expect(
          (await localMembership())?['end_date'],
          isNotNull,
          reason:
              'the push threw before the pull could ask, so a device with '
              'anything waiting — which is everybody who has been recording — '
              'never finds out. That is the field case, not the edge case.',
        );
      },
    );

    test(
      'and can then delete its copy through the path that already exists',
      () async {
        await joinAndSync();
        seedRemovalOnServer();

        // Before the news arrives, the departed-member exemption does not
        // apply: locally this person is still a member, so the delete is
        // refused. This is the state task 11.57 found somebody stuck in.
        await expectLater(
          ProjectRepository(appDb.raw).softDeleteById(
            projectId,
            actor: const MutationActor.user(userId),
            deviceId: deviceId,
            exemption: const MutationExemption.departedMember(projectId),
          ),
          throwsA(isA<UnauthorizedMutation>()),
        );

        await engine().run(projectId);

        // **No second deletion mechanism.** The same call, unchanged, through
        // the same exemption — it works now because the local evidence it
        // reads is finally true.
        await ProjectRepository(appDb.raw).softDeleteById(
          projectId,
          actor: const MutationActor.user(userId),
          deviceId: deviceId,
          exemption: const MutationExemption.departedMember(projectId),
        );
        final project = await appDb.raw.query(
          Tables.projects,
          where: 'project_id = ?',
          whereArgs: [projectId],
          limit: 1,
        );
        expect(project.single['deleted_at'], isNotNull);
      },
    );

    test('and nothing of the project itself arrives with it', () async {
      await joinAndSync();
      // A record the server holds for this project. A member would pull it; a
      // removed person must not.
      transport.seedServerRow(Tables.observations, observation('obs-server'));
      seedRemovalOnServer();

      await engine().run(projectId);

      expect(
        await appDb.raw.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: ['obs-server'],
        ),
        isEmpty,
        reason:
            'the disclosure delivered project data. It may carry one thing: '
            "this person's own closed membership row.",
      );
    });
  });

  test(
    'an ordinary page still acknowledges — the skip is not a general one',
    () async {
      // The guard rail on the change above: "only ack a cursor that moved"
      // must not have quietly stopped this device acknowledging anything at
      // all, which the server needs for the tombstone retention floor.
      await joinAndSync();
      transport.seedServerRow(Tables.observations, observation('obs-server'));

      await engine().run(projectId);

      expect(
        transport.ackedCursors,
        isNotEmpty,
        reason:
            'a normal page moves the cursor and must still be acknowledged; '
            'without it the server never learns where this device has got to',
      );
    },
  );
}

Future<void> _seedLocalProject(AppDatabase db, {required DateTime now}) async {
  final stamp = DbCodec.encodeUtc(now);
  await db.raw.insert(Tables.users, {
    'user_id': 'user-1',
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': 'sam@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': 'user-1',
    'origin_device_id': 'device-A',
  });
  await db.raw.insert(Tables.users, {
    'user_id': 'user-owner',
    'first_name': 'Ada',
    'last_name': 'Owner',
    'email': 'ada@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': 'user-owner',
    'origin_device_id': 'device-B',
  });
  await db.raw.insert(Tables.projects, {
    'project_id': 'proj-1',
    'project_name': 'Elk',
    'owner_user_id': 'user-owner',
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': 'user-owner',
    'origin_device_id': 'device-B',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  });
}
