import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/features/more/screens/new_season_screen.dart';
import 'package:tritrack/widgets/saving_filled_button.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.56 — the New season screen.**
///
/// The engine is tested table by table in `season_clone_test.dart`; this
/// file is about what the person sees and taps: the counts are the real
/// ones, the dead-animal choice is offered only when there is one, the
/// button says why it is disabled, and one tap makes the season and makes
/// it the active project.
void main() {
  setUp(installFakeSharedPreferences);

  const source = 'ponui-2025';
  const owner = 'user-owner';
  late ProviderContainer container;
  late AppDatabase database;

  Future<void> seed(
    WidgetTester tester, {
    bool withDead = true,
    bool withPositions = true,
  }) async {
    final project = sampleProject(
      id: source,
      ownerUserId: owner,
    ).copyWith(projectName: 'Ponui 2025');
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentProjectProvider.overrideWith((ref) async => project),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: owner, email: 'owner@x.com'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      database = await container.read(appDatabaseProvider.future);
      final db = database.raw;
      await db.insert(
        Tables.users,
        sampleUser(id: owner, email: 'owner@x.com').toColumns(),
      );
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(projectId: source, userId: owner).toColumns(),
      );
      await db.insert(
        Tables.individuals,
        sampleIndividual(
          id: 'marie',
          projectId: source,
          name: 'Marie',
        ).toColumns(),
      );
      if (withDead) {
        await db.insert(
          Tables.individuals,
          sampleIndividual(
            id: 'kea',
            projectId: source,
            name: 'Kea',
            status: IndividualStatus.dead,
          ).toColumns(),
        );
      }
      await db.insert(
        Tables.tags,
        sampleTag(id: 'collar-a', projectId: source, tagName: 'A').toColumns(),
      );
      await db.insert(
        Tables.tags,
        sampleTag(id: 'collar-b', projectId: source, tagName: 'B').toColumns(),
      );
      await db.insert(
        Tables.deployments,
        sampleDeployment(
          id: 'a-on-marie',
          projectId: source,
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
        ).toColumns(),
      );
      await db.insert(
        Tables.observations,
        sampleObservation(
          id: 'obs-1',
          projectId: source,
          userId: owner,
          tagId: 'collar-a',
          sessionId: null,
          tagVersionId: null,
        ).toColumns(),
      );
      if (withPositions) {
        // Both at the fixture's July moment, inside Marie's open deployment
        // of collar A from January — so both are Marie's last known.
        await db.insert(
          Tables.estimatedPositions,
          sampleEstimatedPosition(
            id: 'est-1',
            projectId: source,
            tagId: 'collar-a',
          ).toColumns(),
        );
        await db.insert(
          Tables.actualTagLocations,
          sampleActualLocation(
            id: 'loc-1',
            projectId: source,
            tagId: 'collar-a',
            tagVersionId: null,
            userId: owner,
          ).toColumns(),
        );
      }
      await container.read(activeProjectIdProvider.notifier).set(source);
      // Resolved here, on the real clock and before the first pump: the
      // plan is a database read, and a widget test's fake clock never
      // finishes one (CLAUDE.md's rule, and the sibling animals test's
      // `resolve`). The listener keeps the autoDispose provider alive.
      container.listen(newSeasonPlanProvider(source), (_, _) {});
      await container.read(newSeasonPlanProvider(source).future);
    });
  }

  /// In the tab shell at phone geometry, because half of what this file
  /// asserts is that a control is findable and tappable — the one claim a
  /// bare pump at 1200x2600 cannot make.
  Future<void> pump(WidgetTester tester) => pumpInAppShell(
    tester,
    container: container,
    screen: const NewSeasonScreen(projectId: source),
    tabIndex: 4,
  );

  /// Scrolls the button into view before reading or tapping it: the screen
  /// is a list, and on a phone the button is below the fold once the
  /// dead-animal switch is showing.
  /// Scrolls the screen's list until [finder] is built and on screen.
  /// `ensureVisible` cannot find a `ListView` child below the fold — it was
  /// never built — so this scrolls the screen's own list instead.
  Future<Finder> reveal(
    WidgetTester tester,
    Finder finder, {
    double delta = 120,
  }) async {
    await tester.scrollUntilVisible(
      finder,
      delta,
      scrollable: find
          .descendant(
            of: find.byType(NewSeasonScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    return finder;
  }

  Future<Finder> createButton(WidgetTester tester) async {
    final finder = find.byKey(const ValueKey('new_season_create'));
    // `ensureVisible` cannot find a `ListView` child that is below the fold
    // — it was never built — so scroll the screen's own list instead.
    await tester.scrollUntilVisible(
      finder,
      120,
      scrollable: find
          .descendant(
            of: find.byType(NewSeasonScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    return finder;
  }

  Future<void> act(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('says what carries over, with the counts, and what stays', (
    tester,
  ) async {
    await seed(tester);
    await pump(tester);

    expect(find.text('2 animals'), findsOneWidget);
    expect(find.text('2 tags'), findsOneWidget);
    expect(
      find.text('1 record of which tag an animal wore, and when'),
      findsOneWidget,
    );
    // Below the fold at phone height once both switches are showing.
    await reveal(tester, find.text('What stays in "Ponui 2025"'));
    expect(
      find.textContaining('Every bearing, note and no-signal record'),
      findsOneWidget,
    );
    // The team is not there yet, and the screen says so rather than
    // showing one.
    await reveal(tester, find.textContaining('Only you, as owner.'));
    expect(find.textContaining('share its join code'), findsOneWidget);
  });

  testWidgets('the button is disabled with its reason until a name is typed', (
    tester,
  ) async {
    await seed(tester);
    await pump(tester);

    final finder = await createButton(tester);
    SavingFilledButton button() => tester.widget<SavingFilledButton>(finder);
    expect(button().onPressed, isNull);
    await reveal(tester, find.text('Give the new season a name first.'));

    // Back up to the name field, which scrolled out of the list above.
    await tester.enterText(
      await reveal(
        tester,
        find.byKey(const ValueKey('new_season_name')),
        delta: -120,
      ),
      'Ponui 2026',
    );
    await tester.pumpAndSettle();
    await createButton(tester);
    expect(button().onPressed, isNotNull);
    expect(find.text('Give the new season a name first.'), findsNothing);
  });

  testWidgets('the dead-animal and last-position choices are offered only '
      'when there is something to choose about', (tester) async {
    await seed(tester, withDead: false, withPositions: false);
    await pump(tester);
    expect(find.byKey(const ValueKey('new_season_include_dead')), findsNothing);
    expect(
      find.byKey(const ValueKey('new_season_include_positions')),
      findsNothing,
    );
    expect(find.text('1 animal'), findsOneWidget);
    await reveal(
      tester,
      find.text(
        'Every bearing, note, no-signal record, position estimate and '
        'truth point.',
      ),
    );
  });

  testWidgets('last known positions: offered with the counts, on by default, '
      'and the "what stays" sentence follows the switch', (tester) async {
    await seed(tester);
    await pump(tester);

    final tile = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('new_season_include_positions')),
    );
    expect(tile.value, isTrue, reason: 'Michael: defaults to on');
    expect(find.text('Bring over last known positions'), findsOneWidget);
    expect(find.textContaining('1 estimate and 1 truth point'), findsOneWidget);
    await reveal(
      tester,
      find.textContaining('except the most recent one for each animal'),
    );

    await tester.tap(
      find.byKey(const ValueKey('new_season_include_positions')),
    );
    await tester.pumpAndSettle();
    await reveal(
      tester,
      find.text(
        'Every bearing, note, no-signal record, position estimate and '
        'truth point.',
      ),
    );
  });

  testWidgets('with the switch on, each animal\'s last estimate and truth '
      'point are in the new season', (tester) async {
    await seed(tester);
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('new_season_name')),
      'Ponui 2026',
    );
    await tester.pumpAndSettle();
    final finder = await createButton(tester);
    await act(tester, () async {
      await tester.tap(finder);
    });
    final projects = await tester.runAsync(
      () => ProjectRepository(database.raw).findAll(),
    );
    final season = projects!.singleWhere((p) => p.projectName == 'Ponui 2026');
    final counts = await tester.runAsync(() async {
      Future<int> n(String table) async =>
          (await database.raw.rawQuery(
                'SELECT count(*) AS n FROM $table WHERE project_id = ?',
                [season.projectId],
              )).single['n']!
              as int;
      return (
        estimates: await n(Tables.estimatedPositions),
        truthPoints: await n(Tables.actualTagLocations),
        bearings: await n(Tables.observations),
      );
    });
    expect(counts!.estimates, 1);
    expect(counts.truthPoints, 1);
    expect(counts.bearings, 0);
  });

  testWidgets('one tap starts the season and makes it the active project', (
    tester,
  ) async {
    await seed(tester);
    await pump(tester);

    await tester.enterText(
      find.byKey(const ValueKey('new_season_name')),
      'Ponui 2026',
    );
    await tester.pumpAndSettle();
    final finder = await createButton(tester);
    await act(tester, () async {
      await tester.tap(finder);
    });

    final projects = await tester.runAsync(
      () => ProjectRepository(database.raw).findAll(),
    );
    expect(projects, hasLength(2));
    final season = projects!.singleWhere((p) => p.projectName == 'Ponui 2026');
    expect(season.lineageId, source);
    expect(season.ownerUserId, owner);
    expect(container.read(activeProjectIdProvider).value, season.projectId);
    // Both animals came across, the dead one as dead: the default is to
    // include them.
    final animals = await tester.runAsync(
      () => IndividualRepository(database.raw).findByProject(season.projectId),
    );
    expect(animals!.map((a) => a.name), unorderedEquals(['Marie', 'Kea']));
    expect(
      animals.singleWhere((a) => a.name == 'Kea').status,
      IndividualStatus.dead,
    );
    expect(find.textContaining('Started "Ponui 2026"'), findsOneWidget);
  });

  testWidgets('switching the dead animals off updates the count and leaves '
      'them behind', (tester) async {
    await seed(tester);
    await pump(tester);

    expect(find.text('Include the animal recorded as dead'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new_season_include_dead')));
    await tester.pumpAndSettle();
    expect(find.text('1 animal'), findsOneWidget);
    expect(find.text('2 animals'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('new_season_name')),
      'Ponui 2026',
    );
    await tester.pumpAndSettle();
    final finder = await createButton(tester);
    await act(tester, () async {
      await tester.tap(finder);
    });

    final projects = await tester.runAsync(
      () => ProjectRepository(database.raw).findAll(),
    );
    final season = projects!.singleWhere((p) => p.projectName == 'Ponui 2026');
    final animals = await tester.runAsync(
      () => IndividualRepository(database.raw).findByProject(season.projectId),
    );
    expect(animals!.map((a) => a.name), ['Marie']);
  });
}
