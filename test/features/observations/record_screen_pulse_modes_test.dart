import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/format/pulse_rate_format.dart';
import 'package:tritrack/core/providers/pulse_rate_unit_provider.dart';
import 'package:tritrack/core/providers/tag_view_refresh.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/record_screen_tags.dart';

/// **The Record screen's pulse-mode picker, and the requirement that it not
/// need a restart — task 11.187.**
///
/// Michael, 2026-09-07: *"It is important that these named modes update in the
/// record screen when they are changed in the tag database (immediately). The
/// user shouldn't have to restart the app."*
///
/// **A screen that happens to rebuild is not a screen that must**, so the test
/// that matters is the second one below: change a mode's name in the database,
/// announce it the way the Tag Database screen announces a tag edit, and watch
/// the wheel the person is looking at change — **without pumping a new
/// widget**. Rebuilding the tree would prove only that a fresh screen reads
/// fresh data, which was never in doubt.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  /// Same shape as `observation_logging_screen_test.dart`'s harness, and for
  /// the same reasons — every provider this screen watches is pre-resolved
  /// inside `runAsync`, because a provider's future is tied to whichever zone
  /// started it and one started in the fake-async zone never resolves.
  Future<ProviderContainer> readyContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith(
          (ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0])),
        ),
        accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);

      await userRepo.insert(sampleUser());
      await projectRepo.insert(sampleProject());
      await tagRepo.insert(
        sampleTag(
          pulseMode1Name: 'Normal',
          pulseMode2Name: 'Mortality',
          pulseMode2RateBpm: 120,
        ),
      );
      // Task 11.249: on an animal, or the wheel does not offer it.
      await putSampleTagOnAnAnimal(container);
      await container.read(activeProjectIdProvider.notifier).set('project-1');

      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(observationFormProvider, (_, _) {});
      container.listen(mayWriteProjectDataProvider('project-1'), (_, _) {});
      container.listen(pulseRateUnitSettingProvider, (_, _) {});

      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(mayWriteProjectDataProvider('project-1').future);
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
      await container.read(pulseRateUnitSettingProvider.future);
    });

    return container;
  }

  /// **Pumped inside the real tab shell, at 6.1-inch phone geometry**, rather
  /// than bare on a generous surface. Every assertion below rests on a mode
  /// being *findable*, and a `WheelPicker` is a `ListWheelScrollView` that
  /// builds only what fits — so a test that hands this screen height it never
  /// has would be finding modes the person cannot see. Task 11.110's harness
  /// is what makes that the same question in the test as on the phone.
  Future<void> pumpScreen(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1, // Map / **Record** / Compass / Position / More
    );
  }

  testWidgets("the picker offers the tag's own modes, and the word Regular is "
      'gone', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    // **'MODE' since task 11.197**, which shortened the three roller
    // headings — the line right below spells the chosen mode out in full, so
    // the heading was saying *pulse mode* twice. The unshortened words are
    // still there for a screen reader (`_RollerColumn.semanticsLabel`);
    // `record_screen_semantics_test.dart` is what holds that.
    expect(find.text('MODE'), findsOneWidget);
    expect(find.text('PULSE TYPE'), findsNothing);
    expect(find.text('Normal'), findsWidgets);
    expect(find.text('Mortality'), findsWidgets);
    // Michael's answer 3, on the screen: the word leaves the app.
    expect(find.text('Regular'), findsNothing);
    // The selected mode's rate, spelled out once under the wheels rather than
    // clipped inside a third-of-a-screen roller.
    expect(find.textContaining('Normal · 40 bpm'), findsOneWidget);
  });

  testWidgets('renaming a mode in the tag database changes the picker without '
      'a restart', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);
    expect(find.text('Mortality'), findsWidgets);

    // What the Tag Database screen does: write the tag, then announce through
    // the one enumeration of "the tag views" (`tag_view_refresh.dart`). The
    // edit dialog offers no project when editing an existing tag, so it passes
    // null — the case task 11.153 measured wrong once already.
    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.update(
        Tables.tags,
        {'pulse_mode_2_name': 'Mortality (fast)', 'pulse_mode_2_rate_bpm': 90.0},
        where: 'tag_id = ?',
        whereArgs: ['tag-1'],
      );
      refreshTagViewsIn(container, projectId: null);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
    });

    // **No new widget is pumped.** Only frames.
    await tester.pumpAndSettle();

    expect(
      find.text('Mortality (fast)'),
      findsWidgets,
      reason:
          'The mode was renamed in the Tag Database and the Record screen is '
          'still offering the old name. Somebody standing at a receiver would '
          'have to close and reopen the app to see the modes they just '
          'entered, which is the restart Michael asked to be rid of.',
    );
    expect(find.text('Mortality'), findsNothing);
  });

  testWidgets('a mode switched off stops being offered, also without a restart',
      (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);
    expect(find.text('Mortality'), findsWidgets);

    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.update(
        Tables.tags,
        {'pulse_mode_2_name': null, 'pulse_mode_2_rate_bpm': null},
        where: 'tag_id = ?',
        whereArgs: ['tag-1'],
      );
      refreshTagViewsIn(container, projectId: null);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
    });
    await tester.pumpAndSettle();

    expect(find.text('Mortality'), findsNothing);
    // And the one that cannot be switched off is still there, which is the
    // "never fewer than 1" half of the rule seen from the screen.
    expect(find.text('Normal'), findsWidgets);
  });

  testWidgets('the seconds-per-pulse preference reaches this screen too',
      (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);
    expect(find.textContaining('40 bpm'), findsWidgets);

    await tester.runAsync(() async {
      await container
          .read(pulseRateUnitSettingProvider.notifier)
          .set(PulseRateUnit.secondsPerPulse);
    });
    await tester.pumpAndSettle();

    // 40 bpm is 1.5 seconds between pulses. The stored number never moved.
    expect(find.textContaining('1.5 s/pulse'), findsWidgets);
    expect(find.textContaining('40 bpm'), findsNothing);
  });
}
