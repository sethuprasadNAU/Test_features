import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/individuals_provider.dart';
import 'package:tritrack/core/providers/project_time_zone_provider.dart';
import 'package:tritrack/core/time/device_time_zone.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/deployment_linking.dart'
    show deploymentDateFor, formatLinkDate;
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/features/more/screens/animals_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart' show dynamicTypeSliderCeiling;

/// **Task 11.321, item 3 — Quick add, on the screen.**
///
/// Reached the way a person reaches it: More → Animals, then the Quick add
/// button, inside the tab shell at phone size. The project has Marie, wearing
/// 150.321, and 150.523 on the shelf; the Tag Library has two collars that
/// both read 151.200.
void main() {
  setUp(installFakeSharedPreferences);

  const projectId = 'project-1';
  const owner = 'user-owner';
  late ProviderContainer container;
  late AppDatabase database;

  Future<void> resolve() async {
    container.listen(projectTagsProvider(projectId), (_, _) {});
    container.listen(projectIndividualsProvider(projectId), (_, _) {});
    container.listen(projectDeploymentsProvider(projectId), (_, _) {});
    container.listen(myProjectStandingProvider(projectId), (_, _) {});
    await container.read(projectTagsProvider(projectId).future);
    await container.read(projectIndividualsProvider(projectId).future);
    await container.read(projectDeploymentsProvider(projectId).future);
    await container.read(myProjectStandingProvider(projectId).future);
    await container.read(currentUserProvider.future);
    // Task 11.331: the project's zone, which "today" and the stored day are
    // read in.
    container.listen(projectTimeZoneProvider(projectId), (_, _) {});
    await container.read(projectTimeZoneProvider(projectId).future);
  }

  Future<void> seed(
    WidgetTester tester, {
    ProjectRole role = ProjectRole.owner,
    double textScale = 1.0,
  }) async {
    const creator = 'user-creator';
    // Task 11.331: the project's zone is this process's own, so the dates
    // this file computes with the phone's clock are the field's too.
    final project = sampleProject(
      id: projectId,
      ownerUserId: role == ProjectRole.owner ? owner : creator,
    ).copyWith(timeZone: deviceTimeZone());
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
      await db.insert(
        Tables.users,
        sampleUser(id: creator, email: 'creator@x.com').toColumns(),
      );
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(userId: owner, role: role).toColumns(),
      );
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(id: 'm-c', userId: creator, role: ProjectRole.owner)
            .toColumns(),
      );
      await IndividualRepository(db).insert(
        sampleIndividual(id: 'marie', name: 'Marie', modifiedBy: creator),
      );
      for (final (id, freq) in [('collar-a', 150.321), ('collar-b', 150.523)]) {
        await db.insert(
          Tables.tags,
          sampleTag(
            id: id,
            tagName: freq.toStringAsFixed(3),
            frequencyMhz: freq,
            modifiedBy: creator,
          ).toColumns(),
        );
      }
      await DeploymentRepository(db).link(
        sampleDeployment(
          id: 'marie-a',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          modifiedBy: creator,
        ),
      );
      final library = TagLibraryRepository(db);
      for (final (id, name) in [('x1', 'Twin one'), ('x2', 'Twin two')]) {
        await library.insert(
          sampleTagLibraryEntry(
            id: id,
            lineageId: 'l-$id',
            tagName: name,
            frequencyMhz: 151.200,
          ),
        );
      }
      await resolve();
    });
    await pumpInAppShell(
      tester,
      container: container,
      screen: const AnimalsScreen(),
      tabIndex: 4,
      textScale: textScale,
    );
  }

  /// Runs [body] on the real clock, then lets the database answer.
  Future<void> act(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    });
    await tester.pumpAndSettle();
  }

  Future<void> openQuickAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('quick_add')));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    final field = find.byKey(ValueKey(key));
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, text);
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
  }

  void paste(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': text} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  testWidgets('WATCHED RED: the date the tags went on is first, and is '
      'today', (tester) async {
    await seed(tester);
    await openQuickAdd(tester);

    final today = formatLinkDate(deploymentDateFor(clock.now()));
    expect(find.text('$today (today)'), findsOneWidget);
    final dateTop = tester.getTopLeft(find.byKey(const ValueKey('quick_add_date'))).dy;
    final speciesTop =
        tester.getTopLeft(find.byKey(const ValueKey('quick_add_species'))).dy;
    expect(dateTop, lessThan(speciesTop),
        reason: 'the date comes before every other field');
  });

  testWidgets('three animals typed in: reviewed, then saved together',
      (tester) async {
    await seed(tester);
    await openQuickAdd(tester);

    await type(tester, 'quick_add_name_0', 'Ada');
    await type(tester, 'quick_add_freq_0', '150.111');
    for (final (i, name, freq) in [(1, 'Bea', '150.222'), (2, 'Cy', '150.523')]) {
      await tapVisible(tester, 'quick_add_add_row');
      await tester.pumpAndSettle();
      await type(tester, 'quick_add_name_$i', name);
      await type(tester, 'quick_add_freq_$i', freq);
    }
    await act(tester, () => tapVisible(tester, 'quick_add_review'));

    expect(
      find.text('3 animals, 2 new tags, 1 already on this project.'),
      findsOneWidget,
    );
    final before = await tester.runAsync(
      () => IndividualRepository(database.raw).findByProject(projectId),
    );
    expect(before, hasLength(1), reason: 'nothing written before Save');

    await act(tester, () => tester.tap(find.byKey(const ValueKey('quick_add_save'))));
    expect(find.text('Added 3 animals.'), findsOneWidget);
    expect(find.byKey(const ValueKey('quick_add')), findsOneWidget,
        reason: 'back on the Animals list');

    final animals = await tester.runAsync(
      () => IndividualRepository(database.raw).findByProject(projectId),
    );
    expect([for (final a in animals!) a.name]..sort(), ['Ada', 'Bea', 'Cy', 'Marie']);
    final links = await tester.runAsync(
      () => DeploymentRepository(database.raw).findByProject(projectId),
    );
    expect(links, hasLength(4));
  });

  testWidgets('three pasted from a spreadsheet, one of them asked about',
      (tester) async {
    await seed(tester);
    await openQuickAdd(tester);
    paste(tester, 'Animal\tFrequency\nDee\t150.444\nEve\t151.200\nFay\t150.555\n');

    await tester.tap(find.byKey(const ValueKey('quick_add_paste')));
    await tester.pumpAndSettle();
    expect(find.text('Added 3 rows.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('quick_add_name_1'))).controller!.text,
      'Eve',
      reason: 'the paste filled the table, with no blank row left above it',
    );

    await act(tester, () => tapVisible(tester, 'quick_add_review'));
    expect(find.text('3 animals, 2 new tags, 1 tag to choose.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('quick_add_save'))).onPressed,
      isNull,
      reason: 'never guessed: Save waits for the choice',
    );

    await tester.tap(find.byKey(const ValueKey('quick_add_choose_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick_add_option_library:x2')));
    await tester.pumpAndSettle();
    expect(find.text('3 animals, 2 new tags, 1 from your library.'), findsOneWidget);

    await act(tester, () => tester.tap(find.byKey(const ValueKey('quick_add_save'))));
    final tags = await tester.runAsync(
      () => TagRepository(database.raw).findByProject(projectId),
    );
    expect(tags!.singleWhere((t) => t.tagName == 'Twin two').lineageId, 'l-x2');
  });

  testWidgets('a row the deployment rules refuse says why, and nothing can '
      'be saved', (tester) async {
    await seed(tester);
    await openQuickAdd(tester);
    await type(tester, 'quick_add_name_0', 'Ada');
    await type(tester, 'quick_add_freq_0', '150.321');
    await act(tester, () => tapVisible(tester, 'quick_add_review'));

    expect(find.text('This tag is on Marie on that date.'), findsOneWidget);
    expect(find.text('1 animal, 1 problem.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('quick_add_save'))).onPressed,
      isNull,
    );
  });

  testWidgets('WATCHED RED (task 11.339): a pasted row whose Tag ID is '
      'already on the project, on another frequency, stops and asks before '
      'Add, and its line says both frequencies', (tester) async {
    await seed(tester);
    await openQuickAdd(tester);
    paste(tester, 'Animal\tFrequency\tTag\nKea\t152.000\t150.523\n');
    await tester.tap(find.byKey(const ValueKey('quick_add_paste')));
    await tester.pumpAndSettle();

    await act(tester, () => tapVisible(tester, 'quick_add_review'));
    expect(find.text('1 animal, 1 tag to choose.'), findsOneWidget);
    expect(
      find.text('Tag ID 150.523 is already on this project at 150.523 MHz; '
          'this row says 152.000 MHz. Choose which.'),
      findsOneWidget,
      reason: 'the review line says both frequencies',
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('quick_add_save'))).onPressed,
      isNull,
      reason: 'Add waits for the choice — Michael: stop and ask',
    );

    await tester.tap(find.byKey(const ValueKey('quick_add_choose_1')));
    await tester.pumpAndSettle();
    expect(find.text('Use the existing tag (150.523 MHz)'), findsOneWidget);
    expect(find.text('Create anyway: a second tag with this Tag ID'),
        findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('quick_add_option_project:collar-b')),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 animal, 1 already on this project.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('quick_add_save'))).onPressed,
      isNotNull,
    );
  });

  testWidgets('a viewer cannot open Quick add', (tester) async {
    await seed(tester, role: ProjectRole.viewer);
    expect(
      tester.widget<TextButton>(find.byKey(const ValueKey('quick_add'))).onPressed,
      isNull,
    );
    expect(find.textContaining('Viewers cannot add an animal'), findsOneWidget,
        reason: 'the reason is on the screen, never a tooltip');
  });

  testWidgets('at the largest ordinary text size, Quick add and its review '
      'lay out without overflowing', (tester) async {
    // Quick add is pushed from Animals, not a route, so the clipped-text
    // sweep does not reach it; an overflow throws in a widget test, which
    // is what this relies on.
    await seed(tester, textScale: dynamicTypeSliderCeiling);
    await openQuickAdd(tester);
    await tapVisible(tester, 'quick_add_more_0');
    await tester.pumpAndSettle();
    await type(tester, 'quick_add_name_0', 'Ada with a long name');
    await type(tester, 'quick_add_freq_0', '151.200');
    await act(tester, () => tapVisible(tester, 'quick_add_review'));
    expect(find.byKey(const ValueKey('quick_add_summary')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
