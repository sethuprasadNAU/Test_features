import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/download_manager.dart';
import 'package:tritrack/features/map/services/geo_polygon.dart';
import 'package:tritrack/features/map/services/offline_region_store.dart';
import 'package:tritrack/features/map/services/tile_cache.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

import '../../../support/fake_path_provider.dart';

void main() {
  setUp(installFakePathProvider);

  final poly = [
    const LatLng(35.10, -111.70),
    const LatLng(35.10, -111.60),
    const LatLng(35.20, -111.60),
    const LatLng(35.20, -111.70),
  ];

  ProviderContainer makeContainer() => ProviderContainer();

  // Polls until [predicate] is true or a generous real-time budget elapses.
  // The manager's queue does genuine `dart:io` file I/O (even against a temp
  // dir), so draining bare microtasks isn't enough — this advances real time
  // in small steps so pending I/O actually completes between checks.
  Future<void> pollUntil(bool Function() predicate) async {
    for (var i = 0; i < 500; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('cancel() on a still-queued job marks it cancelled and it never runs', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadManagerProvider.notifier);

    // A job whose tiles are all already cached completes essentially
    // synchronously with no network, so it occupies the "currently running"
    // slot just long enough for a second job to sit `queued` behind it.
    final zoomLevels = [12];
    for (final t in GeoPolygon.tilesInPolygon(polygon: poly, zoomLevels: zoomLevels)) {
      final f = await TileCache.tileFile(TileSources.openStreetMap.id, t.z, t.x, t.y);
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1]);
    }

    notifier.enqueueTiles(
      polygon: poly,
      sourceId: TileSources.openStreetMap.id,
      minZoom: 12,
      maxZoom: 12,
      id: 'job-a',
    );
    final secondId = notifier.enqueueTiles(
      polygon: poly,
      sourceId: TileSources.openStreetMap.id,
      minZoom: 12,
      maxZoom: 12,
      id: 'job-b',
    );
    notifier.cancel(secondId);

    final jobB = container.read(downloadManagerProvider).firstWhere((j) => j.id == secondId);
    expect(jobB.status, DownloadJobStatus.cancelled);

    // Let job A actually finish so its manifest write doesn't leak into the
    // next test as dangling async work after teardown.
    await pollUntil(() =>
        container.read(downloadManagerProvider).firstWhere((j) => j.id == 'job-a').isTerminal);
  });

  test('a fully-cached tiles job completes and writes a complete manifest entry after reconcile', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadManagerProvider.notifier);

    final zoomLevels = [12];
    for (final t in GeoPolygon.tilesInPolygon(polygon: poly, zoomLevels: zoomLevels)) {
      final f = await TileCache.tileFile(TileSources.openStreetMap.id, t.z, t.x, t.y);
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1]);
    }

    final jobId = notifier.enqueueTiles(
      polygon: poly,
      sourceId: TileSources.openStreetMap.id,
      minZoom: 12,
      maxZoom: 12,
      id: 'tiles-complete',
    );

    await pollUntil(() =>
        container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId).isTerminal);

    final job = container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId);
    expect(job.status, DownloadJobStatus.complete);
    expect(job.failed, 0);

    final regions = await OfflineRegionStore().loadAll();
    final region = regions.firstWhere((r) => r.id == jobId);
    expect(region.status, OfflineRegionStatus.complete);
    expect(region.tileCompleted, region.tileTotal);
  });

  test('a DEM job with no missing tiles completes instantly with total 0', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadManagerProvider.notifier);

    // Pre-seed every DEM tile the polygon needs so missingTilesForPolygon is
    // empty and the job never touches the network.
    final demStore = DemTileStore();
    for (final id in demStore.tilesIntersectingPolygon(poly)) {
      final spec = id.gridSpec();
      final n = spec.ncols * spec.nrows;
      await demStore.saveTile(
        id,
        ElevationGrid(
          ncols: spec.ncols,
          nrows: spec.nrows,
          xllCorner: spec.xllCorner,
          yllCorner: spec.yllCorner,
          cellSizeDegrees: spec.cellSizeDegrees,
          data: Float64List(n)..fillRange(0, n, 500.0),
        ),
      );
    }

    final jobId = notifier.enqueueDem(polygon: poly, id: 'dem-complete');

    await pollUntil(() =>
        container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId).isTerminal);

    final job = container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId);
    expect(job.status, DownloadJobStatus.complete);
    expect(job.total, 0);
    expect(job.failed, 0);
  });

  test('backgrounding the app while a job is running pauses it, and resuming re-queues it', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(downloadManagerProvider.notifier);

    // A client that never responds until the test lets it, so the job is
    // guaranteed to still be "running" when the lifecycle event fires.
    var releaseGate = false;
    final client = MockClient((request) async {
      while (!releaseGate) {
        await Future<void>.delayed(Duration.zero);
      }
      return http.Response.bytes([1], 200);
    });
    notifier.debugConfigureForTesting(httpClient: client);

    final jobId = notifier.enqueueTiles(
      polygon: poly,
      sourceId: TileSources.openStreetMap.id,
      minZoom: 12,
      maxZoom: 12,
      id: 'tiles-pausable',
    );

    // Let the job actually reach `running` (past the cache-miss/HTTP-call
    // dispatch) before backgrounding.
    await pollUntil(() =>
        container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId).status ==
        DownloadJobStatus.running);
    var job = container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId);
    expect(job.status, DownloadJobStatus.running);

    notifier.didChangeAppLifecycleState(AppLifecycleState.paused);
    releaseGate = true; // let any in-flight requests resolve so the loop can observe the pause
    await pollUntil(() =>
        container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId).status ==
        DownloadJobStatus.paused);
    job = container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId);
    expect(job.status, DownloadJobStatus.paused);

    notifier.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pollUntil(() =>
        container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId).isTerminal);
    job = container.read(downloadManagerProvider).firstWhere((j) => j.id == jobId);
    expect(job.status, DownloadJobStatus.complete);
  });
}
