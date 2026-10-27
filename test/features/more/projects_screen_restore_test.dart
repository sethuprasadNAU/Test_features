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
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **An owner restores a project they deleted, from the section task 11.292
/// built** (task 11.302), now at the bottom of the Projects screen rather
/// than the join screen (task 11.313).
///
/// The server half — who may, and what every device then receives — is
/// `server/test/integration/deleted_project_directory_test.dart`; what each
/// device does on its next sync is
/// `test/core/providers/restored_project_arrival_test.dart`. This is the
/// screen: the button is on the row, the confirmation says what will happen
/// to other people's phones (and that a scheduled deletion is withdrawn),
/// the request sent is `restore`, and **every refusal ends in a sentence a
/// person can act on** — above all the one the brief named: a project the
/// server already destroyed, said as such rather than discovered by tapping.
void main() {
  setUp(installFakeSharedPreferences);

  const me = 'user-me';
  const projectId = 'old-mac-project';
  final deletedOn = DateTime.utc(2026, 9, 20, 9, 30);
  const heading = 'Trash';

  Future<({ProviderContainer container, FakeSyncTransport server})> seed({
    /// Extra server setup — a schedule already in place, say — that must
    /// land before [deletedOnServerListingProvider]'s first read below, not
    /// after: unlike the old `_load()` this future provider is pre-resolved
    /// here rather than started fresh when the widget is pumped, so a caller
    /// that configured the server only after `seed()` returned would be
    /// seeding a state the first read had already missed.
    Future<void> Function(FakeSyncTransport server)? beforeLoad,
  }) async {
    final server = FakeSyncTransport()
      ..sessionUserId = me
      ..sessionEmail = '$me@x.com'
      ..serverDeletedProjects.add(
        DeletedProjectSummary(
          projectId: projectId,
          projectName: 'Hihi 2024',
          deletedAt: deletedOn,
        ),
      );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        serverTransportProvider.overrideWith((ref) async => server),
        // This device holds no local projects in every case here — what is
        // under test is the section at the bottom, not the list above it.
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
    await beforeLoad?.call(server);
    container.listen(projectDeletionNoticesProvider, (_, _) {});
    await container.read(projectDeletionNoticesProvider.future);
    // `deletedOnServerListingProvider` gates on `currentSessionProvider`,
    // which is still `AsyncLoading` for a tick after the override above —
    // read it to completion first, or the listing's own first read shortcuts
    // to "no session" and never gets the chance to notice one arrived.
    container.listen(currentSessionProvider, (_, _) {});
    await container.read(currentSessionProvider.future);
    container.listen(deletedOnServerListingProvider, (_, _) {});
    await container.read(deletedOnServerListingProvider.future);
    return (container: container, server: server);
  }

  /// In the tab shell at phone geometry, as the app shows it: the Restore
  /// button, the dialog and the sentences are all things a person has to be
  /// able to find and tap, so the screen gets the height it really has.
  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ProjectsScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
  }

  /// Nothing on screen shows a spinner while the section reloads (the same
  /// non-blocking shape `notices` and `undelivered` already use on this
  /// screen), so waits after an action poll for [until] rather than for a
  /// spinner's absence — bounded so a broken build goes red rather than
  /// hanging (task 11.209).
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

  /// Taps the row's Restore, then the dialog's confirm, and waits for the
  /// request to land.
  Future<void> restoreFromTheRow(
    WidgetTester tester,
    FakeSyncTransport server,
  ) async {
    final restore = find.widgetWithText(FilledButton, 'Restore');
    await tester.ensureVisible(restore);
    await tester.pumpAndSettle();
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(find.text('Restore "Hihi 2024"?'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Restore project'));
      // Waited for by a SnackBar actually rendering, not merely by the
      // request landing: `_restoreDeletedProject`'s `try` runs the request,
      // then (on the success path) a whole sync round, before it reaches
      // `messenger.showSnackBar` — stopping at the request left that tail
      // still in flight when a test ended, and Flutter reported the
      // SnackBar call landing on an already-torn-down tree in the *next*
      // test (task 11.209: a wait that can time out must fail when it does,
      // and this one was not waiting on the right thing).
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.byType(SnackBar).evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (find.byType(SnackBar).evaluate().isEmpty) {
        fail('restoring never produced a SnackBar');
      }
    });
    // Not `pumpAndSettle()` from here — the SnackBar carries a ten-second
    // duration and nothing here needs to wait it out. A caller whose
    // assertion depends on the section reloading (task 11.313's
    // `deletedOnServerListingProvider`, which shows no spinner of its own)
    // follows with `settleUntil` for that instead.
    await tester.pump();
  }

  testWidgets(
    'the row carries Restore; restoring asks first, sends restore, and the '
    'section clears once nothing this account deleted is left on the server',
    (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed();
        container = seeded.container;
        server = seeded.server;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      expect(find.text(heading), findsOneWidget);
      // Task 11.339 reworded the Trash's explanation (the heading now covers
      // this phone's own projects too); the server half still says it.
      expect(
        find.textContaining('restoring it brings it back for every member'),
        findsOneWidget,
      );

      // Backing out of the dialog sends nothing.
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('for every member'),
        findsWidgets,
        reason: 'the confirmation says the act reaches other people',
      );
      expect(find.textContaining('is canceled'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(server.deletionRequests, isEmpty);

      await restoreFromTheRow(tester, server);
      expect(server.deletionRequests, [
        (projectId, ProjectDeletionAction.restore),
      ]);
      // **Not "find it in the list above"** — that sentence pointed at the
      // joinable list on the join screen, and this screen is not that screen
      // any more (task 11.313). This device holds no copy, so the way back
      // in is named instead: the "Join a project" tile, on this same screen.
      await settleUntil(
        tester,
        () => find
            .textContaining(
              '"Hihi 2024" is restored on the server, for every member. To '
              'have it on this device too, use "Join a project" above.',
            )
            .evaluate()
            .isNotEmpty,
      );
      // Gone from the deleted section — which goes with its last row. This
      // screen shows only local projects and this device holds no copy, so
      // there is nothing further to find here; "Join a project" is where a
      // person would bring it down.
      expect(find.text(heading), findsNothing);
    },
  );

  testWidgets(
    'a scheduled deletion is named in the confirmation as withdrawn',
    (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed(
          beforeLoad: (server) async {
            await server.setProjectDeletion(
              projectId,
              ProjectDeletionAction.schedule,
            );
            server.deletionRequests.clear();
          },
        );
        container = seeded.container;
        server = seeded.server;
      });
      addTearDown(container.dispose);
      await pump(tester, container);
      expect(
        find.textContaining('Scheduled for deletion from the server on'),
        findsOneWidget,
      );

      await restoreFromTheRow(tester, server);
      expect(server.scheduledDeletions, isNot(contains(projectId)));
    },
  );

  testWidgets(
    'a project the server already destroyed is said to be gone — asked of '
    'pull, because the restore route answers it like any refusal',
    (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed();
        container = seeded.container;
        server = seeded.server;
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      // The sweep runs between the list being drawn and the tap. The fake's
      // deletion route then refuses the id like any other it cannot act on.
      server.destroyProject(projectId);
      await restoreFromTheRow(tester, server);

      expect(
        find.text(
          '"Hihi 2024" was already deleted from the server, so there is '
          'nothing there to restore. Nothing has changed on this device.',
        ),
        findsOneWidget,
      );
      await settleUntil(tester, () => find.text(heading).evaluate().isEmpty);
      expect(find.text(heading), findsNothing);
    },
  );

  testWidgets('a refusal that is not a destroyed project says which it is', (
    tester,
  ) async {
    late ProviderContainer container;
    late FakeSyncTransport server;
    await tester.runAsync(() async {
      final seeded = await seed();
      container = seeded.container;
      server = seeded.server
        ..deletionActionFailure = const SyncTransportException(
          'forbidden',
          statusCode: 403,
        );
    });
    addTearDown(container.dispose);
    await pump(tester, container);

    await restoreFromTheRow(tester, server);
    expect(
      find.textContaining('it no longer records this account as the owner '
          'who deleted it. Nothing has changed.'),
      findsOneWidget,
    );
    expect(find.textContaining('already deleted'), findsNothing);
  });

  testWidgets(
    'a server from before restoring existed is named as a possibility, not '
    'asserted',
    (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed();
        container = seeded.container;
        server = seeded.server
          ..deletionActionFailure = const SyncTransportException(
            'malformed_body',
            statusCode: 400,
          );
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      await restoreFromTheRow(tester, server);
      expect(
        find.textContaining('it may be running a build from before restoring '
            'existed'),
        findsOneWidget,
      );
      // Nothing changed: the row is still there to try again.
      expect(find.text(heading), findsOneWidget);
    },
  );
}
