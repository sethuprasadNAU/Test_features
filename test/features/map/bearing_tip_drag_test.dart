import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';
import 'package:tritrack/features/map/services/geo_math.dart';
import 'package:tritrack/localization/coordinate_projection.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.131 — press and hold a selected bearing's tip and drag it radially,
/// so several wedges can be out at once and you can see where they actually
/// overlap.
///
/// What these tests are actually pinning down, in the order that matters:
///
/// 1. **The ray and its wedge read one length.** They used to carry separate
///    `400` literals and a comment claiming they agreed. Now that the length
///    moves, a ray and a wedge disagreeing about how far a bearing reaches
///    would be worse than the fixed length this replaced — so the drawn radius
///    of the cone is asserted equal to the ray's, before and after a drag.
/// 2. **The cone is recomputed, not stretched.** Angular uncertainty does not
///    shrink with distance, so a longer wedge is a wider one. (The half-angle
///    itself is checked in `services/bearing_wedge_cache_test.dart`.)
/// 3. **Nothing else on the map changed.** A long press on empty map still
///    offers "Navigate here", and a long press on the handle does not — the
///    gesture this task adds has to take precedence without also dropping a
///    free-point selection over the top of the drag.
///
/// The harness (runAsync around the whole first build, real delays for
/// flutter_map's tap detector, `pumpUntil` instead of a fixed sleep) is
/// `map_screen_test.dart`'s, and its file doc explains every part of why.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  const handleKey = ValueKey('bearing-tip-handle');

  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required Project project,
    required List<Tag> tags,
    required List<Observation> observations,
  }) async {
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

      await userRepo.insert(sampleUser());
      await projectRepo.insert(project);
      // Task 11.237: the phone holder is on the project. The device's own
      // fresh user used to resolve to "cannot say" and be permitted; now a
      // user the rows do not name holds a read-only snapshot, whose
      // selection card carries a refusal line this test's geometry never
      // budgeted for.
      await seedContributors(
        (await container.read(appDatabaseProvider.future)).raw,
        projectId: project.projectId,
        userIds: [(await container.read(currentUserProvider.future)).userId],
      );
      for (final t in tags) {
        await tagRepo.insert(t);
      }
      for (final o in observations) {
        await obsRepo.insert(o);
      }
      await container.read(activeProjectIdProvider.notifier).set(project.projectId);
    });

    return container;
  }

  /// A layout overflow or a tile fetch surfaces as a framework error; drop
  /// exactly the tile-load noise, the way the space-budget test does.
  void silenceTileLoadErrors(WidgetTester tester) {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  /// A degenerate bbox puts the camera exactly on the observation, so tapping
  /// the map's own centre lands within `_selectAtPoint`'s 24px hit radius of
  /// the ray's origin.
  Project pointProject(Observation at) => sampleProject().copyWith(
        bboxMinLat: at.latitude,
        bboxMaxLat: at.latitude,
        bboxMinLon: at.longitude,
        bboxMaxLon: at.longitude,
      );

  Future<void> tapMapCenter(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
  }

  /// flutter_map dispatches its long press straight through
  /// `PositionedTapDetector2` with no double-tap window to wait out (unlike
  /// its *tap*, which is why `tapMapCenter` above needs `runAsync`), so the
  /// fake clock is enough here.
  Future<void> longPressMapAt(WidgetTester tester, Offset at) async {
    await tester.longPressAt(at);
    await tester.pump();
  }

  /// The drawn radius of the bearing ray, in metres, straight off the
  /// `Polyline` the map is actually painting.
  double rayLength(WidgetTester tester) {
    final polylines = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .where((p) => p.points.length == 2)
        .toList();
    expect(polylines, hasLength(1));
    final p = polylines.single.points;
    return distanceAndBearing(
      GeoPoint(p.first.latitude, p.first.longitude),
      GeoPoint(p.last.latitude, p.last.longitude),
    ).distanceMeters;
  }

  /// The drawn radius of the uncertainty cone, in metres: the distance from
  /// the wedge's origin vertex to the middle of its arc.
  double wedgeRadius(WidgetTester tester) {
    final polygons = tester
        .widgetList<PolygonLayer>(find.byType(PolygonLayer))
        .expand((l) => l.polygons)
        // The wedge is `origin → arc`, 18 points for the default 16 segments;
        // the error ellipse (the only other polygon this screen draws) is a
        // closed 48-point ring.
        .where((p) => p.points.length == 18)
        .toList();
    expect(polygons, hasLength(1));
    final pts = polygons.single.points;
    final origin = GeoPoint(pts.first.latitude, pts.first.longitude);
    final mid = pts[1 + (pts.length - 1) ~/ 2];
    return distanceAndBearing(origin, GeoPoint(mid.latitude, mid.longitude))
        .distanceMeters;
  }

  /// Presses and holds the tip handle, then drags it [pixels] screen pixels
  /// outward along the ray (negative pulls it in) and releases.
  Future<void> dragTip(WidgetTester tester, double pixels) async {
    final centre = tester.getCenter(find.byType(FlutterMap));
    final handle = tester.getCenter(find.byKey(handleKey));
    final along = handle - centre;
    final unit = along / along.distance;

    final gesture = await tester.startGesture(handle);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    // Several steps, the way a finger moves — one jump can be read as a fling.
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(unit * (pixels / 5));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
  }

  Future<void> setUpSelectedBearing(WidgetTester tester) async {
    silenceTileLoadErrors(tester);
    final tag = sampleTag();
    final observation = sampleObservation(sessionId: null, tagId: tag.tagId);
    final project = pointProject(observation);
    final container = await readyContainer(
      tester,
      project: project,
      tags: [tag],
      observations: [observation],
    );
    await pumpInAppShell(
      tester,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0, // **Map** / Record / Compass / Position / More
    );
    expect(tester.takeException(), isNull);
    await tapMapCenter(tester);
  }

  testWidgets('with nothing selected there is no tip handle to grab',
      (tester) async {
    silenceTileLoadErrors(tester);
    final tag = sampleTag();
    final observation = sampleObservation(sessionId: null, tagId: tag.tagId);
    final project = pointProject(observation);
    final container = await readyContainer(
      tester,
      project: project,
      tags: [tag],
      observations: [observation],
    );
    await pumpInAppShell(
      tester,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0,
    );

    expect(find.byKey(handleKey), findsNothing);
    // The default length, read by both layers.
    expect(rayLength(tester), closeTo(400, 1));
    expect(wedgeRadius(tester), closeTo(400, 1));
  });

  testWidgets('selecting a bearing puts a grabbable handle at its tip',
      (tester) async {
    await setUpSelectedBearing(tester);

    expect(find.byKey(handleKey), findsOneWidget);
    // Larger than the dot it draws: a comfortable touch target.
    final size = tester.getSize(find.byKey(handleKey));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));

    // And it is out along the ray, not at the origin. It is drawn at the tip
    // whenever the tip is on screen and clear of the selection card, and
    // clamped back down the same ray when it is not — so what is always true,
    // and what is asserted, is that it sits **on the ray**. On a 6.1-inch
    // phone with the card up, the default 400 m tip is close to that
    // boundary, which is exactly why this is checked as collinearity rather
    // than as a distance.
    final centre = tester.getCenter(find.byType(FlutterMap));
    final handle = tester.getCenter(find.byKey(handleKey));
    expect((handle - centre).distance, greaterThan(50));

    final rayEnd = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .firstWhere((p) => p.points.length == 2)
        .points
        .last;
    final camera =
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController;
    final tipOffset = camera!.camera.latLngToScreenOffset(rayEnd) +
        tester.getTopLeft(find.byType(FlutterMap));
    final toTip = tipOffset - centre;
    final toHandle = handle - centre;
    final cross = toTip.dx * toHandle.dy - toTip.dy * toHandle.dx;
    expect((cross / toTip.distance).abs(), lessThan(2.0),
        reason: 'the handle is on the ray, whether at the tip or clamped '
            'back along it');
  });

  testWidgets(
      'press-hold-drag lengthens the ray and its wedge together, live, and '
      'names the radius while it happens', (tester) async {
    await setUpSelectedBearing(tester);
    expect(rayLength(tester), closeTo(400, 1));

    final centre = tester.getCenter(find.byType(FlutterMap));
    final handle = tester.getCenter(find.byKey(handleKey));
    final unit = (handle - centre) / (handle - centre).distance;

    final gesture = await tester.startGesture(handle);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(unit * 40);
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Live: the drawn length has already moved, mid-gesture.
    final duringDrag = rayLength(tester);
    expect(duringDrag, greaterThan(500));
    // And the wedge came with it — one length, two layers.
    expect(wedgeRadius(tester), closeTo(duringDrag, 1));
    // The readout is what makes this a measurement rather than a fidget.
    expect(find.textContaining('Drawn to'), findsOneWidget);

    await gesture.up();
    await tester.pump();

    // Released, it stays.
    expect(rayLength(tester), closeTo(duringDrag, 1));
    expect(wedgeRadius(tester), closeTo(duringDrag, 1));
    // The readout is only for the drag.
    expect(find.textContaining('Drawn to'), findsNothing);
  });

  testWidgets('the map does not pan during a tip drag', (tester) async {
    await setUpSelectedBearing(tester);
    final originBefore = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .firstWhere((p) => p.points.length == 2)
        .points
        .first;
    final screenBefore = tester.getCenter(find.byType(FlutterMap));

    await dragTip(tester, 120);

    // The ray's origin is a fixed lat/lon; if the camera had panned, the
    // *screen* position of the map centre relative to it would have moved.
    // Compare the origin's rendered offset instead: it must not have moved.
    final originAfter = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .expand((l) => l.polylines)
        .firstWhere((p) => p.points.length == 2)
        .points
        .first;
    expect(originAfter.latitude, originBefore.latitude);
    expect(originAfter.longitude, originBefore.longitude);
    expect(tester.getCenter(find.byType(FlutterMap)), screenBefore);
  });

  testWidgets('a dragged length survives deselecting the bearing',
      (tester) async {
    await setUpSelectedBearing(tester);
    await dragTip(tester, 200);
    final extended = rayLength(tester);
    expect(extended, greaterThan(600));

    // Tap well away from the ray to clear the selection.
    await tester.runAsync(() async {
      final box = tester.getRect(find.byType(FlutterMap));
      await tester.tapAt(Offset(box.left + 30, box.top + 200));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });

    expect(find.byKey(handleKey), findsNothing,
        reason: 'nothing selected, so no handle');
    expect(rayLength(tester), closeTo(extended, 1),
        reason: 'the length is a display choice about the map, not about the '
            'selection — several bearings have to be able to stay out at once');
    expect(wedgeRadius(tester), closeTo(extended, 1));
  });

  testWidgets('double-tapping the tip returns that bearing to the default',
      (tester) async {
    await setUpSelectedBearing(tester);
    await dragTip(tester, 200);
    expect(rayLength(tester), greaterThan(600));

    final handle = tester.getCenter(find.byKey(handleKey));
    await tester.tapAt(handle);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(handle);
    await tester.pump(const Duration(milliseconds: 400));

    expect(rayLength(tester), closeTo(400, 1));
    expect(wedgeRadius(tester), closeTo(400, 1));
  });

  testWidgets(
      'dragging out clamps at 40 km, and the handle is still grabbable there',
      (tester) async {
    await setUpSelectedBearing(tester);

    // Far more pixels than the viewport is wide.
    await dragTip(tester, 40000);
    expect(rayLength(tester), closeTo(40000, 50),
        reason: '40 km: Michael\'s field report of trackers picking up a '
            'VHF collar at around 35 km from elevation, with a margin above '
            'it (task 11.87)');
    expect(wedgeRadius(tester), closeTo(rayLength(tester), 1));

    // The tip is now far off screen. The handle is clamped back onto the
    // visible part of the ray, and — this is the part that matters — it is
    // still hit-testable, so the bearing can be dragged back in. A handle
    // that is merely *present* under the selection card or the record button
    // would satisfy `findsOneWidget` and be exactly the trap this avoids.
    expect(find.byKey(handleKey).hitTestable(), findsOneWidget);
  });

  testWidgets('dragging in clamps at 100 m', (tester) async {
    await setUpSelectedBearing(tester);

    await dragTip(tester, -20000);
    expect(rayLength(tester), closeTo(100, 5),
        reason: 'a bearing must not be draggable down to nothing — that reads '
            'as a bearing that was deleted');
    expect(wedgeRadius(tester), closeTo(rayLength(tester), 1));
  });

  testWidgets(
      'a long press on empty map still offers Navigate here, and a long '
      'press on the handle does not', (tester) async {
    await setUpSelectedBearing(tester);

    // Unchanged behaviour: a hold on empty map selects the free point.
    final box = tester.getRect(find.byType(FlutterMap));
    await longPressMapAt(tester, Offset(box.left + 40, box.top + 240));
    expect(find.text('Map point'), findsOneWidget);
    expect(find.text('Navigate here'), findsOneWidget);
    expect(find.byKey(handleKey), findsNothing,
        reason: 'the free point is what is selected now');

    // Back to the bearing, then hold its handle: the drag takes precedence
    // and no free-point selection lands on top of it.
    await tapMapCenter(tester);
    expect(find.byKey(handleKey), findsOneWidget);
    await dragTip(tester, 150);
    expect(rayLength(tester), greaterThan(500));
    expect(find.byKey(handleKey), findsOneWidget,
        reason: 'still the bearing that is selected, not a free point');
  });
}
