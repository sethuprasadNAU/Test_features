import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/errors/guarded_write.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../support/app_shell_harness.dart';
import '../support/fake_path_provider.dart';
import '../support/fake_shared_preferences.dart';

/// **Task 11.137 — the taps that did nothing at all.**
///
/// Task 11.94's sweep counted thirteen UI-facing call sites in `lib/` that
/// awaited a write with no `try`/`catch` of any kind. A refused delete, save,
/// share, supersede, exclude or export produced **no message, no dialog, and no
/// stopped spinner** — which on a phone is indistinguishable from a tap that
/// never registered, and a tap that appears not to have registered gets
/// repeated rather than reported.
///
/// All thirteen now go through [runGuardedWrite]. This file is the render proof
/// for one of them, at 6.1-inch phone geometry inside the real app shell, per
/// task 11.126: a message that exists and does not fit is the defect that
/// survived every previous sweep, and a message nobody has ever rendered is a
/// sentence nobody has checked.
///
/// ## Why the Log's delete, of the thirteen
///
/// It is the site with the least excuse and the clearest consequence: it is
/// destructive, it is offered to everybody, and it is reachable in two lines
/// from the tab bar. It also drives **both** branches of the mechanism from one
/// screen, which is the property the acceptance turns on — a permission refusal
/// and a device fault must not read as the same event.
///
/// ## How each branch is reached, and why neither is a shortcut
///
/// - **Refused.** The row's Delete is enabled because the observation was
///   Bob's when the screen rendered. The database then records it as Alice's,
///   which is the documented race in miniature — the screen's pre-check
///   resolved under one answer and the write asks under another. The repository
///   re-reads the row it is about to tombstone (see `BaseRepository._authorize`)
///   and refuses. Nothing here reaches around the production path: the refusal
///   is thrown by the same code a real role change would throw it from.
/// - **Failed.** The database is closed under the running screen. That is a
///   real fault of exactly the shape [runGuardedWrite]'s second branch exists
///   for — the write was permitted and the device could not carry it out — and
///   it must not be reported as a permission problem, because telling somebody
///   to ask their project owner about a broken disk sends them to a person who
///   cannot help.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  /// Bob, Alice, one project, one tag, and one observation Bob recorded.
  Future<ProviderContainer> seed(WidgetTester tester) async {
    final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');
    final alice = sampleUser(id: 'user-alice', email: 'alice@example.com');
    final project = sampleProject(id: 'project-1', ownerUserId: bob.userId);
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
      await db.insert(Tables.users, alice.toColumns());
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(Tables.tags, tag.toColumns());
      await db.insert(Tables.observations, own.toColumns());
      await container.read(historyDataProvider(project.projectId).future);
      // `@riverpod`-generated and therefore autoDispose: a bare read is thrown
      // away the instant the tree watches it, so listen first.
      container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
      await container.read(mayWriteProjectDataProvider(project.projectId).future);
    });
    return container;
  }

  /// Opens the row's ⋯ menu, taps Delete, and confirms — the whole of what a
  /// person does. Every step is inside `runAsync`: the write is a real SQLite
  /// round trip, which does not complete under the fake clock.
  Future<void> tapDeleteAndConfirm(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Observation actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete observation…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
      'a delete the repository refuses says who may do it — it does not look '
      'like a tap that missed', (tester) async {
    final container = await seed(tester);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const LogScreen(),
      tabIndex: 3,
    );

    // The row rendered while it was Bob's; the stored row is Alice's by the
    // time he confirms. Same sequence as a role changing underneath somebody.
    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.update(
        Tables.observations,
        {'user_id': 'user-alice'},
        where: 'observation_id = ?',
        whereArgs: ['obs-own'],
      );
    });

    await tapDeleteAndConfirm(tester);

    expect(find.byKey(writeRefusedKey), findsOneWidget,
        reason: 'the refusal is reported as a refusal, not as a fault');
    expect(find.byKey(writeFailedKey), findsNothing);
    expect(
      find.textContaining('You can only delete an observation you recorded '
          'yourself'),
      findsOneWidget,
    );
    // The honest-default rule: a refusal ends in something the person can do.
    expect(
      find.textContaining('a project owner can take it out of estimates'),
      findsOneWidget,
    );
    // It fits. The whole point of rendering it at 393×852 rather than on the
    // generous surface most of this project's widget tests use.
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a delete the device cannot carry out says so, and does not blame a '
      'permission', (tester) async {
    final container = await seed(tester);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const LogScreen(),
      tabIndex: 3,
    );

    // Bob is permitted. The device is what fails.
    await tester.runAsync(() async {
      await (await container.read(appDatabaseProvider.future)).raw.close();
    });

    await tapDeleteAndConfirm(tester);

    expect(find.byKey(writeFailedKey), findsOneWidget);
    expect(find.byKey(writeRefusedKey), findsNothing,
        reason: 'a broken database is not a permission problem, and telling '
            'somebody to ask their project owner about one sends them to a '
            'person who cannot help');
    expect(
      find.textContaining('Could not delete this observation'),
      findsOneWidget,
    );
    // No class name, no SQL, no bound values: `describeFailure`'s bar.
    expect(find.textContaining('DatabaseException'), findsNothing);
    expect(find.textContaining('obs-own'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
