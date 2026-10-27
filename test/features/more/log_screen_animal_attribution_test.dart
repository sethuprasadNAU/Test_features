import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/non_detection.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack/widgets/tag_color_swatch.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart' show
    collectLayoutOverflows, iosTextScales, textScaleName, textScaleVerdict;

/// Task 11.272 — Michael, 2026-09-17: *"The animal isn't listed or
/// sortable... a tag that used to be on animal B and was reassigned to
/// animal A shows animal B's colour."*
///
/// Every row's swatch and animal name must resolve the animal at the row's
/// own moment (`DeploymentRepository.animalForObservationIn`), never the
/// collar's current owner, and a row with no covering deployment or with a
/// contested one must render exactly as the Map does for the same fact.
///
/// **Pumped through `pumpInAppShell`, not bare** — these assertions rest on
/// finding, tapping and positioning rows, which is exactly the class
/// `app_shell_harness_default_test.dart` requires the harness for (task
/// 11.111): a bare `MaterialApp(home: LogScreen())` hands the row list
/// height the real app never gives it.
void main() {
  setUp(installFakeSharedPreferences);

  Color swatchColorOf(Finder tileFinder) {
    final swatch = find
        .descendant(of: tileFinder, matching: find.byType(TagColorSwatch))
        .evaluate()
        .single
        .widget as TagColorSwatch;
    return tagColorFromHex(swatch.colorHex);
  }

  group('a collar reassigned from one animal to another', () {
    const projectId = 'project-1';

    Future<ProviderContainer> seed(WidgetTester tester) async {
      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        // Bravo wore this collar first; the same colour must still appear
        // on the bearing recorded then, even after Alpha has worn it since.
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'bravo', name: 'Bravo', colorHex: '#FF0000').toColumns(),
        );
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'alpha', name: 'Alpha', colorHex: '#0000FF').toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-1', tagName: 'T1', frequencyMhz: 150.100).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-bravo',
            tagId: 'tag-1',
            individualId: 'bravo',
            attachedDate: DateTime(2026, 1, 1),
            removedDate: DateTime(2026, 2, 1),
          ).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-alpha',
            tagId: 'tag-1',
            individualId: 'alpha',
            attachedDate: DateTime(2026, 2, 2),
          ).toColumns(),
        );
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-while-bravo',
            tagId: 'tag-1',
            sessionId: null,
            timestampUtc: DateTime.utc(2026, 1, 15),
          ).toColumns(),
        );
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      await pumpInAppShell(
        tester,
        container: container,
        screen: const LogScreen(),
        tabIndex: 4,
      );
      return container;
    }

    testWidgets('the row still names and colours Bravo, not the tag\'s '
        'current owner Alpha', (tester) async {
      await seed(tester);

      // **The failing behaviour this guards against**: before task 11.272,
      // every row's swatch read `Tag.colorHex`, which since schema v16 is
      // the colour of whoever wears the collar *now* — Alpha. This bearing
      // was recorded while Bravo wore it, and the row must say so.
      expect(find.textContaining('Bravo'), findsOneWidget,
          reason: "the bearing was Bravo's, whoever has the collar today");
      expect(find.textContaining('Alpha'), findsNothing,
          reason: 'the row must not repaint history with the current owner');

      final tile = find.ancestor(
        of: find.textContaining('Bravo'),
        matching: find.byType(ListTile),
      );
      expect(swatchColorOf(tile), tagColorFromHex('#FF0000'),
          reason: "Bravo's colour, not Alpha's");
    });
  });

  group('a collar on nobody at its own moment', () {
    const projectId = 'project-1';

    testWidgets('the row says so in words and draws the neutral swatch — '
        'matching the Map\'s treatment of the same fact', (tester) async {
      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-1', tagName: 'T1', frequencyMhz: 150.100).toColumns(),
        );
        // No deployment at all: a bearing on a collar nobody has ever
        // linked, or that fell off and kept transmitting (design §2).
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-nobody',
            tagId: 'tag-1',
            sessionId: null,
            timestampUtc: DateTime.utc(2026, 1, 15),
          ).toColumns(),
        );
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      await pumpInAppShell(
        tester,
        container: container,
        screen: const LogScreen(),
        tabIndex: 4,
      );

      expect(find.textContaining('No animal at this time'), findsOneWidget,
          reason: 'a blank space here would read as a rendering fault');
      final tile = find.ancestor(
        of: find.textContaining('No animal at this time'),
        matching: find.byType(ListTile),
      );
      expect(swatchColorOf(tile), tagColorFromHex(TagColorPalette.noIndividual),
          reason: "the Map's own neutral swatch for the same fact");
    });
  });

  group('a contested moment — two deployments cover one bearing', () {
    const projectId = 'project-1';

    testWidgets('the row draws the neutral swatch and names every '
        'candidate, worded exactly as the Map\'s legend does', (tester) async {
      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'alpha', name: 'Alpha').toColumns(),
        );
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'bravo', name: 'Bravo').toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-2', tagName: 'T2', frequencyMhz: 150.200).toColumns(),
        );
        // Handover day (task 11.251, §4a): both deployments close the same
        // date-only day, so the bearing recorded that day is contested.
        final swapDay = DateTime(2026, 9, 15);
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-bravo',
            tagId: 'tag-2',
            individualId: 'bravo',
            attachedDate: DateTime(2026, 8, 1),
            removedDate: swapDay,
          ).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-alpha',
            tagId: 'tag-2',
            individualId: 'alpha',
            attachedDate: swapDay,
          ).toColumns(),
        );
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-contested',
            tagId: 'tag-2',
            sessionId: null,
            timestampUtc: DateTime(2026, 9, 15, 10, 0).toUtc(),
          ).toColumns(),
        );
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      await pumpInAppShell(
        tester,
        container: container,
        screen: const LogScreen(),
        tabIndex: 4,
      );

      // The exact sentence `contestedLegendLabel` gives the Map's legend —
      // the two screens must never phrase the same fact two different ways.
      expect(find.textContaining('Contested: Alpha or Bravo'), findsOneWidget);
      final tile = find.ancestor(
        of: find.textContaining('Contested: Alpha or Bravo'),
        matching: find.byType(ListTile),
      );
      expect(swatchColorOf(tile), tagColorFromHex(TagColorPalette.noIndividual),
          reason: 'a contested moment draws the same neutral swatch as '
              'nobody covering it — the Map never colours by one of the '
              'guesses');
    });
  });

  group('sorting by animal', () {
    const projectId = 'project-1';

    testWidgets('the Animal chip is offered and orders rows by the animal '
        'each was actually about', (tester) async {
      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'zeta', name: 'Zeta').toColumns(),
        );
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'alpha', name: 'Alpha').toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-z', tagName: 'TZ', frequencyMhz: 150.100).toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-a', tagName: 'TA', frequencyMhz: 150.200).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-zeta',
            tagId: 'tag-z',
            individualId: 'zeta',
            attachedDate: DateTime(2026, 1, 1),
          ).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-alpha',
            tagId: 'tag-a',
            individualId: 'alpha',
            attachedDate: DateTime(2026, 1, 1),
          ).toColumns(),
        );
        // Zeta's bearing is the *newer* one, so the default time sort
        // (newest first) puts Zeta above Alpha — the opposite of the
        // alphabetical order the Animal sort must produce.
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-zeta',
            tagId: 'tag-z',
            sessionId: null,
            timestampUtc: DateTime.utc(2026, 3, 2),
          ).toColumns(),
        );
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-alpha',
            tagId: 'tag-a',
            sessionId: null,
            timestampUtc: DateTime.utc(2026, 3, 1),
          ).toColumns(),
        );
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      await pumpInAppShell(
        tester,
        container: container,
        screen: const LogScreen(),
        tabIndex: 4,
      );

      // Time order (the default) puts Zeta's bearing first — it is the
      // newer one.
      expect(
        tester.getTopLeft(find.textContaining('Zeta').first).dy,
        lessThan(tester.getTopLeft(find.textContaining('Alpha').first).dy),
      );

      await tester.tap(find.widgetWithText(ChoiceChip, 'Animal'));
      await tester.pumpAndSettle();

      // Alphabetically, Alpha now comes first — the order flips, which only
      // the animal sort (not a fixture coincidence) can produce here.
      expect(
        tester.getTopLeft(find.textContaining('Alpha').first).dy,
        lessThan(tester.getTopLeft(find.textContaining('Zeta').first).dy),
      );
    });
  });

  group('a "no signal" record listening for two collars that disagree', () {
    const projectId = 'project-1';

    testWidgets("each collar's own resolved colour is drawn — the stack "
        'shows the disagreement rather than picking one colour for both',
        (tester) async {
      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      final ndTime = DateTime.utc(2026, 3, 1);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'zeta', name: 'Zeta', colorHex: '#00FF00').toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-on-zeta', tagName: 'TZ', frequencyMhz: 150.100).toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-on-nobody', tagName: 'TN', frequencyMhz: 150.200).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-zeta',
            tagId: 'tag-on-zeta',
            individualId: 'zeta',
            attachedDate: DateTime(2026, 1, 1),
          ).toColumns(),
        );
        // No deployment at all for tag-on-nobody.
        await db.insert(
          Tables.nonDetections,
          NonDetection(
            nonDetectionId: 'nd-1',
            projectId: projectId,
            userId: owner.userId,
            timestampLocal: ndTime.toLocal(),
            timestampUtc: ndTime,
            timezoneOffset: '-07:00',
            latitude: 35.2,
            longitude: -111.6,
            positionSource: PositionSource.gpsFix,
            elevation: 2100.0,
            tagIdsListenedFor: const ['tag-on-zeta', 'tag-on-nobody'],
            sync: sampleSync(),
          ).toColumns(),
        );
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      await pumpInAppShell(
        tester,
        container: container,
        screen: const LogScreen(),
        tabIndex: 4,
      );

      final stack = tester.widget<TagColorSwatchStack>(
        find.byType(TagColorSwatchStack),
      );
      expect(stack.colorHexes, ['#00FF00', TagColorPalette.noIndividual],
          reason: "each collar keeps its own moment's colour — Zeta's for "
              'the one she wore, neutral for the one on nobody — rather '
              'than the stack picking a single colour for both');
    });
  });

  group('the row\'s height budget, re-measured (task 11.272)', () {
    const projectId = 'project-1';

    // The longest string this task adds to a row: the contested label,
    // prepended ahead of the collar and frequency this row already showed.
    // Measured here rather than assumed — this is the fixture task 11.272's
    // "a contested moment" group above already watched render correctly at
    // the default scale; this asks whether it still fits when text is much
    // larger.
    Future<ProviderContainer> seedContested(WidgetTester tester) async {
      final owner = sampleUser(id: 'user-1');
      final project = sampleProject(id: projectId, ownerUserId: owner.userId);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => owner),
          currentProjectProvider.overrideWith((ref) async => project),
          gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'alpha', name: 'Alpha').toColumns(),
        );
        await db.insert(
          Tables.individuals,
          sampleIndividual(id: 'bravo', name: 'Bravo').toColumns(),
        );
        await db.insert(
          Tables.tags,
          sampleTag(id: 'tag-2', tagName: 'T2', frequencyMhz: 150.200).toColumns(),
        );
        final swapDay = DateTime(2026, 9, 15);
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-bravo',
            tagId: 'tag-2',
            individualId: 'bravo',
            attachedDate: DateTime(2026, 8, 1),
            removedDate: swapDay,
          ).toColumns(),
        );
        await db.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'd-alpha',
            tagId: 'tag-2',
            individualId: 'alpha',
            attachedDate: swapDay,
          ).toColumns(),
        );
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-contested',
            tagId: 'tag-2',
            sessionId: null,
            timestampUtc: DateTime(2026, 9, 15, 10, 0).toUtc(),
          ).toColumns(),
        );
        await container.read(historyDataProvider(projectId).future);
        container.listen(mayWriteProjectDataProvider(projectId), (_, _) {});
        await container.read(mayWriteProjectDataProvider(projectId).future);
      });
      return container;
    }

    for (final scale in iosTextScales) {
      testWidgets('the contested row holds at ${textScaleName(scale)}',
          (tester) async {
        final overflows = collectLayoutOverflows();
        final container = await seedContested(tester);
        await pumpInAppShell(
          tester,
          container: container,
          screen: const LogScreen(),
          tabIndex: 4,
          textScale: scale,
        );

        final verdict = textScaleVerdict(tester, overflows);
        expect(verdict.stripes, isEmpty,
            reason: 'the row must grow to fit the longer contested label, '
                'never overflow it, at ${textScaleName(scale)}: $verdict');
      });
    }
  });
}
