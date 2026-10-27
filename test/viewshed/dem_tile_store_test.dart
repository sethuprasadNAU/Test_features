import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/services/geo_polygon.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

void main() {
  late Directory tempDir;
  late DemTileStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dem_tile_store_test_');
    store = DemTileStore(baseDirectory: tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ElevationGrid gridFor(DemTileId id, double fill) {
    final spec = id.gridSpec();
    final n = spec.ncols * spec.nrows;
    return ElevationGrid(
      ncols: spec.ncols,
      nrows: spec.nrows,
      xllCorner: spec.xllCorner,
      yllCorner: spec.yllCorner,
      cellSizeDegrees: spec.cellSizeDegrees,
      data: Float64List(n)..fillRange(0, n, fill),
    );
  }

  group('DemTileId indexing', () {
    test('forLatLon floors to the 0.1 grid', () {
      final id = DemTileId.forLatLon(35.19, -111.62);
      expect(id.latIndex, 351);
      expect(id.lonIndex, -1117);
      expect(id.south, closeTo(35.1, 1e-9));
      expect(id.north, closeTo(35.2, 1e-9));
      expect(id.west, closeTo(-111.7, 1e-9));
      expect(id.east, closeTo(-111.6, 1e-9));
    });

    test('center is the tile midpoint', () {
      final c = const DemTileId(0, 0).center;
      expect(c.latitude, closeTo(0.05, 1e-9));
      expect(c.longitude, closeTo(0.05, 1e-9));
    });
  });

  group('gridSpec alignment', () {
    test('cells exactly fill a 0.1 tile and match the global lattice', () {
      final spec = const DemTileId(3, 4).gridSpec();
      expect(spec.ncols, kDemCellsPerTile);
      expect(spec.nrows, kDemCellsPerTile);
      expect(spec.ncols * spec.cellSizeDegrees, closeTo(0.1, 1e-12));
      expect(spec.xllCorner, closeTo(0.4, 1e-12));
      expect(spec.yllCorner, closeTo(0.3, 1e-12));
      // Cell size is ~90 m but snapped so it divides 0.1 exactly.
      expect(spec.cellSizeDegrees, closeTo(0.1 / kDemCellsPerTile, 1e-15));
    });

    test('saveTile rejects a grid that does not match the spec', () async {
      final bad = ElevationGrid(
        ncols: 2,
        nrows: 2,
        xllCorner: 0,
        yllCorner: 0,
        cellSizeDegrees: 0.01,
        data: Float64List.fromList([1, 2, 3, 4]),
      );
      expect(
        () => store.saveTile(const DemTileId(0, 0), bad),
        throwsArgumentError,
      );
    });
  });

  group('compose', () {
    test('merges two adjacent tiles into a seamless grid', () async {
      await store.saveTile(const DemTileId(0, 0), gridFor(const DemTileId(0, 0), 100));
      await store.saveTile(const DemTileId(0, 1), gridFor(const DemTileId(0, 1), 200));

      final merged = await store.composeForBounds(
        minLat: 0.01,
        minLon: 0.01,
        maxLat: 0.09,
        maxLon: 0.19,
      );
      expect(merged, isNotNull);
      expect(merged!.ncols, kDemCellsPerTile * 2);
      expect(merged.nrows, kDemCellsPerTile);
      expect(merged.xllCorner, closeTo(0.0, 1e-12));

      // Left half comes from tile (0,0)=100, right half from (0,1)=200.
      expect(merged.data[0], 100);
      expect(merged.data[kDemCellsPerTile - 1], 100);
      expect(merged.data[kDemCellsPerTile], 200);
      expect(merged.data[merged.ncols - 1], 200);
      // No gaps.
      expect(merged.data.every((v) => v != merged.noDataValue), isTrue);
    });

    test('leaves noData where an intersecting tile is missing', () async {
      await store.saveTile(const DemTileId(0, 0), gridFor(const DemTileId(0, 0), 100));

      final merged = await store.composeForBounds(
        minLat: 0.01,
        minLon: 0.01,
        maxLat: 0.09,
        maxLon: 0.19,
      );
      expect(merged, isNotNull);
      expect(merged!.ncols, kDemCellsPerTile * 2);
      // Left half present, right half (missing tile) is noData.
      expect(merged.data[0], 100);
      expect(merged.data[kDemCellsPerTile], merged.noDataValue);
    });

    test('returns null when no tile is on disk for the bounds', () async {
      final merged = await store.composeForBounds(
        minLat: 40.0,
        minLon: 10.0,
        maxLat: 40.05,
        maxLon: 10.05,
      );
      expect(merged, isNull);
    });
  });

  group('deleteTilesInPolygon', () {
    test('deletes tiles the polygon does not reach at all', () async {
      await store.saveTile(const DemTileId(0, 0), gridFor(const DemTileId(0, 0), 1));
      await store.saveTile(const DemTileId(0, 1), gridFor(const DemTileId(0, 1), 1));
      await store.saveTile(const DemTileId(1, 0), gridFor(const DemTileId(1, 0), 1));

      // Square fully inside tile (0,0), nowhere near the other two.
      final poly = [
        const LatLng(0.01, 0.01),
        const LatLng(0.01, 0.09),
        const LatLng(0.09, 0.09),
        const LatLng(0.09, 0.01),
      ];
      final deleted = await store.deleteTilesInPolygon(poly);
      expect(deleted, 1);

      final remaining = (await store.listTiles()).toSet();
      expect(remaining.contains(const DemTileId(0, 0)), isFalse);
      expect(remaining.contains(const DemTileId(0, 1)), isTrue);
      expect(remaining.contains(const DemTileId(1, 0)), isTrue);
    });

    test(
        'erasing an area\'s exact outline removes every tile it was '
        'credited with (task 11.231)', () async {
      // This polygon is the shape of the mismatch: `tilesIntersectingPolygon`
      // — what elevation coverage credits an area with, and what the
      // download fetches — counts tile (0,1) here because one of the
      // polygon's own vertices falls inside that tile's 0.1° square, even
      // though the tile's *center*, (0.05, 0.15), is outside the drawn
      // shape entirely. Before this task, `deleteTilesInPolygon` used the
      // center rule and left tile (0,1) on disk, so erasing an elevation
      // area's own exact outline read the area as Partial rather than
      // gone. Watched failing against that center rule.
      final poly = [
        const LatLng(0.02, 0.05),
        const LatLng(0.02, 0.12),
        const LatLng(0.08, 0.12),
        const LatLng(0.08, 0.05),
      ];
      final credited = store.tilesIntersectingPolygon(poly).toSet();
      expect(credited, contains(const DemTileId(0, 1)),
          reason: 'fixture must reproduce the touch-vs-center mismatch');
      expect(GeoPolygon.pointInPolygon(const DemTileId(0, 1).center, poly),
          isFalse,
          reason: 'and it must reproduce it via a touch, not a center hit');

      for (final id in credited) {
        await store.saveTile(id, gridFor(id, 1));
      }
      final deleted = await store.deleteTilesInPolygon(poly);
      expect(deleted, credited.length);

      final remaining = (await store.listTiles()).toSet();
      for (final id in credited) {
        expect(remaining.contains(id), isFalse,
            reason: '$id was credited to this area and must be gone');
      }
    });
  });

  group('missing / size / deleteAll', () {
    test('missingTilesForPolygon excludes tiles already on disk', () async {
      final poly = [
        const LatLng(0.01, 0.01),
        const LatLng(0.01, 0.09),
        const LatLng(0.09, 0.09),
        const LatLng(0.09, 0.01),
      ];
      final id = const DemTileId(0, 0);
      expect(await store.missingTilesForPolygon(poly), contains(id));
      await store.saveTile(id, gridFor(id, 5));
      expect(await store.missingTilesForPolygon(poly), isNot(contains(id)));
    });

    test('sizeBytes and deleteAll', () async {
      await store.saveTile(const DemTileId(0, 0), gridFor(const DemTileId(0, 0), 1));
      expect(await store.sizeBytes(), greaterThan(0));
      await store.deleteAll();
      expect(await store.sizeBytes(), 0);
      expect(await store.listTiles(), isEmpty);
    });
  });

  group('unprotectedSizeBytes', () {
    test('excludes protected tiles and sums the rest', () async {
      const a = DemTileId(0, 0);
      const b = DemTileId(0, 1);
      const c = DemTileId(1, 0);
      await store.saveTile(a, gridFor(a, 1));
      await store.saveTile(b, gridFor(b, 2));
      await store.saveTile(c, gridFor(c, 3));

      final expected =
          await store.tileSizeBytes(b) + await store.tileSizeBytes(c);
      final total = await store.unprotectedSizeBytes({a});
      expect(total, expected);
      expect(total, isNot(0));
    });

    test('zero when everything is protected', () async {
      const a = DemTileId(0, 0);
      await store.saveTile(a, gridFor(a, 1));
      expect(await store.unprotectedSizeBytes({a}), 0);
    });
  });

  group('enforceCacheLimit', () {
    test('maxBytes above total evicts nothing', () async {
      const a = DemTileId(0, 0);
      const b = DemTileId(0, 1);
      await store.saveTile(a, gridFor(a, 1));
      await store.saveTile(b, gridFor(b, 2));

      final total = await store.unprotectedSizeBytes({});
      final evicted = await store.enforceCacheLimit(
        maxBytes: total + 1000,
        protectedIds: {},
      );
      expect(evicted, 0);
      final remaining = (await store.listTiles()).toSet();
      expect(remaining, {a, b});
    });

    test('evicts oldest-modified tiles first until under the limit', () async {
      const oldest = DemTileId(0, 0);
      const middle = DemTileId(0, 1);
      const newest = DemTileId(0, 2);
      await store.saveTile(oldest, gridFor(oldest, 1));
      await store.saveTile(middle, gridFor(middle, 1));
      await store.saveTile(newest, gridFor(newest, 1));

      final base = DateTime(2020, 1, 1);
      Future<void> setMtime(DemTileId id, DateTime t) async {
        final file = File(
          '${tempDir.path}/dem_tiles/${id.latIndex}_${id.lonIndex}.asc',
        );
        await file.setLastModified(t);
      }

      await setMtime(oldest, base);
      await setMtime(middle, base.add(const Duration(days: 1)));
      await setMtime(newest, base.add(const Duration(days: 2)));

      final oneTileSize = await store.tileSizeBytes(newest);
      // Only room for one tile: the newest must survive, the other two evicted.
      final evicted = await store.enforceCacheLimit(
        maxBytes: oneTileSize,
        protectedIds: {},
      );
      expect(evicted, 2);

      final remaining = (await store.listTiles()).toSet();
      expect(remaining, {newest});
    });

    test('never evicts protected tiles even if they exceed maxBytes', () async {
      const protectedTile = DemTileId(0, 0);
      const other = DemTileId(0, 1);
      await store.saveTile(protectedTile, gridFor(protectedTile, 1));
      await store.saveTile(other, gridFor(other, 1));

      await File(
        '${tempDir.path}/dem_tiles/${protectedTile.latIndex}_${protectedTile.lonIndex}.asc',
      ).setLastModified(DateTime(2000, 1, 1));
      await File(
        '${tempDir.path}/dem_tiles/${other.latIndex}_${other.lonIndex}.asc',
      ).setLastModified(DateTime(2030, 1, 1));

      // maxBytes of 0 would normally evict everything, but the protected tile
      // is excluded from the accounting entirely and must survive.
      final evicted = await store.enforceCacheLimit(
        maxBytes: 0,
        protectedIds: {protectedTile},
      );
      expect(evicted, 1);

      final remaining = (await store.listTiles()).toSet();
      expect(remaining, {protectedTile});
    });

    test('touchTiles bumps mtime so a stale tile survives eviction', () async {
      const a = DemTileId(0, 0);
      const b = DemTileId(0, 1);
      await store.saveTile(a, gridFor(a, 1));
      await store.saveTile(b, gridFor(b, 1));

      // a is oldest, so it would normally be evicted first.
      await File('${tempDir.path}/dem_tiles/0_0.asc')
          .setLastModified(DateTime(2000, 1, 1));
      await File('${tempDir.path}/dem_tiles/0_1.asc')
          .setLastModified(DateTime(2010, 1, 1));

      // Touch a to make it the most recently modified.
      await store.touchTiles([a]);

      final oneTileSize = await store.tileSizeBytes(a);
      final evicted = await store.enforceCacheLimit(
        maxBytes: oneTileSize,
        protectedIds: {},
      );
      expect(evicted, 1);

      final remaining = (await store.listTiles()).toSet();
      expect(remaining, {a});
    });

    test('touchTiles ignores ids with no on-disk file', () async {
      // Should complete without throwing even though nothing exists yet.
      await store.touchTiles([const DemTileId(9, 9)]);
      expect(await store.listTiles(), isEmpty);
    });
  });
}
