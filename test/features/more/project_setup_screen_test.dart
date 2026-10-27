import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/individuals_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/features/more/screens/project_setup_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.1 updated the ownership group below rather than bypassing it.**
/// Through Phase 8 these tests seeded a `Projects` row and let
/// `Projects.owner_user_id` decide; ownership is now the project's open
/// `owner` memberships, so they seed those instead and two new cases became
/// expressible — a co-equal second owner, and a creator who transferred the
/// project away and no longer owns it despite still being named in the column.
///
/// Widget-level coverage stays scoped to form behavior that doesn't require
/// a completed save round-trip. `sqflite_common_ffi` (used for the in-memory
/// test database) runs its worker on a background isolate, and waiting on
/// that isolate inside `testWidgets`' fake-async pump loop reliably hangs —
/// a real save-and-persist round trip is covered instead at the provider
/// level in `test/core/providers/app_context_provider_test.dart`, using a
/// plain `test()` where the real event loop runs normally.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('Save is disabled until a name is entered', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ProjectSetupScreen())),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'SAVE PROJECT'),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'Test Project',
    );
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'SAVE PROJECT'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'shows "New Project" when there is no active project to load',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: ProjectSetupScreen())),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'New Project'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Project Setup'), findsNothing);
    },
  );

  group('settings gated to the project owner (task 8.3)', () {
    testWidgets('a non-owner sees the explanation and cannot edit or save', (
      tester,
    ) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentProjectProvider.overrideWith((ref) async => project),
          currentUserProvider.overrideWith(
            (ref) async => sampleUser(id: 'user-other', email: 'other@x.com'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.users,
          sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-owner').toColumns(),
        );
        // `isProjectOwnerProvider` is DB-backed and so has to be pre-resolved
        // here too (task 11.1) — same reasoning as the tag providers below.
        // `listen` before `read` for the same reason `projectTagsProvider`
        // needs it: an `@riverpod`-generated provider is autoDispose, so a
        // bare `read` is thrown away the moment the widget tree watches it —
        // and this one gates a spinner, which `pumpAndSettle` never settles.
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
        // Pre-resolve, same reasoning as `log_screen_test.dart`: a tap-free
        // FutureProvider read is safe to await directly, but only inside
        // `runAsync`'s real zone — `_ProjectTagsSection`'s DB-backed
        // providers never resolve inside `pumpAndSettle`'s fake-async loop.
        // `projectTagsProvider` is `@riverpod`-generated and therefore
        // autoDispose, so a
        // bare `read` gets disposed and re-run the moment the widget tree
        // watches it — an explicit `listen` keeps it alive for the test.
        container.listen(projectTagsProvider(project.projectId), (_, _) {});
        await container.read(projectTagsProvider(project.projectId).future);
        // Task 11.241: the animals the tags are grouped under, pre-resolved
        // for the same reason as the tags.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        // Task 11.12: `_ProjectTagsSection` also gates on this — same
        // autoDispose caveat as above.
        container.listen(
          mayWriteProjectDataProvider(project.projectId),
          (_, _) {},
        );
        await container.read(
          mayWriteProjectDataProvider(project.projectId).future,
        );
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ProjectSetupScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Only a project owner can edit these settings'),
        findsOneWidget,
      );
      // Task 11.138: the pinned SAVE PROJECT button carries its own reason,
      // because it is still on screen after the banner above has scrolled
      // away. A different sentence, deliberately — two identical ones on one
      // screen read as a rendering bug.
      expect(
        find.text('Only a project owner can save changes here.'),
        findsOneWidget,
      );
      // Task 11.184: read-only, not disabled. Every value here is also
      // visible in the project list and, for tags, in the CSV export, so a
      // non-owner not being able to select or copy it off this screen was an
      // accident of the widget, not a decision. `enabled` stays true — the
      // field is not greyed — and `readOnly` is what actually stops editing.
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Name'),
      );
      expect(nameField.enabled, isTrue);
      expect(nameField.readOnly, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'SAVE PROJECT'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('the owner sees no explanation and can edit and save', (
      tester,
    ) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentProjectProvider.overrideWith((ref) async => project),
          currentUserProvider.overrideWith(
            (ref) async => sampleUser(id: 'user-owner', email: 'owner@x.com'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.users,
          sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-owner').toColumns(),
        );
        // `listen` before `read` for the same reason `projectTagsProvider`
        // needs it: an `@riverpod`-generated provider is autoDispose, so a
        // bare `read` is thrown away the moment the widget tree watches it —
        // and this one gates a spinner, which `pumpAndSettle` never settles.
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
        container.listen(projectTagsProvider(project.projectId), (_, _) {});
        await container.read(projectTagsProvider(project.projectId).future);
        // Task 11.241: the animals the tags are grouped under, pre-resolved
        // for the same reason as the tags.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        // Task 11.12: `_ProjectTagsSection` also gates on this — same
        // autoDispose caveat as above.
        container.listen(
          mayWriteProjectDataProvider(project.projectId),
          (_, _) {},
        );
        await container.read(
          mayWriteProjectDataProvider(project.projectId).future,
        );
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ProjectSetupScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Only a project owner can edit these settings'),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Name'))
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'SAVE PROJECT'),
            )
            .onPressed,
        isNotNull,
      );
      // Task 11.132: the title used to be computed from `_loadedProject`, a
      // field written mid-build inside `body`'s `data` branch — one build
      // too late to affect the `AppBar` built moments earlier in the same
      // `build`, so a loaded project rendered under "New Project" forever.
      expect(find.widgetWithText(AppBar, 'Project Setup'), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'New Project'), findsNothing);
    });

    testWidgets('a co-equal second owner edits and saves like the creator', (
      tester,
    ) async {
      // The case task 8.4's rule could not express at all: `owner_user_id`
      // names one person, so a second owner was invisible to it.
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentProjectProvider.overrideWith((ref) async => project),
          currentUserProvider.overrideWith(
            (ref) async => sampleUser(id: 'user-second', email: 'second@x.com'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.users,
          sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
        );
        await db.insert(
          Tables.users,
          sampleUser(id: 'user-second', email: 'second@x.com').toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-owner').toColumns(),
        );
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            id: 'membership-2',
            userId: 'user-second',
          ).toColumns(),
        );
        // `listen` before `read` for the same reason `projectTagsProvider`
        // needs it: an `@riverpod`-generated provider is autoDispose, so a
        // bare `read` is thrown away the moment the widget tree watches it —
        // and this one gates a spinner, which `pumpAndSettle` never settles.
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        await container.read(isProjectOwnerProvider(project.projectId).future);
        container.listen(projectTagsProvider(project.projectId), (_, _) {});
        await container.read(projectTagsProvider(project.projectId).future);
        // Task 11.241: the animals the tags are grouped under, pre-resolved
        // for the same reason as the tags.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        // Task 11.12: `_ProjectTagsSection` also gates on this — same
        // autoDispose caveat as above.
        container.listen(
          mayWriteProjectDataProvider(project.projectId),
          (_, _) {},
        );
        await container.read(
          mayWriteProjectDataProvider(project.projectId).future,
        );
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ProjectSetupScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Only a project owner can edit these settings'),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Name'))
            .enabled,
        isTrue,
      );
    });

    testWidgets(
      'a creator who transferred the project away can no longer edit it',
      (tester) async {
        // `owner_user_id` still names them — it is the creator/audit record and
        // 11.1 deliberately keeps it populated. It no longer authorizes, which
        // is the whole point: under Phase 8's rule this person would still hold
        // full settings access after handing the project on.
        final project = sampleProject(
          id: 'project-1',
          ownerUserId: 'user-owner',
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith(
              (ref) => AppDatabase.openInMemory(),
            ),
            currentProjectProvider.overrideWith((ref) async => project),
            currentUserProvider.overrideWith(
              (ref) async => sampleUser(id: 'user-owner', email: 'owner@x.com'),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(
            Tables.users,
            sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
          );
          await db.insert(
            Tables.users,
            sampleUser(id: 'user-successor', email: 'next@x.com').toColumns(),
          );
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(
              userId: 'user-owner',
              endDate: DateTime.utc(2026, 8, 17),
            ).toColumns(),
          );
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(
              id: 'membership-2',
              userId: 'user-successor',
            ).toColumns(),
          );
          // `listen` before `read` for the same reason `projectTagsProvider`
          // needs it: an `@riverpod`-generated provider is autoDispose, so a
          // bare `read` is thrown away the moment the widget tree watches it —
          // and this one gates a spinner, which `pumpAndSettle` never settles.
          container.listen(
            isProjectOwnerProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            isProjectOwnerProvider(project.projectId).future,
          );
          container.listen(
            projectTagsProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            projectTagsProvider(project.projectId).future,
          );
          // Task 11.241: the animals the tags are grouped under.
          container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
          await container.read(projectIndividualsProvider(project.projectId).future);
          // Task 11.243: the dated links, pre-resolved for the same reason.
          container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
          await container.read(projectDeploymentsProvider(project.projectId).future);
          // Task 11.12: `_ProjectTagsSection` also gates on this — same
          // autoDispose caveat as above.
          container.listen(
            mayWriteProjectDataProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            mayWriteProjectDataProvider(project.projectId).future,
          );
          });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ProjectSetupScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Only a project owner can edit these settings'),
          findsOneWidget,
        );
        // Task 11.184: read-only, not disabled — see the other non-owner
        // case above for the reasoning.
        final nameField = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Name'),
        );
        expect(nameField.enabled, isTrue);
        expect(nameField.readOnly, isTrue);
      },
    );
  });

  group('the roles-enforcement footnote is conditional on publication '
      '(task 11.211)', () {
    // Task 11.211: this used to say, unconditionally, "Roles/permissions
    // are device-local only in this release" — false for any project a
    // server knows about, since `_requireOwner` (server-side, §4.21) has
    // enforced roles there since join-and-approve shipped.
    testWidgets(
      'a project never published says nothing but this device enforces roles',
      (tester) async {
        // The footnote sits below the tags section, off the default 800x600
        // test surface's cache extent — same reasoning as the tags-section
        // group below.
        tester.view.physicalSize = const Size(1200, 2600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
            currentProjectProvider.overrideWith((ref) async => project),
            currentUserProvider.overrideWith(
              (ref) async => sampleUser(id: 'user-owner', email: 'owner@x.com'),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(
            Tables.users,
            sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
          );
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(userId: 'user-owner').toColumns(),
          );
          container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
          await container.read(isProjectOwnerProvider(project.projectId).future);
          container.listen(projectTagsProvider(project.projectId), (_, _) {});
          await container.read(projectTagsProvider(project.projectId).future);
          // Task 11.241: the animals the tags are grouped under, pre-resolved
          // for the same reason as the tags.
          container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
          await container.read(projectIndividualsProvider(project.projectId).future);
          // Task 11.243: the dated links, pre-resolved for the same reason.
          container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
          await container.read(projectDeploymentsProvider(project.projectId).future);
          container.listen(
            mayWriteProjectDataProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            mayWriteProjectDataProvider(project.projectId).future,
          );
            container.listen(isProjectLinkedProvider(project.projectId), (_, _) {});
          await container.read(isProjectLinkedProvider(project.projectId).future);
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ProjectSetupScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('nothing but this device enforces'),
          findsOneWidget,
        );
        expect(find.textContaining('device-local only'), findsNothing);
      },
    );

    testWidgets(
      'a published project says the server enforces roles, no matter the '
      'device',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
            currentProjectProvider.overrideWith((ref) async => project),
            currentUserProvider.overrideWith(
              (ref) async => sampleUser(id: 'user-owner', email: 'owner@x.com'),
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(
            Tables.users,
            sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
          );
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(userId: 'user-owner').toColumns(),
          );
          await SyncStateStore().markProjectLinked(project.projectId);
          container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
          await container.read(isProjectOwnerProvider(project.projectId).future);
          container.listen(projectTagsProvider(project.projectId), (_, _) {});
          await container.read(projectTagsProvider(project.projectId).future);
          // Task 11.241: the animals the tags are grouped under, pre-resolved
          // for the same reason as the tags.
          container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
          await container.read(projectIndividualsProvider(project.projectId).future);
          // Task 11.243: the dated links, pre-resolved for the same reason.
          container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
          await container.read(projectDeploymentsProvider(project.projectId).future);
          container.listen(
            mayWriteProjectDataProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            mayWriteProjectDataProvider(project.projectId).future,
          );
            container.listen(isProjectLinkedProvider(project.projectId), (_, _) {});
          await container.read(isProjectLinkedProvider(project.projectId).future);
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ProjectSetupScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('roles and permissions are enforced there, '
              'by the server'),
          findsOneWidget,
        );
        expect(find.textContaining('nothing but this device'), findsNothing);
      },
    );
  });

}
