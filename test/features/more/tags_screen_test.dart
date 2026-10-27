import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/individuals_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/tag_view_refresh.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/tags_screen.dart';
import 'package:tritrack/widgets/tag_form.dart' show TagListRow;
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/tag_version_history.dart';
import '../../support/fake_shared_preferences.dart';

/// **This project's tags — moved off Project Setup by task 11.245.**
///
/// This file is the tag-behaviour coverage that used to live in
/// `project_setup_screen_test.dart` (gating, editing, unlinking, the tag
/// arriving off-screen without a restart), carried over onto `TagsScreen`
/// unchanged in substance — the widget under test moved, the tag rules did
/// not. The grouping-by-animal coverage that used to sit beside it
/// (`project_animals_section_test.dart`) is gone with the grouping itself
/// (design §3a): `More → Animals` and `animal_detail_screen_test.dart` are
/// where linking, merging and viewing an animal are proven now.
void main() {
  setUp(installFakeSharedPreferences);

  group('the project-tags section is gated to "may write" (task 11.12), '
      'separately from the owner-only settings gate above', () {
    testWidgets(
      'a viewer sees the tag-linking controls disabled, with a reason',
      (tester) async {
        // The tags section sits below the name/description/notes/coordinate/
        // extent fields — off the default 800x600 test surface's cache extent,
        // so its buttons never get an Element unless the surface is tall
        // enough to include them.
        tester.view.physicalSize = const Size(1200, 2600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

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
              (ref) async =>
                  sampleUser(id: 'user-viewer', email: 'viewer@x.com'),
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
            sampleUser(id: 'user-viewer', email: 'viewer@x.com').toColumns(),
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
              userId: 'user-viewer',
              role: ProjectRole.viewer,
            ).toColumns(),
          );
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
            child: const MaterialApp(home: TagsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Viewers cannot change a project\'s tags'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Copy from library'),
              )
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets('a contributor (not an owner) can still use them', (
      tester,
    ) async {
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
            (ref) async =>
                sampleUser(id: 'user-contributor', email: 'contributor@x.com'),
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
          sampleUser(
            id: 'user-contributor',
            email: 'contributor@x.com',
          ).toColumns(),
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
            userId: 'user-contributor',
            role: ProjectRole.contributor,
          ).toColumns(),
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
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Viewers cannot change a project\'s tags'),
        findsNothing,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Copy from library'),
            )
            .onPressed,
        isNotNull,
      );
    });

    testWidgets(
      '[Task 11.218] "Link existing tag" does not offer a tag the server '
      'will refuse — one already claimed by another project — but still '
      'offers an unlinked (orphan) one',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final project = sampleProject(
          id: 'project-1',
          ownerUserId: 'user-owner',
        );
        final otherProject = sampleProject(
          id: 'project-2',
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
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(Tables.projects, otherProject.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(userId: 'user-owner').toColumns(),
          );
          // **Task 11.218's finding, and how task 11.219 answered it.**
          // 11.218 stopped the dialog offering a tag another project had
          // claimed, because the server had refused that link since task
          // 11.3 and the row was held forever with no reason it could give.
          // Copy-on-add removes the case rather than the offer: the dialog
          // offers **library entries**, and taking one writes this
          // project's own copy — a collar two projects hold is two rows now,
          // which is the whole design.
          //
          // What is still refused is offering the *same collar twice to one
          // project*: two copies of one lineage inside a project is a real
          // defect with no legitimate use (§2.6).
          final library =
              await container.read(tagLibraryRepositoryProvider.future);
          await library.insert(
            sampleTagLibraryEntry(
              id: 'lib-held',
              lineageId: 'lineage-held',
              tagName: 'Claimed',
            ),
          );
          await library.insert(
            sampleTagLibraryEntry(
              id: 'lib-free',
              lineageId: 'lineage-free',
              tagName: 'Orphan',
            ),
          );
          // This project already holds a copy of the first collar.
          await db.insert(
            Tables.tags,
            sampleTag(
              id: 'tag-held-here',
              projectId: project.projectId,
              lineageId: 'lineage-held',
              tagName: 'Claimed',
            ).toColumns(),
          );
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
            child: const MaterialApp(home: TagsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Reading the library is a real DB read triggered fresh by the tap,
        // not a pre-warmed provider — same reason every other real-write tap
        // in this file goes through `runAsync`.
        await tester.runAsync(() async {
          await tester.tap(
            find.widgetWithText(OutlinedButton, 'Copy from library'),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        // The row already on the project is still on the list behind the
        // dialog; what must not appear is a *second* offer of that collar.
        expect(
          find.descendant(
            of: find.byType(SimpleDialogOption),
            matching: find.textContaining('Claimed'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(SimpleDialogOption),
            matching: find.textContaining('Orphan'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('unlinking a tag is owner-only even for a contributor who may '
        'otherwise write (decision 2026-08-21)', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final tag = sampleTag(id: 'tag-1');
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentProjectProvider.overrideWith((ref) async => project),
          currentUserProvider.overrideWith(
            (ref) async =>
                sampleUser(id: 'user-contributor', email: 'contributor@x.com'),
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
          sampleUser(
            id: 'user-contributor',
            email: 'contributor@x.com',
          ).toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.tags, tag.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-owner').toColumns(),
        );
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            id: 'membership-2',
            userId: 'user-contributor',
            role: ProjectRole.contributor,
          ).toColumns(),
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
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // A contributor may write generally (no "Viewers cannot..." banner,
      // and "Copy from library" stays enabled) but unlinking is a stricter,
      // separate rung.
      expect(
        find.textContaining('Viewers cannot change a project\'s tags'),
        findsNothing,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.link_off),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      // Task 11.138: the icon's tooltip is its *label* again, always, and the
      // reason is one line under the section rather than one tooltip per tag
      // row that a phone cannot open.
      expect(find.byTooltip('Remove from project'), findsOneWidget);
      expect(
        find.text(
          'You can copy tags into this project. Only a project owner can '
          'change one the project already has, or remove or restore it.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an owner can unlink a tag', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      final tag = sampleTag(id: 'tag-1');
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
        await db.insert(Tables.tags, tag.toColumns());
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
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byIcon(Icons.link_off),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNotNull,
      );

      // **Task 11.321: the same row as the Tag Library.** Michael: "shouldn't
      // the format of the tag list in the project tag list be the same as
      // the nice formatting/size you did for the tag library?" It was the
      // default ListTile title (about 16 points) in an outlined box.
      final line = find.text('150.325 MHz · Coco');
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).style!.fontSize, 18,
          reason: 'the Tag Library\'s 18-point line');
      expect(
        find.ancestor(of: line, matching: find.byType(TagListRow)),
        findsOneWidget,
        reason: 'one row widget for a tag, wherever it is listed',
      );
    });

    /// **Task 11.221.** "Add back" on a removed tag was gated on `mayWrite`
    /// while the server, since task 11.219, refuses every change to an
    /// existing tag from a non-owner — so a contributor pressed it, the row
    /// came back on their phone, and the next push was refused. Michael
    /// confirmed owner-only as the rule on 2026-09-10. The button now greys
    /// for a contributor and the reason is the section's one sentence.
    for (final (role, enabled) in [
      (ProjectRole.contributor, false),
      (ProjectRole.owner, true),
    ]) {
      testWidgets(
          '"Add back" on a removed tag is '
          '${enabled ? "enabled" : "disabled"} for ${role == ProjectRole.owner ? "an owner" : "a contributor"} (task 11.221)',
          (tester) async {
        tester.view.physicalSize = const Size(1200, 2600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final project =
            sampleProject(id: 'project-1', ownerUserId: 'user-owner');
        // Stamped by the owner: the tag is inserted through the repository
        // below, which since task 11.237 refuses a stamp that is not on the
        // project.
        final tag = sampleTag(id: 'tag-1', modifiedBy: 'user-owner');
        final me = sampleUser(id: 'user-me', email: 'me@x.com');
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider
                .overrideWith((ref) => AppDatabase.openInMemory()),
            currentProjectProvider.overrideWith((ref) async => project),
            currentUserProvider.overrideWith((ref) async => me),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(
            Tables.users,
            sampleUser(id: 'user-owner', email: 'owner@x.com').toColumns(),
          );
          await db.insert(Tables.users, me.toColumns());
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(userId: 'user-owner').toColumns(),
          );
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(id: 'membership-2', userId: 'user-me', role: role)
                .toColumns(),
          );
          final tags = await container.read(tagRepositoryProvider.future);
          await tags.insert(tag);
          // Removed by the owner: since task 11.219 that is a tombstone on
          // the project's own tag row, which is what "Add back" clears.
          await tags.removeFromProject(
            'tag-1',
            projectId: project.projectId,
            actor: const MutationActor.user('user-owner'),
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
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: TagsScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Removed from this project'), findsOneWidget);
        final button = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Add back'),
        );
        expect(button.onPressed, enabled ? isNotNull : isNull);
        // The reason is the section's sentence, not a per-row note (task
        // 11.138), and it is there exactly when the button is greyed.
        expect(
          find.textContaining('Only a project owner can change one'),
          enabled ? findsNothing : findsOneWidget,
        );
      });
    }
  });

  /// **Task 11.151.** A tag added to this project *from somewhere else* —
  /// the Tag Database screen's "Also add to project" dropdown (renamed by
  /// task 11.234; "Link to project" at the time this was written), a CSV
  /// import, a teammate's copy arriving on a sync pull — has to show up here
  /// without an app restart.
  ///
  /// Michael hit this on his own device on 2026-09-03: *"If I link a tag up
  /// with an existing project, I have to restart the app for it to show up in
  /// the project."*
  ///
  /// The link write happens here the way an off-screen writer does it: the row
  /// is written and the refresh goes through `refreshTagViews`, which is the
  /// one thing every write site now calls. Before task 11.151 each site picked
  /// its own subset of the three providers that hold this answer by hand, and
  /// the Tag Database screen's link — Michael's route — picked none of them.
  group('a tag linked elsewhere appears without a restart (task 11.151)', () {
    testWidgets('the project screen picks up a link written off-screen', (
      tester,
    ) async {
      // Same surface as this file's other tags-section tests: the section
      // sits below enough fields to fall outside the default 800x600
      // surface's cache extent and never get an Element at all.
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      // Stamped by the owner — the off-screen writer below is a repository,
      // which since task 11.237 refuses a stamp that is not on the project.
      final tag = sampleTag(id: 'tag-1', tagName: 'Coco', modifiedBy: 'user-owner');
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
          projectActiveTagsProvider(project.projectId),
          (_, _) {},
        );
        await container.read(
          projectActiveTagsProvider(project.projectId).future,
        );
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
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('No tags on this project yet.'), findsOneWidget);

      // The tag, written the way an off-screen writer writes it. Since task
      // 11.219 that is the tag row itself rather than a link beside it.
      await tester.runAsync(() async {
        final repo = await container.read(tagRepositoryProvider.future);
        await repo.insert(tag);
        refreshTagViewsIn(container, projectId: project.projectId);
        // Resolving the refreshed reads on the real clock — a widget test's
        // fake clock never finishes a database round trip (see CLAUDE.md).
        await container.read(projectTagsProvider(project.projectId).future);
        // Task 11.241: the animals the tags are grouped under, pre-resolved
        // for the same reason as the tags.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        await container.read(
          projectActiveTagsProvider(project.projectId).future,
        );
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('No tags on this project yet.'), findsNothing);
      expect(find.textContaining('150.325 MHz'), findsOneWidget);
      // **One "Coco", not two** (task 11.243). `insert` named an animal
      // after every collar at schema v16, so the name appeared twice: once
      // as the animal's header row and once on the collar's row beneath it.
      // A tag is equipment now and invents no animal, so the row carries
      // "Coco" once — as the tag's own ID — and no subtitle naming an
      // animal at all (task 11.245's flat list): a collar with no animal is
      // the normal starting state for a piece of equipment (design §1)
      // rather than a gap the screen calls out.
      expect(find.textContaining('Coco'), findsOneWidget);
    });

    /// The same write seen from the Record screen's tag wheel and Position
    /// Estimation's tag selector, which read a different provider. A tag you
    /// cannot select is the half of this defect that costs a transect.
    testWidgets('the tag becomes selectable for recording without a restart', (
      tester,
    ) async {
      final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
      // Stamped by the owner — the off-screen writer below is a repository,
      // which since task 11.237 refuses a stamp that is not on the project.
      final tag = sampleTag(id: 'tag-1', tagName: 'Coco', modifiedBy: 'user-owner');
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
        container.listen(
          projectActiveTagsProvider(project.projectId),
          (_, _) {},
        );
        expect(
          await container.read(
            projectActiveTagsProvider(project.projectId).future,
          ),
          isEmpty,
        );

        // The tag arriving in the project — one row since task 11.219,
        // where it used to be a tag row already present plus a link written
        // now. The refresh has to reach the Record screen's wheel either
        // way, which is what this test is about.
        final repo = await container.read(tagRepositoryProvider.future);
        await repo.insert(tag);
        refreshTagViewsIn(container, projectId: project.projectId);

        expect(
          (await container.read(
            projectActiveTagsProvider(project.projectId).future,
          )).map((t) => t.tagId),
          ['tag-1'],
        );
      });
    });
  });

  /// **Task 11.32 at the screen layer, and task 11.219 is why it is here.**
  ///
  /// The correction-or-change question exists because editing a tag rewrites
  /// what every bearing already recorded against it claims, and a bearing
  /// names a **project's** copy of a collar. So this is where the question
  /// is asked: Project Setup's tag list, on the row that has the bearings.
  ///
  /// It used to live in `tag_database_screen_test.dart`, because that screen
  /// edited every tag. That screen shows the device's own tag *library* now
  /// — no project, no bearings, no version chain — and its own tests assert
  /// that editing an entry there asks nothing, which is the other half of
  /// this claim.
  group('editing a project tag asks about earlier records', () {
    Future<ProviderContainer> containerWithATag(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        final user = await container.read(currentUserProvider.future);
        final project = sampleProject(ownerUserId: user.userId);
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(projectId: project.projectId, userId: user.userId)
              .toColumns(),
        );
        final tagRepo = await container.read(tagRepositoryProvider.future);
        await tagRepo.insert(
          sampleTag(projectId: project.projectId, modifiedBy: user.userId),
        );
        // **Task 11.243: the animal and the dated link, written out.** A
        // collar with no animal has no colour to move, so a recolour through
        // the tag form would be a no-op and the test below would measure
        // nothing. `insert` did this itself at schema v16.
        await (await container.read(individualRepositoryProvider.future))
            .insert(
              sampleIndividual(
                projectId: project.projectId,
                modifiedBy: user.userId,
              ),
            );
        await (await container.read(deploymentRepositoryProvider.future)).link(
          sampleDeployment(
            projectId: project.projectId,
            modifiedBy: user.userId,
          ),
        );
        await container
            .read(activeProjectIdProvider.notifier)
            .set(project.projectId);

        container.listen(currentProjectProvider, (_, _) {});
        await container.read(currentProjectProvider.future);
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        container.listen(projectTagsProvider(project.projectId), (_, _) {});
        container.listen(
          mayWriteProjectDataProvider(project.projectId),
          (_, _) {},
        );
        await container.read(isProjectOwnerProvider(project.projectId).future);
        await container.read(projectTagsProvider(project.projectId).future);
        // Task 11.241: the animals the tags are grouped under, pre-resolved
        // for the same reason as the tags.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        await container
            .read(mayWriteProjectDataProvider(project.projectId).future);
        await container.read(deviceIdProvider.future);
        await container.read(tagLibraryRepositoryProvider.future);
      });
      return container;
    }

    Future<void> openTheTag(WidgetTester tester) async {
      await tester.scrollUntilVisible(
        find.text('150.325 MHz · Coco'),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('150.325 MHz · Coco'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    testWidgets('changing the frequency asks, and "it changed" leaves earlier '
        'records reading the old value', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await containerWithATag(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await openTheTag(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Frequency (MHz)'),
          '150.51',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        // The question, asked because a versioned field moved.
        expect(
          find.byKey(const ValueKey('tag_edit_intent_dialog')),
          findsOneWidget,
          reason: 'a frequency edit rewrites what every bearing already '
              'recorded against this tag means — the app cannot tell drift '
              'from a typo, so it must ask',
        );
        await tester.tap(find.byKey(const ValueKey('tag_edit_intent_change')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tag_edit_intent_save')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      await tester.runAsync(() async {
        final project = (await container.read(currentProjectProvider.future))!;
        final tags = await container.read(
          projectTagsProvider(project.projectId).future,
        );
        // Task 11.241: the animals the tags are grouped under.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        expect(tags.single.frequencyMhz, 150.51);

        final versions =
            await container.read(tagVersionRepositoryProvider.future);
        final history = await tagVersionHistory(versions, 'tag-1');
        expect(history, hasLength(2), reason: 'a change appends a version');
        expect(history.first.frequencyMhz, 150.325);
        expect(history.last.frequencyMhz, 150.51);
      });
    });

    testWidgets('recolouring asks nothing at all', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await containerWithATag(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await openTheTag(tester);
        await tester.ensureVisible(
          find.byKey(ValueKey('tag_color_swatch_${TagColorPalette.colors[3]}')),
        );
        await tester.tap(
          find.byKey(ValueKey('tag_color_swatch_${TagColorPalette.colors[3]}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('tag_edit_intent_dialog')),
          findsNothing,
          reason: 'colour is a display key, not a measurement — there is no '
              'such thing as "the colour it was then"',
        );
      });

      await tester.runAsync(() async {
        final project = (await container.read(currentProjectProvider.future))!;
        final tags = await container.read(
          projectTagsProvider(project.projectId).future,
        );
        // Task 11.241: the animals the tags are grouped under.
        container.listen(projectIndividualsProvider(project.projectId), (_, _) {});
        await container.read(projectIndividualsProvider(project.projectId).future);
        // Task 11.243: the dated links, pre-resolved for the same reason.
        container.listen(projectDeploymentsProvider(project.projectId), (_, _) {});
        await container.read(projectDeploymentsProvider(project.projectId).future);
        expect(tags.single.colorHex, TagColorPalette.colors[3]);
        final versions =
            await container.read(tagVersionRepositoryProvider.future);
        expect(
          await tagVersionHistory(versions, 'tag-1'),
          hasLength(1),
          reason: 'a recolour writes no version',
        );
      });
    });

    // =================================================================
    // The custom hex editor — **moved here from
    // `tag_database_screen_test.dart` by task 11.244.**
    //
    // It was tested on the tag *library*, and a library entry no longer has
    // a colour anybody reads: the seed it was kept for (task 11.241) has
    // nowhere to land since 11.243 stopped a copy-into-a-project inventing
    // an animal. **This is where the colour editor lives now** — a project's
    // tag, where the value writes through to the animal and recolours every
    // collar she has worn.
    // =================================================================

    testWidgets('a valid custom hex overrides the swatch selection and '
        'persists to the animal', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await containerWithATag(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await openTheTag(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('tag_color_advanced_toggle')),
        );
        await tester.tap(find.byKey(const ValueKey('tag_color_advanced_toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('tag_color_custom_hex_field')),
          '#123456',
        );
        // A single pump, not pumpAndSettle: the focused field's cursor keeps
        // scheduling frames for pumpAndSettle to chase forever.
        await tester.pump();
        expect(
          find.byIcon(Icons.check),
          findsNothing,
          reason: 'no swatch reads as selected once a custom hex is entered',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      await tester.runAsync(() async {
        final project = (await container.read(currentProjectProvider.future))!;
        final individuals = await container.read(
          individualRepositoryProvider.future,
        );
        final animal = (await individuals.findByProject(
          project.projectId,
        )).single;
        expect(
          animal.colorHex,
          '#123456',
          reason:
              "the colour is the animal's — a tag edit that moves it lands "
              'on her, and every collar she has worn redraws',
        );
      });
    });

    testWidgets('an invalid custom hex blocks save with an inline error',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await containerWithATag(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await openTheTag(tester);
        await tester.ensureVisible(
          find.byKey(const ValueKey('tag_color_advanced_toggle')),
        );
        await tester.tap(find.byKey(const ValueKey('tag_color_advanced_toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('tag_color_custom_hex_field')),
          'not-a-hex',
        );
        await tester.pump();
        expect(find.text('Enter a hex color like #RRGGBB'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        expect(
          find.text('Tag details'),
          findsOneWidget,
          reason: 'the form is still open — the invalid entry blocked save',
        );
      });
    });

    /// **Task 11.234.** `otherProjectCopyCount` excludes the tag's own
    /// project — the fix for a collar with no copies anywhere reading "One
    /// of your projects uses this collar" (Steens' `East Rim`, the real row
    /// that found this). This is the commonest collar there is: one project,
    /// never copied.
    testWidgets('a collar in only this project shows no sharing line at all',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await containerWithATag(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await openTheTag(tester);
        expect(
          find.textContaining('uses this collar'),
          findsNothing,
          reason: 'this tag\'s lineage exists in exactly one project — its '
              'own — so the count of *other* projects holding it is zero',
        );
      });
    });

    /// The other side of the same fix: a collar genuinely held by a second
    /// project must still say so, and say the right number.
    testWidgets(
        'a collar also copied into another project reports that project, '
        'not itself', (tester) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = await containerWithATag(tester);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        final user = await container.read(currentUserProvider.future);
        final otherProject = sampleProject(
          id: 'another-project',
          ownerUserId: user.userId,
        );
        await db.insert(Tables.projects, otherProject.toColumns());
        final tagRepo = await container.read(tagRepositoryProvider.future);
        // A second project's copy of the same collar (lineageId 'tag-1',
        // the default) — this is what a genuinely shared collar looks like.
        await tagRepo.insert(
          sampleTag(
            id: 'tag-2-copy',
            projectId: otherProject.projectId,
            modifiedBy: user.userId,
            lineageId: 'tag-1',
            copiedAt: DateTime(2026, 9, 1),
          ),
          recordInLibrary: false,
        );
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await openTheTag(tester);
        expect(
          find.text("Changes here won't reach the 1 project using this tag"),
          findsOneWidget,
          reason: 'exactly one *other* project holds this lineage, and this '
            'project\'s own copy must not count toward it',
        );
      });
    });
  });
}
