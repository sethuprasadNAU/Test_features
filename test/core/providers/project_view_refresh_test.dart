import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_view_refresh.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.153 — the one list of what "the project views" means.**
///
/// `refreshProjectViews` is the list `membership_provider.dart` used to hold
/// inline, moved out because the sync merger has to invalidate exactly the same
/// set. **Moving it is what showed the list was one provider short**, and the
/// first case below is that one: it fails against the list as it stood before
/// this task, on a change made locally by the owner sitting in front of the
/// screen — nothing to do with syncing.
void main() {
  const projectId = 'project-1';
  const owner = 'user-owner';
  const me = 'user-me';

  setUp(installFakeSharedPreferences);

  ProjectMembership membership(
    String id, {
    required String userId,
    required ProjectRole role,
  }) => ProjectMembership(
    membershipId: id,
    projectId: projectId,
    userId: userId,
    joinDate: DateTime.utc(2026, 8, 1),
    role: role,
    sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1), modifiedBy: owner),
  );

  Future<(ProviderContainer, Database)> seed(ProjectRole myRole) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: me, email: 'me@x.com'),
        ),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    for (final id in [owner, me]) {
      await db.insert(Tables.users, sampleUser(id: id, email: '$id@x.com').toColumns());
    }
    await db.insert(
      Tables.projects,
      sampleProject(id: projectId, ownerUserId: owner).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      membership('m-owner', userId: owner, role: ProjectRole.owner).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      membership('m-me', userId: me, role: myRole).toColumns(),
    );
    return (container, db);
  }

  test('a role change reaches the "Your role" card and the write gate', () async {
    final (container, db) = await seed(ProjectRole.viewer);
    addTearDown(container.dispose);
    // A screen is open on both, which is what holds the stale answer.
    container.listen(myProjectRoleProvider(projectId), (_, _) {});
    container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
    expect(
      await container.read(myProjectRoleProvider(projectId).future),
      ProjectRole.viewer,
    );

    await db.update(
      Tables.projectMemberships,
      {'role': ProjectRole.contributor.name},
      where: 'membership_id = ?',
      whereArgs: ['m-me'],
    );
    refreshProjectViewsIn(container, projectId: projectId);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      await container.read(myProjectRoleProvider(projectId).future),
      ProjectRole.contributor,
      reason:
          'myProjectRole is one line — it returns projectRoleForUser — and '
          'invalidating a provider does not re-run the providers it reads '
          '(measured, riverpod 3.3.2). If projectRoleForUserProvider is not on '
          'the refresh list, this rebuilds against the cached old role and '
          'reports it. What that looked like before task 11.153: an owner '
          'changing somebody\'s role watched the members list update and the '
          '"Your role" card beside it not, from the same tap.',
    );
    expect(
      await container.read(mayWriteProjectDataProvider(projectId).future),
      isTrue,
      reason: 'The write gate is built on the same stale answer.',
    );
  });

  test('an ownership change reaches the owner-only affordances', () async {
    final (container, db) = await seed(ProjectRole.contributor);
    addTearDown(container.dispose);
    container.listen(isProjectOwnerProvider(projectId), (_, _) {});
    container.listen(projectOwnersProvider(projectId), (_, _) {});
    container.listen(projectMembershipsProvider(projectId), (_, _) {});
    expect(await container.read(isProjectOwnerProvider(projectId).future), isFalse);

    await db.update(
      Tables.projectMemberships,
      {'role': ProjectRole.owner.name},
      where: 'membership_id = ?',
      whereArgs: ['m-me'],
    );
    refreshProjectViewsIn(container, projectId: projectId);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(await container.read(isProjectOwnerProvider(projectId).future), isTrue);
    expect(
      await container.read(projectOwnersProvider(projectId).future),
      containsAll(<String>[owner, me]),
    );
  });

  test('the whole-device form refreshes a named project too', () async {
    final (container, db) = await seed(ProjectRole.viewer);
    addTearDown(container.dispose);
    container.listen(myProjectRoleProvider(projectId), (_, _) {});
    expect(
      await container.read(myProjectRoleProvider(projectId).future),
      ProjectRole.viewer,
    );

    await db.update(
      Tables.projectMemberships,
      {'role': ProjectRole.contributor.name},
      where: 'membership_id = ?',
      whereArgs: ['m-me'],
    );
    // Null is what a sync pull passes: the merged page can carry rows for any
    // project on the device and nothing names which.
    refreshProjectViewsIn(container, projectId: null);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      await container.read(myProjectRoleProvider(projectId).future),
      ProjectRole.contributor,
      reason:
          'The family-wide form has to reach the same instances the named '
          'form does, or the sync path is refreshing a different set from the '
          'local one and the two will drift.',
    );
  });
}
