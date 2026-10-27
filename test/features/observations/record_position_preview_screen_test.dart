import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/observations/screens/record_position_preview_screen.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 5.5: with no GPS fix and no manual pin yet, the position picker must
/// render a usable, tappable map centered on the project extent plus the
/// "not a position fix" notice — not the old `_WaitingForGps` dead end.
///
/// No GPS override is needed: `gpsPositionProvider` never resolves under
/// `flutter test` (no platform channel registered), which is exactly the
/// "no fix" state this test wants — the same reasoning `compass_screen_test.dart`
/// relies on for a heading that never arrives.
void main() {
  setUp(installFakeSharedPreferences);
  // Process-wide signal: one test leaving it tripped puts a band on the next
  // test's screen.
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  /// `observationFormProvider` is plain `@riverpod` (autoDispose) — without a
  /// `container.listen` to hold it open, pre-resolving it with a bare
  /// `container.read(...future)` doesn't stick, and the widget's later
  /// `ref.watch` forces a fresh (uncached) rebuild that never settles inside
  /// `testWidgets`' fake-async zone. The `listen` call itself must happen
  /// **inside** `tester.runAsync` too — it kicks off the provider's build
  /// immediately, and whichever zone (real or fake) is active at that exact
  /// moment is the one its underlying Future stays tied to forever. See
  /// `observation_logging_screen_test.dart` for the fuller writeup (that's
  /// where this was actually caught — an early version of this file had the
  /// same bug and hung indefinitely).
  Future<ProviderContainer> readyContainer(WidgetTester tester, {required Project project}) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      await userRepo.insert(sampleUser());
      await projectRepo.insert(project);
      await container.read(activeProjectIdProvider.notifier).set(project.projectId);

      container.listen(observationFormProvider, (_, _) {});

      await container.read(currentProjectProvider.future);
      await container.read(observationFormProvider.future);
    });

    return container;
  }

  /// Deliberately plain `pump()` calls, not `pumpAndSettle()`: the map's
  /// `TileLayer` issues real network image requests that never resolve
  /// under `flutter test`, which would spin `pumpAndSettle()` forever —
  /// same technique as `offline_data_map_screen_test.dart`.
  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const RecordPositionPreviewScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
      'with a project extent, no fix and no pin renders a usable map plus the extent notice',
      (tester) async {
    final container = await readyContainer(tester, project: sampleProject());
    await pumpScreen(tester, container);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('No GPS fix'), findsOneWidget);
    expect(find.textContaining('not your position'), findsOneWidget);
    expect(find.textContaining('Tap the map to place a pin'), findsOneWidget);
    // The old dead end must be gone.
    expect(find.textContaining('Waiting for a GPS fix'), findsNothing);
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets('a project with no bbox still opens something usable', (tester) async {
    final now = DateTime.utc(2026, 7, 16, 18, 30);
    final noBboxProject = Project(
      projectId: 'project-1',
      projectName: 'No Extent Project',
      ownerUserId: 'user-1',
      creationDate: now,
      sync: SyncMeta.initial(now: now, modifiedBy: 'user-1'),
    );
    final container = await readyContainer(tester, project: noBboxProject);
    await pumpScreen(tester, container);

    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.textContaining('No GPS fix'), findsOneWidget);
    expect(find.textContaining('Waiting for a GPS fix'), findsNothing);
  });

  testWidgets('tapping the map places a pin and switches to the manual-position banner',
      (tester) async {
    final container = await readyContainer(tester, project: sampleProject());
    await pumpScreen(tester, container);

    await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Manual position'), findsOneWidget);
    expect(find.textContaining('No GPS fix'), findsNothing);
    expect(find.text('Use GPS'), findsOneWidget);

    final draft = await container.read(observationFormProvider.future);
    expect(draft.useManualPosition, isTrue);
    expect(draft.manualLat, isNotNull);
    expect(draft.manualLon, isNotNull);
  });

  // ---------------------------------------------------------------------
  // Task 11.135 — verdict for this surface: show it, in the column that is
  // already at the top rather than at a second anchor on the same edge.
  // ---------------------------------------------------------------------

  testWidgets('the no-fix map says when tiles are not arriving, and clears '
      'the banner already there', (tester) async {
    usePhoneGeometry(tester);
    final container = await readyContainer(tester, project: sampleProject());
    await pumpScreen(tester, container);

    final band = find.byKey(const ValueKey('record-preview-tiles-not-loading'));
    expect(band, findsNothing, reason: 'nothing has failed yet');

    for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
      TileFetchHealth.instance.recordNetworkFailure();
    }
    await tester.pump();

    expect(
      band,
      findsOneWidget,
      reason:
          'With no fix, **tapping this basemap is the only way to place a '
          'first pin** — the Record screen sends people here for exactly '
          'that. A basemap that is not arriving makes it impossible, and '
          'before task 11.135 the screen said nothing about it.',
    );

    // It joined the existing column rather than taking a second top anchor,
    // which is the `Stack`-children-on-one-edge shape task 11.126 collapsed.
    final banner = tester.getRect(
      find.textContaining('No GPS fix', findRichText: true),
    );
    final bandRect = tester.getRect(band);
    printOnFailure('no-fix banner: $banner\ntiles band: $bandRect');
    expect(
      bandRect.top,
      greaterThanOrEqualTo(banner.bottom - 0.5),
      reason: 'the band must sit under the banner, not over it',
    );
    expect(tester.takeException(), isNull);
  });
}
