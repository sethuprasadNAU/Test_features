import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/arrival_refresh.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/data_arrival.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../data/sync/backup_builders.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.153 — what arrives by syncing must be visible without a restart.**
///
/// Task 11.151 fixed the eight routes where *this* device is the one that
/// acted. This is the other half: an owner promotes somebody on their phone,
/// this device pulls the change, and — before this task — the Members screen
/// went on showing the old role and the Record screen went on refusing the
/// bearing, until the app was closed and reopened, with nothing on screen
/// saying so.
///
/// Every inbound route lands in [ProjectMerger], which announces through
/// [DataArrival]; the tests below drive that real path rather than poking the
/// signal, so they fail if the wire is cut anywhere along it.
void main() {
  const projectId = 'project-1';
  const owner = 'user-owner';
  const me = 'user-me';

  setUp(installFakeSharedPreferences);

  ProjectMembership membership(
    String id, {
    required String userId,
    required ProjectRole role,
    int revision = 0,
  }) => ProjectMembership(
    membershipId: id,
    projectId: projectId,
    userId: userId,
    joinDate: DateTime.utc(2026, 8, 1),
    role: role,
    sync: SyncMeta(
      createdAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 1).add(Duration(minutes: revision)),
      revision: revision,
      lastModifiedBy: owner,
      originDeviceId: 'device-owner',
    ),
  );

  /// A container holding a real database with [projectId] on it, [me] in the
  /// role given, and the two server-only providers stubbed — the members
  /// screen's join code and pending queue need a server and this is the
  /// offline half.
  Future<ProviderContainer> seed({required ProjectRole myRole}) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: me, email: 'me@x.com'),
        ),
        projectJoinSettingsProvider(projectId).overrideWith(
          (ref) async => const JoinSettings(
            projectId: projectId,
            joiningEnabled: false,
            teamSizeLimit: 50,
            memberCount: 2,
            pendingCount: 0,
          ),
        ),
        projectJoinRequestsProvider(projectId).overrideWith((ref) async => []),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(
      Tables.users,
      sampleUser(id: owner, email: 'owner@x.com').toColumns(),
    );
    await db.insert(Tables.users, sampleUser(id: me, email: 'me@x.com').toColumns());
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
    // The refresher is `keepAlive` and started by `app.dart` in the running
    // app; a container-level test has to start it the same way.
    container.read(arrivalRefreshProvider);
    // Held open and pre-resolved for the reason `project_members_screen_test`
    // gives: these are database-backed and the screen spins until they answer,
    // which `pumpAndSettle` would never settle.
    container.listen(isProjectOwnerProvider(projectId), (_, _) {});
    container.listen(projectMembershipsProvider(projectId), (_, _) {});
    container.listen(myProjectRoleProvider(projectId), (_, _) {});
    await container.read(isProjectOwnerProvider(projectId).future);
    await container.read(projectMembershipsProvider(projectId).future);
    await container.read(myProjectRoleProvider(projectId).future);
    return container;
  }

  /// The pull: one page carrying [me]'s membership row at a higher revision,
  /// promoting them. `authenticatedServer` is what `SyncEngine` passes.
  Future<void> pullPromotion(ProviderContainer container) async {
    final db = (await container.read(appDatabaseProvider.future)).raw;
    final report = await ProjectMerger(db).merge(
      makeBackup({
        Tables.projectMemberships: [
          membership(
            'm-me',
            userId: me,
            role: ProjectRole.contributor,
            revision: 3,
          ).toColumns(),
        ],
      }),
      origin: MergeOrigin.authenticatedServer,
    );
    expect(
      report.statsFor(Tables.projectMemberships).updated,
      1,
      reason:
          'The pull did not actually change the role in the database, so '
          'everything below would be testing nothing.',
    );
  }

  group('a membership change delivered by a sync pull', () {
    testWidgets('changes what the open Members screen says, with no restart', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(myRole: ProjectRole.viewer);
      });
      addTearDown(container.dispose);

      // **Inside the real tab shell at 6.1-inch phone geometry**, not bare:
      // this case turns on a word being *visible* on the screen, which is
      // exactly the category `app_shell_harness_default_test.dart` says must
      // not be given height the app never has.
      await pumpInAppShell(
        tester,
        container: container,
        screen: const ProjectMembersScreen(projectId: projectId),
        tabIndex: 4, // Map / Record / Compass / Position / **More**
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Viewer'),
        findsWidgets,
        reason: 'The screen was not showing the old role to begin with.',
      );

      await tester.runAsync(() async {
        await pullPromotion(container);
        // The rebuilds the pull sets off read the database, which answers on
        // real time — so they have to be let finish inside `runAsync` too,
        // before the fake clock takes back over to paint the frame.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Contributor'),
        findsWidgets,
        reason:
            'An owner promoted this person on another device and the pull '
            'wrote the new role to this device. The screen they are looking '
            'at still says Viewer, and nothing on it says to close the app.',
      );
    });
  });

  group('a tag link delivered by a sync pull', () {
    test('appears in the project without a restart', () async {
      final container = await seed(myRole: ProjectRole.contributor);
      addTearDown(container.dispose);
      final db = (await container.read(appDatabaseProvider.future)).raw;
      // A tag in *another* project this device holds, so the list starts
      // empty for the project under test. Before task 11.219 a tag with no
      // link was the way to say that; a tag belongs to a project now, so
      // "not this project's" is where it lives.
      await db.insert(
        Tables.projects,
        sampleProject(id: 'other-project', ownerUserId: owner).toColumns(),
      );
      await db.insert(
        Tables.tags,
        sampleTag(id: 'tag-1', projectId: 'other-project').toColumns(),
      );
      container.listen(projectActiveTagsProvider(projectId), (_, _) {});
      expect(await container.read(projectActiveTagsProvider(projectId).future),
          isEmpty);

      // A teammate published the collar; it arrives as an ordinary row on
      // the next pull. This is the route task 11.151 measured and
      // deliberately left open. **One row since task 11.219** — a tag
      // belongs to the project rather than being linked into it.
      await ProjectMerger(db).merge(
        makeBackup({
          Tables.tags: [
            sampleTag(id: 'tag-arrived', projectId: projectId).toColumns(),
          ],
        }),
        origin: MergeOrigin.authenticatedServer,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        await container.read(projectActiveTagsProvider(projectId).future),
        hasLength(1),
        reason:
            'A teammate linked a collar to this project and it reached this '
            'device. The tag wheel on the Record screen still does not offer '
            'it, so the bearing cannot be recorded against the animal it is '
            'about until the app is restarted.',
      );
    });
  });

  group('the deadlock the obvious fix causes', () {
    /// **The first run, which is where this is reachable in the shipped app.**
    ///
    /// `currentUserProvider` mints this device's first user and announces from
    /// *inside its own build*, so anything awaiting it is mid-build at that
    /// instant. Invalidating a provider mid-build orphans the `Future` an
    /// awaiter holds — measured on riverpod 3.3.2 — and task 11.151 watched
    /// that same shape turn an eleven-second suite into a run that never
    /// finishes.
    ///
    /// The shape here is the app's own: a screen watching the gate
    /// (`observation_logging_screen.dart` line 186) *and* a bare
    /// `ref.read(…future)` on it a few hundred lines later (line 1705).
    test('a first run resolves the write gate instead of hanging on it',
        () async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      container.read(arrivalRefreshProvider);
      container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
      container.listen(myProjectRoleProvider(projectId), (_, _) {});

      final bool mayWrite;
      try {
        mayWrite = await container
            .read(mayWriteProjectDataProvider(projectId).future)
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        fail(
          'The write gate never answered on a first run. currentUserProvider '
          'announces while it is auto-creating this device\'s first user, and '
          'something invalidated this provider while it was still waiting on '
          'that, which orphans its Future for the life of the process. In the '
          'app that is a Record screen that never stops spinning on the first '
          'launch after install.',
        );
      }
      expect(mayWrite, isTrue, reason: 'No membership row: defers to server.');
      expect(
        (await container.read(currentUserProvider.future)).userId,
        isNotEmpty,
        reason:
            'The first-run user was never actually created, so the '
            'announcement this case is about never happened and the test '
            'proved nothing.',
      );
    });

    /// **The case that makes the guard load-bearing rather than decorative.**
    ///
    /// `currentProjectProvider` is `keepAlive`, so nothing disposes it and
    /// nothing complains: invalidated while it is building, the `Future` an
    /// awaiter holds is simply never completed, with no error anywhere.
    /// Measured — this test times out at four seconds against a refresher with
    /// the guard removed, and returns immediately with it.
    ///
    /// The window is a real one: a sync round landing in the moment a screen
    /// is resolving the active project.
    test('a pull landing while the active project is still resolving does not '
        'strand it', () async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith(
            (ref) async => sampleUser(id: me, email: 'me@x.com'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(Tables.users, sampleUser(id: me, email: 'me@x.com').toColumns());
      container.read(arrivalRefreshProvider);

      final resolving = container.read(currentProjectProvider.future);
      DataArrival.announce();

      try {
        await resolving.timeout(const Duration(seconds: 4));
      } on TimeoutException {
        fail(
          'The active project never resolved. An arrival was announced while '
          'currentProjectProvider was still building and something '
          'invalidated it mid-build, which orphans its Future — and because '
          'that provider is keepAlive, nothing disposes it, nothing throws, '
          'and nothing ever completes it. On a phone that is a screen that '
          'never finishes opening, with no error to report.',
        );
      }
    });

    /// The guard skips a refresh that lands while the user is still resolving.
    /// **Skipping must not mean dropping** — a sync round racing app start
    /// would otherwise lose exactly the refresh this task delivers.
    test('a refresh deferred by the guard is re-run, not dropped', () async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      container.read(arrivalRefreshProvider);
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(
        Tables.users,
        sampleUser(id: owner, email: 'owner@x.com').toColumns(),
      );
      await db.insert(
        Tables.projects,
        sampleProject(id: projectId, ownerUserId: owner).toColumns(),
      );
      container.listen(allProjectsProvider, (_, _) {});
      expect(await container.read(allProjectsProvider.future), hasLength(1));

      // A second project lands *while* the first-run user is still being
      // minted, and announces from there.
      await db.insert(
        Tables.projects,
        sampleProject(id: 'project-2', ownerUserId: owner).toColumns(),
      );
      final userSettling = container.read(currentUserProvider.future);
      DataArrival.announce();
      await userSettling;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        await container.read(allProjectsProvider.future),
        hasLength(2),
        reason:
            'The refresh was deferred because the signed-in user was still '
            'resolving, and then never re-run. A sync round that lands during '
            'app start would leave every screen stale with nothing to '
            'correct it.',
      );
    });
  });

  group('the gating providers', () {
    test('a pulled promotion reaches mayWriteProjectData', () async {
      final container = await seed(myRole: ProjectRole.viewer);
      addTearDown(container.dispose);
      // A screen is watching, which is what keeps the answer cached.
      container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
      container.listen(myProjectRoleProvider(projectId), (_, _) {});
      expect(
        await container.read(mayWriteProjectDataProvider(projectId).future),
        isFalse,
      );

      await pullPromotion(container);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        await container.read(mayWriteProjectDataProvider(projectId).future),
        isTrue,
        reason:
            'The Record screen still refuses this person a bearing after an '
            'owner promoted them and the change reached this device.',
      );
      expect(
        await container.read(myProjectRoleProvider(projectId).future),
        ProjectRole.contributor,
      );
    });

    test('a pulled promotion reaches the members list and the owner set',
        () async {
      final container = await seed(myRole: ProjectRole.viewer);
      addTearDown(container.dispose);
      container.listen(projectMembershipsProvider(projectId), (_, _) {});
      container.listen(projectOwnersProvider(projectId), (_, _) {});
      final before = await container.read(
        projectMembershipsProvider(projectId).future,
      );
      expect(
        before.firstWhere((m) => m.membership.userId == me).membership.role,
        ProjectRole.viewer,
      );

      await pullPromotion(container);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final after = await container.read(
        projectMembershipsProvider(projectId).future,
      );
      expect(
        after.firstWhere((m) => m.membership.userId == me).membership.role,
        ProjectRole.contributor,
      );
    });
  });
}
