import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/join_project_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **A project that is not on this device can be deleted from the server**
/// (task 11.290, the fold-in Michael found on 2026-09-20).
///
/// The Projects list shows what the phone holds. The seven projects on his
/// server that were created on a device he no longer owns appear only here,
/// on the join screen, as things he could download — and until this, the
/// only way to delete one was to download it first. This asserts an owner
/// can schedule its destruction from its row here, that the countdown is
/// then shown on the same row, and that a non-owner gets no such control.
void main() {
  setUp(installFakeSharedPreferences);

  Future<({ProviderContainer container, FakeSyncTransport server})> seed({
    required String role,
  }) async {
    const me = 'user-me';
    final server = FakeSyncTransport()
      ..sessionUserId = me
      ..sessionEmail = '$me@x.com'
      ..serverProjects.add(
        ProjectSummary(
          projectId: 'old-phone-project',
          projectName: 'Hihi 2024',
          ownerUserId: role == ownerMembershipRole ? me : 'user-other',
          role: role,
        ),
      );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        serverTransportProvider.overrideWith((ref) async => server),
        joinRequestWatcherProvider.overrideWith(_QuietJoinRequestWatcher.new),
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
    return (container: container, server: server);
  }

  /// The list is a real `Future` over the fake transport, reached through
  /// providers whose continuations run only on a pump — so pump and wait
  /// until the spinner has gone, bounded so a broken build goes red rather
  /// than hanging (task 11.209's rule: a wait that can time out must fail
  /// when it does).
  Future<void> settleList(WidgetTester tester) async {
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the join list never finished loading');
        }
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: JoinProjectScreen()),
      ),
    );
    await settleList(tester);
  }

  testWidgets(
    'an owner schedules a project this device has never held, from its row',
    (tester) async {
      late ProviderContainer container;
      late FakeSyncTransport server;
      await tester.runAsync(() async {
        final seeded = await seed(role: ownerMembershipRole);
        container = seeded.container;
        server = seeded.server;
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      expect(find.text('Hihi 2024'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Join'), findsOneWidget);

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
      // The row re-reads the directory after the act.
      await settleList(tester);
      expect(server.deletionRequests, [
        ('old-phone-project', ProjectDeletionAction.schedule),
      ]);
      // The row re-reads the directory and shows the date, and the menu now
      // offers the cancel instead.
      expect(
        find.textContaining('Scheduled for deletion from the server on'),
        findsOneWidget,
      );
      // The success snackbar sits over the bottom of the screen for eight
      // seconds; dismiss it so the tap below lands on the row and not on it.
      ScaffoldMessenger.of(
        tester.element(find.byType(JoinProjectScreen)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Cancel scheduled deletion'), findsOneWidget);
      expect(find.text('Delete permanently…'), findsNothing);
    },
  );

  testWidgets('a member who is not an owner is offered no such menu', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = (await seed(role: 'contributor')).container;
    });
    addTearDown(container.dispose);
    await pump(tester, container);
    expect(find.text('Hihi 2024'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });
}

/// The join watcher reaches the server on its own schedule; not the subject
/// here, and its poll would keep the fake transport busy.
class _QuietJoinRequestWatcher extends JoinRequestWatcher {
  @override
  JoinWatch build() => const JoinWatch();

  @override
  Future<void> refresh() async {}
}
