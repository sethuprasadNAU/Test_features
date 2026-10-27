import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 7.6's headline regression test. Before Phase 7, `currentUser`
/// (`app_context_provider.dart`) minted every install a random placeholder
/// email (`field-user-` + a UUID + `@local.tritrack`), so `ProjectMerger`'s
/// already-built, already-tested
/// email-dedup logic (`project_merger_test.dart`'s "cross-device user dedup"
/// group) never actually fired between two real devices in the field — two
/// random UUIDs never collide. That existing coverage exercises the
/// algorithm correctly but starts from hand-picked matching emails; it can't
/// catch a regression in the *production path* that is supposed to produce
/// those matching emails in the first place.
///
/// This test exercises that whole path instead: two independent in-memory
/// databases, each standing in for a real device, each auto-creates its own
/// placeholder user via `currentUserProvider` and then completes identity
/// exactly the way `IdentitySetupScreen._save` does (read the existing user,
/// update it in place with a real name/email) — not a fixture shortcut. Both
/// people type in the same real address with harmless case/whitespace
/// differences, since that's the realistic way two independent installs
/// arrive at "the same" email. Only after that does export + merge run.
void main() {
  setUp(installFakeSharedPreferences);

  Future<({ProviderContainer container, String userId})> bootDeviceIdentity(
    String email,
  ) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        sessionStoreProvider.overrideWithValue(FakeSessionStore()),
      ],
    );

    // Mirrors currentUser's auto-create path: a fresh install with no real
    // identity yet.
    final placeholder = await container.read(currentUserProvider.future);
    expect(placeholder.hasPlaceholderIdentity, isTrue);

    // Mirrors IdentitySetupScreen._save exactly: read the existing user,
    // the device id, and the repository, then update the SAME row in place.
    final existing = await container.read(currentUserProvider.future);
    final deviceId = await container.read(deviceIdProvider.future);
    final repo = await container.read(userRepositoryProvider.future);
    final updated = existing.copyWith(
      firstName: 'Sam',
      lastName: 'Ranger',
      email: email,
    );
    await repo.update(
      updated,
      actor: MutationActor.user(existing.userId),
      deviceId: deviceId,
    );
    container.invalidate(currentUserProvider);

    final real = await container.read(currentUserProvider.future);
    expect(real.hasPlaceholderIdentity, isFalse);

    return (container: container, userId: real.userId);
  }

  test('two independent devices completing identity with the same real email '
      '(modulo case/whitespace) converge to one user on merge', () async {
    final deviceA = await bootDeviceIdentity('sam@example.com');
    addTearDown(deviceA.container.dispose);
    final deviceB = await bootDeviceIdentity(
      '  Sam@Example.com ',
    ); // same person, typed differently

    // Each device has its own project/tag/observation, attributed to its own
    // (device-local) user_id — the realistic one-device-per-person setup the
    // phase preamble describes.
    final dbA = await deviceA.container.read(appDatabaseProvider.future);
    final projectRepoA = await deviceA.container.read(
      projectRepositoryProvider.future,
    );
    await projectRepoA.insert(
      Project(
        projectId: 'project-a',
        projectName: 'Device A project',
        ownerUserId: deviceA.userId,
        creationDate: DateTime.utc(2026, 7, 1),
        sync: SyncMeta.initial(
          now: DateTime.utc(2026, 7, 1),
          modifiedBy: deviceA.userId,
        ),
      ),
    );

    final dbB = await deviceB.container.read(appDatabaseProvider.future);
    final projectRepoB = await deviceB.container.read(
      projectRepositoryProvider.future,
    );
    await projectRepoB.insert(
      Project(
        projectId: 'project-b',
        projectName: 'Device B project',
        ownerUserId: deviceB.userId,
        creationDate: DateTime.utc(2026, 7, 2),
        sync: SyncMeta.initial(
          now: DateTime.utc(2026, 7, 2),
          modifiedBy: deviceB.userId,
        ),
      ),
    );

    // Device B's backup arrives on device A (e.g. via the desktop merge tool)
    // and gets merged in.
    final backupB = await ProjectExporter.collect(
      dbB.raw,
      'project-b',
      now: DateTime.utc(2026, 7, 3),
    );
    // `confirmChanges: true` because the dedup this test is about is itself a
    // replacement: device B's `Users` row remaps onto device A's, and the two
    // carry different `created_at`/`origin_device_id` values. §4.19 rule 4
    // (task 10.73) holds that at the door on an unauthenticated archive; the
    // gate is exercised in `backup_restore_overwrite_test.dart`, and what this
    // test asserts is where the ids land once the merge is allowed to run.
    final report =
        await ProjectMerger(dbA.raw).merge(backupB, confirmChanges: true);

    expect(
      report.usersDeduped,
      1,
      reason:
          'the two placeholder-turned-real users must be recognized as the same person',
    );

    final users = await dbA.raw.query(Tables.users);
    expect(
      users,
      hasLength(1),
      reason: 'no duplicate "Field User" row should survive the merge',
    );
    expect(users.single['user_id'], deviceA.userId);
    expect(users.single['email'], 'sam@example.com');

    // Device B's project now attributes to device A's user_id, not its own.
    final mergedProjectB = (await dbA.raw.query(
      Tables.projects,
      where: 'project_id = ?',
      whereArgs: ['project-b'],
    )).single;
    expect(mergedProjectB['owner_user_id'], deviceA.userId);

    deviceB.container.dispose();
  });
}
