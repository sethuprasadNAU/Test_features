import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/computation_status_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.126 item B — the Main Map's accidental `Stack` overlaps, measured.
///
/// Task 11.118 read this file's source and found children of one `Stack` that
/// can paint on top of each other, and said in so many words that a reading
/// is not a measurement. This is the measurement: every case below is pumped
/// at real phone geometry inside the real app shell (see
/// `test/support/app_shell_harness.dart`), driven into the state that raises
/// both widgets at once, and asserted on the **rendered rectangles**.
///
/// **The Main Map has two painting worlds, and only one of them is a
/// `Stack`.** Markers, rays, wedges and the tip-drag handle are drawn inside
/// `flutter_map`'s own layers; the selection card, the record button, the
/// bands and the panels below are drawn *over* the map as `Stack` children.
/// An overlay always paints on top of anything in the map's layers whatever
/// the declaration order, so `Stack` order only answers the question for a
/// pair that is on the same side of that seam. Every pair below is
/// overlay-vs-overlay — same world, later child wins — which is why
/// declaration order is the whole story for these and not for the handle.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  /// A layout overflow, or a tile fetch, surfaces as a framework error. Drop
  /// exactly the tile-load noise.
  void silenceTileLoadErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  Future<ProviderContainer> setUpScreen(WidgetTester tester) async {
    silenceTileLoadErrors();
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-1');
    final user = sampleUser(id: 'user-1', email: 'a@example.com');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      final obsRepo = await container.read(observationRepositoryProvider.future);
      await userRepo.insert(user);
      await projectRepo.insert(project);
      await tagRepo.insert(tag);
      final base = DateTime.utc(2026, 8, 31, 12);
      for (var i = 0; i < 12; i++) {
        await obsRepo.insert(
          sampleObservation(
            id: 'obs-$i',
            projectId: project.projectId,
            userId: user.userId,
            tagId: tag.tagId,
            sessionId: null,
            latitude: 35.10 + i * 0.004,
            longitude: -111.70 + i * 0.006,
          ).copyWith(
            trueNorthBearing: 60.0 + (i * 37) % 120,
            magneticBearing: 60.0 + (i * 37) % 120,
            timestampUtc: base.add(Duration(minutes: i)),
            timestampLocal: base.add(Duration(minutes: i)),
          ),
        );
      }
      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0,
    );
    return container;
  }

  /// Raises the selection card by long-pressing the map, which selects a free
  /// point — the shortest route to the card, and the same card a tapped
  /// recording raises.
  Future<void> selectAPoint(WidgetTester tester) async {
    final map = tester.getRect(find.byKey(const ValueKey('main-map')));
    await tester.longPressAt(map.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey('map-selection-panel')),
      findsOneWidget,
      reason: 'the card this test measures is not up',
    );
  }

  void expectNoOverlap(
    WidgetTester tester,
    Finder a,
    Finder b, {
    required String what,
  }) {
    final ra = tester.getRect(a);
    final rb = tester.getRect(b);
    printOnFailure('$what\n  a = $ra\n  b = $rb');
    expect(
      ra.overlaps(rb),
      isFalse,
      reason: '$what\nThe two rectangles intersect: $ra and $rb. Both are '
          'drawn over the map as `Stack` children, so the one declared later '
          'simply paints over the other and nothing warns anybody.',
    );
  }

  testWidgets('the selection card does not cover the record button',
      (tester) async {
    // Overlap (1). Michael checked this on a device on 2026-09-02: the
    // overlap is real and it is **not** harmful — the Record entry in the
    // bottom navigation still works and tapping out of the selection brings
    // the "+" back. It is a few pixels of clearance and the bottom band
    // beside it already shows how, so it is fixed; nothing here is a control
    // a person cannot reach.
    await setUpScreen(tester);
    await selectAPoint(tester);
    expectNoOverlap(
      tester,
      find.byKey(const ValueKey('map-selection-panel')),
      find.byKey(const ValueKey('map-record-fab')),
      what: 'The selection card must clear the "+" record button.',
    );
  });

  testWidgets('the selection card does not cover the scale bar or the credit',
      (tester) async {
    // The same overlap, and the half that is not cosmetic: the bottom band
    // carries the map-source attribution, which is a licence condition, plus
    // the scale bar and the coordinate readout.
    await setUpScreen(tester);
    await selectAPoint(tester);
    expectNoOverlap(
      tester,
      find.byKey(const ValueKey('map-selection-panel')),
      find.byKey(const ValueKey('map-bottom-band')),
      what: 'The selection card must clear the scale bar, the coordinate '
          'readout and the map-source credit.',
    );
  });

  testWidgets('a solve running under an elevation profile does not collide',
      (tester) async {
    // Overlap (2): both were `left: 0, right: 0, bottom: 0`, and their
    // conditions are not exclusive — a solve can run while two measure
    // points are down.
    final container = await setUpScreen(tester);
    await tester.tap(find.byType(MeasureButton));
    await tester.pump();
    final map = tester.getRect(find.byKey(const ValueKey('main-map')));
    await tester.tapAt(map.center - const Offset(40, 40));
    await tester.pump();
    await tester.tapAt(map.center + const Offset(40, 40));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('map-elevation-panel')),
      findsOneWidget,
      reason: 'two measure points did not raise the elevation profile panel',
    );

    container
        .read(computationStatusProvider.notifier)
        .start('Solving position…');
    await tester.pump();
    expect(find.byKey(const ValueKey('map-computation-progress')), findsOneWidget);

    expectNoOverlap(
      tester,
      find.byKey(const ValueKey('map-elevation-panel')),
      find.byKey(const ValueKey('map-computation-progress')),
      what: 'A running solve and an elevation profile share the bottom edge.',
    );
  });

  testWidgets('the legend does not cover the bottom panels', (tester) async {
    // Not one of task 11.118's four, and found by measuring rather than by
    // reading: the legend card sits at a constant `bottom: 84`, chosen to
    // clear the "+" record button, and the elevation profile is 170 logical
    // pixels of full-width panel along the same edge. Both are up whenever
    // somebody measures two points with the legend on.
    //
    // It is the same defect as marginal (5) in the classification — a
    // centred bottom card reaching under a right-anchored legend — in the
    // state a widget test can actually drive.
    await setUpScreen(tester);

    await tester.tap(find.byType(MeasureButton));
    await tester.pump();
    final map = tester.getRect(find.byKey(const ValueKey('main-map')));
    // Two taps, not one. flutter_map holds a tap until it knows it is not
    // the first half of a double-tap zoom, and on a fake clock what resolves
    // that is the *next* pointer event rather than elapsed time — so the
    // pair lands together and the reachable states are zero measure points
    // or two, never one. That is why marginal (5)'s own state (one point,
    // the centred result card) is not measured here.
    await tester.tapAt(map.center - const Offset(40, 40));
    await tester.pump();
    await tester.tapAt(map.center + const Offset(40, 40));
    await tester.pump();
    expect(find.byKey(const ValueKey('map-elevation-panel')), findsOneWidget);

    // Raise the legend the way a person does — through Layers & Filters.
    await tester.tap(find.byIcon(Icons.layers_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Layers & Filters'), findsOneWidget,
        reason: 'the Layers & Filters sheet did not open');
    await tester.dragUntilVisible(
      find.text('Legend'),
      find.byType(ListView).last,
      const Offset(0, -60),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Legend'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final sheet = find.byType(DraggableScrollableSheet);
    if (sheet.evaluate().isNotEmpty) {
      Navigator.of(tester.element(sheet)).pop();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(find.byType(MapLegendCard), findsOneWidget,
        reason: 'the legend card this test measures is not up');

    expectNoOverlap(
      tester,
      find.byType(MapLegendCard),
      find.byKey(const ValueKey('map-elevation-panel')),
      what: 'The legend must clear the transient bottom column.',
    );
  });
}
