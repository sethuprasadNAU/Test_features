import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:uuid/uuid.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// Plain `test()`, not `testWidgets`: this exercises real sqflite_common_ffi
/// I/O (the in-memory test database), which runs its worker on a background
/// isolate. That isolate's message-passing never resolves inside
/// `testWidgets`' fake-async pump loop (a real, reproducible hang — see
/// project_setup_screen_test.dart), but works normally here since a plain
/// `test()` runs on the real Dart event loop.
void main() {
  setUp(installFakeSharedPreferences);

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      sessionStoreProvider.overrideWithValue(FakeSessionStore()),
    ],
  );

  test(
    'currentUserProvider auto-creates a single local user and persists the id',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final user = await container.read(currentUserProvider.future);
      expect(user.firstName, 'Field');
      // Task 7.4: no insert path should leave last_modified_by NULL, including
      // this auto-created row attributing itself.
      expect(user.sync.lastModifiedBy, user.userId);

      final activeId = await container.read(activeUserIdProvider.future);
      expect(activeId, user.userId);

      // A second read must not create a second user.
      container.invalidate(currentUserProvider);
      final again = await container.read(currentUserProvider.future);
      expect(again.userId, user.userId);
    },
  );

  test(
    'currentUserProvider recovers a tombstoned user row instead of silently minting a second identity',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      // First launch: a real identity is captured (not a placeholder), with
      // prior attribution (a project) riding on its user_id.
      final original = await container.read(currentUserProvider.future);
      final userRepo = await container.read(userRepositoryProvider.future);
      final updated = original.copyWith(
        firstName: 'Sam',
        lastName: 'Ranger',
        email: 'sam@example.com',
      );
      await userRepo.update(
        updated,
        actor: MutationActor.user(original.userId),
      );

      // Something (e.g. a merge) tombstones the row — `findById` now excludes
      // it by default, exactly the condition that used to trigger a silent
      // second-user creation.
      await userRepo.softDeleteById(
        original.userId,
        actor: MutationActor.user(original.userId),
      );
      expect(await userRepo.findById(original.userId), isNull);

      container.invalidate(currentUserProvider);
      final recovered = await container.read(currentUserProvider.future);

      expect(
        recovered.userId,
        original.userId,
        reason: 'must recover the existing identity, not mint a new one',
      );
      expect(
        recovered.email,
        'sam@example.com',
        reason: 'the recovered row keeps its real (non-placeholder) data',
      );
      expect(
        recovered.sync.deletedAt,
        isNull,
        reason: 'the tombstone must be cleared',
      );

      final allUsers = await userRepo.findById(original.userId);
      expect(allUsers, isNotNull);
    },
  );

  test(
    'currentUserProvider recovers via a valid stored session when the '
    'active id was hard-deleted, instead of minting a phantom identity',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      // Simulates the exact interruption window this test guards:
      // `ServerIdentityAdopter.adopt()` (task 10.6) hard-deletes the old local
      // `Users` row and folds its data onto the server's id in one transaction
      // — a real delete, not a tombstone, because the person still exists
      // under the new id (see that class's own doc comment). If
      // `completeSignIn` is then interrupted after the session is stored but
      // before `ActiveUserId` is repointed, `ActiveUserId` is left naming a row
      // that is gone for good, with no tombstone to recover.
      final original = await container.read(currentUserProvider.future);
      final userRepo = await container.read(userRepositoryProvider.future);
      final db = await container.read(appDatabaseProvider.future);

      const serverUserId = 'server-adopted-user-id';
      await userRepo.insert(
        User(
          userId: serverUserId,
          firstName: 'Sam',
          lastName: 'Ranger',
          email: 'sam@example.com',
          sync: SyncMeta.initial(now: DateTime.now(), modifiedBy: serverUserId),
        ),
      );
      // The hard delete `ServerIdentityAdopter` performs directly on the table —
      // there is no repository method for it by design (§ "no hard deletes").
      await db.raw.delete(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [original.userId],
      );

      final sessionStore = container.read(sessionStoreProvider);
      await sessionStore.write(
        StoredSession(
          token: 'session-token',
          userId: serverUserId,
          email: 'sam@example.com',
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      container.invalidate(currentUserProvider);
      final recovered = await container.read(currentUserProvider.future);

      expect(
        recovered.userId,
        serverUserId,
        reason: 'must recover the adopted identity via the stored session',
      );
      expect(
        await container.read(activeUserIdProvider.future),
        serverUserId,
        reason:
            'ActiveUserId must be repointed so this recovery is not repeated every launch',
      );
    },
  );

  test(
    'currentUserProvider mints a genuinely new placeholder user only when the id is truly unrecoverable',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      // Simulate a device whose prefs point at a user_id this (fresh) database
      // has never heard of — e.g. the DB file was replaced.
      await container.read(activeUserIdProvider.notifier).set('ghost-user-id');

      final user = await container.read(currentUserProvider.future);

      expect(user.userId, isNot('ghost-user-id'));
      // The fallback placeholder is detectable by the same identity gate that
      // prompts a fresh install — this is how the recreation is "surfaced"
      // rather than silently accepted, per the task's acceptance criteria.
      expect(user.hasPlaceholderIdentity, isTrue);
      expect(user.sync.lastModifiedBy, user.userId);
    },
  );

  test(
    'creating a project and setting it active makes currentProjectProvider resolve it',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      expect(await container.read(currentProjectProvider.future), isNull);

      final user = await container.read(currentUserProvider.future);
      final repo = await container.read(projectRepositoryProvider.future);
      final now = DateTime.now();
      final project = Project(
        projectId: const Uuid().v4(),
        projectName: 'Test Project',
        ownerUserId: user.userId,
        creationDate: now,
        sync: SyncMeta.initial(now: now, modifiedBy: user.userId),
      );
      await repo.insert(project);
      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
      container.invalidate(currentProjectProvider);

      final loaded = await container.read(currentProjectProvider.future);
      expect(loaded?.projectName, 'Test Project');
    },
  );

  group('Project_Memberships adoption (task 8.4)', () {
    test('currentProjectProvider backfills an owner membership for a project '
        'that predates this table\'s adoption', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final user = await container.read(currentUserProvider.future);
      final repo = await container.read(projectRepositoryProvider.future);
      final membershipRepo = await container.read(
        projectMembershipRepositoryProvider.future,
      );
      final now = DateTime.now();
      final project = Project(
        projectId: const Uuid().v4(),
        projectName: 'Legacy Project',
        ownerUserId: user.userId,
        creationDate: now,
        sync: SyncMeta.initial(now: now, modifiedBy: user.userId),
      );
      // Inserted directly via the repository — no membership row, exactly
      // the state of every project created before task 8.4.
      await repo.insert(project);
      expect(
        await membershipRepo.findForUser(project.projectId, user.userId),
        isNull,
      );

      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
      container.invalidate(currentProjectProvider);
      await container.read(currentProjectProvider.future);

      final membership = await membershipRepo.findForUser(
        project.projectId,
        user.userId,
      );
      expect(membership, isNotNull);
      expect(membership!.role, ProjectRole.owner);
    });

    test(
      'allProjectsProvider backfills owner memberships for every project in the list',
      () async {
        final container = makeContainer();
        addTearDown(container.dispose);

        final user = await container.read(currentUserProvider.future);
        final repo = await container.read(projectRepositoryProvider.future);
        final membershipRepo = await container.read(
          projectMembershipRepositoryProvider.future,
        );
        final now = DateTime.now();
        final projects = [
          Project(
            projectId: const Uuid().v4(),
            projectName: 'A',
            ownerUserId: user.userId,
            creationDate: now,
            sync: SyncMeta.initial(now: now, modifiedBy: user.userId),
          ),
          Project(
            projectId: const Uuid().v4(),
            projectName: 'B',
            ownerUserId: user.userId,
            creationDate: now,
            sync: SyncMeta.initial(now: now, modifiedBy: user.userId),
          ),
        ];
        for (final p in projects) {
          await repo.insert(p);
        }

        // `allProjectsProvider` is `@riverpod`-generated (autoDispose by
        // default): a bare `read` with no listener can be disposed mid-flight
        // once `_ensureOwnerMembership`'s internal `await` yields — the same
        // gotcha `project_setup_screen_test.dart` hit with
        // `projectTagLinksProvider`. `listen` keeps it alive for the read.
        container.listen(allProjectsProvider, (_, _) {});
        await container.read(allProjectsProvider.future);

        for (final p in projects) {
          final role = (await membershipRepo.findForUser(
            p.projectId,
            user.userId,
          ))?.role;
          expect(
            role,
            ProjectRole.owner,
            reason: 'backfilled for ${p.projectName}',
          );
        }
      },
    );

    test(
      'projectRoleForUserProvider resolves the backfilled owner role, and null for '
      'a non-member',
      () async {
        final container = makeContainer();
        addTearDown(container.dispose);

        final owner = await container.read(currentUserProvider.future);
        final repo = await container.read(projectRepositoryProvider.future);
        final userRepo = await container.read(userRepositoryProvider.future);
        final now = DateTime.now();
        final project = Project(
          projectId: const Uuid().v4(),
          projectName: 'Test Project',
          ownerUserId: owner.userId,
          creationDate: now,
          sync: SyncMeta.initial(now: now, modifiedBy: owner.userId),
        );
        await repo.insert(project);
        final stranger = User(
          userId: 'user-stranger',
          firstName: 'Stranger',
          lastName: 'User',
          email: 'stranger@example.com',
          sync: SyncMeta.initial(now: now),
        );
        await userRepo.insert(stranger);

        // Trigger the backfill by resolving the project once (same autoDispose
        // caveat as above — `listen` keeps it alive across the internal await).
        container.listen(projectByIdProvider(project.projectId), (_, _) {});
        await container.read(projectByIdProvider(project.projectId).future);

        expect(
          await container.read(
            projectRoleForUserProvider(project.projectId, owner.userId).future,
          ),
          ProjectRole.owner,
        );
        expect(
          await container.read(
            projectRoleForUserProvider(
              project.projectId,
              stranger.userId,
            ).future,
          ),
          isNull,
        );
      },
    );

    test('the backfill asks about the project\'s owners, not one user\'s row '
        '(task 11.1)', () async {
      // Task 8.4's condition was "does `ownerUserId` hold any open
      // membership". Once ownership can be transferred that question has
      // two wrong answers, and this is the one that undoes a transfer: the
      // creator ended their owner stint, holds no open membership, and under
      // the old condition the very next project load would silently hand
      // ownership back to them.
      final container = makeContainer();
      addTearDown(container.dispose);

      final creator = await container.read(currentUserProvider.future);
      final repo = await container.read(projectRepositoryProvider.future);
      final userRepo = await container.read(userRepositoryProvider.future);
      final membershipRepo = await container.read(
        projectMembershipRepositoryProvider.future,
      );
      final now = DateTime.now();
      final project = Project(
        projectId: const Uuid().v4(),
        projectName: 'Handed on',
        ownerUserId: creator.userId,
        creationDate: now,
        sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
      );
      await repo.insert(project);
      await userRepo.insert(
        User(
          userId: 'user-successor',
          firstName: 'Successor',
          lastName: 'User',
          email: 'successor@example.com',
          sync: SyncMeta.initial(now: now),
        ),
      );
      // Seeded as replication (task 11.2): a transferred-away stint plus a
      // successor's open ownership is state that reaches this device from
      // another one, not something either insert door can produce here — and
      // saying so is the point of the door having to be named.
      const arrived = MembershipInsertAuthority.replication(
        'seeded as though synced from the device that transferred ownership',
      );
      await membershipRepo.insert(
        ProjectMembership(
          membershipId: const Uuid().v4(),
          projectId: project.projectId,
          userId: creator.userId,
          joinDate: now,
          endDate: now,
          role: ProjectRole.owner,
          sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
        ),
        authority: arrived,
      );
      await membershipRepo.insert(
        ProjectMembership(
          membershipId: const Uuid().v4(),
          projectId: project.projectId,
          userId: 'user-successor',
          joinDate: now,
          role: ProjectRole.owner,
          sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
        ),
        authority: arrived,
      );

      container.listen(projectByIdProvider(project.projectId), (_, _) {});
      await container.read(projectByIdProvider(project.projectId).future);

      expect(
        await membershipRepo.ownersOf(project.projectId),
        {'user-successor'},
        reason: 'the backfill must not resurrect the creator\'s ownership',
      );
    });

    test(
      'a project whose only owner was demoted is repaired, not left ownerless '
      '(task 11.1)',
      () async {
        // The other wrong answer: the creator still holds an *open* membership,
        // so 8.4's condition short-circuited — and left a project with nobody
        // who could manage it. Asking about owners repairs it.
        final container = makeContainer();
        addTearDown(container.dispose);

        final creator = await container.read(currentUserProvider.future);
        final repo = await container.read(projectRepositoryProvider.future);
        final membershipRepo = await container.read(
          projectMembershipRepositoryProvider.future,
        );
        final now = DateTime.now();
        final project = Project(
          projectId: const Uuid().v4(),
          projectName: 'Ownerless',
          ownerUserId: creator.userId,
          creationDate: now,
          sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
        );
        await repo.insert(project);
        await membershipRepo.insert(
          ProjectMembership(
            membershipId: const Uuid().v4(),
            projectId: project.projectId,
            userId: creator.userId,
            joinDate: now,
            role: ProjectRole.contributor,
            sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
          ),
          authority: const MembershipInsertAuthority.replication(
            'seeded as though synced from the device that demoted the creator',
          ),
        );

        container.listen(projectByIdProvider(project.projectId), (_, _) {});
        await container.read(projectByIdProvider(project.projectId).future);

        expect(await membershipRepo.ownersOf(project.projectId), {
          creator.userId,
        });
      },
    );

    test(
      'does not resurrect a creator whose own membership row was closed '
      '(task 11.280)',
      () async {
        // "No open row" used to mean one thing to this backfill: never had a
        // membership row at all. It is also what a creator's device sees the
        // moment it learns — from a sync round's `200` or `403` disclosure —
        // that their own stint was closed: by leaving, or by another owner
        // removing them. Reading the project again (which every screen
        // navigation does, via currentProjectProvider/projectByIdProvider)
        // must not silently put them back on a project they were just told
        // they left.
        final container = makeContainer();
        addTearDown(container.dispose);

        final creator = await container.read(currentUserProvider.future);
        final repo = await container.read(projectRepositoryProvider.future);
        final membershipRepo = await container.read(
          projectMembershipRepositoryProvider.future,
        );
        final now = DateTime.now();
        final project = Project(
          projectId: const Uuid().v4(),
          projectName: 'Departed',
          ownerUserId: creator.userId,
          creationDate: now,
          sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
        );
        await repo.insert(project);
        // The row a real disclosure pull would have merged in: the creator's
        // own membership, closed.
        await membershipRepo.insert(
          ProjectMembership(
            membershipId: const Uuid().v4(),
            projectId: project.projectId,
            userId: creator.userId,
            joinDate: now,
            endDate: now.add(const Duration(hours: 1)),
            role: ProjectRole.owner,
            sync: SyncMeta.initial(now: now, modifiedBy: creator.userId),
          ),
          authority: const MembershipInsertAuthority.replication(
            'seeded as though synced from the closed-membership disclosure',
          ),
        );

        container.listen(projectByIdProvider(project.projectId), (_, _) {});
        await container.read(projectByIdProvider(project.projectId).future);

        expect(
          await membershipRepo.findForUser(project.projectId, creator.userId),
          isNull,
          reason:
              'the creator was told they left; this repair must not open a '
              'fresh membership row behind their back',
        );
      },
    );
  });

  test(
    'projectActiveTagsProvider returns this project\'s active tags and '
    'nothing else',
    () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      final tagRepo = await container.read(tagRepositoryProvider.future);
      final projectRepo = await container.read(
        projectRepositoryProvider.future,
      );
      final userRepo = await container.read(userRepositoryProvider.future);
      final now = DateTime.now();

      final owner = User(
        userId: 'user-1',
        firstName: 'Owner',
        lastName: 'User',
        email: 'owner@example.com',
        sync: SyncMeta.initial(now: now),
      );
      await userRepo.insert(owner);
      const projectId = 'proj-1';
      await projectRepo.insert(
        Project(
          projectId: projectId,
          projectName: 'Project',
          ownerUserId: owner.userId,
          creationDate: now,
          sync: SyncMeta.initial(now: now),
        ),
      );

      final activeTag = Tag(
        tagId: 'tag-active',
        projectId: projectId,
        lineageId: 'tag-active',
        frequencyMhz: 150.1,
        tagName: 'Active Tag',
        status: TagStatus.active,
        colorHex: TagColorPalette.colors[0],
        sync: SyncMeta.initial(now: now),
      );
      // **"Removed from this project" is a tombstone since task 11.219**,
      // where it used to be `Project_Tags.status = inactive`. The row stays
      // so every bearing naming it still resolves; it is out of the pickers,
      // which is what this provider answers.
      final removedTag = Tag(
        tagId: 'tag-removed',
        projectId: projectId,
        lineageId: 'tag-removed',
        frequencyMhz: 150.2,
        tagName: 'Removed Tag',
        status: TagStatus.active,
        colorHex: TagColorPalette.colors[1],
        sync: SyncMeta.initial(now: now),
      );
      await tagRepo.insert(activeTag);
      await tagRepo.insert(removedTag);
      await tagRepo.removeFromProject(
        removedTag.tagId,
        projectId: projectId,
        actor: const MutationActor.replication('test seed'),
      );

      final tags = await container.read(
        projectActiveTagsProvider(projectId).future,
      );
      expect(tags.map((t) => t.tagId), [activeTag.tagId]);
    },
  );
}
