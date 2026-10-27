import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/actual_tag_location.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/map_camera_target.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';

import '../../data/fixtures.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.103 — the Main Map opened on the middle of the Atlantic.
///
/// **Every case here runs with location permission *refused*, not merely
/// absent.** Those are different code paths and the brief is explicit that
/// only one of them is what the Android build shipped in: the rest of this
/// suite stubs "no position" as `Stream.empty()`, which is a device still
/// waiting for a fix, and it would have gone green throughout the defect.
/// Here `gpsPositionProvider` errors with the exception the real provider
/// throws on a refusal, and `locationProblemProvider` answers as a refused
/// device does.
///
/// **What the premise turned out to be.** Michael saw the Atlantic on macOS
/// and, on an Android phone with location denied, saw the area near his test
/// data — so the brief asked whether macOS was broken in some way Android was
/// not. It is not: there is no platform branch anywhere in this chain, and
/// the cases below reproduce both behaviours in one process on one machine.
///
/// The difference was what each device's active project offered the chain —
/// **and the macOS project was not empty.** Re-run against the same Mac after
/// the fix, the map opens on a ground-truth point that had been on that map
/// all along. The old chain's data step read `data.observations` (bearings)
/// and nothing else, so a project whose recordings are truth points,
/// estimates or non-detections fell past it to `0, 0` **while drawing the
/// person's own data on screen.** That case is covered below.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  /// Every tile fetch under `flutter test` comes back 400, so the map's own
  /// `CachedTileProvider` reports dozens of these however the screen behaves.
  /// They are the test environment, not the app — dropped by *type*, so a
  /// real error still fails the test.
  void silenceTileLoadErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  /// A device that has been told no. Not "waiting for a fix".
  List<Object> permissionRefused() => [
        gpsPositionProvider.overrideWith(
          (ref) => Stream<Position>.error(
            const LocationPermissionDeniedException(),
          ),
        ),
        locationProblemProvider.overrideWith(
          (ref) async => const LocationProblem(
            LocationFault.permissionDenied,
            'TriTrack has not been allowed to use your location.',
          ),
        ),
      ];

  Future<ProviderContainer> ready(
    WidgetTester tester, {
    required Project project,
    List<Observation> observations = const [],
    List<Tag> tags = const [],
    List<ActualTagLocation> tagLocations = const [],
  }) async {
    silenceTileLoadErrors();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ...permissionRefused().cast(),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final obsRepo = await container.read(observationRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      await userRepo.insert(sampleUser());
      await projectRepo.insert(project);
      for (final t in tags) {
        await tagRepo.insert(t);
      }
      for (final o in observations) {
        await obsRepo.insert(o);
      }
      final locRepo =
          await container.read(actualTagLocationRepositoryProvider.future);
      for (final l in tagLocations) {
        await locRepo.insert(l);
      }
      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
    });
    return container;
  }

  /// Never `pumpAndSettle`: the map's `TileLayer` issues real network image
  /// requests that never resolve under `flutter test`, so a settle loop would
  /// spin forever — the same reasoning as `map_screen_test.dart`.
  Future<MapOptions> pumpMap(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    MapOptions? options;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const MapScreen()),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final found = find.byType(FlutterMap);
        if (found.evaluate().isNotEmpty) {
          options = tester.widget<FlutterMap>(found).options;
          break;
        }
      }
    });
    expect(options, isNotNull, reason: 'the map never built');
    return options!;
  }

  void wideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Project withoutExtent(Project p) => p.copyWith(
        bboxMinLat: null,
        bboxMinLon: null,
        bboxMaxLat: null,
        bboxMaxLon: null,
      );

  testWidgets(
      'permission refused, no recordings, no project extent: the map shows '
      'the whole planet and says why, and never the Gulf of Guinea',
      (tester) async {
    wideSurface(tester);
    final container = await ready(tester, project: withoutExtent(sampleProject()));
    final options = await pumpMap(tester, container);

    // The regression itself. Before this task the same run produced
    // LatLng(0, 0) at zoom 14 — a real place, presented as the person's.
    expect(options.initialCenter, isNot(const ll.LatLng(0, 0)));
    expect(options.initialCenter, MapCameraTarget.worldViewCenter);
    expect(options.initialZoom, MapCameraTarget.worldViewZoom);
    expect(options.initialCameraFit, isNull);

    // Something a person can read, rather than a place.
    expect(find.byKey(const ValueKey('map-nothing-to-show')), findsOneWidget);
    expect(
      find.textContaining('does not know where you are'),
      findsOneWidget,
    );
  });

  testWidgets(
      'permission refused, but the project has an extent: the map opens on '
      'the extent and says nothing about not knowing', (tester) async {
    wideSurface(tester);
    // This is the Android run. Same code, same refusal — it looked fine
    // because this device's project had somewhere to fall back to.
    final container = await ready(tester, project: sampleProject());
    final options = await pumpMap(tester, container);

    expect(options.initialCameraFit, isNotNull);
    expect(options.initialCenter, isNot(const ll.LatLng(0, 0)));
    expect(find.byKey(const ValueKey('map-nothing-to-show')), findsNothing);
  });

  testWidgets(
      'a project whose only recording is a ground-truth point still opens on '
      'it — this is the exact macOS case', (tester) async {
    wideSurface(tester);
    // **What Michael's Mac actually had.** Not "nothing to fall back to": it
    // had a truth point drawn on the map, labelled and visible, and the map
    // still opened on the Atlantic. The old chain's data step read
    // `data.observations` — bearings — and nothing else, so a project whose
    // recordings are truth points, estimates or non-detections fell straight
    // past it to 0,0 while showing the person their own data.
    final container = await ready(
      tester,
      project: withoutExtent(sampleProject()),
      tags: [sampleTag(id: 'tag-1')],
      tagLocations: [
        sampleActualLocation(id: 'loc-1', tagVersionId: null)
            .copyWith(latitude: 35.09, longitude: -111.61),
      ],
    );
    final options = await pumpMap(tester, container);

    expect(options.initialCenter, isNot(const ll.LatLng(0, 0)));
    expect(options.initialCenter, const ll.LatLng(35.09, -111.61));
    expect(
      find.byKey(const ValueKey('map-nothing-to-show')),
      findsNothing,
      reason: 'there is something to show — a truth point',
    );
  });

  testWidgets(
      'permission refused, recordings present: the recordings win over the '
      'project extent', (tester) async {
    wideSurface(tester);
    // The old chain put the project extent first and then took whichever
    // observation the query happened to return first. Both are corrected:
    // where somebody was working yesterday beats a box drawn at setup.
    final project = sampleProject();
    final container = await ready(
      tester,
      project: project,
      tags: [sampleTag(id: 'tag-1')],
      observations: [
        sampleObservation(
          id: 'obs-far',
          sessionId: null,
          tagVersionId: null,
          latitude: 44.10,
          longitude: -110.10,
        ),
        sampleObservation(
          id: 'obs-near',
          sessionId: null,
          tagVersionId: null,
          latitude: 44.20,
          longitude: -110.30,
        ),
      ],
    );
    final options = await pumpMap(tester, container);

    final fit = options.initialCameraFit;
    expect(fit, isA<FitBounds>());
    final bounds = (fit! as FitBounds).bounds;
    expect(bounds.south, closeTo(44.10, 1e-6));
    expect(bounds.north, closeTo(44.20, 1e-6));
    expect(
      bounds.north,
      lessThan(45),
      reason: 'the project extent (35.1–35.3) must not have won',
    );
    expect(find.byKey(const ValueKey('map-nothing-to-show')), findsNothing);
  });
}
