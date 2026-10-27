import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:tritrack/viewshed/dem_tile_fetcher.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/viewshed.dart';

/// **Task 11.142 item B — established rather than assumed.**
///
/// `/w-11` read `_ensureTerrainForRegion`, saw it `break` on a failed fetch
/// while the caller composed anyway, and flagged that a viewshed might be drawn
/// from part of the terrain and presented as complete. It said it had not
/// observed that happen. **It can happen, and the route to it is not the one
/// the code comment described.**
///
/// [DemTileFetcher.fetchTile] does not throw when its terrain requests fail —
/// by design, so one missing source tile does not fail a whole DEM tile. It
/// returns a grid of the right shape with the cells it could not fill left as
/// noData. So the `break` almost never runs; what ran instead was `saveTile`
/// writing an *empty* tile to disk, after which `hasTile` reported coverage
/// that is not there and the loop never tried that square again.
///
/// **Task 11.143 closed that at the store**, so two of these tests now watch a
/// refusal where they used to watch the defect. What they still establish is
/// 11.142's finding, which is untouched: a viewshed computed over terrain with
/// a hole in it reports itself `computed`, and only the coverage fraction says
/// otherwise.
///
/// The viewshed over the result reports `ViewshedStatus.computed`, and a ray
/// stops at a hole exactly as it stops at the edge of the world — so ground
/// nobody has any elevation for is drawn as *not visible*, which is the same
/// raster a mountain would produce.
Uint8List _terrariumPng(double elevation) {
  final value = (elevation + 32768).round();
  final image = img.Image(width: 256, height: 256);
  img.fill(image, color: img.ColorRgb8(value ~/ 256, value % 256, 0));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late Directory tempDir;
  late DemTileStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('partial_terrain_test_');
    store = DemTileStore(baseDirectory: tempDir);
  });
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // Two tiles side by side; the observer sits in the western one.
  final west = DemTileId(351, -1117);
  final east = DemTileId(351, -1116);
  final observer = LatLng(west.south + 0.05, west.west + 0.05);
  const config = ViewshedConfig(maxRangeMeters: 9000);

  final ok = MockClient(
    (_) async => http.Response.bytes(_terrariumPng(1200), 200),
  );
  final offline = MockClient((_) async => http.Response('no', 503));

  test('a total fetch failure arrives as an empty grid, not as a throw',
      () async {
    // The fact the `break` in `_ensureTerrainForRegion` was written for, and
    // which does not hold: nothing is thrown.
    final grid = await DemTileFetcher.fetchTile(east, client: offline);
    expect(grid.ncols, east.gridSpec().ncols);
    expect(grid.dataCoverageFraction, 0);
  });

  test('an empty tile is refused by the store, so it cannot become coverage',
      () async {
    final empty = await DemTileFetcher.fetchTile(east, client: offline);
    // **Task 11.143 closed this at the store.** When this test was written the
    // save succeeded and `hasTile` then said yes forever — a permanent hole
    // nothing ever retried — and only the map screen's own check kept it out.
    // Completeness is now recorded when a tile is written, and a tile with no
    // elevation in it has nothing to record.
    expect(() => store.saveTile(east, empty), throwsArgumentError);
    expect(await store.hasTile(east), isFalse);
  });

  test('a viewshed over part of the terrain reports itself computed, and its '
      'coverage fraction is what says otherwise', () async {
    await store.saveTile(west, await DemTileFetcher.fetchTile(west, client: ok));
    // East is never written — the fetch failed and, since task 11.143, an
    // empty tile is not storable. The composed window still spans both,
    // because the tiles east of the observer intersect the disc, and the half
    // with no tile behind it is the hole this test is about.

    final dem = await store.composeForRegion(
      center: observer,
      radiusMeters: config.maxRangeMeters,
    );
    expect(dem, isNotNull);
    final result = ViewshedComputer.compute(
      dem!,
      observer.latitude,
      observer.longitude,
      config: config,
    );

    // Indistinguishable from a complete answer by status alone — which is the
    // finding, and the reason the coverage fraction exists.
    expect(result.status, ViewshedStatus.computed);
    expect(result.hasResult, isTrue);

    expect(result.terrainIsIncomplete, isTrue);
    // Roughly a third of the composed window carried elevation when this was
    // measured. Asserted as a band rather than a number: the exact figure
    // depends on where the disc's bounding box falls across the two tiles, and
    // pinning it would make an unrelated geometry change look like a defect.
    expect(result.terrainCoverageFraction, greaterThan(0.1));
    expect(result.terrainCoverageFraction, lessThan(0.9));
  });

  test('complete terrain reports complete', () async {
    for (final id in [west, east, DemTileId(350, -1117), DemTileId(352, -1117),
      DemTileId(350, -1116), DemTileId(352, -1116), DemTileId(351, -1118),
      DemTileId(350, -1118), DemTileId(352, -1118)]) {
      await store.saveTile(id, await DemTileFetcher.fetchTile(id, client: ok));
    }
    final dem = await store.composeForRegion(
      center: observer,
      radiusMeters: config.maxRangeMeters,
    );
    final result = ViewshedComputer.compute(
      dem!,
      observer.latitude,
      observer.longitude,
      config: config,
    );
    expect(result.terrainCoverageFraction, 1.0);
    expect(result.terrainIsIncomplete, isFalse);
  });
}
