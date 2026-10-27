import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:tritrack/compass/compass_controller.dart';
import 'package:tritrack/compass/compass_reading.dart';
import 'package:tritrack/compass/magnetometer_interference.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/map_settings_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/features/map/services/bearing_wedge_cache.dart';
import 'package:tritrack/features/map/services/geo_math.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';
import 'package:tritrack/features/observations/providers/bearing_map_provider.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/bearing_map_capture_screen.dart';
import 'package:tritrack/localization/coordinate_projection.dart';
import 'package:tritrack/localization/declination/declination_override_provider.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/roboto_font.dart';
import '../../support/text_scale_probe.dart';

/// A compass the test points by hand.
class _FakeCompass extends CompassController {
  @override
  CompassReading build() =>
      CompassReading.initial.copyWith(magneticHeadingDeg: 100);

  void point(double magneticDeg) =>
      state = state.copyWith(magneticHeadingDeg: magneticDeg);

  void lose() => state = CompassReading.initial;

  void disturb() => state = state.copyWith(
    interference: const InterferenceAssessment(
      level: InterferenceLevel.severe,
      fieldMagnitudeMicroTesla: 140,
      message: 'severe',
    ),
  );
}

/// Task 11.315 — *Take on map*, measured against what its brief asked for.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  // Where the person stands: the record draft's manual pin.
  const standLat = 35.2;
  const standLon = -111.6;
  const declination = 10.0;

  /// The same zone rule every screen test here follows (see
  /// `record_position_preview_screen_test.dart`): every provider this screen
  /// reads is started and held open inside `runAsync`.
  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    int extraBearingsToday = 0,
    bool selectTag = true,
    List<Deployment> Function(DateTime now, DateTime thisMorning)? deploymentsBuilder,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassControllerProvider.overrideWith(_FakeCompass.new),
      ],
    );
    addTearDown(container.dispose);

    final now = DateTime.now();
    final thisMorning = DateTime(now.year, now.month, now.day, 0, 5).toUtc();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 12).toUtc();

    await tester.runAsync(() async {
      await (await container.read(userRepositoryProvider.future)).insert(
        sampleUser(),
      );
      await (await container.read(projectRepositoryProvider.future)).insert(
        sampleProject(),
      );
      final tags = await container.read(tagRepositoryProvider.future);
      await tags.insert(sampleTag());
      await tags.insert(sampleTag(id: 'tag-2', frequencyMhz: 150.9));
      if (deploymentsBuilder != null) {
        final individuals = await container.read(individualRepositoryProvider.future);
        final deployments = await container.read(deploymentRepositoryProvider.future);
        for (final d in deploymentsBuilder(now, thisMorning)) {
          if ((await individuals.findById(d.individualId, projectId: d.projectId)) == null) {
            await individuals.insert(sampleIndividual(id: d.individualId, name: d.individualId));
          }
          await deployments.link(d);
        }
      }
      final obs = await container.read(observationRepositoryProvider.future);
      // Two earlier bearings on this collar this morning, from a little way
      // off; one on another collar; one on this collar yesterday.
      for (final (id, tagId, at, lat) in [
        ('today-a', 'tag-1', thisMorning, 35.21),
        ('today-b', 'tag-1', thisMorning, 35.19),
        ('other-collar', 'tag-2', thisMorning, 35.2),
        ('yesterday', 'tag-1', yesterday, 35.2),
      ]) {
        await obs.insert(
          sampleObservation(
            id: id,
            tagId: tagId,
            sessionId: null,
            tagVersionId: null,
            timestampUtc: at,
            latitude: lat,
            longitude: -111.61,
          ),
        );
      }
      for (var i = 0; i < extraBearingsToday; i++) {
        await obs.insert(
          sampleObservation(
            id: 'many-$i',
            sessionId: null,
            tagVersionId: null,
            timestampUtc: thisMorning.add(Duration(minutes: i)),
            latitude: 35.15 + i * 0.001,
            longitude: -111.65 + i * 0.001,
          ).copyWith(trueNorthBearing: (i * 37) % 360.0),
        );
      }
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(activeProjectIdProvider.notifier).set('project-1');

      container.listen(observationFormProvider, (_, _) {});
      container.listen(currentProjectProvider, (_, _) {});
      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});
      container.listen(
        todaysBearingsOnTagProvider((projectId: 'project-1', tagId: 'tag-1')),
        (_, _) {},
      );
      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(bearingMapOrientationProvider, (_, _) {});
      container.listen(declinationOverrideProvider, (_, _) {});
      container.listen(selectedTileCategoryProvider, (_, _) {});

      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(
        todaysBearingsOnTagProvider((
          projectId: 'project-1',
          tagId: 'tag-1',
        )).future,
      );
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(bearingMapOrientationProvider.future);
      await container.read(declinationOverrideProvider.future);
      await container.read(declinationOverrideProvider.notifier).set(declination);
      await container.read(selectedTileCategoryProvider.future);
      await container.read(observationFormProvider.future);
      final form = container.read(observationFormProvider.notifier);
      if (selectTag) form.setTag('tag-1');
      form.setManualPosition(true, lat: standLat, lon: standLon);
      // Something already on the form, so "unchanged" means something.
      form.setBearing(bearingDeg: 45, uncertaintyDeg: 12);
    });
    return container;
  }

  final navigatorKey = GlobalKey<NavigatorState>();

  /// Pumps a plain home page and pushes the screen over it, so Confirm and
  /// Cancel have somewhere to go back to. Plain `pump`s: tiles never arrive
  /// under `flutter test`, so `pumpAndSettle` would never settle.
  Future<void> openScreen(
    WidgetTester tester,
    ProviderContainer container, {
    double? textScale,
    BearingWedgeCache? wedgeCache,
  }) async {
    if (textScale == null) {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
    } else {
      usePhoneGeometry(tester);
    }
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.light(),
          builder: textScale == null
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
          home: const Scaffold(body: Text('the record form')),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => BearingMapCaptureScreen(wedgeCache: wedgeCache),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  _FakeCompass compassOf(ProviderContainer c) =>
      c.read(compassControllerProvider.notifier) as _FakeCompass;

  BuildContext mapContext(WidgetTester tester) =>
      tester.element(find.byKey(const ValueKey('bearing-map-lines')));

  List<Polyline> lines(WidgetTester tester) => tester
      .widget<PolylineLayer>(find.byKey(const ValueKey('bearing-map-lines')))
      .polylines;

  Future<void> hold(WidgetTester tester, Future<void> Function() during) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('bearing-map-hold'))),
    );
    await settle(tester);
    await during();
    await gesture.up();
    await settle(tester);
  }

  group('every line reaches the screen edge, capped at 40 km', () {
    /// For each drawn line: its far end is off the screen whenever the
    /// screen is smaller than 40 km, and exactly 40 km out when it is not.
    /// Asked after a pan, a zoom and a rotation — each of which moves the
    /// screen's edge relative to every line.
    void expectEveryLineReachesTheEdge(WidgetTester tester, String after) {
      final camera = MapCamera.of(mapContext(tester));
      final screen = Offset.zero & camera.nonRotatedSize;
      final drawn = lines(tester);
      expect(drawn, isNotEmpty);
      for (final line in drawn) {
        final origin = line.points.first;
        final tip = line.points.last;
        final lengthM = distanceAndBearing(
          GeoPoint(origin.latitude, origin.longitude),
          GeoPoint(tip.latitude, tip.longitude),
        ).distanceMeters;
        final tipOnScreen = screen.contains(camera.latLngToScreenOffset(tip));
        expect(
          !tipOnScreen || (lengthM - kMaxBearingRangeMeters).abs() < 1,
          isTrue,
          reason:
              'After $after, a line from $origin stops at $tip, '
              '${lengthM.round()} m out and inside the screen — short of the '
              'edge and short of the 40 km cap.',
        );
        expect(
          lengthM,
          lessThanOrEqualTo(kMaxBearingRangeMeters + 1),
          reason: 'Past 40 km a line is not information.',
        );
      }
    }

    testWidgets('after a pan, a zoom out, a rotation, and a zoom far out', (
      tester,
    ) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      expect(tester.takeException(), isNull);
      final controller = MapController.of(mapContext(tester));

      expectEveryLineReachesTheEdge(tester, 'opening');

      controller.move(const ll.LatLng(standLat + 0.03, standLon - 0.04), 14);
      await settle(tester);
      expectEveryLineReachesTheEdge(tester, 'a pan that puts the position '
          'near the corner');

      controller.move(const ll.LatLng(standLat, standLon), 11);
      await settle(tester);
      expectEveryLineReachesTheEdge(tester, 'a zoom out to about 50 km across');

      controller.rotate(37);
      await settle(tester);
      expectEveryLineReachesTheEdge(tester, 'a rotation');

      // 200 km across: now the cap, not the edge, is where a line stops, and
      // at least one tip must be visibly inside the screen for that half of
      // the claim to have been asked at all.
      controller.move(const ll.LatLng(standLat, standLon), 9);
      await settle(tester);
      expectEveryLineReachesTheEdge(tester, 'a zoom out past 40 km');
      final camera = MapCamera.of(mapContext(tester));
      final screen = Offset.zero & camera.nonRotatedSize;
      expect(
        lines(tester).any(
          (l) => screen.contains(camera.latLngToScreenOffset(l.points.last)),
        ),
        isTrue,
      );
    });
  });

  /// **Redrawing every bearing on every frame must stay smooth** (the
  /// brief's acceptance). The expensive part is a wedge's spherical
  /// trigonometry, and the Map tab's answer is to compute each once
  /// (`BearingWedgeCache`, task 11.131). This counts the computations while
  /// the map is panned, zoomed and turned with 102 bearings on it — far more
  /// than one collar gets in a day — and while a sweep is held.
  testWidgets('102 earlier bearings: panning, zooming and turning recompute '
      'no wedge; a sweep recomputes only its own', (tester) async {
    final container = await readyContainer(tester, extraBearingsToday: 100);
    final cache = BearingWedgeCache();
    await openScreen(tester, container, wedgeCache: cache);
    expect(cache.recomputeCount, 102, reason: 'Each earlier wedge, once.');

    final controller = MapController.of(mapContext(tester));
    for (var i = 0; i < 20; i++) {
      controller.moveAndRotate(
        ll.LatLng(standLat + i * 0.002, standLon - i * 0.002),
        10 + i * 0.3,
        i * 9.0,
      );
      await tester.pump();
    }
    await tester.dragFrom(
      tester.getCenter(find.byType(FlutterMap)),
      const Offset(-200, 90),
    );
    await settle(tester);
    expect(
      cache.recomputeCount,
      102,
      reason: 'Twenty camera moves and a drag, and not one wedge recomputed.',
    );

    final compass = compassOf(container);
    await hold(tester, () async {
      for (final heading in [105.0, 110.0, 115.0, 120.0]) {
        compass.point(heading);
        await tester.pump();
      }
    });
    expect(
      cache.recomputeCount,
      lessThanOrEqualTo(102 + 5),
      reason: 'Only the sweep\'s own wedge follows the compass.',
    );
  });

  group('what is drawn', () {
    testWidgets('today\'s bearings on this collar only, and the sweep in true '
        'north', (tester) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);

      // Two earlier lines and the dashed line where the phone points —
      // another collar's bearing and yesterday's are left out.
      final idle = lines(tester);
      expect(idle, hasLength(3));
      final origins = {
        for (final l in idle.take(2)) l.points.first.latitude,
      };
      expect(origins, {35.21, 35.19});

      // The phone points 100° magnetic; with 10° east declination the line
      // on the map runs at 110° true.
      final pointer = idle.last.points;
      final dir = distanceAndBearing(
        GeoPoint(pointer.first.latitude, pointer.first.longitude),
        GeoPoint(pointer.last.latitude, pointer.last.longitude),
      ).bearingDeg;
      expect(dir, closeTo(110, 0.5));

      // No tile ever arrives under `flutter test`, so this is the screen
      // with no downloaded map: the lines above are drawn over nothing, and
      // the scale bar is still there to read distances off.
      expect(find.byType(MapScaleBar), findsOneWidget);
    });

    testWidgets('with no position yet, it says so instead of drawing from '
        'nowhere', (tester) async {
      final container = await readyContainer(tester);
      container
          .read(observationFormProvider.notifier)
          .setManualPosition(false);
      await openScreen(tester, container);
      expect(find.byType(FlutterMap), findsNothing);
      expect(find.textContaining('No position yet'), findsOneWidget);
    });

    testWidgets('while held, the swept wedge is drawn live', (tester) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      final compass = compassOf(container);

      await hold(tester, () async {
        compass.point(120);
        await settle(tester);
        final wedges = tester
            .widget<PolygonLayer>(find.byKey(const ValueKey('bearing-map-wedges')))
            .polygons;
        // Two earlier wedges and the sweep.
        expect(wedges, hasLength(3));
        final sweepLine = lines(tester).last.points;
        expect(
          distanceAndBearing(
            GeoPoint(sweepLine.first.latitude, sweepLine.first.longitude),
            GeoPoint(sweepLine.last.latitude, sweepLine.last.longitude),
          ).bearingDeg,
          closeTo(120, 0.5),
          reason: 'Swept 100° → 120° magnetic: the middle, 110°, plus 10° '
              'declination.',
        );
      });
    });
  });

  group('taking it', () {
    Future<ProviderContainer> sweep(WidgetTester tester) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      final compass = compassOf(container);
      compass.point(100);
      await settle(tester);
      await hold(tester, () async {
        compass.point(120);
        await settle(tester);
      });
      expect(find.text('110° ± 10°'), findsOneWidget);
      return container;
    }

    testWidgets('Confirm fills the record form and goes back to it', (
      tester,
    ) async {
      final container = await sweep(tester);
      await tester.tap(find.byKey(const ValueKey('bearing-map-confirm')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      final draft = container.read(observationFormProvider).value!;
      expect(draft.bearingDeg, 110);
      expect(draft.bearingUncertaintyDeg, 10);
      expect(draft.bearingCaptureMethodDb, 'range_capture');
      expect(draft.bearingStartDeg, 100);
      expect(draft.bearingEndDeg, 120);
      expect(find.text('the record form'), findsOneWidget);
      expect(find.byType(BearingMapCaptureScreen), findsNothing);

    });

    testWidgets('Cancel goes back with the form unchanged', (tester) async {
      final container = await sweep(tester);
      await tester.tap(find.byKey(const ValueKey('bearing-map-cancel')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      final draft = container.read(observationFormProvider).value!;
      expect(draft.bearingDeg, 45);
      expect(draft.bearingUncertaintyDeg, 12);
      expect(draft.bearingCaptureMethodDb, isNull);
      expect(find.byType(BearingMapCaptureScreen), findsNothing);
    });

    /// The one way this button differs from RANGE, on purpose: a person
    /// turning on the spot slides their thumb, and RANGE's tap recognizer
    /// gives the sweep up after about 18 pixels of that (measured for task
    /// 11.315's report; RANGE itself is unchanged).
    testWidgets('a thumb that slides while holding keeps the sweep', (
      tester,
    ) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      final compass = compassOf(container);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('bearing-map-hold'))),
      );
      await settle(tester);
      compass.point(130);
      await gesture.moveBy(const Offset(60, -20));
      await settle(tester);
      await gesture.up();
      await settle(tester);
      expect(find.text('115° ± 15°'), findsOneWidget);
    });

    testWidgets('Retake clears the sweep and stays on the map', (tester) async {
      final container = await sweep(tester);
      await tester.tap(find.byKey(const ValueKey('bearing-map-retake')));
      await settle(tester);

      expect(find.byType(BearingMapCaptureScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('bearing-map-confirm')), findsNothing);
      expect(find.byKey(const ValueKey('bearing-map-hold')), findsOneWidget);
      expect(find.text('120°'), findsOneWidget, reason: 'The live heading.');
      expect(container.read(observationFormProvider).value!.bearingDeg, 45);
    });
  });

  group('touches while the button is held', () {
    testWidgets('are ignored by the map, and work again after release', (
      tester,
    ) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      ll.LatLng center() => MapCamera.of(mapContext(tester)).center;
      final before = center();
      final mapPoint = tester.getCenter(find.byType(FlutterMap));

      await hold(tester, () async {
        await tester.dragFrom(mapPoint, const Offset(150, 80));
        await settle(tester);
        expect(
          center(),
          before,
          reason: 'A thumb brushing the map mid-sweep must not move it.',
        );
      });

      // Control: the same drag with nothing held does move it, or the check
      // above could pass for a map that never moves at all.
      await tester.dragFrom(mapPoint, const Offset(150, 80));
      await settle(tester);
      expect(center(), isNot(before));
      expect(container.read(observationFormProvider).value!.bearingDeg, 45);
    });
  });

  /// The clipped-text sweep pumps this screen as it opens. The two states it
  /// cannot reach — the button held, and the three choices after release —
  /// are where the longest words on the screen are, so they are measured
  /// here, in Roboto, at every text size from the default up.
  group('readable at every text size, before, during and after a sweep', () {
    setUpAll(loadRobotoFromSdkCache);

    for (final scale in iosTextScalesUpward) {
      testWidgets(textScaleName(scale), (tester) async {
        final container = await readyContainer(tester);
        await openScreen(tester, container, textScale: scale);
        final compass = compassOf(container);

        void expectReadable(String when) {
          expect(tester.takeException(), isNull, reason: when);
          expect(clippedTexts(tester), isEmpty, reason: when);
        }

        expectReadable('as it opens');
        await hold(tester, () async {
          compass.point(120);
          await settle(tester);
          expect(find.textContaining('SWEEPING'), findsOneWidget);
          expectReadable('while the button is held');
        });
        expect(find.byKey(const ValueKey('bearing-map-confirm')), findsOneWidget);
        expectReadable('after release, with Cancel, Retake and Confirm');
      });
    }
  });

  group('two orientations, one button', () {
    testWidgets('facing up puts the phone\'s true heading at the top', (
      tester,
    ) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      expect(find.text('North up'), findsOneWidget);
      expect(MapCamera.of(mapContext(tester)).rotation, 0);

      await tester.tap(find.byKey(const ValueKey('bearing-map-orientation')));
      await settle(tester);
      expect(find.text('Facing up'), findsOneWidget);

      // Measured, not believed: a point along 110° true (100° magnetic plus
      // 10°) from the position lands straight above it on the screen.
      final camera = MapCamera.of(mapContext(tester));
      final here = camera.latLngToScreenOffset(const ll.LatLng(standLat, standLon));
      final ahead = destinationPoint(const GeoPoint(standLat, standLon), 110, 500);
      final there = camera.latLngToScreenOffset(
        ll.LatLng(ahead.latitude, ahead.longitude),
      );
      final angle =
          math.atan2(there.dx - here.dx, -(there.dy - here.dy)) * 180 / math.pi;
      expect(angle, closeTo(0, 1));
    });

    testWidgets('the choice is remembered the next time the screen opens', (
      tester,
    ) async {
      final first = await readyContainer(tester);
      await openScreen(tester, first);
      await tester.tap(find.byKey(const ValueKey('bearing-map-orientation')));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());

      final second = await readyContainer(tester);
      await openScreen(tester, second);
      expect(find.text('Facing up'), findsOneWidget);
    });

    testWidgets('facing up stops turning, and says so, when the compass is '
        'disturbed or gone', (tester) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      await tester.tap(find.byKey(const ValueKey('bearing-map-orientation')));
      await settle(tester);
      final compass = compassOf(container);
      final turned = MapCamera.of(mapContext(tester)).rotation;

      compass.disturb();
      compass.point(250);
      await settle(tester);
      expect(MapCamera.of(mapContext(tester)).rotation, turned);
      expect(find.textContaining('compass is disturbed'), findsOneWidget);

      compass.lose();
      await settle(tester);
      expect(MapCamera.of(mapContext(tester)).rotation, turned);
      expect(find.textContaining('No compass heading'), findsOneWidget);
    });

    testWidgets('panning away in facing up pauses the turning until Back to me',
        (tester) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);
      await tester.tap(find.byKey(const ValueKey('bearing-map-orientation')));
      await settle(tester);
      final compass = compassOf(container);

      await tester.dragFrom(
        tester.getCenter(find.byType(FlutterMap)),
        const Offset(120, 0),
      );
      await settle(tester);
      expect(find.textContaining('stopped turning while you move'), findsOneWidget);
      final paused = MapCamera.of(mapContext(tester)).rotation;
      compass.point(200);
      await settle(tester);
      expect(MapCamera.of(mapContext(tester)).rotation, paused);

      await tester.tap(find.byKey(const ValueKey('bearing-map-back-to-me')));
      await settle(tester);
      final camera = MapCamera.of(mapContext(tester));
      expect(camera.center.latitude, closeTo(standLat, 1e-6));
      expect(camera.center.longitude, closeTo(standLon, 1e-6));
      expect(find.textContaining('stopped turning while you move'), findsNothing);
      expect(camera.rotation, isNot(paused));
    });
  });

  group('map type (task 11.317 item 1)', () {
    testWidgets('is the Map tab\'s own control, and changing it here changes '
        'the shared setting', (tester) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);

      expect(find.byType(MapTypeToggle), findsOneWidget);
      expect(
        find.descendant(of: find.byType(MapTypeToggle), matching: find.text('Terrain')),
        findsWidgets,
      );
      expect(
        container.read(selectedTileCategoryProvider).value,
        TileCategory.terrain,
      );

      // Two copies of each label sit here too (the halo behind the real
      // control, `map_screen_test.dart`'s own pattern) — tap the real one,
      // painted last.
      await tester.tap(
        find.descendant(of: find.byType(MapTypeToggle), matching: find.text('Satellite')).last,
      );
      await settle(tester);

      expect(
        container.read(selectedTileCategoryProvider).value,
        TileCategory.satellite,
        reason: 'One setting, so a change here is a change everywhere it is read.',
      );
    });
  });

  group('the key card is gone (task 11.317 item 2)', () {
    testWidgets('no tag selected: a short line says why, without "bright" or '
        '"faint"', (tester) async {
      final container = await readyContainer(tester, selectTag: false);
      await openScreen(tester, container);

      expect(
        find.byKey(const ValueKey('bearing-map-no-tag-notice')),
        findsOneWidget,
      );
      expect(
        find.text('No tag selected, so no earlier bearings are shown.'),
        findsOneWidget,
      );
      expect(find.textContaining('Bright'), findsNothing);
      expect(find.textContaining('Faint'), findsNothing);
    });

    testWidgets('a tag selected, earlier bearings or none: no notice at all', (
      tester,
    ) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);

      expect(
        find.byKey(const ValueKey('bearing-map-no-tag-notice')),
        findsNothing,
      );
      expect(find.textContaining('Bright'), findsNothing);
      expect(find.textContaining('Faint'), findsNothing);
    });
  });

  group('the collar-swap day (task 11.317 item 4)', () {
    testWidgets('a bearing taken while the collar was on a different animal '
        'is left out', (tester) async {
      final container = await readyContainer(
        tester,
        deploymentsBuilder: (now, thisMorning) {
          // The swap happened a minute before "now": the morning deployment
          // covers `thisMorning`'s bearings and not the sweep taken now; the
          // afternoon one covers now and not this morning.
          final swap = now.subtract(const Duration(minutes: 1));
          return [
            sampleDeployment(
              id: 'deployment-morning',
              individualId: 'individual-morning',
              attachedDate: now.subtract(const Duration(days: 5)),
              removedDate: swap,
            ),
            sampleDeployment(
              id: 'deployment-afternoon',
              individualId: 'individual-afternoon',
              attachedDate: swap,
            ),
          ];
        },
      );
      await openScreen(tester, container);

      // Only the dashed pointer line remains — `today-a` and `today-b`
      // (this morning, on the animal the collar had before the swap) are
      // left out of what *Take on map* draws.
      expect(lines(tester), hasLength(1));
    });

    testWidgets('with no deployments at all, a bearing with no animal '
        'attributed stays, because the current one has none either', (
      tester,
    ) async {
      final container = await readyContainer(tester);
      await openScreen(tester, container);

      // The default fixture has no deployments: both `today-a` and
      // `today-b` are attributed to nobody, exactly as the sweep taken now
      // is, so both stay.
      expect(lines(tester), hasLength(3));
    });
  });
}
