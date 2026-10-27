import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/project_row_menu.dart';

/// **Task 11.28 part 4: the publish action has to say who is about to own the
/// project.**
///
/// Task 11.24 reproduced this live and Michael accepted the risk on
/// 2026-08-22 rather than making projects re-numberable: **if you hold a copy
/// of somebody else's project and you publish it before its real owner does,
/// you become its owner on the server and the real owner is locked out
/// permanently**, because a project's identifier is baked into every row and
/// cannot be renumbered.
///
/// For the malicious case that acceptance is right — the attacker must already
/// hold the project. **The condition attached to it is this dialog**, because
/// the likely path is an accident and the app sets it up: the share screen
/// suggests sending a project file by message or email, and the colleague who
/// receives it has a publish button. So the acceptance is only valid while the
/// publish action names the account that will become the owner and says
/// plainly when the project was imported rather than created here.
///
/// If these tests are ever deleted, the acceptance in
/// `CLAUDE_DOCS/PERMISSIONS_MATRIX.md` §7 goes with them.
Future<ProviderContainer> _seed({
  required String signedInAs,
  required String creator,
  String? creatorFirstName,
}) async {
  final project = sampleProject(id: 'project-1', ownerUserId: creator);
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      allProjectsProvider.overrideWith((ref) async => <Project>[project]),
      currentUserProvider.overrideWith(
        (ref) async => sampleUser(id: signedInAs, email: '$signedInAs@x.com'),
      ),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 'tok',
            userId: signedInAs,
            email: 'sam@example.com',
            expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
          ),
        ),
      ),
    ],
  );
  await container
      .read(serverConfigProvider.notifier)
      .setUrl('https://test.local');
  final db = (await container.read(appDatabaseProvider.future)).raw;
  for (final id in {signedInAs, creator}) {
    await db.insert(
      Tables.users,
      sampleUser(id: id, email: '$id@x.com')
          .copyWith(
            firstName: id == creator ? (creatorFirstName ?? 'Dana') : 'Sam',
          )
          .toColumns(),
    );
  }
  await db.insert(Tables.projects, project.toColumns());
  // The signed-in person owns it locally, which is what puts the Publish
  // button on the row at all. That is the *accident* case exactly: an imported
  // project whose local membership rows make you its owner here while its
  // recorded creator is somebody else.
  await db.insert(
    Tables.projectMemberships,
    ProjectMembership(
      membershipId: 'mem-1',
      projectId: 'project-1',
      userId: signedInAs,
      joinDate: DateTime.utc(2026, 8, 1),
      role: ProjectRole.owner,
      sync: sampleSync(),
    ).toColumns(),
  );
  container.listen(ownedProjectIdsProvider, (_, _) {});
  // Task 11.54 added a second database-backed set the row's controls read.
  container.listen(departedProjectIdsProvider, (_, _) {});
  // Task 11.237 added a third: the read-only snapshots, which the list
  // labels.
  container.listen(snapshotProjectIdsProvider, (_, _) {});
  // Task 11.238 added a fourth: an unlinked project this person is a member
  // of, which the list also labels.
  container.listen(unsyncedMemberProjectIdsProvider, (_, _) {});
  container.listen(currentSessionProvider, (_, _) {});
  container.listen(serverConfigProvider, (_, _) {});
  container.listen(isProjectLinkedProvider('project-1'), (_, _) {});
  container.listen(userRepositoryProvider, (_, _) {});
  await container.read(ownedProjectIdsProvider.future);
  await container.read(departedProjectIdsProvider.future);
  await container.read(snapshotProjectIdsProvider.future);
  await container.read(unsyncedMemberProjectIdsProvider.future);
  await container.read(currentSessionProvider.future);
  await container.read(serverConfigProvider.future);
  await container.read(userRepositoryProvider.future);
  // `_PublishButton` hides itself while this is unresolved (`?? true`), so an
  // unresolved read here would make every assertion below vacuous.
  expect(
    await container.read(isProjectLinkedProvider('project-1').future),
    isFalse,
  );
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ProjectsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps Publish and waits for the dialog.
///
/// Two-step because the confirmation reads the project's recorded creator out
/// of SQLite before it can name them, and real I/O only makes progress inside
/// [WidgetTester.runAsync] — a plain `pumpAndSettle` would time out on the
/// fake clock with the dialog never built.
Future<void> _openPublishDialog(WidgetTester tester) async {
  // **Task 11.99 turned the row's five bare icons into one labelled menu**, so
  // Publish is now chosen by its written name rather than by recognising a
  // cloud glyph. Asserted before tapping for the same reason as before: this
  // whole file is worthless if the affordance is not on screen at all.
  await openProjectMenu(tester);
  expect(
    find.text('Publish to server'),
    findsOneWidget,
    reason: 'the Publish affordance has to be on screen for this to test '
        'anything',
  );
  await tester.tap(find.text('Publish to server'));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
}

void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('publishing confirms, and names the account that becomes owner', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(signedInAs: 'user-me', creator: 'user-me');
    });
    addTearDown(container.dispose);

    await _pump(tester, container);
    await _openPublishDialog(tester);

    expect(find.text('Publish "Mesa Coyotes"?'), findsOneWidget);
    expect(
      find.textContaining('makes sam@example.com its owner'),
      findsOneWidget,
      reason: 'the address, not "you" — on a shared field laptop those differ',
    );
    expect(
      find.textContaining('whoever publishes it first'),
      findsOneWidget,
      reason: 'the permanence has to be stated, not implied',
    );
  });

  testWidgets('a project this account did not create is called out by name', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-me',
        creator: 'user-colleague',
        creatorFirstName: 'Dana',
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);
    await _openPublishDialog(tester);

    expect(
      find.textContaining('created by Dana Ranger, not by this account'),
      findsOneWidget,
    );
    expect(find.textContaining('locks Dana Ranger out of it'), findsOneWidget);
    expect(find.textContaining('Check with them first'), findsOneWidget);
  });

  testWidgets('a project this account created carries no warning', (
    tester,
  ) async {
    // The warning has to stay rare or it becomes wallpaper. Publishing your
    // own project — the ordinary case, and the one a field biologist does at
    // the start of every season — says who becomes the owner and stops there.
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(signedInAs: 'user-me', creator: 'user-me');
    });
    addTearDown(container.dispose);

    await _pump(tester, container);
    await _openPublishDialog(tester);

    expect(find.text('Publish "Mesa Coyotes"?'), findsOneWidget);
    expect(find.textContaining('not by this account'), findsNothing);
  });

  testWidgets('cancelling publishes nothing', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-me',
        creator: 'user-colleague',
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);
    await _openPublishDialog(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    // Still offering to publish, and no progress indicator — the action did
    // not start. (A real publish needs a transport this test has not given it,
    // so "did not start" is the only safe assertion here; the publish path
    // itself is covered by `project_publisher` tests.)
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      (await readProjectMenu(tester)).containsKey('Publish to server'),
      isTrue,
    );
  });
}
