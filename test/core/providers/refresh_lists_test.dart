import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/arrival_refresh.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/individuals_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_view_refresh.dart';
import 'package:tritrack/core/providers/tag_view_refresh.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart' show kTagLibraryTable;
import 'package:tritrack/features/more/screens/tag_database_screen.dart'
    show tagLibraryProvider;
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.154 — the guard on the two hand-kept refresh lists.**
///
/// Task 11.153 found that `refreshProjectViews` invalidated `myProjectRole` and
/// not `projectRoleForUser`, **the single line `myProjectRole` consists of**.
/// Invalidating a provider does not re-run the providers it reads (measured,
/// riverpod 3.3.2), so the list was complete-looking and wrong, and an owner
/// changing somebody's role watched the members list update and the "Your role"
/// card beside it not, from the same tap. Live since task 11.12, found by
/// accident.
///
/// **Three things are asserted here, and none of them is a transcription of the
/// lists.** `visitProjectViewProviders` and `visitTagViewProviders` hand this
/// file the lists themselves; a copy of a list is the defect class this project
/// has hit four times (tasks 11.14, 11.21, 11.23, 11.45).
///
/// 1. **The lists are closed under "reads".** Every provider created while a
///    listed provider builds is derived at run time from a `ProviderObserver`,
///    and each one must be on a list too, or on [_notRefreshed] — the inverted
///    declaration, which says what is deliberately left stale and why, so an
///    unrecognised case fails rather than passing silently. Removing
///    `projectRoleForUserProvider` from the list turns this red, which is
///    exactly 11.153's finding caught by machinery instead of by luck.
/// 2. **Every entry earns its place.** [_cases] gives each entry a change to
///    the database that its value must reflect after a refresh, and the case
///    set is checked against the enumerated list in both directions — so
///    removing an entry, or adding one with nothing behind it, fails.
/// 3. **Every family on a list is `autoDispose`.** `ArrivalRefresh`'s
///    deadlock guard cannot see a family's live instances (riverpod 3.3.2
///    exports no way to enumerate them), and what makes that survivable is
///    that an `autoDispose` provider invalidated mid-build *throws* rather
///    than hanging forever. That was true by accident until this assertion.
///
/// **What this still does not cover, stated rather than assumed away.** The
/// derivation starts from the lists, so a provider that ought to be refreshed
/// and is read by nothing on a list is invisible to it; the app-wide sweep for
/// those is `test/documentation/invalidation_sites_test.dart`, which is a
/// declaration rather than a derivation.
void main() {
  const projectId = 'project-1';
  const owner = 'user-owner';
  const me = 'user-me';
  const third = 'user-third';

  setUp(() async {
    installFakeSharedPreferences();
    final prefs = SharedPreferencesAsync();
    await prefs.setString('active_user_id', me);
    await prefs.setString('active_project_id', projectId);
  });

  /// **What is deliberately not refreshed, and why.**
  ///
  /// This is the inverted half of the closure check: anything a listed provider
  /// reads that is not itself refreshed has to be named here with a reason, so
  /// a *new* unrefreshed read fails the run instead of joining the list of
  /// things nobody looked at. Keyed by the provider's own `name`, which
  /// riverpod's code generator sets — not by a string anybody typed twice.
  const notRefreshed = <String, String>{
    'appDatabaseProvider':
        'The database handle itself. It holds no answer that can go stale — '
        'every listed provider re-queries through it on rebuild — and '
        'invalidating it would close and reopen the database under whatever '
        'else is using it.',
    'activeUserIdProvider':
        'Which user this device is signed in as, held by a notifier that '
        'updates its own state on every set(). Nothing that arrives by syncing '
        'can change it, so a refresh has nothing to correct.',
    'activeProjectIdProvider':
        'Which project is open, same shape as activeUserIdProvider: chosen on '
        'this device, changed only through its own notifier.',
    'currentUserProvider':
        'Who is signed in. Deliberately excluded: it is keepAlive, it mints a '
        'device\'s first user as a side effect of being read, and a membership '
        'change or a tag edit cannot change who you are. The one event that '
        'does change it — signing in and adopting a server identity — '
        'invalidates it in auth_provider.dart, and ServerIdentityAdopter '
        'announces through DataArrival for the rows it rewrote, which is what '
        'refreshes everything else.',
    'deviceIdProvider':
        'This device\'s installation id. Written once and never again.',
    'userRepositoryProvider':
        'A repository, not an answer. Repositories are stateless query objects '
        'over the database handle; the rows they return are re-read on every '
        'call, so a listed provider rebuilding gets fresh rows without the '
        'repository being touched.',
    'projectRepositoryProvider': 'A repository — see userRepositoryProvider.',
    'projectMembershipRepositoryProvider':
        'A repository — see userRepositoryProvider.',
    'tagRepositoryProvider': 'A repository — see userRepositoryProvider.',
    'tagLibraryRepositoryProvider':
        'A repository — see userRepositoryProvider.',
    'individualRepositoryProvider':
        'A repository — see userRepositoryProvider.',
    'deploymentRepositoryProvider':
        'A repository — see userRepositoryProvider.',
    'projectTagRepositoryProvider': 'A repository — see userRepositoryProvider.',
    'sessionStoreProvider':
        'The stored-session reader, a service over secure storage rather than '
        'a cached answer.',
  };

  Future<AppDatabase> seed() async {
    final app = await AppDatabase.openInMemory();
    final db = app.raw;
    for (final id in [owner, me, third]) {
      await db.insert(
        Tables.users,
        sampleUser(id: id, email: '$id@example.com').toColumns(),
      );
    }
    await db.insert(
      Tables.projects,
      sampleProject(id: projectId, ownerUserId: owner).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'm-owner',
        projectId: projectId,
        userId: owner,
      ).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'm-me',
        projectId: projectId,
        userId: me,
        role: ProjectRole.viewer,
      ).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-1', projectId: projectId).toColumns(),
    );
    return app;
  }

  // Changes to the database that a refresh has to make visible. Each is a
  // thing somebody actually does: an owner promotes a member, somebody leaves,
  // a project is renamed, a collar is added or renamed.
  Future<void> promoteMe(Database db) => db.update(
    Tables.projectMemberships,
    {'role': ProjectRole.owner.name},
    where: 'membership_id = ?',
    whereArgs: ['m-me'],
  );
  Future<void> makeMeContributor(Database db) => db.update(
    Tables.projectMemberships,
    {'role': ProjectRole.contributor.name},
    where: 'membership_id = ?',
    whereArgs: ['m-me'],
  );
  Future<void> endMyStint(Database db) => db.update(
    Tables.projectMemberships,
    {'end_date': DateTime.utc(2026, 9, 1).toIso8601String()},
    where: 'membership_id = ?',
    whereArgs: ['m-me'],
  );
  Future<void> renameProject(Database db) => db.update(
    Tables.projects,
    {'project_name': 'Renamed Range'},
    where: 'project_id = ?',
    whereArgs: [projectId],
  );
  Future<void> addProject(Database db) async {
    await db.insert(
      Tables.projects,
      sampleProject(id: 'project-2', ownerUserId: me).toColumns(),
    );
  }

  /// A collar added to the person's own library. **Device-local** — no
  /// project, and nothing a sync round can change (task 11.219).
  Future<void> addLibraryTag(Database db) async {
    await db.insert(
      kTagLibraryTable,
      sampleTagLibraryEntry(id: 'library-tag-2', lineageId: 'tag-2')
          .toColumns(),
    );
  }

  /// A collar added to the project. One row now, where it used to be a tag
  /// plus a link.
  Future<void> addProjectTag(Database db) async {
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-2', projectId: projectId).toColumns(),
    );
  }

  Future<void> addIndividual(Database db) async {
    await db.insert(
      Tables.individuals,
      sampleIndividual(id: 'individual-2', projectId: projectId).toColumns(),
    );
  }

  /// Task 11.243. The animal and the collar both have to exist first — a
  /// deployment's foreign keys name them — so this adds all three, which is
  /// the shape the real act has.
  Future<void> addDeployment(Database db) async {
    await db.insert(
      Tables.individuals,
      sampleIndividual(id: 'individual-3', projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-3', projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        id: 'deployment-2',
        projectId: projectId,
        tagId: 'tag-3',
        individualId: 'individual-3',
      ).toColumns(),
    );
  }

  final cases = <String, _RefreshCase>{
    'allProjectsProvider': _RefreshCase(
      provider: allProjectsProvider,
      change: addProject,
      read: (c) async => (await c.read(allProjectsProvider.future))
          .map((p) => p.projectId)
          .join(','),
    ),
    'ownedProjectIdsProvider': _RefreshCase(
      provider: ownedProjectIdsProvider,
      change: promoteMe,
      read: (c) async =>
          (await c.read(ownedProjectIdsProvider.future)).join(','),
    ),
    'departedProjectIdsProvider': _RefreshCase(
      provider: departedProjectIdsProvider,
      change: endMyStint,
      read: (c) async =>
          (await c.read(departedProjectIdsProvider.future)).join(','),
    ),
    'currentProjectProvider': _RefreshCase(
      provider: currentProjectProvider,
      change: renameProject,
      read: (c) async =>
          (await c.read(currentProjectProvider.future))?.projectName ?? '',
    ),
    'projectRoleForUserProvider': _RefreshCase(
      provider: projectRoleForUserProvider(projectId, me),
      change: makeMeContributor,
      read: (c) async =>
          '${await c.read(projectRoleForUserProvider(projectId, me).future)}',
    ),
    // Task 11.237: the standing is what the role is now read out of, and the
    // snapshot set is what turns a read-only copy live the moment a
    // membership row arrives — ending the stint is the change that moves it.
    'projectStandingForUserProvider': _RefreshCase(
      provider: projectStandingForUserProvider(projectId, me),
      change: makeMeContributor,
      read: (c) async =>
          '${await c.read(projectStandingForUserProvider(projectId, me).future)}',
    ),
    'snapshotProjectIdsProvider': _RefreshCase(
      provider: snapshotProjectIdsProvider,
      change: endMyStint,
      read: (c) async =>
          (await c.read(snapshotProjectIdsProvider.future)).join(','),
    ),
    'myProjectStandingProvider': _RefreshCase(
      provider: myProjectStandingProvider(projectId),
      change: makeMeContributor,
      read: (c) async =>
          '${await c.read(myProjectStandingProvider(projectId).future)}',
    ),
    'projectMembershipsProvider': _RefreshCase(
      provider: projectMembershipsProvider(projectId),
      change: (db) async => db.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'm-third',
          projectId: projectId,
          userId: third,
          role: ProjectRole.contributor,
        ).toColumns(),
      ),
      read: (c) async =>
          (await c.read(projectMembershipsProvider(projectId).future))
              .map((m) => m.membership.membershipId)
              .join(','),
    ),
    'projectOwnersProvider': _RefreshCase(
      provider: projectOwnersProvider(projectId),
      change: promoteMe,
      read: (c) async =>
          (await c.read(projectOwnersProvider(projectId).future)).join(','),
    ),
    'isProjectOwnerProvider': _RefreshCase(
      provider: isProjectOwnerProvider(projectId),
      change: promoteMe,
      read: (c) async =>
          '${await c.read(isProjectOwnerProvider(projectId).future)}',
    ),
    'myProjectRoleProvider': _RefreshCase(
      provider: myProjectRoleProvider(projectId),
      change: makeMeContributor,
      read: (c) async =>
          '${await c.read(myProjectRoleProvider(projectId).future)}',
    ),
    'mayWriteProjectDataProvider': _RefreshCase(
      provider: mayWriteProjectDataProvider(projectId),
      change: makeMeContributor,
      read: (c) async =>
          '${await c.read(mayWriteProjectDataProvider(projectId).future)}',
    ),
    'projectByIdProvider': _RefreshCase(
      provider: projectByIdProvider(projectId),
      change: renameProject,
      read: (c) async =>
          (await c.read(projectByIdProvider(projectId).future))?.projectName ??
          '',
    ),
    'leaveProjectVerdictForProvider': _RefreshCase(
      provider: leaveProjectVerdictForProvider(projectId),
      change: endMyStint,
      read: (c) async =>
          '${await c.read(leaveProjectVerdictForProvider(projectId).future)}',
    ),
    'tagLibraryProvider': _RefreshCase(
      provider: tagLibraryProvider,
      change: addLibraryTag,
      read: (c) async => (await c.read(tagLibraryProvider.future))
          .map((t) => t.tagId)
          .join(','),
    ),
    'projectTagsProvider': _RefreshCase(
      provider: projectTagsProvider(projectId),
      change: addProjectTag,
      read: (c) async => (await c.read(projectTagsProvider(projectId).future))
          .map((t) => t.tagId)
          .join(','),
    ),
    'projectActiveTagsProvider': _RefreshCase(
      provider: projectActiveTagsProvider(projectId),
      change: addProjectTag,
      read: (c) async =>
          (await c.read(projectActiveTagsProvider(projectId).future))
              .map((t) => t.tagId)
              .join(','),
    ),
    // Task 11.241: the animals the tags are grouped under.
    'projectIndividualsProvider': _RefreshCase(
      provider: projectIndividualsProvider(projectId),
      change: addIndividual,
      read: (c) async =>
          (await c.read(projectIndividualsProvider(projectId).future))
              .map((i) => i.individualId)
              .join(','),
    ),
    // Task 11.243: the dated links, on the same list as the two rows they
    // join — a screen that saw a new link but not the animal it names would
    // be showing a grouping that is not true.
    'projectDeploymentsProvider': _RefreshCase(
      provider: projectDeploymentsProvider(projectId),
      change: addDeployment,
      read: (c) async =>
          (await c.read(projectDeploymentsProvider(projectId).future))
              .map((d) => d.deploymentId)
              .join(','),
    ),
  };

  /// The lists themselves, read through the two visitors rather than copied.
  /// Null is the whole-device form, which names each family rather than one
  /// instance — the form that enumerates what the lists *are*.
  List<ProviderOrFamily> listEntries() {
    final entries = <ProviderOrFamily>[];
    visitProjectViewProviders(
      (p) => entries.add(p as ProviderOrFamily),
      projectId: null,
    );
    visitTagViewProviders(
      (p) => entries.add(p as ProviderOrFamily),
      projectId: null,
    );
    return entries;
  }

  /// The list entries as objects, compared by identity. Generated providers
  /// and families are top-level finals, so identity is the strongest available
  /// key — stronger than the name, which a hand-written provider need not have.
  Set<ProviderOrFamily> refreshed() =>
      Set<ProviderOrFamily>.identity()..addAll(listEntries());

  group('the refresh lists are closed under what their providers read', () {
    for (final entry in cases.entries) {
      test('${entry.key} reads nothing that is left stale', () async {
        final db = await seed();
        final seen = <ProviderBase<Object?>>[];
        final container = ProviderContainer(
          observers: [_CreatedProviders(seen)],
          overrides: [
            appDatabaseProvider.overrideWith((ref) async => db),
          ],
        );
        addTearDown(container.dispose);

        container.listen<Object?>(entry.value.provider as dynamic, (_, _) {});
        await entry.value.read(container);

        final onAList = refreshed();
        final unlisted = seen
            .map(_familyOf)
            .where(
              (p) =>
                  !onAList.contains(p) && !notRefreshed.containsKey(_nameOf(p)),
            )
            .map(_nameOf)
            .toSet();
        expect(
          unlisted,
          isEmpty,
          reason:
              'Building ${entry.key} created these providers, and a refresh '
              'does not touch them: $unlisted. Invalidating a provider does '
              'not re-run the providers it reads (riverpod 3.3.2), so each of '
              'these hands back its cached answer to a provider that was just '
              'refreshed — which is exactly what left the "Your role" card '
              'showing an old role after an owner changed it. Either add it '
              'to the refresh list it belongs on, or add it to notRefreshed '
              'in this file with the reason a stale value there is harmless.',
        );
      });
    }
  });

  group('every entry on a refresh list is one a removal would break', () {
    test('the cases and the lists name the same providers', () {
      final covered = Set<ProviderOrFamily>.identity()
        ..addAll(cases.values.map((c) => _familyOf(c.provider as ProviderOrFamily)));
      expect(
        covered.map(_nameOf).toSet(),
        equals(refreshed().map(_nameOf).toSet()),
        reason:
            'Each entry on a refresh list needs a case below showing what goes '
            'stale without it, and each case needs an entry. A list entry with '
            'no case is one nobody could tell had been dropped — which is the '
            'state this whole file exists to end.',
      );
    });

    for (final entry in cases.entries) {
      test('${entry.key} shows the change after a refresh', () async {
        final db = await seed();
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) async => db),
          ],
        );
        addTearDown(container.dispose);
        // A screen is open on it, which is what holds the stale answer.
        container.listen<Object?>(entry.value.provider as dynamic, (_, _) {});
        final before = await entry.value.read(container);

        await entry.value.change(db.raw);
        refreshProjectViewsIn(container, projectId: null);
        refreshTagViewsIn(container, projectId: null);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          await entry.value.read(container),
          isNot(before),
          reason:
              '${entry.key} was on a refresh list and still answered with what '
              'it held before the change. If it has just been taken off the '
              'list, this is the screen that goes on showing a stale answer '
              'until the app is restarted.',
        );
      });
    }
  });

  group('the deadlock guard can survive not seeing family instances', () {
    test('every family on a refresh list is autoDispose', () {
      final keepAlive = [
        for (final entry in listEntries())
          if (entry is Family && !entry.isAutoDispose) _nameOf(entry),
      ];
      expect(
        keepAlive,
        isEmpty,
        reason:
            'ArrivalRefresh holds a refresh back while any provider on its '
            'settle list is mid-build, and families cannot be on that list: '
            'riverpod 3.3.2 exports no way to enumerate a family\'s live '
            'instances. What makes that survivable is that an autoDispose '
            'provider invalidated mid-build throws "disposed during loading '
            'state" — loud, and a watching screen recovers on the rebuild — '
            'while a keepAlive one hangs forever with nothing raised, which on '
            'a phone is a screen that never finishes opening. These families '
            'are keepAlive and re-open that: $keepAlive.',
      );
    });

    test('nothing on the settle list is a family, and each is refreshed', () {
      final onAList = refreshed();
      for (final entry in ArrivalRefresh.settleFirst) {
        final provider = entry as ProviderOrFamily;
        expect(
          provider,
          isNot(isA<Family>()),
          reason:
              '${_nameOf(provider)} is a family, and ArrivalRefresh reads each '
              'settle-list entry by name — a family has no single state to '
              'read.',
        );
        expect(
          onAList.contains(provider) || identical(provider, currentUserProvider),
          isTrue,
          reason:
              '${_nameOf(provider)} is waited on before a refresh but is not '
              'refreshed by one. The settle list exists to name the providers '
              'a refresh could catch mid-build, so an entry that no refresh '
              'touches is either a leftover or a list that has drifted.',
        );
      }
    });
  });
}

/// One entry on a refresh list, and the reason it is there: a change somebody
/// makes, and the value that has to reflect it once the refresh has run.
class _RefreshCase {
  _RefreshCase({
    required this.provider,
    required this.change,
    required this.read,
  });

  /// The concrete provider — a family instance where the list names a family.
  final Object provider;
  final Future<void> Function(Database) change;
  final Future<String> Function(ProviderContainer) read;
}

/// Records every provider riverpod creates, which is how the read-set of a
/// provider is *derived* here rather than transcribed: on a fresh container,
/// everything created while one provider builds is something that provider
/// reads, directly or through another.
final class _CreatedProviders extends ProviderObserver {
  _CreatedProviders(this.seen);

  final List<ProviderBase<Object?>> seen;

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      seen.add(context.provider);
}

/// A family instance carries its family's name, so this is the same string for
/// `myProjectRoleProvider` and `myProjectRoleProvider('project-1')`. The
/// fallback is for hand-written providers, which are not given a name.
String _nameOf(ProviderOrFamily provider) =>
    provider.name ?? provider.toString();

/// The family a provider belongs to, or the provider itself. A family instance
/// and its family are different objects, and it is the family that appears on a
/// refresh list.
ProviderOrFamily _familyOf(ProviderOrFamily provider) =>
    provider is Family ? provider : (provider.from ?? provider);
