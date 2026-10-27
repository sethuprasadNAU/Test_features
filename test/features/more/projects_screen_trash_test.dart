import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/project_row_menu.dart';

/// **Task 11.339 — the Trash holds everything moved there from this phone.**
///
/// Michael's check, as a test: move a project that was never published to
/// the Trash, find it there, restore it. Before this task it was hidden after
/// the six-second UNDO and appeared nowhere, because the Trash section listed
/// only what a server still held. And item 2: a deletion not yet sent to the
/// server sits in the same Trash, with one line saying so, rather than in a
/// section of its own.
///
/// No server and no session in any case here — the phone item 1 is for has
/// never published anything. The project list is read from the database
/// (not a fixed override), so moving the only project to the Trash really
/// does empty the list, which is the empty-projects state the Trash has to
/// appear in too.
void main() {
  setUp(installFakeSharedPreferences);

  const me = 'user-1';

  Future<ProviderContainer> seed({
    List<UndeliveredProjectDeletion>? undelivered,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => sampleUser(id: me)),
        allProjectsProvider.overrideWith(
          (ref) async =>
              (await ref.watch(projectRepositoryProvider.future)).findAll(),
        ),
        if (undelivered != null)
          undeliveredProjectDeletionsProvider.overrideWith(
            (ref) async => undelivered,
          ),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(Tables.users, sampleUser(id: me).toColumns());
    await db.insert(
      Tables.projects,
      sampleProject(id: 'project-1', ownerUserId: me).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(userId: me).toColumns(),
    );
    await db.insert(Tables.tags, sampleTag().toColumns());
    await db.insert(Tables.individuals, sampleIndividual().toColumns());
    await db.insert(Tables.triangulationSessions, sampleSession().toColumns());
    await db.insert(Tables.observations, sampleObservation().toColumns());
    await container.read(deviceIdProvider.future);
    container.listen(ownedProjectIdsProvider, (_, _) {});
    container.listen(departedProjectIdsProvider, (_, _) {});
    container.listen(snapshotProjectIdsProvider, (_, _) {});
    container.listen(unsyncedMemberProjectIdsProvider, (_, _) {});
    await container.read(ownedProjectIdsProvider.future);
    await container.read(departedProjectIdsProvider.future);
    await container.read(snapshotProjectIdsProvider.future);
    await container.read(unsyncedMemberProjectIdsProvider.future);
    container.listen(projectDeletionNoticesProvider, (_, _) {});
    await container.read(projectDeletionNoticesProvider.future);
    container.listen(undeliveredProjectDeletionsProvider, (_, _) {});
    await container.read(undeliveredProjectDeletionsProvider.future);
    container.listen(trashedOnThisDeviceProvider, (_, _) {});
    await container.read(trashedOnThisDeviceProvider.future);
    return container;
  }

  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ProjectsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Taps [target] on the real clock and waits for [until] — the writes and
  /// the provider rebuilds behind each control are real database I/O that
  /// schedules no frame. Bounded, so a broken build goes red rather than
  /// hanging (task 11.209).
  Future<void> tapAndWait(
    WidgetTester tester,
    Finder target,
    bool Function() until,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!until()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the screen never reached the expected state');
        }
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
  }

  Future<Object?> deletedAt(ProviderContainer container) async {
    final db = (await container.read(appDatabaseProvider.future)).raw;
    final rows = await db.query(
      Tables.projects,
      where: 'project_id = ?',
      whereArgs: ['project-1'],
    );
    return rows.isEmpty ? 'gone' : rows.single['deleted_at'];
  }

  Future<int> observations(ProviderContainer container) async {
    final db = (await container.read(appDatabaseProvider.future)).raw;
    return (await db.rawQuery(
              'SELECT COUNT(*) AS c FROM ${Tables.observations} '
              'WHERE project_id = ?',
              ['project-1'],
            )).first['c']
            as int;
  }

  bool showing(String text) => find.textContaining(text).evaluate().isNotEmpty;

  Future<void> moveToTrash(WidgetTester tester) async {
    await tapProjectMenuItem(tester, 'Move to Trash');
    await tapAndWait(
      tester,
      find.widgetWithText(FilledButton, 'Move to Trash'),
      () => showing('never published'),
    );
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).clearSnackBars();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'WATCHED RED: a project that was never published, moved to the Trash, is '
    'in the Trash — and Restore brings it back with its records',
    (tester) async {
      late ProviderContainer container;
      await tester.runAsync(() async => container = await seed());
      addTearDown(container.dispose);
      await pump(tester, container);
      expect(find.text('Trash'), findsNothing,
          reason: 'nothing in the Trash, so no heading over an empty list');

      await moveToTrash(tester);

      expect(find.text('Trash'), findsOneWidget);
      expect(find.text('Mesa Coyotes'), findsOneWidget,
          reason: 'out of the project list and into the Trash, once');
      expect(
        find.textContaining(
          'It was never published, so it is only on this phone.',
        ),
        findsOneWidget,
      );
      expect(await tester.runAsync(() => observations(container)), 1,
          reason: 'moving to the Trash removes no record');

      await tapAndWait(
        tester,
        find.widgetWithText(FilledButton, 'Restore'),
        () => showing('is restored'),
      );
      expect(find.text('Trash'), findsNothing);
      expect(find.text('Mesa Coyotes'), findsOneWidget,
          reason: 'back in the project list');
      expect(await tester.runAsync(() => deletedAt(container)), isNull);
      expect(await tester.runAsync(() => observations(container)), 1);
    },
  );

  testWidgets(
    'WATCHED RED: Delete permanently… says in plain words that nothing is on '
    'a server, Cancel keeps it, and confirming removes it and its records '
    'from this phone',
    (tester) async {
      late ProviderContainer container;
      await tester.runAsync(() async => container = await seed());
      addTearDown(container.dispose);
      await pump(tester, container);
      await moveToTrash(tester);

      await tester.tap(find.byTooltip('Trash actions'));
      await tester.pumpAndSettle();
      expect(find.text('Delete permanently…'), findsOneWidget);
      await tester.tap(find.text('Delete permanently…'));
      await tester.pumpAndSettle();

      expect(find.text('Delete "Mesa Coyotes" permanently?'), findsOneWidget);
      expect(
        find.textContaining(
          'It was never published, so nothing of it is on a server.',
        ),
        findsOneWidget,
        reason: 'the batch decision: the dialog says so in plain words',
      );
      expect(find.textContaining('cannot be undone'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => observations(container)), 1);
      expect(find.text('Mesa Coyotes'), findsOneWidget);

      await tester.tap(find.byTooltip('Trash actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently…'));
      await tester.pumpAndSettle();
      await tapAndWait(
        tester,
        find.widgetWithText(FilledButton, 'Delete permanently'),
        () => showing('deleted from this phone'),
      );
      expect(find.text('Mesa Coyotes'), findsNothing);
      expect(find.text('Trash'), findsNothing);
      expect(await tester.runAsync(() => deletedAt(container)), 'gone');
      expect(await tester.runAsync(() => observations(container)), 0);
    },
  );

  testWidgets(
    'WATCHED RED (item 2): a deletion not yet sent to the server sits in the '
    'Trash with one line saying so, and no separate section',
    (tester) async {
      late ProviderContainer container;
      await tester.runAsync(
        () async => container = await seed(
          undelivered: [
            UndeliveredProjectDeletion(
              projectId: 'project-9',
              projectName: 'Elk Study',
              deletedAt: DateTime.utc(2026, 10, 2, 15),
              refusal: null,
              held: null,
            ),
          ],
        ),
      );
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('Trash'), findsOneWidget);
      expect(find.text('Deleted here, not yet on the server'), findsNothing);
      expect(find.text('Elk Study'), findsOneWidget);
      expect(
        find.textContaining('Not sent to the server yet'),
        findsOneWidget,
      );
      final trashTop = tester.getTopLeft(find.text('Trash')).dy;
      expect(tester.getTopLeft(find.text('Elk Study')).dy,
          greaterThan(trashTop),
          reason: 'the row is under the Trash heading');
      expect(find.widgetWithText(FilledButton, 'Restore'), findsOneWidget,
          reason: 'the same undo as before, named the way every Trash row '
              'names it');
    },
  );
}
