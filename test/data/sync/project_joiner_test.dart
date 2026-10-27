import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/project_joiner.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// Task 10.9's join acceptance criteria: a device with no local copy of a
/// project can discover it and pull its full history, and two same-named
/// projects with different ids never cross.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const deviceId = 'device-B';
  final now = DateTime.utc(2026, 8, 1, 12);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());
  });

  tearDown(() => appDb.close());

  ProjectJoiner joiner() => ProjectJoiner(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: 'user-1',
  );

  test('joining pulls the whole project down and marks it linked', () async {
    transport.seedServerRow(Tables.users, _user('user-1', now));
    transport.seedServerRow(Tables.projects, _project('proj-1', 'Elk', now));
    transport.seedServerRow(
      Tables.observations,
      _observation('obs-1', 'proj-1', 'user-1', now),
    );

    final report = await joiner().join('proj-1');

    expect(report.pulled, greaterThan(0));
    final rows = await appDb.raw.query(
      Tables.observations,
      where: 'observation_id = ?',
      whereArgs: ['obs-1'],
    );
    expect(rows, hasLength(1));
    expect(await state.isProjectLinked('proj-1'), isTrue);
  });

  test(
    'marks linked before the pull, so an interrupted join is resumable',
    () async {
      transport.seedServerRow(Tables.users, _user('user-1', now));
      transport.seedServerRow(Tables.projects, _project('proj-1', 'Elk', now));
      transport.failPullAfterPages = 0;

      // L-13 / task 10.95: `throwsA(anything)` would pass identically on any
      // unrelated bug in `join`, not just the injected pull failure this
      // test exists to prove is resumable. Assert the specific exception
      // `FakeSyncTransport.pull` throws once `failPullAfterPages` is hit.
      await expectLater(
        joiner().join('proj-1'),
        throwsA(isA<SyncTransportException>().having(
          (e) => e.reason,
          'reason',
          'unreachable',
        )),
      );
      // Even though the pull itself failed, the project is already marked
      // linked — the next ordinary sync (automatic or manual) simply resumes
      // the pull from wherever the cursor stopped.
      expect(await state.isProjectLinked('proj-1'), isTrue);
    },
  );

  group('ProjectDirectoryClient', () {
    /// The three states a local copy can be in, and only the first of them
    /// means "you already have this one" (task 11.57).
    Future<List<JoinableProject>> offered() => ProjectDirectoryClient(
      db: appDb.raw,
      transport: transport,
      state: state,
    ).listAvailableToJoin();

    void serverLists(List<String> ids) => transport.serverProjects.addAll([
      for (final id in ids)
        ProjectSummary(
          projectId: id,
          projectName: 'Elk',
          ownerUserId: 'user-1',
          role: 'owner',
        ),
    ]);

    test(
      'excludes a project this device is holding and syncing',
      () async {
        await appDb.raw.insert(Tables.users, _user('user-1', now));
        await appDb.raw.insert(
          Tables.projects,
          _project('proj-local', 'Elk', now),
        );
        await state.markProjectLinked('proj-local');
        serverLists(['proj-local', 'proj-remote']);

        final available = await offered();

        expect(available.map((p) => p.projectId), ['proj-remote']);
        expect(available.single.alreadyOnThisDevice, isFalse);
      },
    );

    test(
      'still offers a project whose local copy has been deleted, and says it '
      'is already here',
      () async {
        // **The lockout Michael reached on 2026-08-29.** He left a project on
        // his iPhone and deleted his copy; the departure had not reached the
        // server, so the fresh code was correctly refused — and the
        // project was excluded from here too, because a tombstoned row counted
        // as "already have it". There was no route back at all.
        await appDb.raw.insert(Tables.users, _user('user-1', now));
        await appDb.raw.insert(Tables.projects, {
          ..._project('proj-local', 'Elk', now),
          'deleted_at': DbCodec.encodeUtc(now),
        });
        await state.markProjectLinked('proj-local');
        serverLists(['proj-local']);

        final available = await offered();

        expect(available.map((p) => p.projectId), ['proj-local']);
        expect(
          available.single.alreadyOnThisDevice,
          isTrue,
          reason:
              'the screen has to be able to say that joining this one restores '
              'the copy already here rather than replacing it',
        );
      },
    );

    test(
      'still offers a project whose local copy is present but not syncing',
      () async {
        // Reachable without anybody deleting anything: a device that learned
        // it was off the project unlinks it (`SyncStateStore.clear` — never
        // sign-out, task 11.304), and if the person is readmitted the copy is
        // still here, sending nothing, receiving nothing, and saying nothing
        // on the sync surface.
        await appDb.raw.insert(Tables.users, _user('user-1', now));
        await appDb.raw.insert(
          Tables.projects,
          _project('proj-local', 'Elk', now),
        );
        serverLists(['proj-local']);

        final available = await offered();

        expect(available.map((p) => p.projectId), ['proj-local']);
        expect(available.single.alreadyOnThisDevice, isTrue);
      },
    );

    test(
      'two same-named projects with different ids both stay offered',
      () async {
        transport.serverProjects.addAll([
          const ProjectSummary(
            projectId: 'proj-a',
            projectName: 'Elk',
            ownerUserId: 'user-1',
            role: 'owner',
          ),
          const ProjectSummary(
            projectId: 'proj-b',
            projectName: 'Elk',
            ownerUserId: 'user-1',
            role: 'owner',
          ),
        ]);

        final available = await offered();

        expect(
          available.map((p) => p.projectId),
          containsAll(['proj-a', 'proj-b']),
        );
        expect(available, hasLength(2));
      },
    );
  });
}

Map<String, Object?> _user(String id, DateTime now) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'user_id': id,
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': 'sam@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': 'device-A',
  };
}

Map<String, Object?> _project(String id, String name, DateTime now) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'project_id': id,
    'project_name': name,
    'owner_user_id': 'user-1',
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': 'user-1',
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };
}

Map<String, Object?> _observation(
  String id,
  String projectId,
  String userId,
  DateTime now,
) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
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
    'notes': 'remote',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };
}
