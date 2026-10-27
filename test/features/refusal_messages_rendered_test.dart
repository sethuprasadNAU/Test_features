import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/individuals_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/features/more/screens/observation_sharing_screen.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack/features/more/screens/tags_screen.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../support/app_shell_harness.dart';
import '../support/fake_path_provider.dart';
import '../support/project_row_menu.dart';
import '../support/fake_shared_preferences.dart';

/// **Task 11.126 item A — the nine refusal messages nobody had ever seen.**
///
/// Ten `on UnauthorizedMutation` handlers exist in `lib/`. Nine of them are
/// what a viewer or a contributor reads when the app refuses their write, and
/// task 11.119's survey found that **not one had ever executed** — not in the
/// app, and not in a test. They are the user-visible half of what tasks 11.12
/// and 11.14 built: the refusal itself was covered by repository tests, the
/// sentence a person reads was covered by nothing.
///
/// ## The question that had to be answered first
///
/// Task 11.105 established that **a typed catch on the far side of
/// `await ref.read(someProvider.future)` can be dead code**: `@riverpod`
/// generates an autoDispose provider, `ref.read(...future)` holds no listener
/// across the await, the element is torn down while still loading, and the
/// caller gets a `StateError` about the teardown instead of the original
/// exception — which is **destroyed, not wrapped**, so nothing at the `catch`
/// can recover it. A test that renders a message the app cannot actually reach
/// is worse than no test: it certifies a sentence a person will never see
/// while the real path shows them something else.
///
/// So this file's first job is a **verdict per site, established by rendering
/// rather than by reading**. Every one of the nine is driven here through the
/// real screen at real phone geometry until the sentence appears. A site whose
/// message cannot be made to appear is reported as unreachable and is not
/// given a passing test.
///
/// **The verdict was: all nine reachable.** The structural reason, checked
/// against every site and then confirmed by these renders, is that in all nine
/// the call that throws is a **direct method call on an already-resolved
/// repository object** — `tagRepo.insert(...)`, `repo.setStatus(...)`,
/// `repo.softDeleteById(...)`. The provider awaits that fetch those
/// repositories sit *outside* the `try`, or are not the throwing call inside
/// it. 11.105's mechanism needs the error to originate *inside* an awaited
/// provider's build, and none of these nine does. They were untested, not
/// unreachable.
///
/// ## Two shapes of reach, and both are real
///
/// - **An ordinary path.** Some of the nine are simply what happens when a
///   person taps a control the screen still offers them — the tag row a
///   contributor may open but not save, and the create-tag dialog whose
///   pre-check is asked of the *active* project while the write is asked of
///   the project the person picks in the dialog.
/// - **The race the comments describe.** The rest are reached exactly as their
///   own comments say: "the moment between a role change and a rebuild." The
///   control's pre-check resolved while the person was still an owner, their
///   role then changed underneath them, and the write refuses. These tests
///   reproduce that by demoting the membership row in the database after the
///   screen has rendered and before the control is used — which is the real
///   sequence, not a shortcut around one.
///
/// ## The nine, each with its verdict and the test that establishes it
///
/// Line numbers are as of 2026-09-02. The tenth handler —
/// `tag_database_screen.dart`'s `mayEditTagProvider` — is the one that *had*
/// executed: it runs on every tag row to decide whether to draw a lock, and it
/// is covered by `tag_database_screen_test.dart`.
///
/// | Site | Verdict | Reached by |
/// |---|---|---|
/// | `tag_database_screen.dart:127` | reachable | an ordinary tap on a locked row |
/// | `tag_database_screen.dart:190` | reachable | creating into a picked project, no active project |
/// | `project_setup_screen.dart:810` | reachable | demoted to viewer, then "Link existing tag" |
/// | `project_setup_screen.dart:913` | reachable | demoted to viewer, then "+ New tag" |
/// | `project_setup_screen.dart:1058` | reachable | demoted to contributor, then unlink |
/// | `project_setup_screen.dart:1121` | reachable | demoted to contributor (viewer until task 11.221), then "Add back" |
/// | `projects_screen.dart:380` | reachable | demoted to viewer, then Delete project |
/// | `observation_sharing_screen.dart:282` | reachable | demoted to viewer, then "Create tag" |
/// | `observation_logging_screen.dart:1766` | reachable | demoted while the quick-add form is open |
///
/// **No site was found unreachable**, so nothing here is reported as a defect
/// of the 11.105 class and nothing was repaired in passing.
///
/// ## Task 11.245: three of the four Project Setup sites moved, and one is gone
///
/// **The tags section, and the handlers with it, moved off Project Setup to
/// its own screen (`tags_screen.dart`, `More → Tags`)** — the rows above name
/// where each one used to live; the tests below drive the same three through
/// the screen it lives on now: `tags_screen.dart` copying a tag from the
/// library, unlinking one, and adding a removed one back.
///
/// **The fourth — "+ New tag" — has no successor, because the control it
/// guarded is gone.** A tag is no longer created from a project's own screen
/// at all (design §3a): it is created on the Tag Library screen instead,
/// whose create FAB has had **no role gate since task 11.219** — a library
/// entry is device-local, in no project, so there is nothing for a role to
/// refuse. The viewer-refusal this row named cannot be reached any more
/// because the write it guarded no longer exists on a project's own screen.
///
/// ## Two of the nine have since moved, and the tests below did not change
///
/// Task 11.137, 2026-09-02, put all thirteen unguarded write handlers onto one
/// shared mechanism — `runGuardedWrite` in `lib/core/errors/guarded_write.dart`
/// — and folded two of the nine sites in this table onto it on the way past,
/// because they sat in the same methods: `projects_screen.dart`'s delete and
/// `observation_sharing_screen.dart`'s create-tag. **Their sentences are
/// unchanged and every test below still drives them through the real screen**;
/// what changed is that the `on UnauthorizedMutation` those two rows name is now
/// inside the shared helper rather than in the screen, and both sites gained the
/// branch they never had — a write that *fails* rather than being refused.
///
/// So the row line numbers for those two are historical. The rest still name a
/// typed catch in the file they say. Nothing in this file asserts a line number;
/// this note exists so the next reader does not go looking for a catch that has
/// moved and conclude the control was deleted.
///
/// Everything is pumped in [pumpInAppShell] rather than bare (task 11.111):
/// a screen pumped bare is handed roughly a `NavigationBar`'s worth of height
/// it never has in the app, and these are snackbars and dialogs that live at
/// the bottom of the screen.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  group('tags screen: opening a project tag', () {
    testWidgets(
        'a contributor opening a project tag reads all of it, under the '
        'refusal', (tester) async {
      // **Task 11.219 moved this refusal and it is worth saying where.** It
      // used to head the Tag Database screen's edit form, because that
      // screen edited every tag. That screen shows this device's own tag
      // *library* now — device-local, in no project, governed by no role —
      // so there is nothing there to refuse. What an owner-only rule
      // protects is what a bearing was recorded against, and that is a
      // *project's* copy, which is edited on `More → Tags` (task 11.245,
      // moved off Project Setup).
      //
      // Same words, same `tag_edit_not_permitted` key, and the same
      // decision Michael made on 2026-09-06: a refusal must not be the end
      // of the road, so the form opens read-only rather than refusing the
      // tap.
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final contributor =
          sampleUser(id: 'user-contributor', email: 'contributor@example.com');
      final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);
      // Stamped by the owner: inserted through the repository below, which
      // since task 11.237 refuses a stamp that is not on the project.
      final tag = sampleTag(
        id: 'tag-1',
        projectId: project.projectId,
        modifiedBy: owner.userId,
      );

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => contributor),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, contributor.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        final tagRepo = await container.read(tagRepositoryProvider.future);
        await tagRepo.insert(tag);
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: contributor.userId,
            role: ProjectRole.contributor,
          ).toColumns(),
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
        await container.read(currentUserProvider.future);
      });

      await pumpInAppShell(
        tester,
        container: container,
        screen: const TagsScreen(),
        tabIndex: 4,
      );

      await tester.runAsync(() async {
        await tester.scrollUntilVisible(
          find.text('150.325 MHz · Coco'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('150.325 MHz · Coco'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(find.byKey(const ValueKey('tag_edit_not_permitted')),
          findsOneWidget);
      expect(find.text('Only an owner can change this tag'), findsOneWidget);
      expect(
        find.textContaining(
          'belongs to a project you are not an owner of',
          findRichText: true,
        ),
        findsOneWidget,
      );
      // The sentence that makes it actionable rather than a dead end — the
      // honest-default rule: a refusal ends in something the person can do.
      // Since 11.219 what they can do is keep their own copy of the collar,
      // which is theirs and reaches no project.
      expect(
        find.textContaining('your tag library', findRichText: true),
        findsOneWidget,
      );
    });
  });

  /// **The project's own tags screen's three handlers** —
  /// `tags_screen.dart:277` (copy from library), `:555` (unlink), `:614`
  /// (add back). Moved here from Project Setup by task 11.245, along with
  /// the tag section itself; the fourth site the table above names — "+ New
  /// tag" — has no successor here, because a project's own screen no longer
  /// creates a tag at all (see the note above the table).
  ///
  /// All three are reached the way their own comments say they are: "the
  /// moment between a role change and a rebuild". The screen resolves
  /// `mayWriteProjectDataProvider` and `isProjectOwnerProvider` once, before
  /// it renders the controls at all (deliberately — showing a control enabled
  /// and then disabling it under the person's finger would be a worse lie
  /// than a moment's spinner). So the control is offered on the strength of
  /// the role this device knew about when the section was built, and the
  /// write asks the database again. Between the two, a sync can land an
  /// owner's decision to change somebody's role.
  ///
  /// These tests reproduce exactly that: seed the person as an owner, let the
  /// screen render, then change the membership row underneath it — which is
  /// what a sync does — and use the control that is still on the screen.
  group('tags screen', () {
    Future<ProviderContainer> ownerContainer(
      WidgetTester tester, {
      required List<Tag> tags,
      /// Tags to seed and then **remove from the project**, so the "Add
      /// back" control has something to act on. Since task 11.219 that is a
      /// tombstone on the project's own tag row, where it used to be a
      /// `Project_Tags` link set inactive.
      List<Tag> removed = const [],
    }) async {
      final user = sampleUser(id: 'user-me', email: 'me@example.com');
      final creator =
          sampleUser(id: 'user-creator', email: 'creator@example.com');
      // **The project was created by somebody else and this person is a
      // co-equal owner by membership (task 11.1).** That distinction is load-
      // bearing here rather than decorative: `readProjectRole` treats
      // `Projects.owner_user_id` as an owner regardless of the membership
      // rows, so a fixture where this person is also the named creator can
      // never be demoted at all — the write would be permitted no matter what
      // the membership row said, and all four of these tests would pass the
      // control and fail the assertion for a reason that has nothing to do
      // with the message being rendered.
      final project = sampleProject(id: 'project-1', ownerUserId: creator.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentProjectProvider.overrideWith((ref) async => project),
          currentUserProvider.overrideWith((ref) async => user),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, user.toColumns());
        await db.insert(Tables.users, creator.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: user.userId,
            role: ProjectRole.owner,
          ).toColumns(),
        );
        final tagRepo = await container.read(tagRepositoryProvider.future);
        for (final tag in [...tags, ...removed]) {
          await tagRepo.insert(tag);
        }
        for (final tag in removed) {
          await tagRepo.removeFromProject(
            tag.tagId,
            projectId: project.projectId,
            actor: MutationActor.user(user.userId),
          );
        }
        // `listen` before `read`: these are `@riverpod`-generated and so
        // autoDispose, and a bare `read` is thrown away the moment the widget
        // tree watches it. Keeping them alive is also what makes the race
        // this group tests reproducible — the screen keeps the answer it was
        // given, which is the whole point.
        container.listen(currentProjectProvider, (_, _) {});
        await container.read(currentProjectProvider.future);
        container.listen(isProjectOwnerProvider(project.projectId), (_, _) {});
        container.listen(projectTagsProvider(project.projectId), (_, _) {});
        container.listen(
            mayWriteProjectDataProvider(project.projectId), (_, _) {});
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
        await container.read(currentUserProvider.future);
      });
      return container;
    }

    /// What a sync does when an owner changes somebody's role: it rewrites
    /// the membership row. Nothing is invalidated, because nothing in the
    /// running app invalidates on somebody else's decision either — that is
    /// the gap these nine handlers exist to cover.
    Future<void> demoteTo(
      WidgetTester tester,
      ProviderContainer container,
      ProjectRole role,
    ) async {
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.update(
          Tables.projectMemberships,
          {'role': role.db},
          where: 'project_id = ? AND user_id = ?',
          whereArgs: ['project-1', 'user-me'],
        );
      });
    }

    Future<void> pumpSetup(
      WidgetTester tester,
      ProviderContainer container,
    ) =>
        pumpInAppShell(
          tester,
          container: container,
          screen: const TagsScreen(),
          tabIndex: 4,
        );

    /// The list is a lazy `ListView` — so a row below the fold is not merely
    /// off-screen, it is **not built at all** until scrolled to.
    /// `ensureVisible` cannot reach a widget that does not exist yet, which
    /// is exactly the trap task 11.111 describes: a test that pumps a screen
    /// at a generous size finds these controls without scrolling, and never
    /// learns how far down they are on the device somebody actually holds.
    Future<void> scrollToTags(WidgetTester tester, Finder target) async {
      await tester.runAsync(() async {
        await tester.scrollUntilVisible(
          target,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      });
    }

    testWidgets(
        'copying a tag from the library after the person is demoted to '
        'viewer says so', (tester) async {
      // **"Link existing tag" became "Copy from library" in task 11.219.**
      // A tag belongs to one project, so putting a collar on a second
      // project is a copy of it rather than a second link — and the refusal
      // this test is about is unchanged, because the rung is unchanged.
      final container = await ownerContainer(tester, tags: const []);
      await tester.runAsync(() async {
        final library =
            await container.read(tagLibraryRepositoryProvider.future);
        await library.insert(sampleTagLibraryEntry(id: 'lib-1'));
      });
      await pumpSetup(tester, container);
      await demoteTo(tester, container, ProjectRole.viewer);

      await scrollToTags(
          tester, find.widgetWithText(OutlinedButton, 'Copy from library'));
      await tester.runAsync(() async {
        await tester
            .tap(find.widgetWithText(OutlinedButton, 'Copy from library'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.text('150.325 MHz · Coco'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(
        find.widgetWithText(
          SnackBar,
          'Viewers cannot change a project\'s tags — ask an owner to change '
          'your role.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'removing a tag from the project after ownership is lost says so',
        (tester) async {
      // Stamped by the person the fixture makes an owner (task 11.237).
      final tag = sampleTag(id: 'tag-1', modifiedBy: 'user-me');
      final container = await ownerContainer(tester, tags: [tag]);
      await pumpSetup(tester, container);
      // Contributor, not viewer: unlinking needs the owner rung, and a
      // contributor is the role that makes *this* control the one that
      // refuses while the others beside it still work.
      await demoteTo(tester, container, ProjectRole.contributor);

      await scrollToTags(tester, find.byIcon(Icons.link_off));
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.link_off));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(
        find.widgetWithText(
          SnackBar,
          'Only a project owner can remove a tag from a project — ask an '
          'owner.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'adding a removed tag back after ownership is lost says so',
        (tester) async {
      final tag = sampleTag(id: 'tag-1', modifiedBy: 'user-me');
      final container =
          await ownerContainer(tester, tags: const [], removed: [tag]);
      await pumpSetup(tester, container);
      // Contributor, not viewer, for the same reason as the removal test
      // above: since task 11.221 the put-back needs the owner rung, so a
      // contributor is the role for which *this* control refuses while
      // "Copy from library" beside it still works. The message used to name
      // viewers, which would be the wrong cause for a contributor.
      await demoteTo(tester, container, ProjectRole.contributor);

      await scrollToTags(tester, find.widgetWithText(TextButton, 'Add back'));
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Add back'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(
        find.widgetWithText(
          SnackBar,
          'Only a project owner can add a tag back to a project — ask an '
          'owner.',
        ),
        findsOneWidget,
      );
    });
  });


  /// **`projects_screen.dart:380`** — deleting a project you no longer own.
  ///
  /// The Delete item is hidden from a non-owner, so this is the race its own
  /// comment names: ownership changed between the list rendering and the
  /// confirm dialog closing.
  group('projects screen', () {
    testWidgets('deleting a project after ownership is lost says so',
        (tester) async {
      final me = sampleUser(id: 'user-me', email: 'me@example.com');
      // Created by somebody else; this person is a co-equal owner by
      // membership (task 11.1). Same reason as the Project Setup group: a
      // person named in `Projects.owner_user_id` is an owner whatever the
      // membership row says, so they cannot be demoted at all.
      final project =
          sampleProject(id: 'project-1', ownerUserId: 'user-creator');

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          allProjectsProvider.overrideWith((ref) async => [project]),
          currentUserProvider.overrideWith((ref) async => me),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, me.toColumns());
        await db.insert(
          Tables.users,
          sampleUser(id: 'user-creator', email: 'creator@example.com')
              .toColumns(),
        );
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: me.userId,
            role: ProjectRole.owner,
          ).toColumns(),
        );
        container.listen(ownedProjectIdsProvider, (_, _) {});
        await container.read(ownedProjectIdsProvider.future);
        container.listen(departedProjectIdsProvider, (_, _) {});
        await container.read(departedProjectIdsProvider.future);
        await container.read(activeProjectIdProvider.future);
        await container.read(deviceIdProvider.future);
        await container.read(currentUserProvider.future);
      });

      await pumpInAppShell(
        tester,
        container: container,
        screen: const ProjectsScreen(),
        tabIndex: 4,
      );

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.update(
          Tables.projectMemberships,
          {'role': ProjectRole.viewer.db},
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [project.projectId, me.userId],
        );
      });

      await tester.runAsync(() async {
        await tapProjectMenuItem(tester, 'Move to Trash');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Move to Trash'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(
        find.widgetWithText(
          SnackBar,
          'Only a project owner can move this project to the Trash.',
        ),
        findsOneWidget,
      );
    });
  });

  /// **`observation_sharing_screen.dart:282`** — creating the tag a pasted
  /// bearing names.
  group('observation sharing screen', () {
    testWidgets(
        'creating the shared bearing\'s tag after a demotion to viewer says so',
        (tester) async {
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final me = sampleUser(id: 'user-me', email: 'me@example.com');
      final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => me),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, me.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: me.userId,
            role: ProjectRole.contributor,
          ).toColumns(),
        );
        await container
            .read(activeProjectIdProvider.notifier)
            .set(project.projectId);
        await container.read(currentProjectProvider.future);
        // Task 11.218: matching is now scoped to the active project's tags
        // (`projectActiveTagsProvider`, not the device-wide `localTagsProvider`
        // this used to pre-resolve). It is autoDispose, so a bare `.future`
        // read with nothing listening would dispose it the instant this
        // completes — `container.listen` keeps it alive for the pumped
        // widget's own `ref.watch` to find already resolved.
        container.listen(
          projectActiveTagsProvider(project.projectId),
          (_, _) {},
        );
        await container.read(
          projectActiveTagsProvider(project.projectId).future,
        );
        await container
            .read(mayWriteProjectDataProvider(project.projectId).future);
        await container.read(deviceIdProvider.future);
        await container.read(currentUserProvider.future);
        final individualRepo =
            await container.read(individualRepositoryProvider.future);
        await individualRepo.nextColorHex(projectId: project.projectId);
      });

      await pumpInAppShell(
        tester,
        container: container,
        screen: const ObservationSharingScreen(),
        tabIndex: 4,
      );

      await tester.runAsync(() async {
        await tester.enterText(
          find.byType(TextField),
          ObservationShare.encode(
            sampleObservation(),
            tag: sampleTag(),
            observer: sampleUser(),
          ),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.update(
          Tables.projectMemberships,
          {'role': ProjectRole.viewer.db},
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [project.projectId, me.userId],
        );

        await tester.scrollUntilVisible(
          find.widgetWithText(OutlinedButton, 'Create tag'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Create tag'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      });

      expect(
        find.widgetWithText(
          SnackBar,
          'Viewers cannot create tags — ask a project owner to change your '
          'role to contributor.',
        ),
        findsOneWidget,
      );
    });
  });

  /// **`observation_logging_screen.dart:1766`** — the quick-add a field tech
  /// uses mid-transect when they hear a collar that is not on the list.
  ///
  /// This one's pre-check is **not** stale: `quickAddTagDialog` asks
  /// `mayWriteProjectDataProvider` freshly at the moment of the tap and shows
  /// its own "Viewers cannot create tags" *dialog* when the answer is no. The
  /// window this handler covers is therefore narrower and later than the
  /// others — the role has to change while the form is open, which is exactly
  /// the case here: the person is a contributor when the dialog opens and a
  /// viewer by the time they press Add.
  ///
  /// **What is not exercised here, said plainly:** the control that opens this
  /// dialog in the app is a scroll-wheel sentinel entry on the Record screen,
  /// and this test calls `quickAddTagDialog` directly from a host widget
  /// inside the real shell rather than driving that wheel. The dialog, the
  /// write, the refusal and the sentence are all the real ones; the wheel is
  /// not covered by this test and is not what this task is about.
  group('observation logging quick-add', () {
    testWidgets(
        'quick-adding a tag after a demotion while the form is open says so',
        (tester) async {
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final me = sampleUser(id: 'user-me', email: 'me@example.com');
      final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => me),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, me.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: me.userId,
            role: ProjectRole.contributor,
          ).toColumns(),
        );
        await container
            .read(activeProjectIdProvider.notifier)
            .set(project.projectId);
        container.listen(
            mayWriteProjectDataProvider(project.projectId), (_, _) {});
        await container
            .read(mayWriteProjectDataProvider(project.projectId).future);
        await container.read(deviceIdProvider.future);
        await container.read(currentUserProvider.future);
        final individualRepo =
            await container.read(individualRepositoryProvider.future);
        await individualRepo.nextColorHex(projectId: project.projectId);
      });

      await pumpInAppShell(
        tester,
        container: container,
        screen: _QuickAddHost(project: project),
        tabIndex: 1,
      );

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Quick-add'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(find.text('Quick-add tag'), findsOneWidget,
            reason: 'the up-front check let a contributor through, which is '
                'the precondition for reaching the write at all');

        await tester.enterText(
            find.widgetWithText(TextField, 'Tag ID'), 'Juniper');
        await tester.enterText(
            find.widgetWithText(TextField, 'Frequency (MHz)'), '151.400');
        await tester.enterText(
            find.widgetWithText(TextField, 'Animal name'), 'Juniper');

        // The role changes while the form is open — the only window this
        // particular handler covers.
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.update(
          Tables.projectMemberships,
          {'role': ProjectRole.viewer.db},
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [project.projectId, me.userId],
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      });

      expect(
        find.widgetWithText(
          SnackBar,
          'Viewers cannot create tags — ask a project owner to change your '
          'role to contributor.',
        ),
        findsOneWidget,
      );
    });
  });

}


/// A one-button host for [quickAddTagDialog], which the app reaches through a
/// scroll-wheel sentinel entry rather than an ordinary button. See the group's
/// doc comment for what that means this test does and does not cover.
class _QuickAddHost extends ConsumerWidget {
  const _QuickAddHost({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => quickAddTagDialog(context, ref, project),
            child: const Text('Quick-add'),
          ),
        ),
      );
}
