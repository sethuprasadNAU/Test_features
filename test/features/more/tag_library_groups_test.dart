import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/tag_library_project_order_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/tags/library_groups.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/tag_library_priming.dart';
import '../../support/tag_row_text.dart';

/// **Task 11.321, item 1 — the Tag Library, grouped by project.**
///
/// Michael, 2026-09-30: the library is in practice project-specific, and he
/// does not want to see every tag at once. Grouped automatically by the
/// projects each collar is on, collapsed, plus "Not on any project". No
/// folders anybody makes, and a collar on two projects is under both.
///
/// The fixture: three collars. Coco is on Mesa and Kaibab, Juno is on Mesa
/// only, and Rex is on no project.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  group('groupLibraryByProject', () {
    final coco = sampleTagLibraryEntry(id: 'coco', lineageId: 'l-coco');
    final juno = sampleTagLibraryEntry(
      id: 'juno',
      lineageId: 'l-juno',
      tagName: 'Juno',
    );
    final rex = sampleTagLibraryEntry(
      id: 'rex',
      lineageId: 'l-rex',
      tagName: 'Rex',
    );
    final holders = {
      'l-coco': {'p-mesa': 'Mesa', 'p-kaibab': 'Kaibab'},
      'l-juno': {'p-mesa': 'Mesa'},
    };

    test('a collar on two projects is under both, and one on none is last',
        () {
      final groups = groupLibraryByProject([coco, juno, rex], holders);
      expect(
        [for (final g in groups) g.title],
        ['Kaibab', 'Mesa', kNotOnAnyProjectTitle],
      );
      expect([for (final e in groups[0].entries) e.tagId], ['coco']);
      expect([for (final e in groups[1].entries) e.tagId], ['coco', 'juno'],
          reason: 'the order handed in (the screen\'s sort) is kept');
      expect([for (final e in groups[2].entries) e.tagId], ['rex']);
    });

    test('no "Not on any project" heading when every collar is on one', () {
      final groups = groupLibraryByProject([coco, juno], holders);
      expect([for (final g in groups) g.title], ['Kaibab', 'Mesa']);
    });

    test('the person\'s own order comes first; projects not in it follow by '
        'name; an id with no project leaves no gap', () {
      final groups = groupLibraryByProject(
        [coco, juno, rex],
        holders,
        projects: {'p-mesa': 'Mesa', 'p-kaibab': 'Kaibab', 'p-zed': 'Zed', 'p-alp': 'Alp'},
        order: ['p-zed', 'p-gone', 'p-mesa'],
      );
      expect([for (final g in groups) g.title],
          ['Zed', 'Mesa', 'Alp', 'Kaibab', kNotOnAnyProjectTitle]);
    });

    test('project names sort naturally — Site 2 before Site 10', () {
      final groups = groupLibraryByProject([coco], {
        'l-coco': {'a': 'Site 10', 'b': 'Site 2'},
      });
      expect([for (final g in groups) g.title], ['Site 2', 'Site 10']);
    });
  });

  group('tagMatchesSearch (task 11.322)', () {
    final coco = sampleTagLibraryEntry(id: 'coco'); // Coco, 150.325
    test('an empty search matches everything', () {
      expect(tagMatchesSearch(coco, ''), isTrue);
      expect(tagMatchesSearch(coco, '   '), isTrue);
    });
    test('the name, in any case, anywhere in it', () {
      expect(tagMatchesSearch(coco, 'coc'), isTrue);
      expect(tagMatchesSearch(coco, 'OCO'), isTrue);
      expect(tagMatchesSearch(coco, 'juno'), isFalse);
    });
    test('the frequency as the row writes it, three decimals', () {
      expect(tagMatchesSearch(coco, '150.325'), isTrue);
      expect(tagMatchesSearch(coco, '150.3'), isTrue);
      expect(tagMatchesSearch(coco, '325'), isTrue);
      expect(tagMatchesSearch(coco, '150.4'), isFalse);
    });
    test('surrounding spaces are ignored', () {
      expect(tagMatchesSearch(coco, '  coco '), isTrue);
    });
  });

  group('projectsHoldingEachLineage', () {
    test('reads live copies in live projects, with the project names', () async {
      final database = await AppDatabase.openInMemory();
      addTearDown(database.close);
      final db = database.raw;
      final library = TagLibraryRepository(db);
      await db.insert(Tables.users, sampleUser(id: 'user-1').toColumns());
      for (final (id, name) in [('p-mesa', 'Mesa'), ('p-gone', 'Gone')]) {
        await db.insert(
          Tables.projects,
          sampleProject(id: id)
              .copyWith(projectName: name)
              .toColumns(),
        );
      }
      final coco = sampleTagLibraryEntry(id: 'coco', lineageId: 'l-coco');
      await library.insert(coco);
      final tags = TagRepository(db);
      for (final project in ['p-mesa', 'p-gone']) {
        await tags.copyFromLibrary(
          coco,
          projectId: project,
          modifiedBy: 'user-1',
        );
      }
      await db.update(
        Tables.projects,
        {'deleted_at': '2026-09-30T00:00:00.000Z'},
        where: 'project_id = ?',
        whereArgs: ['p-gone'],
      );

      expect(await library.projectsHoldingEachLineage(), {
        'l-coco': {'p-mesa': 'Mesa'},
      }, reason: 'a project this device deleted holds nothing an edit here '
          'could reach — the same rule libraryCopyCount keeps (task 11.288)');
    });
  });

  group('the screen', () {
    /// [emptyProjects] adds Site 9, a project with no tags yet, and Ridge,
    /// a project somebody else owns where this person is only a viewer.
    Future<ProviderContainer> seeded(
      WidgetTester tester, {
      bool emptyProjects = false,
    }) async {
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
        final tagRepo = await container.read(tagRepositoryProvider.future);
        for (final (id, name) in [('p-mesa', 'Mesa'), ('p-kaibab', 'Kaibab')]) {
          await db.insert(
            Tables.projects,
            sampleProject(id: id, ownerUserId: user.userId)
                .copyWith(projectName: name)
                .toColumns(),
          );
        }
        final coco = sampleTagLibraryEntry(id: 'coco', lineageId: 'l-coco');
        final juno = sampleTagLibraryEntry(
          id: 'juno',
          lineageId: 'l-juno',
          tagName: 'Juno',
          frequencyMhz: 150.400,
        );
        final rex = sampleTagLibraryEntry(
          id: 'rex',
          lineageId: 'l-rex',
          tagName: 'Rex',
          frequencyMhz: 150.500,
        );
        for (final e in [coco, juno, rex]) {
          await library.insert(e);
        }
        for (final (entry, project) in [
          (coco, 'p-mesa'),
          (coco, 'p-kaibab'),
          (juno, 'p-mesa'),
        ]) {
          await tagRepo.copyFromLibrary(
            entry,
            projectId: project,
            modifiedBy: user.userId,
          );
        }
        if (emptyProjects) {
          await db.insert(
            Tables.projects,
            sampleProject(id: 'p-site9', ownerUserId: user.userId)
                .copyWith(projectName: 'Site 9')
                .toColumns(),
          );
          await db.insert(
            Tables.users,
            sampleUser(id: 'someone-else', email: 'else@x.com').toColumns(),
          );
          await db.insert(
            Tables.projects,
            sampleProject(id: 'p-ridge', ownerUserId: 'someone-else')
                .copyWith(projectName: 'Ridge')
                .toColumns(),
          );
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(
              id: 'm-ridge',
              projectId: 'p-ridge',
              userId: user.userId,
              role: ProjectRole.viewer,
            ).toColumns(),
          );
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(
              id: 'm-ridge-owner',
              projectId: 'p-ridge',
              userId: 'someone-else',
            ).toColumns(),
          );
        }
        await primeTagLibrary(container);
        await container.read(activeProjectIdProvider.future);
        await container.read(deviceIdProvider.future);
      });
      return container;
    }

    /// In the tab shell, at phone size — the height the screen really has.
    Future<void> pump(WidgetTester tester, ProviderContainer container) async {
      await pumpInAppShell(
        tester,
        container: container,
        screen: const TagDatabaseScreen(),
        tabIndex: 4,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('WATCHED RED: one heading per project and one for none, all '
        'closed, each with its count', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);

      expect(find.text('Kaibab'), findsOneWidget);
      expect(find.text('Mesa'), findsOneWidget);
      expect(find.text(kNotOnAnyProjectTitle), findsOneWidget);
      expect(find.text('2 tags'), findsOneWidget, reason: 'Mesa: Coco, Juno');
      expect(find.text('1 tag'), findsNWidgets(2), reason: 'Kaibab, and none');
      expect(
        tagRowLines(tester),
        isEmpty,
        reason: 'closed by default — Michael does not want to see every tag '
            'at once',
      );
    });

    testWidgets('opening a heading shows its tags, and a collar on two '
        'projects is under both', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);

      await tester.tap(
        find.byKey(const ValueKey('tag_library_group_header_p-mesa')),
      );
      await tester.pumpAndSettle();
      expect(tagRowLines(tester), hasLength(2));
      expect(tagRowContaining('Coco'), findsOneWidget);
      expect(tagRowContaining('Juno'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('tag_library_group_header_p-kaibab')),
      );
      await tester.pumpAndSettle();
      expect(
        tagRowContaining('Coco'),
        findsNWidgets(2),
        reason: 'one collar, two projects, listed under each',
      );

      await tester.tap(
        find.byKey(const ValueKey('tag_library_group_header_p-mesa')),
      );
      await tester.pumpAndSettle();
      expect(tagRowLines(tester), hasLength(1), reason: 'closed again');
    });

    testWidgets('select-all opens every heading, so nothing checked is out '
        'of sight, and checks each collar once', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);
      await tester.tap(
        find.byKey(const ValueKey('tag_library_group_header_')),
      );
      await tester.pumpAndSettle();
      await tester.longPress(tagRowContaining('Rex'));
      await tester.pumpAndSettle();

      expect(tagRowLines(tester), hasLength(4),
          reason: 'Coco twice, Juno and Rex — every heading is open');
      await tester.tap(find.byKey(const ValueKey('tag_library_select_all')));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget,
          reason: 'three collars, however many headings they sit under');
    });

    // ---- task 11.322 item 2: search ----------------------------------------
    // Michael, 2026-09-30: with every heading closed, finding one collar means
    // opening its project. A search box, by frequency or name; matching rows
    // show under every heading, opening those headings; clearing it restores
    // what was open.
    Future<void> search(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('tag_library_search')),
        text,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('WATCHED RED: a name opens the headings that hold it and '
        'hides the rest', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);

      await search(tester, 'ju');

      expect(tagRowLines(tester), hasLength(1));
      expect(tagRowContaining('Juno'), findsOneWidget);
      expect(find.text('Mesa'), findsOneWidget);
      expect(find.text('1 tag'), findsOneWidget,
          reason: 'the count is of what matches');
      expect(find.text('Kaibab'), findsNothing,
          reason: 'nothing under it matches, so it is not shown');
      expect(find.text(kNotOnAnyProjectTitle), findsNothing);
    });

    testWidgets('a frequency finds a collar on no project', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);

      await search(tester, '150.5');

      expect(tagRowLines(tester), hasLength(1));
      expect(tagRowContaining('Rex'), findsOneWidget);
      expect(find.text(kNotOnAnyProjectTitle), findsOneWidget);
    });

    testWidgets('a collar on two projects shows under both', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);

      await search(tester, 'coco');

      expect(tagRowContaining('Coco'), findsNWidgets(2));
      expect(find.text('Mesa'), findsOneWidget);
      expect(find.text('Kaibab'), findsOneWidget);
    });

    testWidgets('clearing the search restores exactly what was open',
        (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);
      await tester.tap(
        find.byKey(const ValueKey('tag_library_group_header_p-kaibab')),
      );
      await tester.pumpAndSettle();
      expect(tagRowLines(tester), hasLength(1), reason: 'Kaibab: Coco');

      await search(tester, 'juno'); // opens Mesa, which was closed
      expect(tagRowContaining('Juno'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tag_library_search_clear')));
      await tester.pumpAndSettle();

      expect(find.text('Kaibab'), findsOneWidget);
      expect(find.text(kNotOnAnyProjectTitle), findsOneWidget);
      expect(tagRowLines(tester), hasLength(1),
          reason: 'only Kaibab is open again; Mesa, opened by the search, '
              'is closed once more');
      expect(tagRowContaining('Juno'), findsNothing);
    });

    testWidgets('a search with no match says so', (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);

      await search(tester, 'zzz');

      expect(find.text('No tags match.'), findsOneWidget);
      expect(tagRowLines(tester), isEmpty);
    });

    testWidgets('select-all while searching checks only what is shown',
        (tester) async {
      final container = await seeded(tester);
      await pump(tester, container);
      await search(tester, 'o'); // Coco and Juno; Rex has no "o" in it

      await tester.longPress(tagRowContaining('Juno'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tag_library_select_all')));
      await tester.pumpAndSettle();

      expect(find.text('2 selected'), findsOneWidget,
          reason: 'Rex is in the library but not on screen, so select-all '
              'must not check it');
    });

    testWidgets('WATCHED RED: a heading reads as a heading — bigger and bolder '
        'than a tag, on its own band of color', (tester) async {
      // Michael's phone, 2026-09-30: "The project names are smaller than the
      // tags and the same color. Makes it hard to distinguish section titles
      // from tags."
      final container = await seeded(tester);
      await pump(tester, container);
      await tester.tap(
        find.byKey(const ValueKey('tag_library_group_header_p-mesa')),
      );
      await tester.pumpAndSettle();

      TextStyle styleOf(Finder text) =>
          tester.widget<Text>(text).style ??
          DefaultTextStyle.of(tester.element(text)).style;
      final heading = styleOf(find.text('Mesa'));
      final row = tester
          .widgetList<Text>(
            find.descendant(
              of: tagRowContaining('Juno'),
              matching: find.byType(Text),
            ),
          )
          .first
          .style!;
      expect(heading.fontSize, greaterThan(row.fontSize!),
          reason: 'a heading is larger than the rows under it');
      expect(heading.fontWeight, FontWeight.w700);

      final band = find.ancestor(
        of: find.text('Mesa'),
        matching: find.byKey(const ValueKey('tag_library_group_band_p-mesa')),
      );
      expect(band, findsOneWidget,
          reason: 'the heading sits on a band, so it is not mistaken for a row '
              'by its text alone');
      final scheme = Theme.of(tester.element(band)).colorScheme;
      expect(
        (tester.widget<Container>(band).decoration as BoxDecoration).color,
        scheme.secondaryContainer,
      );
      expect(heading.color, scheme.onSecondaryContainer);
    });

    group('dragging a tag onto a project adds it there (task 11.321)', () {
      // Michael, 2026-09-30: "click and drag a tag in the database from one
      // project to another to assign it. Mainly from the not on any project
      // category to an actual project."

      /// Drags [tagId]'s handle onto [projectId]'s heading and lets go.
      Future<void> dragOnto(
        WidgetTester tester,
        String tagId,
        String projectId,
      ) async {
        final from = tester.getCenter(
          find.byKey(ValueKey('tag_library_drag_$tagId')),
        );
        final to = tester.getCenter(
          find.byKey(ValueKey('tag_library_group_header_$projectId')),
        );
        final gesture = await tester.startGesture(from);
        await gesture.moveBy(const Offset(0, -20));
        await tester.pump();
        await gesture.moveTo(to);
        await tester.pump();
        await tester.runAsync(() async {
          await gesture.up();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });
        await tester.pumpAndSettle();
      }

      Future<List<String>> projectsHolding(
        ProviderContainer container,
        WidgetTester tester,
        String lineage,
      ) async {
        final db = (await tester.runAsync(
          () => container.read(appDatabaseProvider.future),
        ))!.raw;
        final rows = await tester.runAsync(
          () => db.query(
            Tables.tags,
            where: 'lineage_id = ? AND deleted_at IS NULL',
            whereArgs: [lineage],
          ),
        );
        return [for (final r in rows!) r['project_id'] as String]..sort();
      }

      testWidgets('WATCHED RED: a project with no tags still has a heading to '
          'drop on', (tester) async {
        final container = await seeded(tester, emptyProjects: true);
        await pump(tester, container);
        expect(find.text('Site 9'), findsOneWidget);
        expect(find.text('0 tags'), findsNWidgets(2),
            reason: 'Site 9 and Ridge, both empty');
      });

      testWidgets('WATCHED RED: Rex, on no project, dragged onto Site 9 — asked '
          'first, then added', (tester) async {
        final container = await seeded(tester, emptyProjects: true);
        await pump(tester, container);
        await openLibraryGroup(tester, null);

        await dragOnto(tester, 'rex', 'p-site9');
        expect(find.text('Add Rex to Site 9?'), findsOneWidget);
        expect(find.text('The project gets its own copy of the tag.'),
            findsOneWidget);
        expect(await projectsHolding(container, tester, 'l-rex'), isEmpty,
            reason: 'nothing is written before the person says Add');

        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('tag_library_assign_confirm')),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });
        expect(await projectsHolding(container, tester, 'l-rex'), ['p-site9']);
        expect(find.text('Rex added to Site 9.'), findsOneWidget);
      });

      testWidgets('dragged from one project to another, it is added, the first '
          'project keeps it, and Cancel writes nothing', (tester) async {
        final container = await seeded(tester, emptyProjects: true);
        await pump(tester, container);
        await openLibraryGroup(tester, 'p-mesa');

        await dragOnto(tester, 'juno', 'p-site9');
        expect(find.text('Add Juno to Site 9?'), findsOneWidget);
        expect(
          find.text('The project gets its own copy of the tag. Mesa keeps '
              'its copy.'),
          findsOneWidget,
          reason: 'a drag adds; it never takes a tag off a project, which '
              'is an owner\'s act',
        );
        await tester.tap(find.byKey(const ValueKey('tag_library_assign_cancel')));
        await tester.pumpAndSettle();
        expect(await projectsHolding(container, tester, 'l-juno'), ['p-mesa']);
      });

      testWidgets('onto a project that already has it, it says so and writes '
          'nothing', (tester) async {
        final container = await seeded(tester, emptyProjects: true);
        await pump(tester, container);
        await openLibraryGroup(tester, 'p-mesa');

        await dragOnto(tester, 'coco', 'p-kaibab');
        expect(find.text('Coco is already on Kaibab.'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
      });

      testWidgets('onto a project where this person is a viewer, it says why '
          'and writes nothing', (tester) async {
        final container = await seeded(tester, emptyProjects: true);
        await pump(tester, container);
        await openLibraryGroup(tester, null);

        await dragOnto(tester, 'rex', 'p-ridge');
        expect(find.textContaining('Viewers cannot add a tag to a project'),
            findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(await projectsHolding(container, tester, 'l-rex'), isEmpty);
      });
    });

    group('the headings can be dragged into any order (task 11.321)', () {
      // Michael, 2026-09-30: "I should also be able to click and drag and
      // change the order of the projects in the tag library."

      double topOf(WidgetTester tester, String title) =>
          tester.getTopLeft(find.text(title)).dy;

      testWidgets('WATCHED RED: Mesa dragged above Kaibab stays there, and is '
          'still there next time the screen opens', (tester) async {
        final container = await seeded(tester);
        await pump(tester, container);
        expect(topOf(tester, 'Kaibab'), lessThan(topOf(tester, 'Mesa')),
            reason: 'by name until somebody says otherwise');

        final handle = find.byKey(const ValueKey('tag_library_reorder_p-mesa'));
        final gesture = await tester.startGesture(tester.getCenter(handle));
        await tester.pump(const Duration(milliseconds: 50));
        final target = tester.getTopLeft(find.text('Kaibab')).dy - 30;
        final start = tester.getCenter(handle).dy;
        for (var i = 1; i <= 10; i++) {
          await gesture.moveBy(Offset(0, (target - start) / 10));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await gesture.up();
        await tester.pumpAndSettle();

        expect(topOf(tester, 'Mesa'), lessThan(topOf(tester, 'Kaibab')));
        expect(
          topOf(tester, kNotOnAnyProjectTitle),
          greaterThan(topOf(tester, 'Kaibab')),
          reason: '"Not on any project" stays last',
        );

        // Saved on this phone: a fresh container — what the next launch
        // gets — reads the same order back.
        final fresh = ProviderContainer();
        addTearDown(fresh.dispose);
        final saved = await tester.runAsync(
          () => fresh.read(tagLibraryProjectOrderProvider.future),
        );
        expect(saved!.take(2), ['p-mesa', 'p-kaibab']);
      });

      testWidgets('"Not on any project" has no handle — it is not a project',
          (tester) async {
        final container = await seeded(tester);
        await pump(tester, container);
        expect(find.byKey(const ValueKey('tag_library_reorder_p-mesa')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('tag_library_reorder_')), findsNothing);
      });
    });
  });
}
