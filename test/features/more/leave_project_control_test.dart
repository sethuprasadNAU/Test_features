import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/project_row_menu.dart';

/// **Task 11.28 part 1, at the screen: the control M8 said did not exist.**
///
/// `CLAUDE_DOCS/PERMISSIONS_MATRIX.md` M8 read *"Nothing implements it… There
/// is no control anywhere"*, and called it the most consequential entry in the
/// table. This file is the control, and the three things it has to get right:
///
/// 1. **It is there, and it works, for a contributor and for a viewer.**
/// 2. **It refuses the project's last owner, with the reason on the control**
///    rather than as a failure at the tap — task 11.12's rule, which exists
///    because a control that renders enabled and then throws is worse than one
///    that explains itself.
/// 3. **It confirms first**, and the confirmation says what leaving does not
///    do: nothing is deleted, here or on the server.
Future<ProviderContainer> _seed({
  required String signedInAs,
  required List<ProjectMembership> memberships,
  bool linked = true,
}) async {
  final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      allProjectsProvider.overrideWith((ref) async => <Project>[project]),
      currentUserProvider.overrideWith(
        (ref) async => sampleUser(id: signedInAs, email: '$signedInAs@x.com'),
      ),
    ],
  );
  final db = (await container.read(appDatabaseProvider.future)).raw;
  for (final id in {
    'user-owner',
    'user-second',
    'user-contributor',
    'user-viewer',
    signedInAs,
  }) {
    await db.insert(
      Tables.users,
      sampleUser(id: id, email: '$id@x.com').toColumns(),
    );
  }
  await db.insert(Tables.projects, project.toColumns());
  for (final membership in memberships) {
    await db.insert(Tables.projectMemberships, membership.toColumns());
  }
  if (linked) {
    // The real store rather than an override of `isProjectLinkedProvider`, so
    // the screen's own read is what is being exercised.
    await container.read(syncStateStoreProvider).markProjectLinked('project-1');
  }
  container.listen(ownedProjectIdsProvider, (_, _) {});
  // Task 11.54 added a second database-backed set the row's controls read.
  container.listen(departedProjectIdsProvider, (_, _) {});
  // Task 11.237 added a third: the read-only snapshots, which the list
  // labels.
  container.listen(snapshotProjectIdsProvider, (_, _) {});
  // Task 11.238 added a fourth: an unlinked project this person is a member
  // of, which the list also labels.
  container.listen(unsyncedMemberProjectIdsProvider, (_, _) {});
  container.listen(isProjectLinkedProvider('project-1'), (_, _) {});
  container.listen(leaveProjectVerdictForProvider('project-1'), (_, _) {});
  await container.read(ownedProjectIdsProvider.future);
  await container.read(departedProjectIdsProvider.future);
  await container.read(snapshotProjectIdsProvider.future);
  await container.read(unsyncedMemberProjectIdsProvider.future);
  await container.read(isProjectLinkedProvider('project-1').future);
  await container.read(leaveProjectVerdictForProvider('project-1').future);
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

/// **Task 11.99 moved this control into a labelled menu**, and the reason is
/// point 2 of that task rather than tidiness: leave and delete were two
/// unlabelled glyphs of the same size, one tap apart, and only one of them is
/// recoverable. Both now carry text, and delete sits below a divider of its
/// own. The three properties this file asserts are unchanged — the control is
/// there, it refuses the last owner *with the reason on it*, and it confirms
/// first — but the reason is now a second line on the item instead of tooltip
/// text, because a touchscreen never shows a tooltip.
Future<ProjectMenuItem?> _leave(WidgetTester tester) async =>
    (await readProjectMenu(tester))['Leave project'];

Future<DateTime?> _endDateOf(ProviderContainer container, String id) async {
  final db = (await container.read(appDatabaseProvider.future)).raw;
  final rows = await db.query(
    Tables.projectMemberships,
    where: 'membership_id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty
      ? null
      : ProjectMembership.fromRow(rows.first).endDate;
}

void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('a contributor is offered the control', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-contributor',
        memberships: [
          sampleMembership(userId: 'user-owner'),
          sampleMembership(
            id: 'membership-contributor',
            userId: 'user-contributor',
            role: ProjectRole.contributor,
          ),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect(await _leave(tester), (enabled: true, note: null));
  });

  testWidgets('a viewer is offered it too', (tester) async {
    // The rung the gap hurt most: a viewer writes nothing in a project, so
    // without a deliberate exception the person with the fewest rights is the
    // one person who can never get off it.
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-viewer',
        memberships: [
          sampleMembership(userId: 'user-owner'),
          sampleMembership(
            id: 'membership-viewer',
            userId: 'user-viewer',
            role: ProjectRole.viewer,
          ),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect((await _leave(tester))?.enabled, isTrue);
  });

  testWidgets('the last owner is refused, on the control', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-owner',
        memberships: [sampleMembership(userId: 'user-owner')],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    final refused = await _leave(tester);
    expect(refused?.enabled, isFalse);
    expect(
      refused?.note,
      contains("You are this project's last owner"),
      reason: 'the reason is on the item, where a phone can show it',
    );
  });

  testWidgets('a co-equal owner may leave', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-owner',
        memberships: [
          sampleMembership(userId: 'user-owner'),
          sampleMembership(id: 'membership-2', userId: 'user-second'),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect((await _leave(tester))?.enabled, isTrue);
  });

  testWidgets('a project that is not on a server has nothing to leave', (
    tester,
  ) async {
    // Not a permission hide. An unpublished project has no other members to be
    // a member alongside, so ending your own row would change nothing anybody
    // could observe. The button appears exactly where Publish disappears.
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-contributor',
        linked: false,
        memberships: [
          sampleMembership(userId: 'user-owner'),
          sampleMembership(
            id: 'membership-contributor',
            userId: 'user-contributor',
            role: ProjectRole.contributor,
          ),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect(
      await _leave(tester),
      isNull,
      reason: 'the item is absent, not merely disabled',
    );
  });

  testWidgets('leaving confirms first, and says nothing is deleted', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-contributor',
        memberships: [
          sampleMembership(userId: 'user-owner'),
          sampleMembership(
            id: 'membership-contributor',
            userId: 'user-contributor',
            role: ProjectRole.contributor,
          ),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);
    await tapProjectMenuItem(tester, 'Leave project');

    expect(find.text('Leave "Mesa Coyotes"?'), findsOneWidget);
    expect(
      find.textContaining('still attributed to you'),
      findsOneWidget,
      reason: 'leaving must not read as withdrawing your observations',
    );
    expect(find.textContaining('Nothing is deleted.'), findsOneWidget);

    // Cancel writes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(await _endDateOf(container, 'membership-contributor'), isNull);
    });
  });

  test('the controller ends the caller\'s own row and nobody else\'s', () async {
    // Driven through the controller rather than through a tap, because the
    // in-progress spinner is a continuous animation and `pumpAndSettle` never
    // returns while one is on screen. What the tap does beyond this is
    // covered above (it confirms, and Cancel writes nothing); what it does
    // *here* is exactly this call.
    //
    // Unlinked on purpose: a project that has never reached a server has
    // nobody to tell, so this isolates the write from the sync round trip.
    // `test/data/repositories/leave_project_test.dart` covers the write's own
    // rules, and `server/test/authz/leave_project_test.dart` covers what the
    // server does with the row.
    final container = await _seed(
      signedInAs: 'user-contributor',
      linked: false,
      memberships: [
        sampleMembership(userId: 'user-owner'),
        sampleMembership(
          id: 'membership-contributor',
          userId: 'user-contributor',
          role: ProjectRole.contributor,
        ),
        sampleMembership(
          id: 'membership-viewer',
          userId: 'user-viewer',
          role: ProjectRole.viewer,
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container
        .read(membershipControllerProvider.notifier)
        .leaveProject('project-1');

    expect(result.wasLinked, isFalse);
    expect(result.serverToldNow, isFalse);
    expect(await _endDateOf(container, 'membership-contributor'), isNotNull);
    expect(await _endDateOf(container, 'membership-1'), isNull);
    expect(await _endDateOf(container, 'membership-viewer'), isNull);
  });
}
