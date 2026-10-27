import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/features/map/services/offline_tile_downloader.dart';
import 'package:tritrack/features/map/services/tile_cache.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';

import '../../../support/fake_path_provider.dart';

void main() {
  setUp(installFakePathProvider);

  group('SlippyMap', () {
    test('the whole world at zoom 0 is exactly tile (0,0)', () {
      expect(SlippyMap.lonToTileX(-179.9, 0), 0);
      expect(SlippyMap.lonToTileX(179.9, 0), 0);
      expect(SlippyMap.latToTileY(80, 0), 0);
      expect(SlippyMap.latToTileY(-80, 0), 0);
    });

    test('longitude 0 sits on the boundary between the two halves at zoom 1', () {
      // Just west/east of the prime meridian land in different tiles.
      expect(SlippyMap.lonToTileX(-1, 1), 0);
      expect(SlippyMap.lonToTileX(1, 1), 1);
    });

    test('tile index never leaves [0, 2^z) even at the poles/antimeridian', () {
      const z = 10;
      final maxIndex = (1 << z) - 1;
      expect(SlippyMap.lonToTileX(-180, z), inInclusiveRange(0, maxIndex));
      expect(SlippyMap.lonToTileX(180, z), inInclusiveRange(0, maxIndex));
      expect(SlippyMap.latToTileY(89.9, z), inInclusiveRange(0, maxIndex));
      expect(SlippyMap.latToTileY(-89.9, z), inInclusiveRange(0, maxIndex));
    });

    test('tilesForBounds covers a small region with a small tile count at high zoom', () {
      // Flagstaff, AZ, a ~0.01deg (~1km) box.
      final tiles = SlippyMap.tilesForBounds(
        minLat: 35.19,
        minLon: -111.66,
        maxLat: 35.20,
        maxLon: -111.65,
        zoomLevels: [14],
      );
      expect(tiles, isNotEmpty);
      expect(tiles.length, lessThan(10));
      expect(tiles.every((t) => t.z == 14), isTrue);
    });

    test('more zoom levels means more tiles', () {
      const bounds = (minLat: 35.0, minLon: -112.0, maxLat: 35.1, maxLon: -111.9);
      final oneZoom = SlippyMap.tilesForBounds(
        minLat: bounds.minLat, minLon: bounds.minLon, maxLat: bounds.maxLat, maxLon: bounds.maxLon,
        zoomLevels: [12],
      );
      final twoZooms = SlippyMap.tilesForBounds(
        minLat: bounds.minLat, minLon: bounds.minLon, maxLat: bounds.maxLat, maxLon: bounds.maxLon,
        zoomLevels: [12, 13],
      );
      expect(twoZooms.length, greaterThan(oneZoom.length));
    });
  });

  test('estimateTileCount matches the actual enumeration', () {
    final estimate = OfflineTileDownloader.estimateTileCount(
      minLat: 35.19, minLon: -111.66, maxLat: 35.20, maxLon: -111.65,
      zoomLevels: [13, 14],
    );
    final actual = SlippyMap.tilesForBounds(
      minLat: 35.19, minLon: -111.66, maxLat: 35.20, maxLon: -111.65,
      zoomLevels: [13, 14],
    ).length;
    expect(estimate, actual);
  });

  test('estimateTileCount counts a planet-sized box without building it', () {
    // Task 11.103. This used to be `tilesForBounds(...).length`, which
    // allocates one object per tile to find out how many there are. The
    // Offline Data Map's "new selection" seeds a box covering 60% of what is
    // on screen, so somebody who has zoomed out to find themselves and then
    // taps it asked for a list of every tile on Earth at zooms 12–16 — and
    // the app stopped responding. Nothing about the number needed the list.
    //
    // A test that only asserted the value would have passed before the fix,
    // eventually. **This one is about the time**: the old implementation does
    // not finish this call in any bound worth writing down.
    final started = DateTime.now();
    final count = OfflineTileDownloader.estimateTileCount(
      minLat: -85,
      minLon: -180,
      maxLat: 85,
      maxLon: 180,
      zoomLevels: const [12, 13, 14, 15, 16],
    );
    final elapsed = DateTime.now().difference(started);

    expect(count, greaterThan(1000000000));
    expect(
      elapsed,
      lessThan(const Duration(seconds: 1)),
      reason: 'counting \$count tiles took \${elapsed.inMilliseconds}ms — it '
          'is arithmetic, one multiplication per zoom level. If this is slow '
          'again, something is enumerating the tiles to count them, and the '
          'Offline Data Map freezes on "new selection" at a wide zoom.',
    );
  });

  test('buildUrl substitutes z/x/y and picks a deterministic, repeatable subdomain', () {
    final url = TileCache.buildUrl(TileSources.openTopoMap, 5, 10, 15);
    expect(url, contains('/5/10/15.png'));
    expect(TileSources.openTopoMap.subdomains, contains(RegExp('[abc]').stringMatch(url)));
    // Same coordinates always resolve to the same subdomain (so a tile
    // fetched live and one pre-downloaded land in the same cache file).
    expect(TileCache.buildUrl(TileSources.openTopoMap, 5, 10, 15), url);
  });

  test('buildUrl leaves a no-subdomain source (Esri) untouched aside from z/x/y', () {
    final url = TileCache.buildUrl(TileSources.esriWorldImagery, 5, 10, 15);
    // Esri's template is z/y/x order, not z/x/y — substitution must respect
    // wherever the placeholders actually appear, not assume an order.
    expect(url, contains('/5/15/10'));
  });

  group('downloadTiles honest accounting', () {
    const tiles = [
      TileXY(5, 0, 0),
      TileXY(5, 0, 1),
      TileXY(5, 0, 2),
      TileXY(5, 0, 3),
    ];

    test('a mix of cached/downloaded/failed tallies correctly and is a partial (not full) success', () async {
      // Pre-seed one tile on disk so it counts as a cache hit, not a request.
      final cachedFile = await TileCache.tileFile(TileSources.openStreetMap.id, 5, 0, 0);
      await cachedFile.parent.create(recursive: true);
      await cachedFile.writeAsBytes([1, 2, 3]);

      final client = MockClient((request) async {
        // /5/0/1.png -> ok, /5/0/2.png -> 500, /5/0/3.png -> throws
        if (request.url.path.endsWith('/5/0/1.png')) {
          return http.Response.bytes([9, 9], 200);
        }
        if (request.url.path.endsWith('/5/0/2.png')) {
          return http.Response('server error', 500);
        }
        throw Exception('network blip');
      });

      final result = await OfflineTileDownloader.downloadTiles(
        tiles: tiles,
        source: TileSources.openStreetMap,
        client: client,
      );

      expect(result.total, 4);
      expect(result.completed, 2); // 1 cached + 1 downloaded
      expect(result.failed, 2); // 500 + thrown exception
      expect(result.isFullSuccess, isFalse);

      expect(await cachedFile.exists(), isTrue);
      final downloaded = await TileCache.tileFile(TileSources.openStreetMap.id, 5, 0, 1);
      expect(await downloaded.exists(), isTrue);
      final failed500 = await TileCache.tileFile(TileSources.openStreetMap.id, 5, 0, 2);
      expect(await failed500.exists(), isFalse);
    });

    test('all tiles succeeding (cached or downloaded) is a full success', () async {
      final client = MockClient((request) async => http.Response.bytes([1], 200));
      final result = await OfflineTileDownloader.downloadTiles(
        tiles: tiles,
        source: TileSources.openTopoMap,
        client: client,
      );
      expect(result.failed, 0);
      expect(result.completed, 4);
      expect(result.isFullSuccess, isTrue);
    });

    test('every tile failing yields zero completed and no full success', () async {
      final client = MockClient((request) async => http.Response('nope', 500));
      final result = await OfflineTileDownloader.downloadTiles(
        tiles: tiles,
        source: TileSources.esriWorldImagery,
        client: client,
      );
      expect(result.completed, 0);
      expect(result.failed, 4);
      expect(result.isFullSuccess, isFalse);
    });

    test('isCancelled stops early without counting the remaining tiles as failed', () async {
      final client = MockClient((request) async => http.Response.bytes([1], 200));
      final result = await OfflineTileDownloader.downloadTiles(
        tiles: tiles,
        source: TileSources.openStreetMap,
        client: client,
        isCancelled: () => true,
      );
      expect(result.total, 4);
      expect(result.completed, 0);
      expect(result.failed, 0);
    });
  });
}
