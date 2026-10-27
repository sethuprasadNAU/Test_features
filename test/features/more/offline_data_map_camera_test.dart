import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/features/map/map_camera_target.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/download_manager.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/more/screens/offline_data_map_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.120 — the Offline Data Map's place in the fallback chain.**
///
/// The screen used to have steps 1 and 4 only: this device's fix, or the
/// whole planet. Somebody with no fix who had drawn a project extent still
/// opened on a world view and had to pan to their study area before they
/// could draw a download region — on the one screen whose entire purpose is
/// downloading data for that study area.
///
/// Every case here overrides `currentProjectProvider`, so no database is
/// opened. What it costs to watch that provider for real is measured
/// separately, on the real clock, in
/// `test/features/more/current_project_watch_cost_test.dart`.
class _FakeOfflineRegions extends OfflineRegions {
  @override
  Future<List<OfflineRegion>> build() async => const [];
}

class _NoDownloads extends DownloadManager {
  @override
  List<DownloadJob> build() => const [];
}

Project _project({
  double? minLat,
  double? minLon,
  double? maxLat,
  double? maxLon,
}) =>
    Project(
      projectId: 'p1',
      projectName: 'Study site',
      ownerUserId: 'u1',
      creationDate: DateTime.utc(2026, 1, 1),
      bboxMinLat: minLat,
      bboxMinLon: minLon,
      bboxMaxLat: maxLat,
      bboxMaxLon: maxLon,
      sync: SyncMeta.initial(
        now: DateTime.utc(2026, 1, 1),
        modifiedBy: 'u1',
        originDeviceId: 'd1',
      ),
    );

Position _fix(double lat, double lon) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.utc(2026, 1, 1),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  /// Pumps the screen. [projectStream] lets a case decide *when* the project
  /// resolves, which is the whole point of one of them.
  Future<MapCamera> pumpScreen(
    WidgetTester tester, {
    required Stream<Project?> projects,
    Stream<Position> fixes = const Stream.empty(),
  }) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    final container = ProviderContainer(
      overrides: [
        gpsPositionProvider.overrideWith((ref) => fixes),
        currentProjectProvider.overrideWith((ref) => projects.first),
        offlineRegionsProvider.overrideWith(_FakeOfflineRegions.new),
        downloadManagerProvider.overrideWith(_NoDownloads.new),
      ],
    );
    addTearDown(container.dispose);

    // Real phone geometry inside the real tab shell: a bare pump gives this
    // map about a navigation bar's worth of height it never has, and this
    // file's subject is what the camera *fits*.
    await pumpInAppShell(
      tester,
      container: container,
      screen: const OfflineDataMapScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
    // Never `pumpAndSettle`: the basemap's tile requests never resolve under
    // test, so a settle loop would not terminate.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    return map.mapController!.camera;
  }

  testWidgets('with no fix it opens on the project extent, not the planet',
      (tester) async {
    final camera = await pumpScreen(
      tester,
      projects: Stream.value(
        _project(minLat: 35.0, minLon: -111.5, maxLat: 35.4, maxLon: -111.0),
      ),
    );

    printOnFailure('camera: ${camera.center} at zoom ${camera.zoom}');
    expect(camera.center.latitude, closeTo(35.2, 0.15));
    expect(camera.center.longitude, closeTo(-111.25, 0.15));
    expect(
      camera.zoom,
      greaterThan(MapCameraTarget.worldViewZoom),
      reason: 'the extent was fitted, so the camera is not at world zoom',
    );
  });

  testWidgets('a project that resolves after the first build still places it',
      (tester) async {
    // The real provider answers off a database, so the first build of this
    // screen sees `loading`. If the camera were only ever decided on that
    // first build, the extent step would never fire in the app — only in a
    // test that handed it a resolved value.
    final pending = Completer<Project?>();
    final container = ProviderContainer(
      overrides: [
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        currentProjectProvider.overrideWith((ref) => pending.future),
        offlineRegionsProvider.overrideWith(_FakeOfflineRegions.new),
        downloadManagerProvider.overrideWith(_NoDownloads.new),
      ],
    );
    addTearDown(container.dispose);

    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    await pumpInAppShell(
      tester,
      container: container,
      screen: const OfflineDataMapScreen(),
      tabIndex: 4,
    );
    await tester.pump();

    final before =
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;
    expect(
      before.center,
      MapCameraTarget.worldViewCenter,
      reason: 'while the project is loading the map claims nothing',
    );

    pending.complete(
      _project(minLat: 35.0, minLon: -111.5, maxLat: 35.4, maxLon: -111.0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final after =
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;
    printOnFailure('camera: ${after.center} at zoom ${after.zoom}');
    expect(after.center.latitude, closeTo(35.2, 0.15));
    expect(after.zoom, greaterThan(MapCameraTarget.worldViewZoom));
  });

  testWidgets('a device fix outranks the project extent', (tester) async {
    final camera = await pumpScreen(
      tester,
      projects: Stream.value(
        _project(minLat: 35.0, minLon: -111.5, maxLat: 35.4, maxLon: -111.0),
      ),
      fixes: Stream.value(_fix(44.5, -110.5)),
    );

    printOnFailure('camera: ${camera.center} at zoom ${camera.zoom}');
    expect(camera.center.latitude, closeTo(44.5, 0.01));
    expect(camera.center.longitude, closeTo(-110.5, 0.01));
  });

  testWidgets('no fix and no extent is still the honest whole-planet framing',
      (tester) async {
    final camera = await pumpScreen(tester, projects: Stream.value(_project()));

    printOnFailure('camera: ${camera.center} at zoom ${camera.zoom}');
    expect(camera.center, MapCameraTarget.worldViewCenter);
    expect(camera.zoom, MapCameraTarget.worldViewZoom);
  });

  testWidgets('no project at all is the whole-planet framing too',
      (tester) async {
    final camera = await pumpScreen(tester, projects: Stream.value(null));

    printOnFailure('camera: ${camera.center} at zoom ${camera.zoom}');
    expect(camera.center, MapCameraTarget.worldViewCenter);
    expect(camera.zoom, MapCameraTarget.worldViewZoom);
  });

  testWidgets('once the person has panned, a late project does not take it back',
      (tester) async {
    final pending = Completer<Project?>();
    final container = ProviderContainer(
      overrides: [
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        currentProjectProvider.overrideWith((ref) => pending.future),
        offlineRegionsProvider.overrideWith(_FakeOfflineRegions.new),
        downloadManagerProvider.overrideWith(_NoDownloads.new),
      ],
    );
    addTearDown(container.dispose);

    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    await pumpInAppShell(
      tester,
      container: container,
      screen: const OfflineDataMapScreen(),
      tabIndex: 4,
    );
    await tester.pump();

    // A drag on the map itself, which reports as a person-sourced event.
    await tester.drag(find.byType(FlutterMap), const Offset(-120, -80));
    await tester.pump();
    final panned =
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;

    pending.complete(
      _project(minLat: 35.0, minLon: -111.5, maxLat: 35.4, maxLon: -111.0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final after =
        tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;
    printOnFailure('panned to ${panned.center}, ended at ${after.center}');
    expect(
      after.center,
      panned.center,
      reason: 'a camera that jumps out from under a finger is worse than one '
          'that opened somewhere unhelpful',
    );
  });
}
