import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/sync/project_deletion_notice.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/project_row_menu.dart';

/// **Destroying a project on a visible schedule, from the Projects list**
/// (task 11.290).
///
/// What a person sees and can do, per role, and what the two dialogs may
/// say. The mechanism underneath — the server's clock, the sweep, the
/// refusal a destroyed id draws — is asserted in the server suite and in
/// `project_deletion_provider_test.dart`; this file is about the screen.
///
/// Three claims per row are checked separately, because fixing one has not
/// fixed the others on this project before (CLAUDE.md, the Map's color): the
/// **sentence** under the name, the **menu** the row offers, and the
/// **tint** that marks it in a long list.
void main() {
  setUp(installFakeSharedPreferences);

  final destroyAt = DateTime.now().toUtc().add(
    const Duration(days: 27, hours: 3),
  );

  Future<({ProviderContainer container, FakeSyncTransport server})> seed({
    required String signedInAs,
    required List<ProjectMembership> memberships,
    required String roleOnServer,
    ProjectDeletionNotice? notice,
    bool linked = true,
  }) async {
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
    final server = FakeSyncTransport()
      ..sessionUserId = signedInAs
      ..sessionEmail = '$signedInAs@x.com'
      ..serverProjects.add(
        ProjectSummary(
          projectId: 'project-1',
          projectName: project.projectName,
          ownerUserId: 'user-owner',
          role: roleOnServer,
        ),
      );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        allProjectsProvider.overrideWith((ref) async => [project]),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: signedInAs, email: '$signedInAs@x.com'),
        ),
        serverTransportProvider.overrideWith((ref) async => server),
        sessionStoreProvider.overrideWithValue(
          FakeSessionStore(
            StoredSession(
              token: 'not-a-real-token',
              userId: signedInAs,
              email: '$signedInAs@x.com',
              expiresAt: DateTime.now().add(const Duration(days: 30)),
            ),
          ),
        ),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    for (final id in {'user-owner', 'user-member', signedInAs}) {
      await db.insert(
        Tables.users,
        sampleUser(id: id, email: '$id@x.com').toColumns(),
      );
    }
    await db.insert(Tables.projects, project.toColumns());
    for (final membership in memberships) {
      await db.insert(Tables.projectMemberships, membership.toColumns());
    }
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    final store = container.read(syncStateStoreProvider);
    if (linked) await store.markProjectLinked('project-1');
    if (notice != null) await store.setDeletionNotice('project-1', notice);
    await container.read(deviceIdProvider.future);
    await container.read(syncControllerProvider.future);
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
    return (container: container, server: server);
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

  /// The tile for project-1, so the tint can be read off it.
  ListTile projectTile(WidgetTester tester) => tester.widget<ListTile>(
    find.ancestor(
      of: find.text('Mesa Coyotes'),
      matching: find.byType(ListTile),
    ),
  );

  group('a scheduled deletion, seen by every member', () {
    testWidgets('the owner sees the countdown, and may cancel or export', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        final seeded = await seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
          roleOnServer: ownerMembershipRole,
          notice: ProjectDeletionNotice(
            destroyAt: destroyAt,
            learnedAt: DateTime.now().toUtc(),
          ),
        );
        container = seeded.container;
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      // The sentence: the count, the date, and the owner's way out.
      expect(find.textContaining('28 days left'), findsOneWidget);
      expect(find.textContaining('or cancel from ⋮'), findsOneWidget);
      // The tint.
      expect(
        projectTile(tester).tileColor,
        Theme.of(
          tester.element(find.byType(ProjectsScreen)),
        ).colorScheme.errorContainer,
      );
      // The menu.
      final menu = await readProjectMenu(tester);
      expect(menu['Cancel scheduled deletion']?.enabled, isTrue);
      expect(menu.containsKey('Export records'), isTrue);
      expect(menu.containsKey('Delete permanently…'), isFalse);
    });

    testWidgets('a contributor sees the same countdown and cannot cancel', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        final seeded = await seed(
          signedInAs: 'user-member',
          memberships: [
            sampleMembership(userId: 'user-owner'),
            sampleMembership(
              id: 'm-2',
              userId: 'user-member',
              role: ProjectRole.contributor,
            ),
          ],
          roleOnServer: 'contributor',
          notice: ProjectDeletionNotice(
            destroyAt: destroyAt,
            learnedAt: DateTime.now().toUtc(),
          ),
        );
        container = seeded.container;
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.textContaining('28 days left'), findsOneWidget);
      // Not offered a control they do not have.
      expect(find.textContaining('or cancel from ⋮'), findsNothing);
      expect(find.textContaining('Export from ⋮ before then.'), findsOneWidget);
      final menu = await readProjectMenu(tester);
      final cancel = menu['Cancel scheduled deletion'];
      expect(cancel, isNotNull, reason: 'explained, not hidden');
      expect(cancel!.enabled, isFalse);
      expect(cancel.note, 'Only a project owner can cancel it.');
      expect(menu.containsKey('Export records'), isTrue);
    });
  });

  group('the owner schedules, or deletes now', () {
    testWidgets(
      'scheduling sends the schedule action and starts the countdown',
      (tester) async {
        late ProviderContainer container;
        late FakeSyncTransport server;
        await tester.runAsync(() async {
          final seeded = await seed(
            signedInAs: 'user-owner',
            memberships: [sampleMembership(userId: 'user-owner')],
            roleOnServer: ownerMembershipRole,
          );
          container = seeded.container;
          server = seeded.server;
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        final menu = await readProjectMenu(tester);
        expect(menu['Delete permanently…']?.enabled, isTrue);

        await tester.runAsync(() async {
          await tapProjectMenuItem(tester, 'Delete permanently…');
          await tester.pumpAndSettle();
        });
        // The number in the dialog is the server's, not the app's.
        expect(find.textContaining('in 30 days'), findsOneWidget);
        expect(find.textContaining('You can cancel any time'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'Schedule delete'));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (server.deletionRequests.isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
        });
        expect(server.deletionRequests, [
          ('project-1', ProjectDeletionAction.schedule),
        ]);
        expect(find.textContaining('30 days left'), findsOneWidget);
        expect(
          find.textContaining('is scheduled for deletion'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '"delete now" sits behind a second confirmation whose words do not '
      'overclaim',
      (tester) async {
        late ProviderContainer container;
        late FakeSyncTransport server;
        await tester.runAsync(() async {
          final seeded = await seed(
            signedInAs: 'user-owner',
            memberships: [sampleMembership(userId: 'user-owner')],
            roleOnServer: ownerMembershipRole,
          );
          container = seeded.container;
          server = seeded.server;
          server.deletionBackupRetentionDays = 45;
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        await tester.runAsync(() async {
          await tapProjectMenuItem(tester, 'Delete permanently…');
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(TextButton, 'Delete immediately…'));
          await tester.pumpAndSettle();
        });
        // Nothing has been sent yet: the first dialog chose, the second
        // confirms.
        expect(server.deletionRequests, isEmpty);
        expect(
          find.text('Remove "Mesa Coyotes" from the server now?'),
          findsOneWidget,
        );
        final words = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join('\n');
        expect(
          words,
          contains('out of the server\'s backups within 45 days'),
          reason: 'the backup number is the server\'s, and it is said',
        );
        expect(
          words.toLowerCase(),
          isNot(contains('permanent')),
          reason:
              'the backups keep the project for weeks whatever the live '
              'server does, so "permanently" would be a claim the server '
              'cannot keep',
        );
        expect(words, contains('copy on their own device stays'));

        await tester.runAsync(() async {
          await tester.tap(find.widgetWithText(FilledButton, 'Remove now'));
          // The request, the notice write and the unlink are real async work
          // that schedules no frame; polled rather than a fixed wait, bounded
          // so a broken build goes red instead of hanging.
          // Pumped as well as waited: the providers the request goes through
          // schedule their continuations on this binding's clock, and only a
          // pump runs them (the trap task 11.289's test documents).
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!await container
                  .read(syncStateStoreProvider)
                  .deletionNotices()
                  .then((n) => n['project-1']?.executed ?? false) &&
              DateTime.now().isBefore(deadline)) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
        });
        expect(server.deletionRequests, [
          ('project-1', ProjectDeletionAction.immediate),
        ]);
        expect(server.destroyedProjects, {'project-1'});
        // The row now says what happened, and the records are still here.
        expect(
          find.textContaining('Deleted from the server on'),
          findsOneWidget,
        );
        expect(
          find.textContaining('records on this device are kept'),
          findsOneWidget,
        );
        expect(find.text('Mesa Coyotes'), findsOneWidget);
        // Unlinked, so nothing keeps offering rows to a refusal.
        expect(
          await container
              .read(syncStateStoreProvider)
              .isProjectLinked('project-1'),
          isFalse,
        );
      },
    );

    testWidgets('cancel from the dialog sends nothing', (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
          roleOnServer: ownerMembershipRole,
        );
        container = seeded.container;
        server = seeded.server;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      await tester.runAsync(() async {
        await tapProjectMenuItem(tester, 'Delete permanently…');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
      });
      expect(server.deletionRequests, isEmpty);
      expect(find.textContaining('days left'), findsNothing);
    });

    testWidgets(
      'a 404 from the deletion route names both causes and does not claim '
      'an old build (task 11.307)',
      (tester) async {
        // Task 11.290 wrote "it is running a build older than this app" for
        // this case — a cause asserted from a status code that has two. The
        // sentence now comes from `SyncTransportException.userMessage`, the
        // one place every screen reads a refusal from, and it names both.
        late ProviderContainer container;
        late FakeSyncTransport server;
        await tester.runAsync(() async {
          final seeded = await seed(
            signedInAs: 'user-owner',
            memberships: [sampleMembership(userId: 'user-owner')],
            roleOnServer: ownerMembershipRole,
          );
          container = seeded.container;
          server = seeded.server;
        });
        addTearDown(container.dispose);
        await pump(tester, container);
        // Set after the seed so the providers above loaded normally; from
        // here every route answers as shelf_router does for a path it has
        // no handler for.
        server.permanentFailure = const SyncTransportException(
          SyncTransportException.routeNotOffered,
          statusCode: 404,
        );
        await tester.runAsync(() async {
          await tapProjectMenuItem(tester, 'Delete permanently…');
          await tester.pumpAndSettle();
        });
        // No dialog: the numbers it would quote are the server's, and the
        // server did not answer with them.
        expect(find.textContaining('Schedule delete'), findsNothing);
        expect(server.deletionRequests, isEmpty);
        final words = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join('\n');
        expect(words, contains('older than this app'));
        expect(words, contains('between this device and the server'));
        expect(words, contains('cannot tell which'));
        expect(words, isNot(contains('it is running a build older')));
        expect(words, isNot(contains('signal')));
      },
    );

    testWidgets('a non-owner is told why the control is greyed', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        final seeded = await seed(
          signedInAs: 'user-member',
          memberships: [
            sampleMembership(userId: 'user-owner'),
            sampleMembership(
              id: 'm-2',
              userId: 'user-member',
              role: ProjectRole.contributor,
            ),
          ],
          roleOnServer: 'contributor',
        );
        container = seeded.container;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      final item = (await readProjectMenu(tester))['Delete permanently…'];
      expect(item, isNotNull);
      expect(item!.enabled, isFalse);
      expect(
        item.note,
        'Only a project owner can delete this project permanently.',
      );
    });
  });

  group('after the deletion has run', () {
    testWidgets(
      'a device that kept its records says why, and cannot republish the id',
      (tester) async {
        late ProviderContainer container;
        await tester.runAsync(() async {
          final seeded = await seed(
            signedInAs: 'user-owner',
            memberships: [sampleMembership(userId: 'user-owner')],
            roleOnServer: ownerMembershipRole,
            // What `markDestroyed` leaves: the notice executed, the project
            // unlinked.
            linked: false,
            notice: ProjectDeletionNotice(
              destroyAt: DateTime.utc(2026, 10, 20, 9),
              learnedAt: DateTime.utc(2026, 10, 21),
              executed: true,
            ),
          );
          container = seeded.container;
        });
        addTearDown(container.dispose);
        await pump(tester, container);

        expect(
          find.textContaining('Deleted from the server on 2026-10-2'),
          findsOneWidget,
        );
        expect(find.textContaining('export them from ⋮'), findsOneWidget);
        // Not also told to publish it — the id is retired.
        expect(find.textContaining('Not syncing yet'), findsNothing);
        final menu = await readProjectMenu(tester);
        final publish = menu['Publish to server'];
        expect(publish, isNotNull);
        expect(publish!.enabled, isFalse);
        expect(publish.note, contains('cannot be published again'));
        expect(menu.containsKey('Export records'), isTrue);
        expect(menu['Delete from this device']?.enabled, isTrue);
      },
    );

    testWidgets('a date that passed while offline is reported as unconfirmed', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        final seeded = await seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
          roleOnServer: ownerMembershipRole,
          notice: ProjectDeletionNotice(
            destroyAt: DateTime.now().toUtc().subtract(const Duration(days: 2)),
            learnedAt: DateTime.now().toUtc().subtract(const Duration(days: 9)),
          ),
        );
        container = seeded.container;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      expect(find.textContaining('that date has passed'), findsOneWidget);
      expect(
        find.textContaining('has not synced since to confirm'),
        findsOneWidget,
      );
      // Not claimed deleted: the server has not said so to this device.
      expect(find.textContaining('Deleted from the server on'), findsNothing);
    });
  });
}
