import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/project_row_menu.dart';

/// **Task 11.99, second finding: nothing on this screen said what it did.**
///
/// Every action on a project's row was a bare `IconButton` whose meaning lived
/// in a `tooltip`, and the one way into joining a project was a bare
/// `cloud_download` glyph in the app bar with the same treatment. **A
/// touchscreen never shows a tooltip.** On a phone — the device this app is
/// built for — a project's row was four or five unlabelled glyphs and the app
/// bar held a fifth, and the user guide had to describe the way in as *the
/// cloud icon at the top right* and hope.
///
/// Two of those glyphs were the part to take seriously. **Leave the project**
/// is recoverable: you ask again with the code, or an owner puts you back, and
/// your records stay in the project either way. **Delete the project** is the
/// most destructive thing on the screen. They were the same size, the same
/// weight, and one tap apart, with nothing on screen distinguishing them. That
/// is a data-loss shape, not a polish item.
///
/// So these cases assert three properties, and the third is the one a labels-
/// only fix would have quietly skipped:
///
/// 1. **Every action carries written text**, on every platform, with no hover.
/// 2. **A refused action says why, on the item** rather than in tooltip text —
///    which is task 11.12's *explain, don't hide* actually being obeyed on a
///    phone. (Asserted in `projects_screen_test.dart` and
///    `leave_project_control_test.dart`, where the gating rules live.)
/// 3. **Leave and delete are separated**, not merely labelled: delete is last,
///    below a divider of its own.
Future<ProviderContainer> _seed({
  required String signedInAs,
  required List<ProjectMembership> memberships,
  List<Project>? projects,
  bool linked = true,
  bool serverConfigured = true,
}) async {
  final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      allProjectsProvider.overrideWith(
        (ref) async => projects ?? <Project>[project],
      ),
      currentUserProvider.overrideWith(
        (ref) async => sampleUser(id: signedInAs, email: '$signedInAs@x.com'),
      ),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          serverConfigured
              ? StoredSession(
                  token: 'tok',
                  userId: signedInAs,
                  email: '$signedInAs@x.com',
                  expiresAt: DateTime.now().toUtc().add(
                    const Duration(days: 30),
                  ),
                )
              : null,
        ),
      ),
    ],
  );
  if (serverConfigured) {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://test.local');
  }
  final db = (await container.read(appDatabaseProvider.future)).raw;
  for (final id in {'user-owner', 'user-contributor', signedInAs}) {
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
    await container.read(syncStateStoreProvider).markProjectLinked('project-1');
  }
  // Every one of these is database- or platform-backed and the screen either
  // spins or renders a provisional answer until it resolves, which
  // `pumpAndSettle` would never settle.
  container.listen(ownedProjectIdsProvider, (_, _) {});
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
  container.listen(leaveProjectVerdictForProvider('project-1'), (_, _) {});
  await container.read(ownedProjectIdsProvider.future);
  await container.read(departedProjectIdsProvider.future);
  await container.read(snapshotProjectIdsProvider.future);
  await container.read(unsyncedMemberProjectIdsProvider.future);
  await container.read(currentSessionProvider.future);
  await container.read(serverConfigProvider.future);
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

void main() {
  setUp(installFakeSharedPreferences);

  group('leave and delete are no longer two unlabelled neighbours', () {
    testWidgets(
      'a member of a published project sees named actions, with delete last '
      'and separated',
      (tester) async {
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

        // The whole menu, in order, in one assertion — which pins the labels,
        // the order, and the separation together. A test that checked only
        // that the labels existed would pass with leave and delete adjacent,
        // which is the half of the finding that costs somebody their data.
        expect(await readProjectMenuOrder(tester), [
          'Members',
          'Edit project',
          'Start next season',
          projectMenuDivider,
          'Leave project',
          // Task 11.290: deleting the project from the server, on a
          // countdown every member sees. Its own divider, below Leave and
          // above the local delete — the two deletes are different acts and
          // neither may sit beside Leave.
          projectMenuDivider,
          'Delete permanently…',
          projectMenuDivider,
          'Move to Trash',
        ]);
      },
    );

    testWidgets(
      'an owner of an unpublished project is offered publish, and no leave',
      (tester) async {
        // Leave is absent rather than disabled, and that is not a permission
        // hide: a project not on a server has no other members to be a member
        // alongside, so ending your own row would change nothing anybody could
        // observe. It appears exactly where Publish disappears.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await _seed(
            signedInAs: 'user-owner',
            linked: false,
            memberships: [sampleMembership(userId: 'user-owner')],
          );
        });
        addTearDown(container.dispose);
        await _pump(tester, container);

        expect(await readProjectMenuOrder(tester), [
          'Publish to server',
          'Members',
          'Edit project',
          'Start next season',
          projectMenuDivider,
          'Move to Trash',
        ]);
      },
    );

    testWidgets(
      'a non-owner of an unpublished project is offered publish, explained '
      'rather than hidden',
      (tester) async {
        // Task 11.184: this item used to be removed outright for a non-owner
        // — the one entry in this menu that was still a hide rather than an
        // explanation. It is now shown greyed with its reason, the same as
        // every other refused entry here.
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

        expect((await readProjectMenu(tester))['Publish to server'], (
          enabled: false,
          note: 'Only a project owner can publish this project.',
        ));
      },
    );
  });

  group('the way to the members screen (task 11.99, first finding)', () {
    testWidgets('a contributor is offered it, and told what it holds', (
      tester,
    ) async {
      // **This is the route that did not exist.** It was rendered inside
      // `if (isOwner)`, so a contributor or a viewer had no way in the app to
      // find out what role they held or who else was on the project — and the
      // only place TriTrack named somebody's role to them was inside a refusal
      // message, after they had already been stopped.
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

      expect((await readProjectMenu(tester))['Members'], (
        enabled: true,
        note: 'Who is on the project, and what role you hold',
      ));
    });

    testWidgets('an owner is told what the same screen holds for them', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect((await readProjectMenu(tester))['Members'], (
        enabled: true,
        note: 'Who is on the project, the join code, and who is waiting',
      ));
    });
  });

  group('joining a project is labelled, not a glyph', () {
    testWidgets('the app bar carries no unlabelled action at all', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(IconButton),
        ),
        findsNothing,
        reason:
            'the cloud glyph in the app bar was the control the guide had to '
            'describe as "the cloud icon at the top right"',
      );
      expect(find.text('Join a project'), findsOneWidget);
      expect(
        find.textContaining('with the code they give you'),
        findsOneWidget,
        reason: 'a label alone does not say a code is what you need',
      );
    });

    testWidgets('it is on the empty state too, where a newcomer is looking', (
      tester,
    ) async {
      // Somebody handed a join code by a colleague has no projects. Before
      // this, the one screen they were looking at said only "Tap + to create
      // one" — the one route that was not theirs.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-newcomer',
          projects: const <Project>[],
          linked: false,
          memberships: const [],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.text('Join a project'), findsOneWidget);
      expect(find.textContaining('or join a colleague'), findsOneWidget);
    });

    testWidgets('and it is absent with no server configured', (tester) async {
      // Not a hide-the-control-you-may-not-use: with no server address and
      // nobody signed in there is no server to ask, so this offers nothing.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          serverConfigured: false,
          linked: false,
          memberships: [sampleMembership(userId: 'user-owner')],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.text('Join a project'), findsNothing);
    });
  });

  group('an adopted-but-unlinked project says so (task 11.238)', () {
    // `ImportCase.adopt` lands a project live and unlinked, and until this
    // task nothing on the list said why a week of new recordings had not
    // left the phone. The sentence lives on the same shelf the snapshot line
    // does, and is derived the same way: per read, from a role and a link
    // state, never stored.

    testWidgets('an owner of it is told, and told how to fix it', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          linked: false,
          memberships: [sampleMembership(userId: 'user-owner')],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(
        find.textContaining(notSyncingYetOwnerDescription),
        findsOneWidget,
      );
    });

    testWidgets(
      'a non-owner member of it is told, worded for somebody who cannot '
      'publish it themselves',
      (tester) async {
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
          find.textContaining(notSyncingYetMemberDescription),
          findsOneWidget,
        );
        expect(
          find.textContaining(notSyncingYetOwnerDescription),
          findsNothing,
        );
      },
    );

    testWidgets('a linked project says nothing about it', (tester) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          // `linked` defaults to true.
          memberships: [sampleMembership(userId: 'user-owner')],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.textContaining(notSyncingYetOwnerDescription), findsNothing);
      expect(find.textContaining(notSyncingYetMemberDescription), findsNothing);
    });

    testWidgets(
      'with no server configured, nothing is said — there is no step to '
      'name',
      (tester) async {
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await _seed(
            signedInAs: 'user-owner',
            serverConfigured: false,
            linked: false,
            memberships: [sampleMembership(userId: 'user-owner')],
          );
        });
        addTearDown(container.dispose);
        await _pump(tester, container);

        expect(
          find.textContaining(notSyncingYetOwnerDescription),
          findsNothing,
        );
      },
    );

    testWidgets(
      'it disappears on its own once the project links — derived per read, '
      'never stored',
      (tester) async {
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await _seed(
            signedInAs: 'user-owner',
            linked: false,
            memberships: [sampleMembership(userId: 'user-owner')],
          );
        });
        addTearDown(container.dispose);
        await _pump(tester, container);

        expect(
          find.textContaining(notSyncingYetOwnerDescription),
          findsOneWidget,
        );

        // The same event a real Publish or a real join triggers: the stored
        // link flips, and everything that reads it is invalidated rather
        // than re-derived by hand from a re-import.
        await tester.runAsync(
          () => container
              .read(syncStateStoreProvider)
              .markProjectLinked('project-1'),
        );
        container.invalidate(isProjectLinkedProvider('project-1'));
        container.invalidate(unsyncedMemberProjectIdsProvider);
        await tester.runAsync(
          () => container.read(unsyncedMemberProjectIdsProvider.future),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining(notSyncingYetOwnerDescription),
          findsNothing,
        );
      },
    );

    testWidgets('a snapshot holder never sees this line — they have no role', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-stranger',
          linked: false,
          memberships: [sampleMembership(userId: 'user-owner')],
        );
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      expect(find.textContaining(notSyncingYetOwnerDescription), findsNothing);
      expect(find.textContaining(notSyncingYetMemberDescription), findsNothing);
    });
  });
}
