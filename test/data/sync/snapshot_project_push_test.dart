import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// **Task 11.237 — sync offers nothing for a project this device holds no
/// membership in, and offers everything the round after the membership
/// arrives.**
///
/// Asserted on the **push set** — what reached the transport — rather than on
/// a refusal count. The refused-row pile was the symptom; not generating it is
/// the fix, and a test that counted refusals would pass on a push that offered
/// everything to a server which happened to say yes.
///
/// The fixture is the archive-import shape: `proj-1` was created by the
/// colleague, the colleague's owner row is the only membership row, and this
/// device is signed in as somebody the rows do not name. Every row here is
/// unreceipted, so under the pre-11.237 rule all of it would go on the wire.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const holderId = 'user-holder';
  const colleagueId = 'user-colleague';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 9, 13, 9);
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
    userId: holderId,
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

  Map<String, Object?> membership(String id, String userId, {String? ended}) =>
      {
        'membership_id': id,
        'project_id': projectId,
        'user_id': userId,
        'join_date': stamp,
        'end_date': ended,
        'role': 'owner',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      };

  Map<String, Object?> observation(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': colleagueId,
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
    'last_modified_by': colleagueId,
    'origin_device_id': 'their-device',
  };

  /// The colleague's project as an archive import leaves it: their row, their
  /// membership, their bearing, nothing naming the holder.
  Future<void> seedColleaguesProject() async {
    await appDb.raw.insert(Tables.users, user(colleagueId));
    await appDb.raw.insert(Tables.users, user(holderId));
    await appDb.raw.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Their study',
      'owner_user_id': colleagueId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': colleagueId,
      'origin_device_id': 'their-device',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
    await appDb.raw.insert(
      Tables.projectMemberships,
      membership('membership-theirs', colleagueId),
    );
    await appDb.raw.insert(Tables.observations, observation('obs-theirs'));
    await state.markProjectLinked(projectId);
  }

  int rowsOffered() => [
    for (final push in transport.pushes)
      for (final rows in push.rows.values) rows.length,
  ].fold(0, (a, b) => a + b);

  test('a snapshot puts nothing on the wire, and counts nothing as waiting',
      () async {
    await seedColleaguesProject();

    expect(
      await SyncEngine.pendingRowCount(appDb.raw, projectId, holderId),
      0,
      reason: 'the status surface would say records were waiting',
    );

    await engine().run(projectId);

    expect(transport.pushes, isEmpty, reason: 'a push was made at all');
    expect(rowsOffered(), 0);
    expect(
      await SyncEngine.heldRowCount(appDb.raw, projectId),
      0,
      reason: 'nothing was offered, so nothing can have been refused',
    );
  });

  test(
    'the round after the membership arrives offers everything, with no '
    're-import and nothing cleared',
    () async {
      await seedColleaguesProject();
      await engine().run(projectId);
      expect(transport.pushes, isEmpty);

      // What a pull does the moment the owner approves the request: one open
      // row naming the holder. Nothing else on the device changes.
      await appDb.raw.insert(
        Tables.projectMemberships,
        membership('membership-holder', holderId),
      );

      expect(
        await SyncEngine.pendingRowCount(appDb.raw, projectId, holderId),
        greaterThan(0),
      );
      await engine().run(projectId);
      expect(transport.pushes, isNotEmpty, reason: 'still offering nothing');
      final offered = {
        for (final push in transport.pushes) ...push.rows.keys,
      };
      expect(offered, contains(Tables.observations));
    },
  );

  test(
    'a project the device holds no rows for is offered as before — the '
    'withholding is only for a standing the device can see',
    () async {
      // No Projects row, no memberships: a project this device knows only by
      // id. The push has nothing to offer either way, but the gate must not
      // be the reason — `offersNothingFor` answers false.
      expect(
        await SyncEngine.offersNothingFor(appDb.raw, 'proj-unknown', holderId),
        isFalse,
      );
    },
  );

  test('a member whose row is closed is withheld too', () async {
    await seedColleaguesProject();
    await appDb.raw.insert(
      Tables.projectMemberships,
      membership('membership-holder', holderId, ended: stamp),
    );
    expect(
      await SyncEngine.offersNothingFor(appDb.raw, projectId, holderId),
      isTrue,
    );
  });
}
