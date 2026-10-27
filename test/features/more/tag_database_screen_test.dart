import 'dart:async' show unawaited;
import 'dart:math' show pow;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/format/pulse_rate_format.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/pulse_rate_unit_provider.dart';
import 'package:tritrack/core/providers/tag_sort_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/csv/tag_csv_import.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/tag_library_entry.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart';
import 'package:tritrack/widgets/tag_color_swatch.dart';
import 'package:tritrack/widgets/tag_form.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/tag_row_text.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/tag_library_priming.dart';
import '../../support/tag_version_history.dart';
import '../../support/text_scale_probe.dart';

/// Unlike `currentProjectProvider`, `tagLibraryProvider` unconditionally
/// watches `tagLibraryRepositoryProvider` (this device's personal tag
/// library is device-local, not project-scoped), so it always touches the
/// database — this needs the same `tester.runAsync` + in-memory-db treatment
/// as `manage_offline_maps_screen_test.dart`.
///
/// **The screen it covers changed subject in task 11.219.** It listed every
/// `Tags` row on the device; copy-on-add made a tag one project's copy of a
/// collar, so "every tag row" is a list of copies rather than a list of
/// anything a person owns. What it shows now is `Tag_Library`: one row per
/// transmitter, device-local, never synced, and **governed by no role** —
/// which is why the create and edit gates this file used to pre-resolve
/// (`mayCreateTagProvider`, `mayEditTagProvider`) are gone. Those questions
/// still exist; they are about a *project's* copy, and they live on Project
/// Setup.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    // Without this, any `pumpAndSettle()` called while a TextField is
    // focused can spin forever: the cursor's blink timer keeps scheduling
    // new frames, and pumpAndSettle only returns once two consecutive pumps
    // produce none.
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  testWidgets('renders an empty tag list without hanging', (tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      // Pre-resolve so the widget doesn't trigger a fresh FFI call after
      // pumping (that never resolves inside testWidgets' fake-async zone).
      await primeTagLibrary(container);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TagDatabaseScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No tags yet — add one or import a CSV.'), findsOneWidget);
    expect(find.byIcon(Icons.upload_file), findsOneWidget);
  });

  Future<ProviderContainer> readyContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await primeTagLibrary(container);
      await container.read(allProjectsProvider.future);
      await container.read(activeProjectIdProvider.future);
      final repo = await container.read(tagLibraryRepositoryProvider.future);
      await repo.nextColorHex();
      // Pre-resolve these too: `_showEditDialog`'s post-`showDialog`
      // continuation reads them for the first time at Save, and
      // `currentUserProvider` itself does a fresh DB query/user-creation on
      // an uncached first read — one more real gap the fixed Save-tap delay
      // would otherwise have to blindly cover.
      await container.read(deviceIdProvider.future);
      await container.read(currentUserProvider.future);
    });
    return container;
  }

  /// Pumps `TagDatabaseScreen` with a taller-than-default test surface (the
  /// tag edit dialog's content column overflows the default 800x600 window,
  /// which fails hit tests on swatches/advanced-toggle below the fold even
  /// though they're rendered).
  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: TagDatabaseScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the library form asks for no colour at all — task 11.244',
      (tester) async {
    // **Two tests used to live here**: that a new library entry defaulted to
    // the next palette colour, and that picking a swatch persisted. Both
    // described a value that is now read by nothing.
    //
    // A library entry's colour was the seed for the animal a copy-into-a-
    // project created (task 11.241). Task 11.243 stopped creating that
    // animal — a collar is equipment and invents no bird — and 11.244's
    // linking flow attaches a collar to an animal that already exists and
    // already has a colour. **So the seed has nowhere to land, and a form
    // that asked for it would be asking a question with no answer.**
    //
    // Colour is still chosen, and still matters, on a *project's* tag, where
    // it writes through to the animal — `tags_screen_test.dart` holds that
    // (moved off Project Setup by task 11.245), custom hex included.
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    await tester.runAsync(() async {
      await tester.tap(find.byType(FloatingActionButton));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });

    expect(find.text('Add tag'), findsOneWidget);
    expect(find.text('Color'), findsNothing);
    expect(find.byType(TagColorSwatch), findsNothing);
    expect(
      find.byKey(const ValueKey('tag_color_advanced_toggle')),
      findsNothing,
    );
  });

  testWidgets('the list row carries no colour swatch — task 11.244',
      (tester) async {
    // **A swatch showing a colour nothing uses is a promise about the map
    // that the map does not keep.** See the form test above for why a
    // library entry no longer has a colour anybody reads.
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final repo = await container.read(tagLibraryRepositoryProvider.future);
      await repo.insert(
        sampleTagLibraryEntry(colorHex: TagColorPalette.colors[0]),
      );
      await primeTagLibrary(container);
      await container.read(activeProjectIdProvider.future);
      await container.read(deviceIdProvider.future);
      await container.read(currentUserProvider.future);
    });
    await pumpScreen(tester, container);

    expect(find.byType(ListTile), findsWidgets);
    expect(find.byType(TagColorSwatch), findsNothing);
  });

  /// **Task 11.11's warning, through the screen.**
  ///
  /// The two assertions that matter are opposites: it must fire, with enough
  /// detail to be evaluated, when a real collision is about to be created; and
  /// it must stay silent for a genuinely distinct tag, because a warning that
  /// cries wolf gets dismissed unread and then is not there for the real one.
  /// In neither case may it *refuse* — "Create anyway" is the affirmative
  /// button, deliberately.
  Future<ProviderContainer> containerWithCoco(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final repo = await container.read(tagLibraryRepositoryProvider.future);
      await repo.insert(sampleTagLibraryEntry(tagName: 'Coco', frequencyMhz: 150.325));
      await primeTagLibrary(container);
      await container.read(allProjectsProvider.future);
      await container.read(activeProjectIdProvider.future);
      await repo.nextColorHex();
      await container.read(deviceIdProvider.future);
      await container.read(currentUserProvider.future);
    });
    return container;
  }

  Future<void> fillNewTag(
    WidgetTester tester, {
    required String frequency,
    required String name,
  }) async {
    await tester.tap(find.byType(FloatingActionButton));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), frequency);
    await tester.enterText(
        find.widgetWithText(TextField, 'Tag ID'), name);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('a frequency collision warns and names the existing tag',
      (tester) async {
    final container = await containerWithCoco(tester);
    await pumpScreen(tester, container);

    await tester.runAsync(() async {
      await fillNewTag(tester, frequency: '150.325', name: 'Bandit');
    });

    expect(find.byKey(const ValueKey('near_duplicate_tag_dialog')),
        findsOneWidget);
    // Evaluable, not "possible duplicate": which tag, and on what.
    expect(find.textContaining('Coco'), findsWidgets);
    expect(find.textContaining('same frequency'), findsOneWidget);
    expect(find.textContaining('150.325'), findsWidgets);
  });

  testWidgets('and the user can proceed — the tag is created', (tester) async {
    final container = await containerWithCoco(tester);
    await pumpScreen(tester, container);

    late List<TagLibraryEntry> tags;
    await tester.runAsync(() async {
      await fillNewTag(tester, frequency: '150.325', name: 'Bandit');
      await tester
          .tap(find.byKey(const ValueKey('near_duplicate_tag_create_anyway')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      tags = await container.read(tagLibraryProvider.future);
    });

    expect(tags.map((t) => t.tagName), containsAll(['Coco', 'Bandit']));
  });

  testWidgets('going back leaves the tag uncreated', (tester) async {
    final container = await containerWithCoco(tester);
    await pumpScreen(tester, container);

    late List<TagLibraryEntry> tags;
    await tester.runAsync(() async {
      await fillNewTag(tester, frequency: '150.325', name: 'Bandit');
      await tester.tap(find.widgetWithText(TextButton, 'Go back'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      tags = await container.read(tagLibraryProvider.future);
    });

    expect(tags.map((t) => t.tagName), ['Coco']);
  });

  testWidgets('no warning fires for a genuinely distinct tag', (tester) async {
    final container = await containerWithCoco(tester);
    await pumpScreen(tester, container);

    late List<TagLibraryEntry> tags;
    await tester.runAsync(() async {
      await fillNewTag(tester, frequency: '151.775', name: 'Bandit');
      tags = await container.read(tagLibraryProvider.future);
    });

    expect(find.byKey(const ValueKey('near_duplicate_tag_dialog')), findsNothing);
    expect(tags, hasLength(2));
  });

  group('saying which way a copy went (task 11.219, §2.5)', () {
    /// **The direction that will actually confuse people is editing the
    /// library and expecting the project to follow**, so that is the one the
    /// library screen has to state. It is a count and never the projects'
    /// names: a device can hold a project the person is only a viewer on,
    /// and naming it would tell them it exists.
    Future<ProviderContainer> containerWithCopies(
      WidgetTester tester,
      int copies,
    ) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        final user = await container.read(currentUserProvider.future);
        final library =
            await container.read(tagLibraryRepositoryProvider.future);
        final entry =
            sampleTagLibraryEntry(id: 'lib-1', lineageId: 'lineage-1');
        await library.insert(entry);
        final tagRepo = await container.read(tagRepositoryProvider.future);
        for (var i = 0; i < copies; i++) {
          final project = sampleProject(id: 'p$i', ownerUserId: user.userId);
          await db.insert(Tables.projects, project.toColumns());
          await tagRepo.copyFromLibrary(
            entry,
            projectId: project.projectId,
            modifiedBy: user.userId,
          );
        }
        // `allProjectsProvider` is autoDispose and writes owner memberships
        // as it builds, so a bare `read` can be disposed before the rebuild
        // that write triggers finishes. Hold a subscription for the test's
        // lifetime rather than racing it.
        container.listen(allProjectsProvider, (_, _) {});
        container.listen(tagLibraryProvider, (_, _) {});
        await primeTagLibrary(container);
        await container.read(activeProjectIdProvider.future);
        await container.read(allProjectsProvider.future);
        await container.read(deviceIdProvider.future);
        await library.nextColorHex();
      });
      return container;
    }

    testWidgets('a collar no project uses says nothing about copies',
        (tester) async {
      final container = await containerWithCopies(tester, 0);
      await pumpScreen(tester, container);
      await tester.runAsync(() async {
        await tester.tap(tagRowContaining('Coco'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(
        find.byKey(const ValueKey('tag_copy_provenance_info')),
        findsNothing,
        reason: 'there is nothing to warn about — no project holds a copy, '
            'so editing this reaches nobody and saying so would be noise',
      );
    });

    testWidgets('a collar two projects use says how many, never which',
        (tester) async {
      final container = await containerWithCopies(tester, 2);
      await pumpScreen(tester, container);
      // Task 11.321: the collar is under both projects' headings, closed.
      await openLibraryGroup(tester, 'p0');
      await tester.runAsync(() async {
        await tester.tap(tagRowContaining('Coco'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(
        find.text("Changes here won't reach the 2 projects using this tag"),
        findsOneWidget,
      );
      expect(
        find.textContaining('p0'),
        findsNothing,
        reason: 'a count is safe and a name is not — a device can hold a '
            'project the person is only a viewer on, and naming it would '
            'tell them it exists (cancelled task 11.29\'s standing rule)',
      );

      // The long form is behind an information affordance, per Michael's
      // simplicity instruction of 2026-09-07.
      await tester.tap(find.byKey(const ValueKey('tag_copy_provenance_info')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tag_copy_provenance_detail')),
        findsOneWidget,
      );
      expect(
        find.textContaining('will not reach those projects'),
        findsOneWidget,
        reason: 'the long form says what happens to the person\'s data, not '
            'what the feature is called',
      );
    });

    group('the push that fixes it everywhere (task 11.250)', () {
      Future<void> editFrequency(WidgetTester tester, String value) async {
        // Task 11.321: open the first project's heading if it is closed.
        if (tagRowLines(tester).isEmpty) await openLibraryGroup(tester, 'p0');
        await tester.tap(tagRowContaining('Coco'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Frequency (MHz)'),
          value,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      }

      testWidgets('is offered after saving, never automatic', (tester) async {
        final container = await containerWithCopies(tester, 1);
        await pumpScreen(tester, container);

        // **The whole chain, taps and final DB reads alike, runs inside one
        // `runAsync`.** Tapping "Save" starts a real (non-fake-clock)
        // database write, and reading the project's tag back afterwards is
        // another one; splitting either across a `runAsync` boundary is the
        // widget-test hang class `CLAUDE.md` documents — a real async gap
        // outside `runAsync` leaves the test waiting on a Future the fake
        // clock's dead pump loop can never resolve.
        await tester.runAsync(() async {
          await editFrequency(tester, '151.000');

          expect(find.text('Apply this to your projects?'), findsOneWidget);

          // "Not now" leaves the project's own copy alone.
          await tester.tap(find.text('Not now'));
          await tester.pumpAndSettle();

          final tagRepo = await container.read(tagRepositoryProvider.future);
          final copy = (await tagRepo.findByProject('p0')).single;
          expect(
            copy.frequencyMhz,
            150.325,
            reason: 'declining the offer must not touch the project\'s copy',
          );
        });
      });

      testWidgets('applying it updates every project\'s copy and reports '
          'the count', (tester) async {
        final container = await containerWithCopies(tester, 1);
        await pumpScreen(tester, container);

        await tester.runAsync(() async {
          await editFrequency(tester, '151.000');

          await tester.tap(
            find.byKey(const ValueKey('tag_library_push_confirm')),
          );
          // A real gap — `findByLineage` reads the database — sits between
          // this tap and the intent dialog appearing, and `pumpAndSettle`
          // alone has nothing scheduled to wait on while that read is in
          // flight (same reason `editFrequency` above waits for the save
          // itself). The delay gives it time to finish before pumping.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();

          // A versioned field moved (frequency), so task 11.32's question is
          // asked once — never once per project.
          expect(
            find.byKey(const ValueKey('tag_edit_intent_dialog')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(
              ValueKey('tag_edit_intent_${TagEditIntent.correction.name}'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('tag_edit_intent_save')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();

          expect(find.textContaining('Updated 1 project'), findsOneWidget);

          final tagRepo = await container.read(tagRepositoryProvider.future);
          final copy = (await tagRepo.findByProject('p0')).single;
          expect(copy.frequencyMhz, 151.000);

          final versions = await container.read(
            tagVersionRepositoryProvider.future,
          );
          expect(
            (await versions.currentFor(copy.tagId))!.frequencyMhz,
            151.000,
            reason: 'the project keeps its own version chain — this is not '
                'a raw column write',
          );
        });
      });
    });
  });

  group('the library is nobody\'s to lock (task 11.219)', () {
    /// **What this group used to assert, and why it now asserts the
    /// opposite.**
    ///
    /// It covered task 11.12's role-aware controls on this screen: a viewer
    /// of the active project got a tappable-but-refusing create button, and
    /// a contributor saw a padlock on a row whose tag belonged to a project
    /// they did not own.
    ///
    /// Copy-on-add moved both questions rather than answering them
    /// differently. This screen shows the device's own **tag library** —
    /// device-local, in no project, reaching no server — so there is no role
    /// to resolve and nothing here to refuse. **A viewer on somebody else's
    /// project may keep their own transmitter list, and always could have.**
    /// What they still cannot do is change a *project's* copy of a tag, and
    /// that is asserted where it happens: `tags_screen_test.dart` (moved off
    /// Project Setup by task 11.245) for the controls, and
    /// `refusal_messages_rendered_test.dart` for the
    /// `tag_edit_not_permitted` banner, in the same words and under the same
    /// key.
    ///
    /// Written as a test rather than deleted, because "this screen refuses
    /// nothing" is a claim somebody could break by accident.
    testWidgets('a viewer of the active project still owns their own list',
        (tester) async {
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => viewer),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, viewer.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: viewer.userId,
            role: ProjectRole.viewer,
          ).toColumns(),
        );
        final library =
            await container.read(tagLibraryRepositoryProvider.future);
        await library.insert(sampleTagLibraryEntry());
        await container
            .read(activeProjectIdProvider.notifier)
            .set(project.projectId);

        await primeTagLibrary(container);
        await container.read(deviceIdProvider.future);
        await container.read(currentUserProvider.future);
      });

      await pumpScreen(tester, container);

      expect(
        tester
            .widget<FloatingActionButton>(find.byType(FloatingActionButton))
            .onPressed,
        isNotNull,
        reason: 'a library entry is in no project — there is no role that '
            'could refuse it',
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.upload_file),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.byIcon(Icons.lock_outline),
        findsNothing,
        reason: 'the padlock previewed "you may read but not change this", '
            'which was true of a tag in somebody else\'s project and is not '
            'true of anything on this screen',
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });
  });


  /// **Task 11.32 at the screen layer.** The repository decides what a
  /// correction and a change *mean*; these two check that the screen asks the
  /// question exactly when it must, and never when it must not.
  group('editing a tag asks about earlier records — only when it has to', () {
    /// One tag, owned by the acting user's project, ready to edit.
    Future<ProviderContainer> containerWithATag(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        // `allProjectsProvider` is autoDispose: a bare `read` lets it drop the
        // moment its future resolves, and the `activeProjectIdProvider` change
        // below then rebuilds a disposed Ref. Holding a subscription is what
        // the screen itself does once pumped; this covers the window before
        // that. Opened inside `runAsync` because it starts a real database
        // read, which never completes in the fake-async zone.
        final projectsSub = container.listen(allProjectsProvider, (_, _) {});
        addTearDown(projectsSub.close);
        final db = (await container.read(appDatabaseProvider.future)).raw;
        final user = await container.read(currentUserProvider.future);
        final project = sampleProject(ownerUserId: user.userId);
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(projectId: project.projectId, userId: user.userId)
              .toColumns(),
        );
        // **The library entry the form edits.** Task 11.32's
        // correction-or-change question is about a *project's* tag — the
        // thing bearings point at — and lives on Project Setup since task
        // 11.219. What this group covers is the form itself: which fields
        // it shows, how the pulse-mode editor behaves, and that a recolour
        // asks nothing. A library entry has no version chain, so the
        // question is not asked here at all, which the last test in the
        // group states rather than leaves implicit.
        final library =
            await container.read(tagLibraryRepositoryProvider.future);
        await library.insert(sampleTagLibraryEntry());
        // Set the active project *before* pre-resolving the providers that
        // watch it. Reading `allProjectsProvider` first and then changing the
        // selection disposes it mid-flight, and the rebuild throws inside
        // `runAsync` rather than anywhere the test can see.
        await container.read(activeProjectIdProvider.notifier)
            .set(project.projectId);

        await primeTagLibrary(container);
        await container.read(allProjectsProvider.future);
        await container.read(deviceIdProvider.future);
        // The edit dialog reads these on the way in and on the way out; an
        // uncached first read inside the tap chain would be a real DB call
        // the fixed delays would have to blindly cover.
        final library2 =
            await container.read(tagLibraryRepositoryProvider.future);
        await library2.nextColorHex();
      });
      return container;
    }

    Future<void> openTheEditDialog(WidgetTester tester) async {
      // The row's line is '<freq> MHz · <name>' in the default frequency
      // order, and '<name> · <freq> MHz' once somebody sorts by name
      // (Michael, 2026-09-06). Since the line was made unwrappable it is
      // three `Text`s rather than one, so the row is found by the name piece
      // and tapped as a whole row — see `tagRowContaining`.
      await tester.tap(tagRowContaining('Coco'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    Future<void> saveTheForm(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    testWidgets('the chevron opens something called "Tag details"',
        (tester) async {
      // **Michael, 2026-09-06.** A chevron on a list row promises somewhere
      // to read the rest of a tag, and this form already is that: every
      // field the list dropped is on it, the date put on included. Renaming
      // it is the whole of the change — a separate read-only page would be a
      // second rendering of the same fields to keep true.
      final container = await containerWithATag(tester);
      await pumpScreen(tester, container);

      await tester.runAsync(() => openTheEditDialog(tester));
      await tester.pumpAndSettle();

      expect(find.text('Tag details'), findsOneWidget);
      expect(find.text('Edit tag'), findsNothing);
      // The field the list gave up is here, which is what makes dropping it
      // from the row a move rather than a loss.
      //
      // **"Date put on" was the other one and it is gone from both** (task
      // 11.243): it described a deployment, and this form describes a piece
      // of equipment. It is not a loss either — when a collar went on an
      // animal is a `Deployments` row now, recorded where the animal is
      // chosen.
      expect(find.textContaining('Date put on:'), findsNothing);
      expect(find.text('Status'), findsOneWidget);
    });

    testWidgets('changing the frequency of a library entry asks nothing, '
        'because nothing was recorded against it', (tester) async {
      // **Task 11.32's question is about a *project\'s* tag, and task
      // 11.219 is what makes that precise.** The question exists because
      // editing a tag rewrites what every bearing already recorded against
      // it claims — and a bearing names a project's copy. **Nothing is ever
      // recorded against a library entry**, so there is no history to
      // reinterpret and nothing honest to ask.
      //
      // The correction-or-change flow itself is covered where it happens:
      // `tags_screen_test.dart` (moved off Project Setup by task 11.245), on
      // a project's tag, with the version chain asserted there.
      final container = await containerWithATag(tester);
      await pumpScreen(tester, container);

      late List<TagLibraryEntry> tags;
      await tester.runAsync(() async {
        await openTheEditDialog(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Frequency (MHz)'),
          '150.51',
        );
        await saveTheForm(tester);

        expect(
          find.byKey(const ValueKey('tag_edit_intent_dialog')),
          findsNothing,
          reason: 'a library entry has no bearings and no version chain, so '
              'asking would be a question with no consequence either way',
        );

        tags = await container.read(tagLibraryProvider.future);
      });

      expect(tags.single.frequencyMhz, 150.51);
      await tester.runAsync(() async {
        final versions = await container.read(
          tagVersionRepositoryProvider.future,
        );
        expect(
          await tagVersionHistory(versions, 'tag-1'),
          isEmpty,
          reason: 'the library holds no history — a version records what a '
              'collar read when a bearing was taken, and none was',
        );
      });
    });

    testWidgets('Tag details shows the tag\'s own modes, and slot 1 has no '
        'control that would remove it', (tester) async {
      // **Michael\'s rule as a widget** (2026-09-07): *"up to three modes but
      // not fewer than 1."* A control that is not offered is a rule that
      // cannot be broken by pressing it — which is stronger than validating
      // afterwards and telling somebody off.
      final container = await containerWithATag(tester);
      await pumpScreen(tester, container);
      await tester.runAsync(() => openTheEditDialog(tester));
      await tester.pumpAndSettle();

      expect(find.text('Pulse modes'), findsOneWidget);
      // The fixture tag names no mode, which is the shape of a row written
      // before schema v12: it reads as one mode called Normal.
      expect(
        find.widgetWithText(TextField, 'Mode 1 name'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Mode 1 name'))
            .controller!
            .text,
        'Normal',
      );
      expect(
        find.byKey(const ValueKey('pulse_mode_remove_1')),
        findsNothing,
        reason: 'slot 1 cannot be switched off, so nothing offers to',
      );
      // And the unit control, which changes no tag and is offered to anybody.
      expect(find.byKey(const ValueKey('pulse_rate_unit_toggle')),
          findsOneWidget);
    });

    testWidgets('adding a mode to a library entry saves it, and asks nothing',
        (tester) async {
      // The mode editor itself is what this covers — that adding a slot and
      // typing a rate lands. Whether adding a mode has to ask about earlier
      // records is a question about a project's tag, and is covered on
      // Project Setup; see the note on the frequency test above.
      final container = await containerWithATag(tester);
      await pumpScreen(tester, container);

      late List<TagLibraryEntry> tags;
      await tester.runAsync(() async {
        await openTheEditDialog(tester);
        await tester.tap(find.byKey(const ValueKey('pulse_mode_add')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Mode 2 name'),
          'Mortality',
        );
        await tester.enterText(
          find.byKey(const ValueKey('pulse_mode_rate_2')),
          '120',
        );
        await saveTheForm(tester);

        expect(
          find.byKey(const ValueKey('tag_edit_intent_dialog')),
          findsNothing,
        );

        tags = await container.read(tagLibraryProvider.future);
      });

      final modes = tags.single.pulseModes;
      expect(modes.map((m) => m.name), ['Normal', 'Mortality']);
      expect(modes.last.rateBpm, 120);
    });

    testWidgets('the rate field follows the seconds-per-pulse preference, and '
        'the stored number stays in beats per minute', (tester) async {
      final container = await containerWithATag(tester);
      await pumpScreen(tester, container);

      late List<TagLibraryEntry> tags;
      await tester.runAsync(() async {
        await container
            .read(pulseRateUnitSettingProvider.notifier)
            .set(PulseRateUnit.secondsPerPulse);
        await openTheEditDialog(tester);
      });
      await tester.pumpAndSettle();

      // 40 bpm is 1.5 seconds between pulses, and the field says so.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('pulse_mode_rate_1')))
            .controller!
            .text,
        '1.5',
      );

      await tester.runAsync(() async {
        // Two seconds between pulses is 30 bpm. What lands in the database is
        // the beats-per-minute number, because nothing but the display ever
        // leaves that unit.
        await tester.enterText(
          find.byKey(const ValueKey('pulse_mode_rate_1')),
          '2',
        );
        await saveTheForm(tester);
        // No correction-or-change question: a library entry has no version
        // chain. See the note on the frequency test above.
        tags = await container.read(tagLibraryProvider.future);
      });

      expect(tags.single.pulseRate, 30);
    });

    testWidgets('task 11.191: the app-bar unit menu and the edit dialog\'s '
        'toggle are one preference, kept in step with no restart', (tester) async {
      final container = await containerWithATag(tester);
      await pumpScreen(tester, container);

      // The app-bar menu's tooltip names the stored preference, which
      // defaults to bpm.
      expect(container.read(pulseRateUnitProvider), PulseRateUnit.bpm);
      expect(
        find.byTooltip('Pulse rate unit (Beats per minute)'),
        findsOneWidget,
      );

      // Open the app-bar menu and choose seconds-per-pulse.
      await tester.tap(find.byKey(const ValueKey('pulse_rate_unit_menu_app_bar')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Seconds per pulse'));
      await tester.pumpAndSettle();

      // The stored preference changed — one provider, not a screen-local
      // copy — and the app bar's own tooltip reflects it immediately.
      expect(
        container.read(pulseRateUnitProvider),
        PulseRateUnit.secondsPerPulse,
      );
      expect(
        find.byTooltip('Pulse rate unit (Seconds per pulse)'),
        findsOneWidget,
      );

      // Opening the edit dialog's own toggle shows the same choice, with no
      // restart in between — it is reading the same provider, not a snapshot
      // taken when the dialog first appeared.
      await tester.runAsync(() => openTheEditDialog(tester));
      await tester.pumpAndSettle();
      final dialogToggle = tester.widget<SegmentedButton<PulseRateUnit>>(
        find.byKey(const ValueKey('pulse_rate_unit_toggle')),
      );
      expect(dialogToggle.selected, {PulseRateUnit.secondsPerPulse});

      // And changing it back from inside the dialog is visible on the app
      // bar's menu underneath, again with no restart.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('pulse_rate_unit_toggle')),
          matching: find.text('bpm'),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(pulseRateUnitProvider), PulseRateUnit.bpm);
      expect(
        find.byTooltip('Pulse rate unit (Beats per minute)'),
        findsOneWidget,
      );
    });

    // **`recolouring asks nothing at all` moved to Project Setup**
    // (task 11.244). A library entry has no colour to recolour any more —
    // see the form test at the top of this file — and the assertion it made
    // is about a *project's* tag, where a colour edit writes through to the
    // animal and still must not raise the correction-or-change question.
    // `tags_screen_test.dart` holds it (moved off Project Setup by task
    // 11.245).
  });

  group('sort order (task 11.178)', () {
    /// The tag names down the list, whichever way round the row prints them.
    ///
    /// **Order-agnostic on purpose (Michael, 2026-09-06).** The row leads with
    /// whichever field the list is sorted by, so a helper that assumed
    /// `'<freq> MHz · <name>'` would read an empty list under name order and
    /// report "the sort produced nothing" — which is what it did — rather than
    /// "the row is laid out the other way". The name is the half that is not
    /// the frequency.
    List<String> tagNamesInOrder(WidgetTester tester) => tagRowLines(tester)
        .map((s) => s.split(' · ').firstWhere((part) => !part.endsWith('MHz')))
        .toList();

    Future<ProviderContainer> containerWithThreeTags(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final repo = await container.read(tagLibraryRepositoryProvider.future);
        // Frequency order: Tag 10, Tag 2, Tag 1. Name order (natural, not
        // lexical): Tag 1, Tag 2, Tag 10.
        await repo.insert(
          sampleTagLibraryEntry(
            id: 't10',
            tagName: 'Tag 10',
            frequencyMhz: 150.100,
          ),
        );
        await repo.insert(
          sampleTagLibraryEntry(
            id: 't2',
            tagName: 'Tag 2',
            frequencyMhz: 150.200,
          ),
        );
        await repo.insert(
          sampleTagLibraryEntry(
            id: 't1',
            tagName: 'Tag 1',
            frequencyMhz: 150.300,
          ),
        );
        await primeTagLibrary(container);
        await container.read(activeProjectIdProvider.future);
        await container.read(deviceIdProvider.future);
        await container.read(currentUserProvider.future);
      });
      return container;
    }

    testWidgets('defaults to frequency order, ascending', (tester) async {
      final container = await containerWithThreeTags(tester);
      await pumpScreen(tester, container);

      expect(tagNamesInOrder(tester), ['Tag 10', 'Tag 2', 'Tag 1']);
    });

    testWidgets('switching to name order uses a natural, not lexical, sort',
        (tester) async {
      final container = await containerWithThreeTags(tester);
      await pumpScreen(tester, container);

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by name'));
      await tester.pumpAndSettle();

      // A plain string sort would read 'Tag 10' < 'Tag 2' < 'Tag 1' —
      // naturalCompare instead orders the embedded numbers 1, 2, 10.
      expect(tagNamesInOrder(tester), ['Tag 1', 'Tag 2', 'Tag 10']);
    });

    testWidgets('the chosen order persists across a fresh provider container',
        (tester) async {
      final container = await containerWithThreeTags(tester);
      await pumpScreen(tester, container);

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by name'));
      await tester.pumpAndSettle();

      // A brand-new container reads the same (fake, module-level)
      // SharedPreferencesAsyncPlatform backing store — standing in for a
      // relaunch, since nothing about the setting is per-container state.
      final freshContainer = ProviderContainer();
      addTearDown(freshContainer.dispose);
      await tester.runAsync(() async {
        final order = await freshContainer.read(tagSortOrderSettingProvider.future);
        expect(order, TagSortOrder.name);
      });
    });

    // The export button's `onPressed` is wired to `sortedTags` — the same
    // sorted-in-Dart list the `ListView` builds from, computed once per
    // `build()` — rather than `tagsAsync.value!` (the provider's raw,
    // unsorted order), so export and the on-screen list cannot disagree.
    // Exercising that through `FilePicker.saveFile` here would mean driving
    // a real file-save dialog from a widget test; `sortTags` itself is
    // covered directly above and in `natural_sort_test.dart`.
  });

  // ---------------------------------------------------------------------
  // Michael's two notes on the tag database, 2026-09-06.
  //
  // Both are about the *list*, and neither is about what a tag is. They are
  // tested here rather than left to a device look because they are assertions
  // about text a widget test can read exactly — unlike the reason they were
  // asked for, which is that the list "is text heavy" and only a phone can
  // settle.
  group('what a row says, and in what order', () {
    /// Every row's title, verbatim and in list order.
    List<String> tagTitlesInOrderOf(WidgetTester tester) => tagRowLines(tester);

    Future<ProviderContainer> containerWith(
      WidgetTester tester,
      List<TagLibraryEntry> tags,
    ) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final repo = await container.read(tagLibraryRepositoryProvider.future);
        for (final tag in tags) {
          await repo.insert(tag);
        }
        await primeTagLibrary(container);
      });
      return container;
    }

    testWidgets('the date put on is not on the list at all', (tester) async {
      final container = await containerWith(tester, [sampleTagLibraryEntry()]);
      await pumpScreen(tester, container);

      expect(
        find.textContaining('since '),
        findsNothing,
        reason:
            'The date a tag went on an animal is on the details form, which '
            'is one tap away and where it has always been editable. On the '
            'list it is a third of a line on every row, spent on the field '
            'somebody is least often scanning for.',
      );
    });

    testWidgets('the row is the frequency and the name and nothing else',
        (tester) async {
      // **Michael, 2026-09-06:** "The special notes (ie view only) should
      // move to the tag details page. This will allow all the info on the tag
      // database table be on one line (frequency name) which will allow the
      // font size to be increased a bit for readability."
      final container = await containerWith(tester, [sampleTagLibraryEntry()]);
      await pumpScreen(tester, container);

      expect(tagTitlesInOrderOf(tester), ['150.325 MHz · Coco']);
      expect(find.textContaining('active'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ListTile).first,
          matching: find.textContaining('bpm'),
        ),
        findsNothing,
        reason:
            'The pulse rate moved to Tag details with the rest of the second '
            'line. It is still on that page, which is what makes this a move '
            'rather than a loss. (Task 11.191 put a "bpm" segment label on '
            'the app bar, which is outside the row and not what this checks.)',
      );
      // A one-line `ListTile` is what the taller font is paid for with. A
      // check that passed because the row went blank would be worth nothing,
      // so the line itself is asserted above.
      expect(
        tester.getRect(find.byType(ListTile).first).height,
        lessThan(64),
        reason: 'a two-line ListTile is 72 logical pixels or more',
      );
    });

    testWidgets('a lost, recovered or malfunctioning tag still says so — with an icon',
        (tester) async {
      // **Michael, 2026-09-06**, choosing between three offered treatments:
      // "use either a little icon or color state of the text (grey etc.)",
      // then picking the one that tells the three non-active states apart.
      // The word itself is on Tag details, one tap away.
      // One active tag and one of each non-active state in the same list, so
      // the greying is compared against a live row rather than against a
      // colour somebody wrote down — a treatment that fired on every row
      // would say nothing at all, and only a mixed list can catch that.
      final container = await containerWith(tester, [
        sampleTagLibraryEntry(id: 'ok', tagName: 'Alive', frequencyMhz: 150.100),
        sampleTagLibraryEntry(id: 'l', tagName: 'Lost', frequencyMhz: 150.200)
            .copyWith(status: TagStatus.lost),
        sampleTagLibraryEntry(id: 'r', tagName: 'Back', frequencyMhz: 150.300)
            .copyWith(status: TagStatus.recovered),
        sampleTagLibraryEntry(id: 'm', tagName: 'Broken', frequencyMhz: 150.400)
            .copyWith(status: TagStatus.malfunction),
      ]);
      await pumpScreen(tester, container);

      for (final icon in [
        Icons.help_outline,
        Icons.check_circle_outline,
        Icons.warning_amber_rounded,
      ]) {
        expect(
          find.byIcon(icon),
          findsOneWidget,
          reason:
              'This is the row somebody scanning the list is looking for. '
              'Showing nothing at all would have made it indistinguishable '
              'from a live one until it was opened.',
        );
      }

      /// The colour the row leading with [frequency] is drawn in.
      Color? colourOf(String frequency) => tester
          .widget<Text>(find.textContaining(frequency))
          .style
          ?.color;

      final live = colourOf('150.100');
      expect(live, isNotNull, reason: 'the active row has the ordinary text colour');
      for (final greyed in ['150.200', '150.300', '150.400']) {
        expect(
          colourOf(greyed),
          isNot(live),
          reason:
              'a non-active row is greyed so the state is visible before the '
              'icon is read; the icon then says which state, because colour '
              'alone fails in sun and for a colour-blind reader',
        );
      }
    });

    testWidgets('a long tag name cuts off rather than wrapping the row',
        (tester) async {
      // **Michael's own concern about this change, 2026-09-06:** "My concern
      // with forcing it all to one line and increasing the font size is that
      // it won't all fit on a single line and then wrap." It cannot: the name
      // is the only flexible piece and it is capped at one line, so the row's
      // height does not depend on how long anybody's tag names are.
      final container = await containerWith(tester, [
        sampleTagLibraryEntry(id: 'short', tagName: 'B', frequencyMhz: 150.100),
        sampleTagLibraryEntry(
          id: 'long',
          tagName: 'Kestrel Nest Site Seven — north ridge, second bird',
          frequencyMhz: 150.200,
        ),
      ]);
      usePhoneGeometry(tester);
      await pumpScreen(tester, container);
      await tester.pumpAndSettle();

      final heights =
          tester.widgetList<ListTile>(find.byType(ListTile)).length;
      expect(heights, 2);
      final shortRow = tester.getRect(find.byType(ListTile).first).height;
      final longRow = tester.getRect(find.byType(ListTile).last).height;
      expect(
        longRow,
        shortRow,
        reason:
            'the row with the 50-character name must be exactly as tall as '
            'the one with a single-character name',
      );
      // And the frequency is never what gets cut — it is the fixed-width
      // field somebody scans a column of.
      expect(find.textContaining('150.200 MHz'), findsOneWidget);
    });

    testWidgets('the row leads with whichever field the list is sorted by',
        (tester) async {
      final container = await containerWith(tester, [
        sampleTagLibraryEntry(id: 't1', tagName: 'Coco', frequencyMhz: 150.325),
      ]);
      await pumpScreen(tester, container);

      expect(
        tagTitlesInOrderOf(tester),
        ['150.325 MHz · Coco'],
        reason: 'Frequency is the default order, so frequency leads.',
      );

      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sort by name'));
      await tester.pumpAndSettle();

      expect(
        tagTitlesInOrderOf(tester),
        ['Coco · 150.325 MHz'],
        reason:
            'Sorted by name, the names are what the eye runs down, so they '
            'go first. Leaving the frequency in front would put every value '
            'the sort ordered behind a name of unpredictable width.',
      );
    });
  });

  group('task 11.198: the badge icon, the padlock and the greyed line meet '
      'the WCAG floor against the Scaffold background they render on', () {
    // Relative luminance and contrast ratio per WCAG 2.x, computed from the
    // real values rather than eyeballed. https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    double linearComponent(double c) =>
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();

    double relativeLuminance(Color color) {
      final r = linearComponent(color.r);
      final g = linearComponent(color.g);
      final b = linearComponent(color.b);
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    }

    double contrastRatio(Color a, Color b) {
      final la = relativeLuminance(a);
      final lb = relativeLuminance(b);
      final lighter = la > lb ? la : lb;
      final darker = la > lb ? lb : la;
      return (lighter + 0.05) / (darker + 0.05);
    }

    // WCAG 1.4.11 "Non-text Contrast": 3:1 for icons and other graphical UI
    // components. This screen's row background is the bare Scaffold — there
    // is no card under it — so that is the background these are measured
    // against, not white.
    const floor = 3.0;

    Future<ProviderContainer> containerWith(
      WidgetTester tester,
      List<TagLibraryEntry> tags,
    ) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final repo = await container.read(tagLibraryRepositoryProvider.future);
        for (final tag in tags) {
          await repo.insert(tag);
        }
        await primeTagLibrary(container);
      });
      return container;
    }

    Future<void> pumpThemed(
      WidgetTester tester,
      ProviderContainer container,
      ThemeData theme,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: theme, home: const TagDatabaseScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final entry in {
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      testWidgets(
          'in ${entry.key} mode: badge icon, padlock and greyed text all '
          'clear $floor:1 against the scaffold background', (tester) async {
        final theme = entry.value;
        final background = theme.scaffoldBackgroundColor;

        final container = await containerWith(tester, [
          sampleTagLibraryEntry(id: 'l', tagName: 'Lost', frequencyMhz: 150.200)
              .copyWith(status: TagStatus.lost),
        ]);
        await pumpThemed(tester, container, theme);

        final badgeIcon = tester.widget<Icon>(find.byIcon(Icons.help_outline));
        final badgeColor = badgeIcon.color;
        expect(badgeColor, isNotNull);
        final badgeContrast = contrastRatio(badgeColor!, background);
        expect(
          badgeContrast,
          greaterThanOrEqualTo(floor),
          reason: 'the status badge icon was drawn in `outline` (measured '
              '1.12:1 light / 1.28:1 dark against this background) until '
              'task 11.198 — a colour a reader can no longer see is not a '
              'signal',
        );

        final line = tester
            .widget<Text>(find.textContaining('150.200'))
            .style
            ?.color;
        expect(line, isNotNull);
        expect(
          contrastRatio(line!, background),
          greaterThanOrEqualTo(floor),
          reason: 'the greyed-out tag name/frequency line must stay legible '
              '— it is the row itself, not decoration',
        );
      });
    }

    // **The padlock's contrast test is gone with the padlock (task
    // 11.219)**, and the reason is worth writing down rather than leaving as
    // an absence. It measured the icon a non-owner saw beside a tag they
    // could not edit, after task 11.198 found it drawn in `outline` at
    // 1.12:1 light / 1.28:1 dark. There is no such row on this screen now:
    // the tag library is device-local and nothing in it is read-only.
    //
    // **The colour that icon was fixed to is still measured** — the status
    // badge above uses the same `onSurfaceVariant`, in both themes, against
    // the same background, so the finding 11.198 made is still guarded by
    // this group. What is not measured any more is a widget that no longer
    // exists.
  });

  /// **Task 11.229.** The name field moves to the top of "Tag details", and
  /// the dialog's small type gets measurably bigger — without touching the
  /// grey task 11.200 already fixed, and without reopening the 139-pixel
  /// overflow task 11.126 paid for. `TagEditDialog` is exercised directly
  /// here — add, edit and read-only are the same widget with a flag, so one
  /// set of checks against all three constructions covers every route in.
  group('task 11.229: the name leads, the small type is bigger, nothing '
      'overflows', () {
    Future<void> pumpDialog(
      WidgetTester tester,
      TagEditDialog dialog, {
      Size size = phoneSize,
      double textScale = 1.0,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
              ),
              child: child ?? const SizedBox.shrink(),
            ),
            home: Scaffold(body: dialog),
          ),
        ),
      );
      // Task 11.229 wrote here that `pumpAndSettle()` "waited past its own
      // 10-minute timeout at every text scale above 1.0". **That was a
      // wrong cause written into a comment** — task 11.232 measured the
      // hang and it was never the pump: `collectLayoutOverflows` was
      // swallowing the test's own failure because its `reason` quoted a
      // stripe (see `text_scale_probe.dart`). `pumpAndSettle` settles this
      // dialog fine; this file's `setUp` pins the cursor blink for exactly
      // that.
      await tester.pumpAndSettle();
    }

    /// A tag with every optional field populated — two extra pulse modes,
    /// a custom (non-palette) colour so the Advanced section starts
    /// expanded, and a name long enough to be a realistic worst case —
    /// so a "nothing overflows" check is against the full dialog, not the
    /// empty one.
    Tag stressTag() => sampleTag(
          tagName: 'Great Horned Owl Female Adult',
          pulseMode1Name: 'Normal',
          pulseMode2Name: 'Mortality',
          pulseMode2RateBpm: 120,
          pulseMode3Name: 'Hibernation',
          pulseMode3RateBpm: 20,
        ).copyWith(colorHex: '#123456');

    testWidgets('Add tag: the name field comes before frequency', (tester) async {
      installFakeSharedPreferences();
      await pumpDialog(
        tester,
        TagEditDialog(initialColorHex: TagColorPalette.defaultColor),
      );

      // The *direct* child of the dialog's `SingleChildScrollView` — not a
      // descendant search, which also matches the pulse-modes editor's own
      // nested `Column` and fails with "too many elements".
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final column = scrollView.child! as Column;
      final labels = [
        for (final child in column.children)
          if (child is TextField && child.decoration?.labelText != null)
            child.decoration!.labelText,
      ];
      expect(
        labels.indexOf('Tag ID'),
        lessThan(labels.indexOf('Frequency (MHz)')),
        reason: 'Michael opens this dialog to see which animal it is; the '
            'name must lead rather than sit behind frequency and the whole '
            'pulse-mode editor',
      );
      // A new tag's name field is deliberately empty first — there is
      // nothing yet to lead with, and Save already refuses a blank one.
      expect(find.widgetWithText(TextField, 'Tag ID'), findsOneWidget);
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Tag ID'),
      );
      expect(nameField.controller?.text, isEmpty);
    });

    testWidgets('Edit tag: the name field comes before frequency, populated',
        (tester) async {
      installFakeSharedPreferences();
      final tag = stressTag();
      await pumpDialog(
        tester,
        TagEditDialog(existing: tag, initialColorHex: tag.colorHex),
      );

      // The *direct* child of the dialog's `SingleChildScrollView` — not a
      // descendant search, which also matches the pulse-modes editor's own
      // nested `Column` and fails with "too many elements".
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final column = scrollView.child! as Column;
      final labels = [
        for (final child in column.children)
          if (child is TextField && child.decoration?.labelText != null)
            child.decoration!.labelText,
      ];
      expect(
        labels.indexOf('Tag ID'),
        lessThan(labels.indexOf('Frequency (MHz)')),
      );
      final nameField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Tag ID'),
      );
      expect(nameField.controller?.text, tag.tagName);
    });

    testWidgets('Read-only: the name field still comes first', (tester) async {
      installFakeSharedPreferences();
      final tag = stressTag();
      await pumpDialog(
        tester,
        TagEditDialog(existing: tag, readOnly: true, initialColorHex: tag.colorHex),
      );

      // The *direct* child of the dialog's `SingleChildScrollView` — not a
      // descendant search, which also matches the pulse-modes editor's own
      // nested `Column` and fails with "too many elements".
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final column = scrollView.child! as Column;
      final labels = [
        for (final child in column.children)
          if (child is TextField && child.decoration?.labelText != null)
            child.decoration!.labelText,
      ];
      expect(
        labels.indexOf('Tag ID'),
        lessThan(labels.indexOf('Frequency (MHz)')),
        reason: 'a viewer opens this page precisely because the row did not '
            'carry enough — the name must lead here too',
      );
    });

    testWidgets(
        'the grey stays the grey: onSurfaceVariant is unchanged on the '
        'Advanced toggle', (tester) async {
      installFakeSharedPreferences();
      final tag = stressTag();
      await pumpDialog(
        tester,
        TagEditDialog(existing: tag, initialColorHex: tag.colorHex),
      );

      final advancedLabel = tester.widget<Text>(
        find.textContaining('Advanced: custom hex color'),
      );
      final theme = AppTheme.light();
      expect(
        advancedLabel.style?.color,
        theme.colorScheme.onSurfaceVariant,
        reason: 'task 11.200 measured onSurfaceVariant at 5.35:1 light / '
            '6.19:1 dark, both clearing WCAG AA — this task changes the '
            'size of this label, never its colour',
      );
    });

    testWidgets(
        'the small type is measurably bigger: section labels and the pulse '
        'rate unit toggle', (tester) async {
      installFakeSharedPreferences();
      final tag = stressTag();
      await pumpDialog(
        tester,
        TagEditDialog(existing: tag, initialColorHex: tag.colorHex),
      );

      final theme = AppTheme.light();
      final titleMediumSize = theme.textTheme.titleMedium!.fontSize!;
      expect(titleMediumSize, greaterThan(12));

      for (final label in ['Status', 'Color', 'Pulse modes']) {
        final size = tester.widget<Text>(find.text(label)).style?.fontSize;
        expect(
          size,
          titleMediumSize,
          reason: '"$label" was a hard-coded 12px, w700 label — task 11.229 '
              'moves it onto titleMedium (16px, w700), the size the app\'s '
              'own type scale already names for a section header',
        );
      }
      final advancedSize = tester
          .widget<Text>(find.textContaining('Advanced: custom hex color'))
          .style
          ?.fontSize;
      expect(advancedSize, titleMediumSize);

      final toggle = tester.widget<SegmentedButton<PulseRateUnit>>(
        find.byType(SegmentedButton<PulseRateUnit>),
      );
      final toggleSize =
          toggle.style?.textStyle?.resolve(const <WidgetState>{})?.fontSize;
      expect(
        toggleSize,
        12.0,
        reason: 'labelSmall is 9.5px — the theme\'s smallest role, measured '
            'too small to read, and used nowhere else in the app — bumped '
            'to 12px here',
      );
      expect(toggleSize, greaterThan(9.5));
    });

    testWidgets("Also add to project: label is also titleMedium", (tester) async {
      installFakeSharedPreferences();
      await pumpDialog(
        tester,
        TagEditDialog(
          initialColorHex: TagColorPalette.defaultColor,
          projects: [sampleProject(id: 'project-1')],
        ),
      );
      final theme = AppTheme.light();
      final size = tester
          .widget<Text>(find.text('Also add to project'))
          .style
          ?.fontSize;
      expect(size, theme.textTheme.titleMedium!.fontSize);
    });

    /// **Task 11.232 — the whole ladder, every path, and a test that fails
    /// rather than hangs.**
    ///
    /// Task 11.229 stopped this ladder at xxLarge and recorded that above it
    /// the dialog "never finishes laying out" — ten idle minutes to the
    /// harness timeout, three times. **The dialog was never the thing that
    /// hung.** It laid out in 86 ms at xxxLarge; what it produced was one
    /// striped `Row`, and the 11.229 test's `reason` quoted that stripe into
    /// its own failure message, which `collectLayoutOverflows` then swallowed
    /// as if it were an overflow — the binding asserted, the test could not
    /// complete, and nothing burned any CPU while it waited. Fixed in
    /// `text_scale_probe.dart`, held by `text_scale_probe_test.dart`.
    ///
    /// Two real defects were behind the stripe and the clip, both fixed in
    /// `tag_form.dart` and both re-measured in Roboto before being called
    /// defects on a phone: the pulse-modes header `Row` squeezed its title to
    /// 19.7 px at AX5 (a `Row` gives a non-flexible child no width bound, so
    /// only the title could give way), and the dense `DropdownButtonFormField`
    /// boxed its label at one line, cutting a wrapped label from AX3 up.
    ///
    /// **Three modes is the ceiling the data model has** — slots 1 to 3 in
    /// `TagFields`, and Michael's rule of "up to three"; the plan entry's
    /// "four or more" cannot be built, so this is the fullest dialog there is.
    ///
    /// Each test carries its own `timeout:` because `testWidgets` otherwise
    /// pins ten minutes and ignores `flutter test --timeout`; if a hang ever
    /// comes back, it reports in two minutes with the scale in its name.
    const ladderTimeout = Timeout(Duration(minutes: 2));

    for (final scale in iosTextScalesUpward) {
      testWidgets(
          'Add tag (with a project to link): no stripe and no silent clip at '
          '${textScaleName(scale)}, 6.1-inch phone width',
          timeout: ladderTimeout, (tester) async {
        installFakeSharedPreferences();
        final overflows = collectLayoutOverflows();
        await pumpDialog(
          tester,
          TagEditDialog(
            initialColorHex: TagColorPalette.defaultColor,
            projects: [sampleProject(id: 'project-1')],
          ),
          textScale: scale,
        );
        final verdict = textScaleVerdict(tester, overflows);
        // `printOnFailure`, never the `reason`: a reason that quotes a stripe
        // is what hung task 11.229.
        printOnFailure('Add tag at ${textScaleName(scale)}: $verdict');
        expect(verdict.clean, isTrue, reason: 'see the printed verdict');

        // The dropdown's selected label is shown whole. In the test font
        // "Don't add to a project" is wider than the field at every scale,
        // so it wraps; the box must be as tall as the wrapped text, which is
        // a value, not an absence. (Roboto fits it on one line until AX2 and
        // wraps from AX3 — the same mechanism, reached later; task 11.234
        // renamed the label and this has not been re-measured in Roboto.)
        final label = tester.renderObject<RenderParagraph>(
          find.text("Don't add to a project").first,
        );
        // One line, measured rather than computed: the engine rounds line
        // heights, and 16 × 1.5 × 1.35 is not what it draws at xxxLarge.
        final oneLine = TextPainter(
          text: TextSpan(text: "Don't", style: label.text.style),
          textDirection: TextDirection.ltr,
          textScaler: label.textScaler,
        )..layout();
        expect(
          label.size.height,
          greaterThanOrEqualTo(2 * oneLine.height - 0.5),
          reason: 'the label needs two lines here and the dense dropdown gave '
              'it one; non-dense, the box follows the text',
        );
        oneLine.dispose();
      });

      for (final readOnly in [false, true]) {
        final path = readOnly ? 'Read-only' : 'Edit tag';
        testWidgets(
            '$path (every field populated): no stripe and no silent clip at '
            '${textScaleName(scale)}, 6.1-inch phone width',
            timeout: ladderTimeout, (tester) async {
          installFakeSharedPreferences();
          final overflows = collectLayoutOverflows();
          final tag = stressTag();
          await pumpDialog(
            tester,
            TagEditDialog(
              existing: tag,
              readOnly: readOnly,
              initialColorHex: tag.colorHex,
            ),
            textScale: scale,
          );
          final verdict = textScaleVerdict(tester, overflows);
          printOnFailure('$path at ${textScaleName(scale)}: $verdict');
          expect(verdict.clean, isTrue, reason: 'see the printed verdict');

          // The header by position: the toggle sits inside the dialog's
          // content column at every scale — a `Row` let it run 3.4 to 255 px
          // past the right edge — and it is never scaled or ellipsised, so
          // its height is at least one line of its own label.
          final content = tester.getRect(find.byType(SingleChildScrollView));
          final toggle = tester.getRect(
            find.byKey(const ValueKey('pulse_rate_unit_toggle')),
          );
          expect(toggle.right, lessThanOrEqualTo(content.right + 0.5));
          expect(toggle.left, greaterThanOrEqualTo(content.left - 0.5));
          expect(toggle.height, greaterThanOrEqualTo(12 * scale));
          // And the title is a title, not a column of letters: it keeps at
          // least the width its own first word needs.
          final title = tester.renderObject<RenderParagraph>(
            find.text('Pulse modes'),
          );
          final firstWord = TextPainter(
            text: TextSpan(text: 'Pulse', style: title.text.style),
            textDirection: TextDirection.ltr,
            textScaler: title.textScaler,
          )..layout();
          expect(
            title.size.width,
            greaterThanOrEqualTo(firstWord.width - 0.5),
            reason: 'in a Row the title was given 19.7 px at AX5 on a phone',
          );
          firstWord.dispose();
        });
      }
    }

    /// **The reopen trigger for `_DryLayoutFromIntrinsics`, mechanised.**
    /// Material's `SegmentedButton` throws when asked for a dry layout,
    /// which a `Wrap` inside an `IntrinsicWidth` does. The day this test
    /// fails, Flutter has fixed it and the shim in `tag_form.dart` should be
    /// deleted rather than kept out of habit.
    testWidgets(
        'Material SegmentedButton still cannot be dry-laid-out under a Wrap '
        'in an IntrinsicWidth (delete _DryLayoutFromIntrinsics when this '
        'fails)', (tester) async {
      final errors = <String>[];
      final original = FlutterError.onError;
      FlutterError.onError = (details) => errors.add(details.exceptionAsString());
      addTearDown(() => FlutterError.onError = original);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IntrinsicWidth(
              child: Column(
                children: [
                  Wrap(
                    children: [
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('a')),
                          ButtonSegment(value: 2, label: Text('b')),
                        ],
                        selected: const {1},
                        onSelectionChanged: (_) {},
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        errors.any(
          (e) => e.contains('does not have any constraints before it has been laid out'),
        ),
        isTrue,
        reason: 'no such error: Flutter now dry-lays-out SegmentedButton, so '
            'the shim around PulseRateUnitToggle has nothing left to work '
            'around — delete it and this test',
      );
    });

    testWidgets('the shimmed toggle lays out under a Wrap in an IntrinsicWidth',
        (tester) async {
      installFakeSharedPreferences();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: IntrinsicWidth(
                child: Column(
                  children: [
                    Wrap(
                      children: [
                        PulseRateUnitToggle(
                          unit: PulseRateUnit.bpm,
                          onChanged: (_) {},
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('bpm'), findsOneWidget);
    });
  });

  testWidgets('the import preview says a spreadsheet cannot say which collar '
      'a row is', (tester) async {
    // §2.8. A `lineage_id` is what says two projects hold one animal, and a
    // file that could assert one could assert that two unrelated collars are
    // the same animal — a claim about the primary scientific record. So the
    // import mints one per row, and the loss is on the screen in words
    // rather than left to be discovered.
    await tester.pumpWidget(
      MaterialApp(
        home: TagImportPreviewScreen(
          preview: TagCsvImport.preview(
            'frequency_mhz,tag_name,date_put_on\n150.1,A,2026-01-15\n',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('new tags in your library'),
      findsOneWidget,
    );
    expect(
      find.textContaining('a second, separate tag'),
      findsOneWidget,
      reason: 'the loss is that a re-import does not match the collar you '
          'already have, and saying only "new tags" would not carry it',
    );
  });

  /// **Task 11.288.** Michael, building a 50-tag library: "there doesn't
  /// appear to be a way to delete a tag. I should be able to select a
  /// single tag or select multiple, or select all and trash them."
  group('deleting from the Tag Library (task 11.288)', () {
    Future<ProviderContainer> containerWithThreeTags(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final repo = await container.read(tagLibraryRepositoryProvider.future);
        await repo.insert(
          sampleTagLibraryEntry(id: 'a', tagName: 'Alpha', frequencyMhz: 150.100),
        );
        await repo.insert(
          sampleTagLibraryEntry(id: 'b', tagName: 'Bravo', frequencyMhz: 150.200),
        );
        await repo.insert(
          sampleTagLibraryEntry(id: 'c', tagName: 'Charlie', frequencyMhz: 150.300),
        );
        await primeTagLibrary(container);
        await container.read(activeProjectIdProvider.future);
        await container.read(deviceIdProvider.future);
        await container.read(currentUserProvider.future);
      });
      return container;
    }

    group('one entry, no selection mode', () {
      /// **The swipe gesture itself is exercised once, directly, by invoking
      /// `Dismissible`'s own `confirmDismiss` callback rather than a real
      /// drag.** `Dismissible`'s gesture mechanics are Flutter's own and
      /// already covered by its test suite; a real `tester.drag` here ties
      /// the callback's completion to the gesture recognizer's animation
      /// clock, which raced against this screen's real (non-fake-clock)
      /// database read in a way that never reliably settled. What matters
      /// for this screen is that the swipe reaches the *same* confirmation
      /// dialog the selection app bar's delete button does — proven once
      /// here — so every other case (confirm, cancel, undo, several, all)
      /// is covered through that second, reliable path instead of chaining
      /// more gesture-driven calls.
      testWidgets('a swipe reveals a confirmation naming the tag count',
          (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        final dismissible =
            tester.widget<Dismissible>(find.byKey(const ValueKey('a')));
        unawaited(dismissible.confirmDismiss!(DismissDirection.endToStart));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        expect(find.text('Delete this tag?'), findsOneWidget);
        expect(
          find.textContaining('projects'),
          findsNothing,
          reason: 'nothing holds a copy of this collar, so the confirmation '
              'has nothing to say about copies surviving',
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });

      /// One entry, selected without ever entering multi-select (a long
      /// press followed immediately by the close button would also do it,
      /// but the delete button reaches the same one-entry case through the
      /// selection app bar without needing that extra step described here).
      Future<void> selectOne(WidgetTester tester, String tagName) async {
        await tester.longPress(tagRowContaining(tagName));
        await tester.pumpAndSettle();
      }

      testWidgets('confirming removes it from the list, and offers undo',
          (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await selectOne(tester, 'Alpha');
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_selected')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_confirm')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        // Asserted on the rendered list rather than by re-reading the
        // provider — `pumpAndSettle` above already proved the screen
        // finished rebuilding on the post-delete data.
        expect(tagRowContaining('Alpha'), findsNothing);
        expect(find.text('Tag deleted'), findsOneWidget);
        expect(find.text('UNDO'), findsOneWidget);
      });

      testWidgets('cancelling the confirmation leaves the tag in place',
          (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await selectOne(tester, 'Alpha');
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_selected')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(tagRowContaining('Alpha'), findsOneWidget);
      });

      testWidgets('UNDO brings the deleted tag back', (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await selectOne(tester, 'Alpha');
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_selected')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_confirm')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        await tester.tap(find.text('UNDO'));
        // `tagLibraryProvider` keeps its previous value visible while it
        // recomputes after `ref.invalidate` — there is no spinner and
        // nothing scheduled for `pumpAndSettle` to wait on, so the fresh
        // (post-restore) data can still be in flight after one round of
        // delay-then-pump. A second round is what actually catches it.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();

        expect(tagRowContaining('Alpha'), findsOneWidget);
      });
    });

    group('several and all, by long-press selection', () {
      testWidgets('a long press enters selection mode with that row checked',
          (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await tester.longPress(tagRowContaining('Alpha'));
        await tester.pumpAndSettle();

        expect(find.text('1 selected'), findsOneWidget);
        expect(find.byType(Checkbox), findsNWidgets(3));
        expect(
          find.byKey(const ValueKey('tag_library_selection_close')),
          findsOneWidget,
        );
      });

      testWidgets('tapping a second row while selecting adds it, tapping '
          'again removes it', (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await tester.longPress(tagRowContaining('Alpha'));
        await tester.pumpAndSettle();
        await tester.tap(tagRowContaining('Bravo'));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);

        await tester.tap(tagRowContaining('Bravo'));
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
      });

      testWidgets('select-all checks every visible row, and toggles back off',
          (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await tester.longPress(tagRowContaining('Alpha'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tag_library_select_all')));
        await tester.pumpAndSettle();

        expect(find.text('3 selected'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('tag_library_select_all')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('tag_library_selection_close')),
          findsNothing,
          reason: 'deselecting every row leaves nothing selected, which is '
              'this screen\'s own definition of "not selecting" any more',
        );
      });

      testWidgets('the close button leaves selection mode without deleting '
          'anything', (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await tester.longPress(tagRowContaining('Alpha'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('tag_library_selection_close')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Tag Library'), findsOneWidget);
        expect(find.byType(Checkbox), findsNothing);

        late List<TagLibraryEntry> tags;
        await tester.runAsync(() async {
          tags = await container.read(tagLibraryProvider.future);
        });
        expect(tags, hasLength(3));
      });

      testWidgets('deleting several at once names how many, and removes '
          'exactly those', (tester) async {
        final container = await containerWithThreeTags(tester);
        await pumpScreen(tester, container);

        await tester.longPress(tagRowContaining('Alpha'));
        await tester.pumpAndSettle();
        await tester.tap(tagRowContaining('Bravo'));
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_selected')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        expect(find.text('Delete 2 tags?'), findsOneWidget);

        await tester.tap(
          find.byKey(const ValueKey('tag_library_delete_confirm')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();

        expect(tagRowContaining('Alpha'), findsNothing);
        expect(tagRowContaining('Bravo'), findsNothing);
        expect(tagRowContaining('Charlie'), findsOneWidget);
        expect(find.text('2 tags deleted'), findsOneWidget);
        // Selection mode ends with the delete — the close button is gone.
        expect(
          find.byKey(const ValueKey('tag_library_selection_close')),
          findsNothing,
        );
      });
    });

    group('the confirmation names surviving copies, from libraryCopyCount',
        () {
      Future<ProviderContainer> containerWithACopiedTag(
        WidgetTester tester,
      ) async {
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          ],
        );
        addTearDown(container.dispose);
        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          final user = await container.read(currentUserProvider.future);
          final library =
              await container.read(tagLibraryRepositoryProvider.future);
          final entry = sampleTagLibraryEntry(
            id: 'lib-1',
            tagName: 'Coco',
            lineageId: 'lineage-1',
          );
          await library.insert(entry);
          final tagRepo = await container.read(tagRepositoryProvider.future);
          final project = sampleProject(id: 'p0', ownerUserId: user.userId);
          await db.insert(Tables.projects, project.toColumns());
          await tagRepo.copyFromLibrary(
            entry,
            projectId: project.projectId,
            modifiedBy: user.userId,
          );
          container.listen(allProjectsProvider, (_, _) {});
          container.listen(tagLibraryProvider, (_, _) {});
          await primeTagLibrary(container);
          await container.read(activeProjectIdProvider.future);
          await container.read(allProjectsProvider.future);
          await container.read(deviceIdProvider.future);
        });
        return container;
      }

      testWidgets('says a project still holds a copy, and that it stays',
          (tester) async {
        final container = await containerWithACopiedTag(tester);
        await pumpScreen(tester, container);

        // Selection-app-bar path rather than swipe — see the note on
        // `dismissibleFor` above for why the swipe's own two callbacks are
        // exercised directly rather than through a real drag gesture; the
        // selection app bar's delete button is a plain `onPressed`, which
        // does not have that problem.
        await tester.longPress(tagRowContaining('Coco'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('tag_library_delete_selected')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        expect(
          find.textContaining('still in use'),
          findsOneWidget,
          reason: 'a person clearing test tags will assume their projects '
              'are emptied too — the confirmation says what survives',
        );
        expect(
          find.textContaining('does not touch that copy'),
          findsOneWidget,
        );
        expect(
          find.textContaining('p0'),
          findsNothing,
          reason: 'a count is safe, a project name is not (§2.5)',
        );
      });
    });
  });
}
