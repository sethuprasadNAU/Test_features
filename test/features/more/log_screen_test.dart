import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation_exclusion.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// `currentProjectProvider` resolves to `null` without ever touching the
/// real database when no active project id is persisted (it only reads
/// `activeProjectIdProvider`, short-circuiting before any repository/db
/// provider is watched) — so this stays a plain `testWidgets` test, same
/// reasoning as `project_setup_screen_test.dart`.
///
/// A populated-list test was attempted (seed a real observation, tap delete,
/// verify it disappears + an Undo snackbar appears) and confirmed by direct
/// experiment that a tap-triggered `softDeleteById` (a fresh `sqflite_common_ffi`
/// isolate round trip after the widget has already settled) does **not**
/// resolve within `pumpAndSettle()` — the same gotcha documented in
/// `manage_offline_maps_screen_test.dart`, just triggered by a later
/// interaction instead of the initial build. `pumpAndSettle()` returns
/// "settled" the instant nothing new is scheduled, which happens immediately
/// once the awaited Future stalls — it is not proof the awaited work
/// completed. There's no known way to interleave `tester.runAsync` with the
/// `tester.tap()`/`pumpAndSettle()` calls that would need it, so this is left
/// to the already-thorough generic `test/data/soft_delete_test.dart` coverage
/// of `softDeleteById`/`restoreById` (the exact methods this screen's delete
/// button calls) plus manual verification.
///
/// That experiment did catch one real, unrelated bug worth keeping fixed
/// regardless: `_deleteObservation`/`_editNotes` used `ref` after `await`s
/// with no `mounted` guard, throwing once the widget disposed mid-flight —
/// fixed by guarding every `ref` touch after each `await`.
/// Opens an observation row's ⋯ menu and reports which entries it offers and
/// whether each is enabled. Task 11.100 item 4 folded Edit, Delete and Share
/// into that menu, so this is how the row's controls are read now.
Future<Map<String, bool>> rowMenuEntries(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Observation actions').first);
  await tester.pumpAndSettle();
  return {
    for (final item in tester.widgetList<PopupMenuItem<String>>(
      find.byType(PopupMenuItem<String>),
    ))
      item.value!: item.enabled,
  };
}

void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('renders the no-project empty state without touching the database', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: LogScreen())),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Set up a project first.'), findsOneWidget);
  });

  group('edit/delete gated to the observation\'s own creator (task 6.3/6.4), '
      'now disabled-with-reason rather than hidden (task 11.12)', () {
    // A replicated shared observation preserves the original observer's
    // user_id (task 6.3) rather than the receiving user's — which means the
    // existing "only the creator can edit" rule (currentUser.userId ==
    // o.userId) correctly makes it read-only on the receiving device. That is
    // the desired outcome, not a bug, but 6.3 flagged it as "confirm the edit
    // UI degrades gracefully" rather than crashing or silently failing — this
    // is that confirmation.
    //
    // Task 11.12 changed *how* it degrades: the icons used to be absent
    // entirely, which reads as "this observation has no Edit" rather than
    // "you may not". They are now always rendered, disabled with a Tooltip
    // reason when not permitted — the standing "explain, don't just hide"
    // rule (Phase 5.2, task 8.3/11.1) applied to this control.
    testWidgets(
        'a replica (observer != current user) shows Edit/Delete disabled, with a reason',
        (tester) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final alice = sampleUser(id: 'user-alice', email: 'alice@example.com');
      final tag = sampleTag(id: 'tag-1');
      // The replica: same shape a faithful save produces — userId is the
      // original observer (Alice), not the receiving user (Bob).
      final replica = sampleObservation(
        id: 'obs-replica',
        projectId: project.projectId,
        userId: alice.userId,
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.users, alice.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, replica.toColumns());
        // Pre-resolve, same reasoning as `localTagsProvider`/`allTagsProvider`
        // in the other screen tests: a tap-free FutureProvider read is safe to
        // await directly, but only inside `runAsync`'s real zone.
        await container.read(historyDataProvider(project.projectId).future);
        // `mayWriteProjectDataProvider` is `@riverpod`-generated (autoDispose):
        // a bare `read` would be thrown away the instant the widget tree
        // watches it, so `listen` first keeps it alive — same reasoning as
        // `isProjectOwnerProvider` in `project_setup_screen_test.dart`.
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Coco'), findsOneWidget);
      // Task 11.100 item 4: the row's controls are one ⋯ menu now, so the
      // entries are read by opening it rather than by looking for icons.
      final entries = await rowMenuEntries(tester);
      expect(entries.containsKey('share'), isTrue);
      expect(entries['edit'], isFalse,
          reason: 'present but disabled, not absent');
      expect(entries['delete'], isFalse);
      // Task 11.137: on the item, not in a `Tooltip` — a phone never shows
      // one, so this reason existed and nobody could read it.
      expect(
        find.text('You can only edit or delete observations you recorded yourself.'),
        findsWidgets,
      );
    });

    testWidgets('the current user\'s own observation still shows Edit/Delete, enabled',
        (tester) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag(id: 'tag-1');
      final own = sampleObservation(
        id: 'obs-own',
        projectId: project.projectId,
        userId: bob.userId,
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, own.toColumns());
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final entries = await rowMenuEntries(tester);
      expect(entries['edit'], isTrue);
      expect(entries['delete'], isTrue);
    });

    // Task 11.194. Michael: "add it to the log list." Task 11.193 built the
    // flag and showed it only on the Position screen; this is the Log row's
    // half, and it must say the word rather than rely on colour alone.
    testWidgets('a signal flagged irregular/malfunctioning shows the word on '
        'the log row', (tester) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag(id: 'tag-1');
      final flagged = sampleObservation(
        id: 'obs-flagged',
        projectId: project.projectId,
        userId: bob.userId,
        tagId: tag.tagId,
        sessionId: null,
        signalIrregular: true,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, flagged.toColumns());
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const LogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Malfunctioning'), findsOneWidget,
          reason: 'The colour rule: a mark never carries meaning alone. The '
              'Position row\'s bare triangle is the one argued exception, '
              'and this row is not it.');
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets(
        'no flag means no mark, and no filter exists to hide unflagged rows',
        (tester) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag(id: 'tag-1');
      final ordinary = sampleObservation(
        id: 'obs-ordinary',
        projectId: project.projectId,
        userId: bob.userId,
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, ordinary.toColumns());
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const LogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Malfunctioning'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('a viewer (author of their own pre-demotion observation) is still refused',
        (tester) async {
      // The gap `canEdit` used to have: it only asked authorship, not role —
      // so a contributor demoted to viewer would still see their own old
      // observations offered as editable and be refused at the tap.
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final tag = sampleTag(id: 'tag-1');
      final own = sampleObservation(
        id: 'obs-own',
        projectId: project.projectId,
        userId: viewer.userId,
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => viewer),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, viewer.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, own.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: viewer.userId, role: ProjectRole.viewer).toColumns(),
        );
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect((await rowMenuEntries(tester))['edit'], isFalse);
      expect(
        find.text('Viewers cannot edit or delete observations — ask an owner to change your role.'),
        findsWidgets,
      );
    });
  });

  /// **Task 11.7's controls, per role.** Task 11.12 could not sweep this
  /// feature because it did not exist yet, and recorded that 11.7 must carry
  /// the "disabled with a reason" treatment itself. This is that.
  group('supersede and exclude controls (task 11.7)', () {
    Future<ProviderContainer> pumpAs(
      WidgetTester tester,
      ProjectRole role,
    ) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final me = sampleUser(id: 'user-me', email: 'me@example.com');
      final tag = sampleTag(id: 'tag-1');
      // Somebody else's observation, which is the interesting case: a
      // contributor may supersede it and may not exclude it.
      final theirs = sampleObservation(
        id: 'obs-theirs',
        projectId: project.projectId,
        userId: owner.userId,
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => me),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, me.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, theirs.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: owner.userId).toColumns(),
        );
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            id: 'membership-me',
            userId: me.userId,
            role: role,
          ).toColumns(),
        );
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    /// Opens the row's position-estimate menu and reports whether each entry
    /// is offered or shown disabled.
    Future<Map<String, bool>> menuEntries(WidgetTester tester) async {
      // Task 11.100 item 4: Edit/Delete/Share and the supersede entries now
      // share one ⋯ menu, so this opens the whole row's menu rather than a
      // separate position-estimate one.
      await tester.tap(find.byTooltip('Observation actions').first);
      await tester.pumpAndSettle();
      final entries = <String, bool>{};
      for (final item in tester.widgetList<PopupMenuItem<String>>(
        find.byType(PopupMenuItem<String>),
      )) {
        entries[item.value!] = item.enabled;
      }
      return entries;
    }

    testWidgets('a viewer is offered neither, and both say why', (tester) async {
      await pumpAs(tester, ProjectRole.viewer);
      expect(tester.takeException(), isNull);

      final entries = await menuEntries(tester);
      expect(entries['supersede'], isFalse);
      expect(entries['exclude'], isFalse);
      expect(
        find.text(
          'Viewers cannot supersede an observation — ask an owner to change '
          'your role.',
        ),
        findsWidgets,
      );
    });

    testWidgets(
      "a contributor may supersede somebody else's observation but not "
      'exclude it',
      (tester) async {
        await pumpAs(tester, ProjectRole.contributor);
        expect(tester.takeException(), isNull);

        final entries = await menuEntries(tester);
        expect(entries['supersede'], isTrue);
        expect(entries['exclude'], isFalse);
        // Disabled *with the alternative named* — a control that only says no
        // teaches nothing.
        expect(
          find.text(
            'Only a project owner can exclude an observation from position '
            'estimates. You can supersede it with a corrected record instead.',
          ),
          findsWidgets,
        );
      },
    );

    testWidgets('an owner is offered both', (tester) async {
      await pumpAs(tester, ProjectRole.owner);
      expect(tester.takeException(), isNull);

      final entries = await menuEntries(tester);
      expect(entries['supersede'], isTrue);
      expect(entries['exclude'], isTrue);
    });
  });

  group('supersede picker candidate rows (task 11.211)', () {
    // Task 11.211: each candidate used to be one ellipsised
    // `Text('<when> · <who> · <bearing or type>')`, truncated from the
    // right — so on the smallest phone this app supports, the bearing or
    // record-type field (the one thing that tells two candidates by the
    // same observer apart) was cut before the observer's own name was.
    // Proved here on the 6.1-inch profile, which is where the plan entry
    // measured the defect; the fix puts `<when> · <who>` in the part that
    // ellipsises and the distinguishing field after it, unconstrained.
    testWidgets(
      'the distinguishing field is never the one that gets cut, even with a '
      'long observer name at 6.1-inch width',
      (tester) async {
        usePhoneGeometry(tester);

        final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
        final owner = sampleUser(id: 'user-owner', email: 'owner@example.com')
            .copyWith(firstName: 'Alexandria', lastName: 'Featherstonhaugh');
        final tag = sampleTag(id: 'tag-1');
        final beingSuperseded = sampleObservation(
          id: 'obs-superseded',
          projectId: project.projectId,
          userId: owner.userId,
          tagId: tag.tagId,
          sessionId: null,
        );
        // The one candidate to supersede it with — same observer (so the
        // date and name alone cannot tell the two apart), a bearing that
        // was the part cut off before this fix.
        final candidate = beingSuperseded.copyWith(
          observationId: 'obs-candidate',
          trueNorthBearing: 88.0,
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
            currentUserProvider.overrideWith((ref) async => owner),
            currentProjectProvider.overrideWith((ref) async => project),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(Tables.users, owner.toColumns());
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(Tables.tags, tag.toColumns());
          await db.insert(Tables.observations, beingSuperseded.toColumns());
          await db.insert(Tables.observations, candidate.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(userId: owner.userId).toColumns(),
          );
          await container.read(historyDataProvider(project.projectId).future);
          container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
          await container.read(mayWriteProjectDataProvider(project.projectId).future);
          container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
          await container.read(isProjectOwnerProvider(project.projectId).future);
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LogScreen()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Observation actions').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Superseded by another record…'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(' · 88°'), findsWidgets);
      },
    );
  });

  /// **Task 11.15's control, per role and per mark.**
  ///
  /// The menu used to offer "Count in estimates again" to anyone who could
  /// supersede — the rights *making* a mark needs, which is not the question
  /// withdrawing asks. A contributor was therefore shown a live control for a
  /// colleague's mark and got a raw `UnauthorizedMutation` at the tap, which
  /// is the exact failure task 11.12 exists to prevent.
  group('the withdraw control (task 11.15)', () {
    Future<ProviderContainer> pumpWithMark(
      WidgetTester tester,
      ProjectRole role, {
      required String markBy,
      ObservationExclusionKind kind = ObservationExclusionKind.superseded,
    }) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final me = sampleUser(id: 'user-me', email: 'me@example.com');
      // The contributor who marked a bearing and then left the project: a
      // `Users` row and no membership at all, which is the state that made
      // the mark unwithdrawable under task 11.7's author-only rule.
      final gone = sampleUser(id: 'user-gone', email: 'gone@example.com');
      final tag = sampleTag(id: 'tag-1');
      final theirs = sampleObservation(
        id: 'obs-theirs',
        projectId: project.projectId,
        userId: owner.userId,
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => me),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, me.toColumns());
        await db.insert(Tables.users, gone.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, theirs.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: owner.userId).toColumns(),
        );
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(id: 'membership-me', userId: me.userId, role: role)
              .toColumns(),
        );
        await db.insert(
          Tables.observationExclusions,
          ObservationExclusion(
            exclusionId: 'mark-1',
            projectId: project.projectId,
            observationId: theirs.observationId,
            userId: markBy,
            kind: kind,
            supersededByObservationId: null,
            sync: sampleSync(),
          ).toColumns(),
        );
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    Future<Map<String, bool>> menuEntries(WidgetTester tester) async {
      // Task 11.100 item 4: Edit/Delete/Share and the supersede entries now
      // share one ⋯ menu, so this opens the whole row's menu rather than a
      // separate position-estimate one.
      await tester.tap(find.byTooltip('Observation actions').first);
      await tester.pumpAndSettle();
      return {
        for (final item in tester.widgetList<PopupMenuItem<String>>(
          find.byType(PopupMenuItem<String>),
        ))
          item.value!: item.enabled,
      };
    }

    testWidgets('a contributor may withdraw their own mark', (tester) async {
      await pumpWithMark(tester, ProjectRole.contributor, markBy: 'user-me');
      expect(tester.takeException(), isNull);
      expect((await menuEntries(tester))['restore'], isTrue);
    });

    testWidgets("but not a colleague's — and is told why rather than being "
        'shown a control that throws', (tester) async {
      await pumpWithMark(tester, ProjectRole.contributor, markBy: 'user-owner');
      expect(tester.takeException(), isNull);

      expect((await menuEntries(tester))['restore'], isFalse);
      expect(
        find.text(
          'Only the person who marked this observation, or a project owner, '
          'can make it count again.',
        ),
        findsWidgets,
      );
    });

    testWidgets("an owner may withdraw a contributor's mark — the case task "
        '11.15 exists for', (tester) async {
      // `user-me` is the owner here and the mark belongs to `user-gone`, who
      // holds no membership in this project any more. Before 11.15 this entry
      // was offered and the write was then refused — which is how a wrongly
      // marked bearing became permanent the moment its author left.
      await pumpWithMark(tester, ProjectRole.owner, markBy: 'user-gone');
      expect(tester.takeException(), isNull);
      expect((await menuEntries(tester))['restore'], isTrue);
    });

    testWidgets('an exclusion stays owner-only to undo', (tester) async {
      await pumpWithMark(
        tester,
        ProjectRole.contributor,
        markBy: 'user-me',
        kind: ObservationExclusionKind.excluded,
      );
      expect(tester.takeException(), isNull);

      expect((await menuEntries(tester))['restore'], isFalse);
      expect(
        find.text(
          'Only a project owner can put an excluded observation back into '
          'position estimates.',
        ),
        findsWidgets,
      );
    });
  });

  /// **Task 11.18.** 11.15 let an owner withdraw a contributor's mark and
  /// left the contributor with no way to find out. The information already
  /// exists — the tombstoned `Observation_Exclusions` row names both the
  /// original marker ([ObservationExclusion.userId], untouched) and the
  /// withdrawer ([SyncMeta.lastModifiedBy], overwritten on withdrawal) — this
  /// is on trial for showing both names, not just one.
  group('withdrawn-mark visibility (task 11.18)', () {
    testWidgets(
        'shows both halves: who made the mark, and who withdrew it',
        (tester) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final owner = User(
        userId: 'user-owner',
        firstName: 'Alex',
        lastName: 'Owner',
        email: 'owner@example.com',
        sync: sampleSync(),
      );
      final tag = sampleTag(id: 'tag-1');
      final obs = sampleObservation(
        id: 'obs-1',
        projectId: project.projectId,
        userId: 'user-marker',
        tagId: tag.tagId,
        sessionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(
          Tables.users,
          User(
            userId: 'user-marker',
            firstName: 'Casey',
            lastName: 'Marker',
            email: 'marker@example.com',
            sync: sampleSync(),
          ).toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.observations, obs.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: owner.userId).toColumns(),
        );
        await db.insert(
          Tables.observationExclusions,
          ObservationExclusion(
            exclusionId: 'mark-1',
            projectId: project.projectId,
            observationId: obs.observationId,
            userId: 'user-marker',
            kind: ObservationExclusionKind.excluded,
            supersededByObservationId: null,
            sync: sampleSync().copyWith(
              deletedAt: DateTime.utc(2026, 3, 14, 9, 15),
              lastModifiedBy: owner.userId,
            ),
          ).toColumns(),
        );
        await container.read(historyDataProvider(project.projectId).future);
        // Both `@riverpod`-generated (autoDispose) — a bare `read` is thrown
        // away the instant the widget tree watches it, so `listen` first
        // keeps each alive. Same pattern as `pumpWithMark` above.
        container.listen(
          mayWriteProjectDataProvider(project.projectId),
          (_, _) {},
        );
        await container.read(
          mayWriteProjectDataProvider(project.projectId).future,
        );
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Both halves, not just one — either alone would misrepresent what
      // happened (task 11.18's own acceptance test).
      expect(
        find.textContaining('Excluded by Casey Marker'),
        findsWidgets,
        reason: 'the original mark must still be shown, not just its undo',
      );
      expect(
        find.textContaining('then withdrawn by Alex Owner'),
        findsWidgets,
        reason: 'and who reversed it',
      );
      // No live exclusion state — the mark was withdrawn, so nothing should
      // claim the observation is currently excluded.
      expect(
        find.textContaining('Excluded from position estimates'),
        findsNothing,
      );
    });
  });

  group('Team tab (task 11.4)', () {
    /// Seeds a project with two members' observations — Alice's older
    /// `Alpha` tag reading, Bob's newer `Zulu` tag reading — and pumps
    /// `LogScreen` on the Team tab. Both observations already land in
    /// `Observations` locally (Phase 6 replica import), so no server is
    /// involved.
    Future<ProviderContainer> pumpTeamTab(
      WidgetTester tester, {
      Stream<Position>? gpsStream,
    }) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
      final alice = sampleUser(id: 'user-alice', email: 'alice@example.com')
          .copyWith(firstName: 'Alice', lastName: 'Vega');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com')
          .copyWith(firstName: 'Bob', lastName: 'Wren');
      final tagAlpha = sampleTag(id: 'tag-alpha', tagName: 'Alpha');
      final tagZulu = sampleTag(id: 'tag-zulu', tagName: 'Zulu');
      final aliceObs = sampleObservation(
        id: 'obs-alice',
        projectId: project.projectId,
        userId: alice.userId,
        tagId: tagAlpha.tagId,
        sessionId: null,
      ).copyWith(
        timestampLocal: DateTime(2026, 7, 16, 9, 0, 0),
        timestampUtc: DateTime.utc(2026, 7, 16, 16, 0, 0),
      );
      final bobObs = sampleObservation(
        id: 'obs-bob',
        projectId: project.projectId,
        userId: bob.userId,
        tagId: tagZulu.tagId,
        sessionId: null,
      ).copyWith(
        timestampLocal: DateTime(2026, 7, 16, 10, 0, 0),
        timestampUtc: DateTime.utc(2026, 7, 16, 17, 0, 0),
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => gpsStream ?? const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.users, alice.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tagAlpha.toColumns());
        await db.insert(Tables.tags, tagZulu.toColumns());
        await db.insert(Tables.observations, aliceObs.toColumns());
        await db.insert(Tables.observations, bobObs.toColumns());
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Team'));
      await tester.pumpAndSettle();

      return container;
    }

    /// The list order within the Team tab's `ListView`, read off the tile
    /// titles (each starts with the tag name for a directional observation).
    List<String> tileTitles(WidgetTester tester) => tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title as Text).data ?? '')
        .toList();

    testWidgets('teammates\' observations appear with observer attribution',
        (tester) async {
      await pumpTeamTab(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Alice Vega'), findsOneWidget);
      expect(find.textContaining('Bob Wren'), findsOneWidget);
    });

    testWidgets('member sort orders by observer name', (tester) async {
      await pumpTeamTab(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Member'));
      await tester.pumpAndSettle();

      final titles = tileTitles(tester);
      expect(titles, [
        'No animal at this time · Alpha · 150.325 MHz',
        'No animal at this time · Zulu · 150.325 MHz',
      ]);
    });

    testWidgets('tag sort orders alphabetically by tag name', (tester) async {
      await pumpTeamTab(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Tag'));
      await tester.pumpAndSettle();

      final titles = tileTitles(tester);
      expect(titles, [
        'No animal at this time · Alpha · 150.325 MHz',
        'No animal at this time · Zulu · 150.325 MHz',
      ]);
    });

    testWidgets('time sort orders newest first', (tester) async {
      await pumpTeamTab(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Time'));
      await tester.pumpAndSettle();

      final titles = tileTitles(tester);
      expect(titles, [
        'No animal at this time · Zulu · 150.325 MHz',
        'No animal at this time · Alpha · 150.325 MHz',
      ]);
    });

    testWidgets(
        'distance sort is disabled with a reason when there is no GPS fix, '
        'and never silently reorders by anything else', (tester) async {
      await pumpTeamTab(tester);

      // Distance chip is present but disabled (no onTap effect) — attempting
      // to tap it must not change the sort or crash.
      // Task 11.137: the reason is in the chip's own label now. It was in a
      // `Tooltip`, which a touchscreen never shows — and the fallback line
      // below the sort bar only appears once somebody has *selected* distance
      // and then lost their fix, so with Time selected there was no
      // explanation on the screen at all.
      final distanceChipFinder =
          find.widgetWithText(ChoiceChip, 'Distance — no GPS fix');
      expect(distanceChipFinder, findsOneWidget);
      final chip = tester.widget<ChoiceChip>(distanceChipFinder);
      expect(chip.onSelected, isNull, reason: 'distance sort must be unselectable with no GPS fix');

      // Switching to Member first (a real reorder), then confirming the
      // still-default Time order is what actually renders, rather than a
      // stale or silently-different order.
      final titlesBeforeTap = tileTitles(tester);
      await tester.tap(distanceChipFinder);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tileTitles(tester), titlesBeforeTap,
          reason: 'a disabled distance chip must not change the list order');
    });

    testWidgets('distance sort works and is enabled once a GPS fix exists',
        (tester) async {
      final fix = Position(
        latitude: 35.19,
        longitude: -111.62,
        timestamp: DateTime.utc(2026, 7, 16, 17, 0, 0),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
      await pumpTeamTab(tester, gpsStream: Stream.value(fix));

      final distanceChipFinder = find.widgetWithText(ChoiceChip, 'Distance');
      final chip = tester.widget<ChoiceChip>(distanceChipFinder);
      expect(chip.onSelected, isNotNull, reason: 'distance sort must be selectable with a GPS fix');

      await tester.tap(distanceChipFinder);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(ChoiceChip, 'Distance — no GPS fix'),
          findsNothing);
      expect(
        find.text('No GPS fix — distance unavailable, showing time order instead.'),
        findsNothing,
      );
    });

    testWidgets('the personal Log tab is unaffected and shown first', (tester) async {
      await pumpTeamTab(tester);
      // pumpTeamTab already switched to Team; switch back and confirm the
      // personal tab still renders the same full observation set (task 11.4
      // does not restrict it to "mine only" — see log_screen.dart's header
      // comment on why).
      await tester.tap(find.widgetWithText(Tab, 'Log'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Alice Vega'), findsOneWidget);
      expect(find.textContaining('Bob Wren'), findsOneWidget);
    });
  });

  // **Task 11.92.** The Log listed observations and non-detections and did not
  // know truth points existed, so a season of "where the animal actually was"
  // records had no list on any screen — only a dot on the map.
  group('truth points in the Log', () {
    Future<ProviderContainer> seed(WidgetTester tester, {ProjectRole role = ProjectRole.owner}) async {
      // The project is owned by somebody else, so `role` alone decides whether
      // Bob may write — a project whose `owner_user_id` is the signed-in user
      // would be permitted whatever membership row it carries.
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag = sampleTag(id: 'tag-1');
      final point = sampleActualLocation(
        id: 'loc-1',
        projectId: project.projectId,
        tagId: tag.tagId,
        foundKind: GroundTruthKind.collarOnly,
        tagVersionId: null,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: bob.userId, role: role).toColumns(),
        );
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(Tables.actualTagLocations, point.toColumns());
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('the row shows the precision and what was found, not just tag '
        'and time', (tester) async {
      await seed(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Truth point'), findsOneWidget);
      // The two fields that decide what the point means. Without them a
      // ±3 m animal-and-collar fix and a ±40 m shed collar look identical.
      expect(find.textContaining('Tag only'), findsOneWidget);
      expect(find.textContaining('precision ±15 m'), findsOneWidget);
    });

    testWidgets('an owner is offered Edit and Delete', (tester) async {
      await seed(tester);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      // Task 11.100: the label names moving the point, because the dialog
      // it opens can move it.
      expect(
        find.text('Edit position / precision / what was found…'),
        findsOneWidget,
      );
      expect(find.text('Delete truth point…'), findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text('Delete truth point…'),
            matching: find.byType(PopupMenuItem<String>),
          ),
        ).enabled,
        isTrue,
      );
    });

    testWidgets('a viewer sees them disabled with a reason, not hidden',
        (tester) async {
      await seed(tester, role: ProjectRole.viewer);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text('Delete truth point…'),
            matching: find.byType(PopupMenuItem<String>),
          ),
        ).enabled,
        isFalse,
        reason: 'the standing "explain, do not just hide" rule',
      );
      expect(
        find.text('Viewers cannot change or delete a truth point — ask an '
            'owner to change your role.'),
        findsWidgets,
      );
    });
  });

  group('"no signal" records in the Log (task 11.252)', () {
    Future<ProviderContainer> seed(
      WidgetTester tester, {
      ProjectRole role = ProjectRole.owner,
      String nonDetectionUserId = 'user-bob',
    }) async {
      // Same shape as the truth-point seed above: the project is owned by
      // somebody else, so `role` alone decides whether Bob may write.
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
      final tag1 = sampleTag(id: 'tag-1');
      final tag2 = sampleTag(id: 'tag-2', frequencyMhz: 150.500);
      final nd = sampleNonDetection(
        id: 'nd-1',
        projectId: project.projectId,
        userId: nonDetectionUserId,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => bob),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, bob.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: bob.userId, role: role).toColumns(),
        );
        await db.insert(Tables.tags, tag1.toColumns());
        await db.insert(Tables.tags, tag2.toColumns());
        await db.insert(Tables.nonDetections, nd.toColumns());
        await container.read(historyDataProvider(project.projectId).future);
        container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('the row now offers a Delete control (task 11.252 — it '
        'used to offer none)', (tester) async {
      await seed(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('No signal'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(find.text('Delete "no signal" record…'), findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text('Delete "no signal" record…'),
            matching: find.byType(PopupMenuItem<String>),
          ),
        ).enabled,
        isTrue,
      );
    });

    testWidgets('a viewer sees it disabled with a reason, not hidden',
        (tester) async {
      await seed(tester, role: ProjectRole.viewer);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text('Delete "no signal" record…'),
            matching: find.byType(PopupMenuItem<String>),
          ),
        ).enabled,
        isFalse,
        reason: 'the standing "explain, do not just hide" rule',
      );
      expect(
        find.text('Viewers cannot delete a "no signal" record — ask an '
            'owner to change your role.'),
        findsWidgets,
      );
    });

    testWidgets(
        "a contributor sees a colleague's record disabled — author-only, "
        'same as a bearing', (tester) async {
      await seed(
        tester,
        role: ProjectRole.contributor,
        nonDetectionUserId: 'user-owner',
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();

      expect(
        tester.widget<PopupMenuItem<String>>(
          find.ancestor(
            of: find.text('Delete "no signal" record…'),
            matching: find.byType(PopupMenuItem<String>),
          ),
        ).enabled,
        isFalse,
      );
      expect(
        find.text('You can only delete a "no signal" record you recorded '
            'yourself.'),
        findsWidgets,
      );
    });

    testWidgets('tapping Delete asks for confirmation and names how many '
        'collars', (tester) async {
      await seed(tester);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete "no signal" record…'));
      await tester.pumpAndSettle();

      expect(find.text('Delete this "no signal" record?'), findsOneWidget);
      expect(
        find.textContaining(
            'you listened for 2 collars and heard nothing'),
        findsOneWidget,
      );
    });
  });
}
