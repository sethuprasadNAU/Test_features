import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/features/more/screens/members_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **More → Members, a second door to `ProjectMembersScreen` for the open
/// project** (task 11.313) — the same shape `animals_screen.dart` already
/// has: a thin wrapper that resolves [currentProjectProvider] and either
/// says there is no open project or hands off entirely.
///
/// Everything the destination screen does with a role — who sees the join
/// code, who can change a role — is `project_members_screen_test.dart`'s to
/// assert; this file only has to show the hand-off actually happens and that
/// the no-project state reads the way `animals_screen.dart`'s does.
void main() {
  setUp(installFakeSharedPreferences);

  const projectId = 'project-1';
  const owner = 'user-owner';

  Future<ProviderContainer> seed({required Project? project}) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentProjectProvider.overrideWith((ref) async => project),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: owner, email: '$owner@x.com'),
        ),
        // The join code and the pending list are the two things on the
        // destination screen that need a server — not the subject here, and
        // left unset they retry against a server that was never configured.
        if (project != null) ...[
          projectJoinSettingsProvider(projectId).overrideWith(
            (ref) async => const JoinSettings(
              projectId: projectId,
              joiningEnabled: false,
              teamSizeLimit: 50,
              memberCount: 1,
              pendingCount: 0,
            ),
          ),
          projectJoinRequestsProvider(
            projectId,
          ).overrideWith((ref) async => const []),
        ],
      ],
    );
    if (project != null) {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(
        Tables.users,
        sampleUser(id: owner, email: '$owner@x.com').toColumns(),
      );
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(
        Tables.projectMemberships,
        ProjectMembership(
          membershipId: 'membership-owner',
          projectId: projectId,
          userId: owner,
          joinDate: DateTime.utc(2026, 8, 1),
          role: ProjectRole.owner,
          sync: SyncMeta.initial(
            now: DateTime.utc(2026, 8, 1),
            modifiedBy: owner,
          ),
        ).toColumns(),
      );
      container.listen(isProjectOwnerProvider(projectId), (_, _) {});
      container.listen(projectMembershipsProvider(projectId), (_, _) {});
      container.listen(myProjectStandingProvider(projectId), (_, _) {});
      await container.read(isProjectOwnerProvider(projectId).future);
      await container.read(projectMembershipsProvider(projectId).future);
      await container.read(myProjectStandingProvider(projectId).future);
    }
    return container;
  }

  Future<void> pump(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MembersScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with no open project, says so and names where to pick one', (
    tester,
  ) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await seed(project: null);
    });
    addTearDown(container.dispose);
    await pump(tester, container);

    expect(find.text('Members'), findsOneWidget, reason: 'the app bar title');
    expect(
      find.textContaining('No project is active. Choose one under More → '
          'Projects'),
      findsOneWidget,
    );
  });

  testWidgets(
    'with an open project, hands off to the same screen the project row '
    'reaches',
    (tester) async {
      final project = sampleProject(id: projectId, ownerUserId: owner);
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await seed(project: project);
      });
      addTearDown(container.dispose);
      await pump(tester, container);

      // `_YourRoleCard` and the current-members section — the destination
      // screen's own furniture, reached without a projectId in the route.
      expect(find.text('Your role'), findsOneWidget);
      expect(find.text('Current members'), findsOneWidget);
      expect(
        find.text('No project is active. Choose one under More → Projects, '
            'and who is on it is listed here.'),
        findsNothing,
      );
    },
  );
}
