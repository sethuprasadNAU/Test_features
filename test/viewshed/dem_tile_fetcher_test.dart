import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:tritrack/viewshed/dem_tile_fetcher.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';

/// Builds a 256×256 terrarium PNG where every pixel encodes [elevation] m via
/// the terrarium formula `elevation = R*256 + G + B/256 - 32768`.
Uint8List _terrariumPng(double elevation) {
  final value = (elevation + 32768).round();
  final r = value ~/ 256;
  final g = value % 256;
  final image = img.Image(width: 256, height: 256);
  img.fill(image, color: img.ColorRgb8(r, g, 0));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late Directory tempDir;
  late DemTileStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dem_tile_fetcher_test_');
    store = DemTileStore(baseDirectory: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  final id = DemTileId(351, -1117);

  test('builds a canonical-spec grid from terrain tiles that saveTile accepts', () async {
    final client = MockClient((req) async => http.Response.bytes(_terrariumPng(1000), 200));

    final grid = await DemTileFetcher.fetchTile(id, client: client);
    final spec = id.gridSpec();
    expect(grid.ncols, spec.ncols);
    expect(grid.nrows, spec.nrows);
    expect(grid.xllCorner, closeTo(spec.xllCorner, 1e-9));
    expect(grid.yllCorner, closeTo(spec.yllCorner, 1e-9));

    // Every cell decoded to ~1000 m (allow ±1 m for the B-channel rounding).
    expect(grid.data.first, closeTo(1000, 1));
    expect(grid.data[grid.ncols * grid.nrows ~/ 2], closeTo(1000, 1));

    // saveTile throws ArgumentError on any spec mismatch — this must not throw.
    await store.saveTile(id, grid);
    expect(await store.hasTile(id), isTrue);
  });

  test('a missing terrain tile leaves noData gaps rather than failing the whole tile', () async {
    final client = MockClient((req) async => http.Response('not found', 404));

    final grid = await DemTileFetcher.fetchTile(id, client: client);
    final spec = id.gridSpec();
    expect(grid.ncols, spec.ncols);
    expect(grid.nrows, spec.nrows);
    // All cells are noData; rawAt returns null for them.
    expect(grid.rawAt(0, 0), isNull);
    expect(grid.rawAt(spec.nrows ~/ 2, spec.ncols ~/ 2), isNull);
    // A valid grid of the right shape — and, since task 11.143, one the store
    // will not write: a tile with nothing in it would read as coverage and
    // never be asked for again. The fetcher's job is still to hand back the
    // gap rather than throw; deciding what to keep is the store's.
    expect(() => store.saveTile(id, grid), throwsArgumentError);
    expect(await store.hasTile(id), isFalse);
  });

  test('stops early when cancelled', () async {
    var requests = 0;
    final client = MockClient((req) async {
      requests++;
      return http.Response.bytes(_terrariumPng(500), 200);
    });

    final grid = await DemTileFetcher.fetchTile(id, client: client, isCancelled: () => true);
    // Cancellation before any fetch → no requests, all noData.
    expect(requests, 0);
    expect(grid.rawAt(0, 0), isNull);
  });

  group('region fill (task 11.281)', () {
    // The exact DEM tile set `_ensureTerrainForRegion` computes for the
    // harness's seeded fixture (`seedLat` 42.7008, `seedLon` -117.3612) and
    // the app's fixed 35 km viewshed range — reproduced here rather than
    // imported so this test does not depend on `map_screen.dart`. Task
    // `/w-20` measured this exact region against the real bucket: 72 DEM
    // tiles, 380 terrarium-tile requests as coded, only 143 distinct.
    const seedLat = 42.7008;
    const seedLon = -117.3612;
    const radiusMeters = 35000.0;

    List<DemTileId> seededRegionTiles() {
      const metersPerDegLat = 111320.0;
      final dLat = radiusMeters / metersPerDegLat;
      final cosLat = math.cos(seedLat * math.pi / 180.0).abs();
      final dLon = radiusMeters / (metersPerDegLat * math.max(cosLat, 1e-6));
      return store.tilesIntersectingBounds(
        minLat: seedLat - dLat,
        minLon: seedLon - dLon,
        maxLat: seedLat + dLat,
        maxLon: seedLon + dLon,
      );
    }

    test('the seeded 35 km viewshed needs 72 DEM tiles', () {
      expect(seededRegionTiles().length, 72);
    });

    test(
      'filling the region issues 143 terrarium-tile requests, not 380, '
      'with a shared cache',
      () async {
        var requests = 0;
        final client = MockClient((req) async {
          requests++;
          return http.Response.bytes(_terrariumPng(1000), 200);
        });

        final tiles = seededRegionTiles();
        expect(tiles.length, 72);

        final cache = TerrainTileCache();
        for (final tileId in tiles) {
          await DemTileFetcher.fetchTile(tileId, client: client, cache: cache);
        }

        expect(requests, 143);
      },
    );

    test(
      'without a shared cache the same region issues 380 terrarium-tile '
      'requests',
      () async {
        var requests = 0;
        final client = MockClient((req) async {
          requests++;
          return http.Response.bytes(_terrariumPng(1000), 200);
        });

        final tiles = seededRegionTiles();
        for (final tileId in tiles) {
          await DemTileFetcher.fetchTile(tileId, client: client);
        }

        expect(requests, 380);
      },
    );
  });
}
