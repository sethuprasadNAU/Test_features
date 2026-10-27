import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **A project the owner deleted in the app, which the server still holds,
/// can be reached and destroyed from the Projects screen** (task 11.292,
/// moved here from the join screen by task 11.313 — "nobody looks for a
/// deleted thing on a join screen").
///
/// Task 11.289 made a plain *Delete* reach the server as a tombstone; task
/// 11.290 built destruction; and between them a tombstoned project was on no
/// screen of any device, including its owner's, because `/projects/mine`
/// leaves it out. This asserts the section — now at the bottom of the
/// Projects screen, like a Trash folder — lists such a project with the date
/// it was deleted, that ⋮ → *Delete permanently…* opens the same dialog a
/// joinable row uses and sends the same request, that the countdown then
/// appears on the row, and that the section is absent when there is nothing
/// in it — and, when the server does not offer the list, says so without
/// guessing why (task 11.307).
///
/// This device holds no local projects of its own in every case here — the
/// screen's empty-projects state is exactly where an owner who deleted their
/// only project would meet this section, and it needs no database seeding
/// beyond the in-memory one every provider still expects.
void main() {
  setUp(installFakeSharedPreferences);

  const me = 'user-me';
  final deletedOn = DateTime.utc(2026, 9, 20, 9, 30);

  Future<({ProviderContainer container, FakeSyncTransport server})> seed({
    required List<DeletedProjectSummary> deleted,
    SyncTransportException? deletedListingFailure,
  }) async {
    final server = FakeSyncTransport()
      ..sessionUserId = me
      ..sessionEmail = '$me@x.com'
      ..serverDeletedProjects.addAll(deleted)
      ..deletedListingFailure = deletedListingFailure;
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        serverTransportProvider.overrideWith((ref) async => server),
        // This screen's own content — no local projects on this device, in
        // every case here. What is under test is the section at the bottom,
        // not the list above it.
        allProjectsProvider.overrideWith((ref) async => const []),
        ownedProjectIdsProvider.overrideWith((ref) async => const {}),
        departedProjectIdsProvider.overrideWith((ref) async => const {}),
        snapshotProjectIdsProvider.overrideWith((ref) async => const {}),
        unsyncedMemberProjectIdsProvider.overrideWith((ref) async => const {}),
        sessionStoreProvider.overrideWithValue(
          FakeSessionStore(
            StoredSession(
              token: 'not-a-real-token',
              userId: me,
              email: '$me@x.com',
              expiresAt: DateTime.now().add(const Duration(days: 30)),
            ),
          ),
        ),
      ],
    );
    await container.read(appDatabaseProvider.future);
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    container.listen(projectDeletionNoticesProvider, (_, _) {});
    await container.read(projectDeletionNoticesProvider.future);
    // `deletedOnServerListingProvider` gates on `currentSessionProvider`,
    // which is still `AsyncLoading` for a tick after the override above —
    // read to completion first, or the listing's own first read shortcuts to
    // "no session" and never gets the chance to notice one arrived.
    container.listen(currentSessionProvider, (_, _) {});
    await container.read(currentSessionProvider.future);
    container.listen(deletedOnServerListingProvider, (_, _) {});
    await container.read(deletedOnServerListingProvider.future);
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

  /// Re-reads the section after an action — every handler invalidates
  /// [deletedOnServerListingProvider] on its `finally`, and nothing on
  /// screen shows a spinner for that reload (the same non-blocking shape
  /// `notices` and `undelivered` already use on this screen), so there is no
  /// spinner to poll. Poll for [until] instead, bounded so a broken build
  /// goes red rather than hanging (task 11.209).
  Future<void> settleUntil(WidgetTester tester, bool Function() until) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!until()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the section never reached the expected state');
        }
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
  }

  const heading = 'Trash';

  testWidgets(
    'a deleted project is listed with its date, and its ⋮ schedules the '
    'same destruction a joinable row does',
    (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed(
          deleted: [
            DeletedProjectSummary(
              projectId: 'old-mac-project',
              projectName: 'Hihi 2024',
              deletedAt: deletedOn,
            ),
          ],
        );
        container = seeded.container;
        server = seeded.server;
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('No projects yet. Tap + to start one, or join a '
          'colleague\'s project below.'), findsOneWidget);
      expect(find.text(heading), findsOneWidget);
      expect(find.text('Hihi 2024'), findsOneWidget);
      expect(
        find.textContaining(
          'You moved it to the Trash on ${deletedOn.toLocal().toIso8601String().substring(0, 10)}',
        ),
        findsOneWidget,
      );

      // One ⋮ on screen: the deleted row's — there is no local project and
      // no joinable row here.
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await tester.ensureVisible(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Delete permanently…'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Delete permanently…'));
        await tester.pumpAndSettle();
      });
      expect(find.text('Delete "Hihi 2024" permanently?'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Schedule delete'));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (server.deletionRequests.isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      expect(server.deletionRequests, [
        ('old-mac-project', ProjectDeletionAction.schedule),
      ]);
      await settleUntil(
        tester,
        () => find
            .textContaining('Scheduled for deletion from the server on')
            .evaluate()
            .isNotEmpty,
      );
      // The section re-reads the directory and the row now carries the date
      // and offers the cancel instead.
      expect(
        find.textContaining('Scheduled for deletion from the server on'),
        findsOneWidget,
      );
      ScaffoldMessenger.of(
        tester.element(find.byType(ProjectsScreen)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Cancel scheduled deletion'), findsOneWidget);
      expect(find.text('Delete permanently…'), findsNothing);
    },
  );

  testWidgets('"delete now" removes the row from the section', (tester) async {
    late ProviderContainer container;
    late FakeSyncTransport server;
    await tester.runAsync(() async {
      final seeded = await seed(
        deleted: [
          DeletedProjectSummary(
            projectId: 'old-mac-project',
            projectName: 'Hihi 2024',
            deletedAt: deletedOn,
          ),
        ],
      );
      container = seeded.container;
      server = seeded.server;
    });
    addTearDown(container.dispose);
    await pump(tester, container);
    expect(find.text('Hihi 2024'), findsOneWidget);

    await tester.ensureVisible(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Delete permanently…'));
      await tester.pumpAndSettle();
    });
    await tester.runAsync(() async {
      await tester.tap(find.text('Delete immediately…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove now'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (server.deletionRequests.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    expect(server.deletionRequests, [
      ('old-mac-project', ProjectDeletionAction.immediate),
    ]);
    await settleUntil(tester, () => find.text('Hihi 2024').evaluate().isEmpty);
    expect(server.destroyedProjects, {'old-mac-project'});
    // Nothing left to list: the section goes with its last row.
    expect(find.text('Hihi 2024'), findsNothing);
    expect(find.text(heading), findsNothing);
  });

  testWidgets('with nothing deleted the section is absent', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = (await seed(deleted: const [])).container;
    });
    addTearDown(container.dispose);
    await pump(tester, container);
    expect(find.text(heading), findsNothing);
    // The absence is not an unrendered screen: nothing needs a ⋮ at all.
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets(
    'a 404 from the route says why the list is missing, names both causes, '
    'and shows no row and no control (task 11.307)',
    (tester) async {
      // Until task 11.307 this case left the section absent and said
      // nothing, and Michael spent four database queries establishing that
      // everything was correct before anybody asked whether the running
      // server had the route at all (it predated task 11.292). The shape the
      // real transport produces for shelf_router's "Route not found" is
      // pinned in `sync_transport_refusal_test.dart`; this is the same
      // exception built by hand.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = (await seed(
          deleted: const [],
          deletedListingFailure: const SyncTransportException(
            SyncTransportException.routeNotOffered,
            statusCode: 404,
          ),
        )).container;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      expect(find.text(heading), findsOneWidget);
      // Both causes, neither asserted — the app cannot tell an old build from
      // something in front of a current one answering for the path.
      expect(find.textContaining('older than this app'), findsOneWidget);
      expect(
        find.textContaining('between this device and the server'),
        findsOneWidget,
      );
      expect(find.textContaining('cannot tell which'), findsOneWidget);
      // Not a network problem, and not said as one.
      expect(find.textContaining('signal'), findsNothing);
      // No row and no control that cannot work.
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.textContaining('Its records are still held'), findsNothing);
    },
  );

  testWidgets(
    'any other failure is said in the section, without losing the rest of '
    'the screen',
    (tester) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = (await seed(
          deleted: const [],
          deletedListingFailure: const SyncTransportException(
            SyncTransportException.serverRejected,
            statusCode: 500,
          ),
        )).container;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      expect(find.text(heading), findsOneWidget);
      expect(
        find.textContaining('Could not load the projects you deleted'),
        findsOneWidget,
      );
    },
  );
}
