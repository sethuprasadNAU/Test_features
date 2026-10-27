import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.241 — *"show me Marie"* means both her collars.
///
/// Marie wore 160.321 MHz last season and 160.523 MHz this season; one
/// bearing was taken against each. Coco has one collar and one bearing.
/// Filtering the Log by the animal shows Marie's two rows and not Coco's;
/// filtering by one collar still shows exactly that collar's row.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('the filter offers animals above tags, and an animal filter '
      'admits every collar she has worn', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final owner = sampleUser(id: 'user-1');
    final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => owner),
        currentProjectProvider.overrideWith((ref) async => project),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(Tables.users, owner.toColumns());
      await db.insert(Tables.projects, project.toColumns());
      final marie = sampleIndividual(id: 'marie', name: 'Marie');
      final coco = sampleIndividual(id: 'coco', name: 'Coco');
      await db.insert(Tables.individuals, marie.toColumns());
      await db.insert(Tables.individuals, coco.toColumns());
      for (final (id, freq, animal) in [
        ('marie-2025', 160.321, 'marie'),
        ('marie-2026', 160.523, 'marie'),
        ('coco-collar', 150.100, 'coco'),
      ]) {
        await db.insert(
          Tables.tags,
          sampleTag(
            id: id,
            tagName: animal == 'marie' ? 'Marie' : 'Coco',
            frequencyMhz: freq,
          ).toColumns(),
        );
        // Task 11.243: the link is a dated row. **Every deployment feeds the
        // filter, not only the current one** — filtering by Marie has to
        // reach the bearings taken on the collar she has since stopped
        // wearing, which is what these two rows are.
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-$id',
            tagId: id,
            individualId: animal,
            attachedDate: id == 'marie-2025'
                ? DateTime.utc(2025)
                : DateTime.utc(2026),
            removedDate: id == 'marie-2025' ? DateTime.utc(2026) : null,
          ).toColumns(),
        );
        // **Each bearing inside its own deployment** (task 11.244). The
        // animal filter asks the interval derivation now, so a fixture
        // where every bearing shares one instant while the deployments sit
        // in different years would be asking a question it had made
        // unanswerable.
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-$id',
            tagId: id,
            sessionId: null,
            timestampUtc: id == 'marie-2025'
                ? DateTime.utc(2025, 6, 1)
                : DateTime.utc(2026, 6, 1),
          ).toColumns(),
        );
      }
      // **A bearing on Marie's old collar after she stopped wearing it.**
      // The collar fell off and kept transmitting; this is the case design
      // §2 built the dated link for, and the filter must *not* show it under
      // Marie. Before task 11.244 it did — the filter matched every collar
      // she had ever worn, whatever the date.
      await db.insert(
        Tables.observations,
        sampleObservation(
          id: 'obs-after-she-stopped',
          tagId: 'marie-2025',
          sessionId: null,
          latitude: 35.77,
          timestampUtc: DateTime.utc(2026, 8, 1),
        ).toColumns(),
      );
      await container.read(historyDataProvider(project.projectId).future);
      container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
      await container.read(mayWriteProjectDataProvider(project.projectId).future);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LogScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Four rows, unfiltered. Two of them are on the 160.321 collar — one
    // while Marie wore it, one after it came off.
    expect(find.textContaining('160.321'), findsNWidgets(2));
    expect(find.textContaining('160.523'), findsOneWidget);
    expect(find.textContaining('150.100'), findsOneWidget);

    await tester.tap(find.text('Tag: All'));
    await tester.pumpAndSettle();
    expect(find.text('Filter by animal or tag'), findsOneWidget);
    // Animals first, each with its collar count; then the collars.
    final animalsLabel = find.text('ANIMALS');
    final tagsLabel = find.text('TAGS');
    expect(animalsLabel, findsOneWidget);
    expect(tagsLabel, findsOneWidget);
    expect(tester.getTopLeft(animalsLabel).dy, lessThan(tester.getTopLeft(tagsLabel).dy));
    expect(find.text('Marie · 2 tags'), findsOneWidget);
    expect(find.text('Coco · 1 tag'), findsOneWidget);

    await tester.tap(find.text('Marie · 2 tags'));
    await tester.pumpAndSettle();

    expect(find.text('Animal: Marie'), findsOneWidget, reason: 'the chip says what is filtered');
    expect(find.textContaining('160.523'), findsOneWidget);
    expect(find.textContaining('150.100'), findsNothing, reason: 'Coco is not Marie');
    // **One 160.321 bearing, not two** (task 11.244). The one taken while
    // she wore that collar is hers; the one taken after it came off is
    // nobody's, and this is the whole difference between filtering by "every
    // collar she has ever worn" and asking which animal each bearing was
    // actually about.
    expect(
      find.textContaining('160.321'),
      findsOneWidget,
      reason: 'the bearing taken after the collar came off is not hers',
    );

    // One collar only, the way the filter has always worked.
    await tester.tap(find.text('Animal: Marie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('160.321 MHz · Marie'));
    await tester.pumpAndSettle();
    expect(find.text('Tag: Marie'), findsOneWidget);
    // **Both** — a *tag* filter is about the collar, whoever was wearing it,
    // and the bearing taken after it came off is still a bearing on that
    // collar. That is the distinction between the two kinds of filter and it
    // is why both are offered.
    expect(find.textContaining('160.321'), findsNWidgets(2));
    expect(find.textContaining('160.523'), findsNothing);
  });

  group('a handover day — "show me Alpha" through the Log\'s animal filter '
      '(task 11.251, Michael, 2026-09-15)', () {
    // Michael's fixture: tag 1 on Alpha, tag 2 on Bravo, one bearing on each
    // at 10:00; tag 2 moved from Bravo to Alpha the same day, which (§5a)
    // closes Alpha's tag 1 that day too. Two fixtures for §4a's two rules —
    // dates only (the floor: a whole day, and a contested bearing listed
    // under both animals) and a timed swap (resolved).
    const projectId = 'project-1';
    final tenAm = DateTime(2026, 9, 15, 10, 0).toUtc();

    Future<ProviderContainer> seed(
      WidgetTester tester, {
      required DateTime swapEnd,
      required DateTime swapStart,
    }) async {
      tester.view.physicalSize = const Size(1200, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(Tables.individuals, sampleIndividual(id: 'alpha', name: 'Alpha').toColumns());
        await db.insert(Tables.individuals, sampleIndividual(id: 'bravo', name: 'Bravo').toColumns());
        await db.insert(Tables.tags, sampleTag(id: 'tag-1', tagName: 'T1', frequencyMhz: 150.100).toColumns());
        await db.insert(Tables.tags, sampleTag(id: 'tag-2', tagName: 'T2', frequencyMhz: 150.200).toColumns());
        for (final (id, tag, animal, attached, removed) in [
          ('d-tag1-alpha', 'tag-1', 'alpha', DateTime(2026, 8, 1), swapEnd),
          ('d-tag2-bravo', 'tag-2', 'bravo', DateTime(2026, 8, 1), swapEnd),
          ('d-tag2-alpha', 'tag-2', 'alpha', swapStart, null),
        ]) {
          await db.insert(
            Tables.deployments,
            sampleDeployment(
              id: id,
              tagId: tag,
              individualId: animal,
              attachedDate: attached,
              removedDate: removed,
            ).toColumns(),
          );
        }
        for (final tag in ['tag-1', 'tag-2']) {
          await db.insert(
            Tables.observations,
            sampleObservation(id: 'obs-$tag', tagId: tag, sessionId: null, timestampUtc: tenAm).toColumns(),
          );
        }
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LogScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    /// Taps the filter chip (whatever it currently reads) and picks an
    /// option from the sheet it opens.
    Future<void> filterBy(
      WidgetTester tester,
      String option, {
      String chip = 'Tag: All',
    }) async {
      await tester.tap(find.text(chip));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option));
      await tester.pumpAndSettle();
    }

    testWidgets('DATES ONLY: the bearing on the day tag 1 came off is still '
        "Alpha's, and tag 2's bearing is listed under BOTH animals rather "
        'than silently under one', (tester) async {
      await seed(tester, swapEnd: DateTime(2026, 9, 15), swapStart: DateTime(2026, 9, 15));
      expect(find.textContaining('150.100'), findsOneWidget);
      expect(find.textContaining('150.200'), findsOneWidget);

      await filterBy(tester, 'Alpha · 2 tags');
      expect(find.text('Animal: Alpha'), findsOneWidget);
      expect(find.textContaining('150.100'), findsOneWidget,
          reason: 'tag 1 was removed today, and today was still Alpha\'s — '
              'before this task "show me Alpha" dropped this bearing');
      expect(find.textContaining('150.200'), findsOneWidget,
          reason: 'contested between Alpha and Bravo, so it may be hers');

      await filterBy(tester, 'Bravo · 1 tag', chip: 'Animal: Alpha');
      expect(find.text('Animal: Bravo'), findsOneWidget);
      expect(find.textContaining('150.200'), findsOneWidget,
          reason: 'and it may be Bravo\'s — a contested record is not '
              'dropped from either list');
      expect(find.textContaining('150.100'), findsNothing);
    });

    testWidgets('WITH A TIME: a 14:32 swap gives the 10:00 bearing to Bravo '
        'and to Bravo alone', (tester) async {
      final swapAt = DateTime(2026, 9, 15, 14, 32);
      await seed(tester, swapEnd: swapAt, swapStart: swapAt);

      await filterBy(tester, 'Alpha · 2 tags');
      expect(find.textContaining('150.100'), findsOneWidget);
      expect(find.textContaining('150.200'), findsNothing,
          reason: 'recorded on Bravo hours before the collar went near Alpha');

      await filterBy(tester, 'Bravo · 1 tag', chip: 'Animal: Alpha');
      expect(find.textContaining('150.200'), findsOneWidget);
      expect(find.textContaining('150.100'), findsNothing);
    });
  });
}
