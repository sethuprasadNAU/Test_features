import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/sync/project_joiner.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// **Leave, delete, get back on — and the project comes back invisible.**
///
/// Confirmed by Michael on real hardware, 2026-08-29, after task 11.54 made a
/// departed member's copy deletable. Task 11.54 wrote this down as an
/// *unverified* risk and could not test it, because reaching it needs a live
/// server and a real return to the project. He reached it and it happens.
///
/// ## The mechanism
///
/// Deleting the project writes a tombstone on the local `Projects` row and —
/// like every soft delete in this app — bumps its `revision`. `MergeResolver`
/// compares **revision before timestamp**, so that local row now beats the
/// server's copy of the same project outright. Rejoining pulls the server's
/// row, the merge correctly declines to overwrite a newer local one, and the
/// tombstone survives. The project is in the database, fully populated, and
/// filtered out of every list that reads it.
///
/// **It is silent and it looks like getting back on failed.** Nothing errors,
/// the sync reports success, and the project simply is not there.
///
/// ## Why the fix is in the join and not in the delete
///
/// The clock bump is not wrong in itself — it is what every soft delete does,
/// and `Projects` is never offered to the server by any device
/// (`offer_rules.dart`), so it has no outbound consequence at all. What is
/// wrong is that a *local visibility choice* outranks the server on the way
/// back in. Joining a project is this device's explicit, later statement that
/// it wants the project here, so that is where the earlier statement is
/// withdrawn.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 8, 1, 12);
  final stamp = DbCodec.encodeUtc(now);

  Map<String, Object?> projectRow({int revision = 0}) => {
    'project_id': projectId,
    'project_name': 'Elk',
    'owner_user_id': 'user-owner',
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': revision,
    'last_modified_by': 'user-owner',
    'origin_device_id': 'device-owner',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    for (final id in [userId, 'user-owner']) {
      await appDb.raw.insert(Tables.users, {
        'user_id': id,
        'first_name': 'Sam',
        'last_name': 'Ranger',
        'email': '$id@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': id,
        'origin_device_id': deviceId,
      });
    }
    // The project as it stands on this device after a previous stint, and as
    // it stands on the server.
    await appDb.raw.insert(Tables.projects, projectRow());
    transport.seedServerRow(Tables.projects, projectRow());
  });

  tearDown(() => appDb.close());

  ProjectJoiner joiner() => ProjectJoiner(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  /// Leaves the project and removes this device's copy — the two steps
  /// task 11.54 built, in the order Michael ran them.
  Future<void> leaveAndDelete() async {
    await state.clear(projectId);
    await appDb.raw.insert(Tables.projectMemberships, {
      'membership_id': 'mem-1',
      'project_id': projectId,
      'user_id': userId,
      'join_date': stamp,
      'end_date': stamp,
      'role': 'contributor',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
    await ProjectRepository(appDb.raw).softDeleteById(
      projectId,
      actor: const MutationActor.user(userId),
      deviceId: deviceId,
      exemption: const MutationExemption.departedMember(projectId),
    );
  }

  Future<bool> isVisible() async {
    final project = await ProjectRepository(appDb.raw).findById(projectId);
    return project != null;
  }

  test('rejoining a project you deleted brings it back visible', () async {
    await leaveAndDelete();
    expect(await isVisible(), isFalse, reason: 'the delete has to have worked');

    // The owner approves, and `joinApprovedProject` calls this.
    await joiner().join(projectId);

    expect(
      await isVisible(),
      isTrue,
      reason: 'the project was granted again and pulled again; a tombstone '
          'this device wrote before the grant must not outlive it',
    );
  });

  test(
    'and the tombstone is why — the pulled row cannot clear it on its own',
    () async {
      // Names the mechanism rather than only the symptom, so a later change to
      // the merge rule that happens to fix this does not leave this file
      // asserting something it no longer explains. `MergeResolver.compare`
      // reads `revision` before `updated_at`.
      await leaveAndDelete();
      final local = (await appDb.raw.query(
        Tables.projects,
        where: 'project_id = ?',
        whereArgs: [projectId],
      )).single;
      expect(local['deleted_at'], isNotNull);
      expect(
        MergeResolver.incomingWins(projectRow(), local),
        isFalse,
        reason: "the server's copy loses to the local tombstone, so nothing "
            'the pull delivers can clear it',
      );
    },
  );

  test('a project that was never deleted is joined exactly as before', () async {
    // The repair must be a no-op on the ordinary path, which is every join
    // this app has ever done.
    final before = (await appDb.raw.query(
      Tables.projects,
      where: 'project_id = ?',
      whereArgs: [projectId],
    )).single;

    await joiner().join(projectId);

    final after = (await appDb.raw.query(
      Tables.projects,
      where: 'project_id = ?',
      whereArgs: [projectId],
    )).single;
    expect(after['revision'], before['revision']);
    expect(after['updated_at'], before['updated_at']);
    expect(await isVisible(), isTrue);
  });
}
