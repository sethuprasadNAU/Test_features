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
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/sync/project_deletion_notice.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../data/sync/fake_sync_transport.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/roboto_font.dart';
import '../../support/text_scale_probe.dart';

/// **Task 11.323 item 5 — the Projects screen on the 6.1-inch iPhone.**
///
/// `/w-32`'s pictures on that phone showed two things no test had seen:
///
/// 1. **The owner's countdown cut off at "…or cancel f…"** — the words that
///    tell an owner they can stop the deletion were the ones lost.
/// 2. **The "+" over the last row** of *Trash* (then named *Deleted from your
///    devices, still on the server*), covering its ⋮ with nothing further to
///    scroll to.
///
/// Both are measured here **inside the real tab shell, in Roboto**, because
/// both are claims about what fits on a phone: a bare pump hands the screen
/// a navigation bar's worth of height it never has, and the test font is
/// about twice Roboto's width. **The second test passed in the test font
/// before the fix** — the wide font made the row tall enough to lift its
/// controls clear of the button — and went red only once Roboto was loaded
/// (defect vocabulary entry 21).
///
/// **Why the clipped-text sweep did not find the first**
/// (`clipped_text_sweep_test.dart`): its Projects fixture schedules no
/// deletion, so the countdown row was never on screen; and the sweep fails
/// only on a *silent* clip, while this sentence ended in an ellipsis, which
/// the sweep records but does not fail on. **Task 11.332 closed both**: the
/// sweep's Projects fixture now schedules a deletion, and a sentence cut short
/// by "…" fails it (watched red with this fix reverted).
void main() {
  setUp(installFakeSharedPreferences);
  setUpAll(loadRobotoFromSdkCache);

  const me = 'user-owner';

  Future<ProviderContainer> seed({
    List<Project> localProjects = const [],
    ProjectDeletionNotice? notice,
    List<DeletedProjectSummary> deleted = const [],
  }) async {
    final server = FakeSyncTransport()
      ..sessionUserId = me
      ..sessionEmail = '$me@x.com'
      ..serverDeletedProjects.addAll(deleted);
    for (final p in localProjects) {
      server.serverProjects.add(
        ProjectSummary(
          projectId: p.projectId,
          projectName: p.projectName,
          ownerUserId: me,
          role: ownerMembershipRole,
        ),
      );
    }
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        allProjectsProvider.overrideWith((ref) async => localProjects),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: me, email: '$me@x.com'),
        ),
        serverTransportProvider.overrideWith((ref) async => server),
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
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(Tables.users, sampleUser(id: me, email: '$me@x.com').toColumns());
    for (final p in localProjects) {
      await db.insert(Tables.projects, p.toColumns());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'm-${p.projectId}',
          projectId: p.projectId,
          userId: me,
        ).toColumns(),
      );
    }
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    final store = container.read(syncStateStoreProvider);
    for (final p in localProjects) {
      await store.markProjectLinked(p.projectId);
    }
    if (notice != null && localProjects.isNotEmpty) {
      await store.setDeletionNotice(localProjects.first.projectId, notice);
    }
    await container.read(deviceIdProvider.future);
    await container.read(syncControllerProvider.future);
    container
      ..listen(ownedProjectIdsProvider, (_, _) {})
      ..listen(departedProjectIdsProvider, (_, _) {})
      ..listen(snapshotProjectIdsProvider, (_, _) {})
      ..listen(unsyncedMemberProjectIdsProvider, (_, _) {})
      ..listen(projectDeletionNoticesProvider, (_, _) {})
      ..listen(undeliveredProjectDeletionsProvider, (_, _) {})
      ..listen(currentSessionProvider, (_, _) {})
      ..listen(deletedOnServerListingProvider, (_, _) {});
    await container.read(ownedProjectIdsProvider.future);
    await container.read(departedProjectIdsProvider.future);
    await container.read(snapshotProjectIdsProvider.future);
    await container.read(unsyncedMemberProjectIdsProvider.future);
    await container.read(projectDeletionNoticesProvider.future);
    await container.read(undeliveredProjectDeletionsProvider.future);
    // The listing gates on the session, so the session resolves first.
    await container.read(currentSessionProvider.future);
    await container.read(deletedOnServerListingProvider.future);
    return container;
  }

  testWidgets("the owner's countdown, and the description under it, are "
      'shown whole', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await seed(
        localProjects: [sampleProject(id: 'project-1', ownerUserId: me)],
        notice: ProjectDeletionNotice(
          destroyAt: DateTime.now().toUtc().add(
            const Duration(days: 27, hours: 3),
          ),
          learnedAt: DateTime.now().toUtc(),
        ),
      );
    });
    addTearDown(container.dispose);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ProjectsScreen(),
      tabIndex: 4,
    );

    expect(find.textContaining('or cancel from ⋮'), findsOneWidget);
    final cut = clippedTexts(tester)
        .where(
          (c) =>
              c.text.contains('Deletion from the server scheduled') ||
              c.text.contains('Winter range study'),
        )
        .toList();
    expect(cut, isEmpty, reason: 'cut off on the 6.1-inch phone: $cut');
  });

  testWidgets("the + does not cover the last deleted row's Restore or ⋮", (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await seed(
        localProjects: [
          for (var i = 0; i < 8; i++)
            sampleProject(
              id: 'local-$i',
              ownerUserId: me,
            ).copyWith(projectName: 'Local $i'),
        ],
        deleted: [
          DeletedProjectSummary(
            projectId: 'old-mac-project',
            projectName: 'Hihi 2024',
            deletedAt: DateTime.utc(2026, 9, 20, 9, 30),
          ),
        ],
      );
    });
    addTearDown(container.dispose);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ProjectsScreen(),
      tabIndex: 4,
    );
    expect(find.text('Hihi 2024', skipOffstage: false), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();

    final fab = tester.getRect(find.byType(FloatingActionButton));
    final restore = tester.getRect(
      find.widgetWithText(FilledButton, 'Restore'),
    );
    final menu = tester.getRect(find.byIcon(Icons.more_vert).last);
    expect(
      restore.overlaps(fab),
      isFalse,
      reason: 'Restore $restore is under the + $fab',
    );
    expect(menu.overlaps(fab), isFalse, reason: '⋮ $menu is under the + $fab');
  });
}
