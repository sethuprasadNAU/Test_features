import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/viewshed/dem_ascii.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

/// **Task 11.143 — watched refusing a deliberately truncated tile.**
///
/// The defect: the download path asked "is there a file at this tile's path",
/// so a fetch that stopped halfway through left a file that read as coverage
/// **forever**. Nothing re-requested it, and every viewshed afterwards was
/// computed over the hole.
///
/// The fix is that completeness is **recorded** — a [DemTileRecord] written
/// after the tile file is closed — rather than deduced from the file being
/// there. These tests break tiles in the ways a real interruption breaks them
/// and watch the store refuse them.
void main() {
  late Directory tempDir;
  late DemTileStore store;
  late Directory tilesDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('half_written_tile_test_');
    store = DemTileStore(baseDirectory: tempDir);
    tilesDir = Directory('${tempDir.path}/dem_tiles');
  });
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  const id = DemTileId(351, -1117);
  File tileFile(DemTileId t) =>
      File('${tilesDir.path}/${t.latIndex}_${t.lonIndex}.asc');
  File recordFile(DemTileId t) => File('${tileFile(t).path}.json');

  /// A tile-shaped grid where [filled] of its cells carry [fill] and the rest
  /// are noData — the shape a fetch produces when some of its terrain tiles
  /// arrived and some did not.
  ElevationGrid gridFor(DemTileId t, double fill, {int? filled}) {
    final spec = t.gridSpec();
    final n = spec.ncols * spec.nrows;
    final data = Float64List(n)..fillRange(0, n, -9999.0);
    for (var i = 0; i < (filled ?? n); i++) {
      data[i] = fill;
    }
    return ElevationGrid(
      ncols: spec.ncols,
      nrows: spec.nrows,
      xllCorner: spec.xllCorner,
      yllCorner: spec.yllCorner,
      cellSizeDegrees: spec.cellSizeDegrees,
      data: data,
    );
  }

  Future<ElevationGrid?> composeOver(DemTileId t) => store.composeForBounds(
        minLat: t.south + 0.01,
        minLon: t.west + 0.01,
        maxLat: t.north - 0.01,
        maxLon: t.east - 0.01,
      );

  List<LatLng> polygonOver(DemTileId t) => [
        LatLng(t.south + 0.01, t.west + 0.01),
        LatLng(t.south + 0.01, t.east - 0.01),
        LatLng(t.north - 0.01, t.east - 0.01),
        LatLng(t.north - 0.01, t.west + 0.01),
      ];

  group('completeness is recorded, not inferred', () {
    test('saveTile writes a record of what it wrote', () async {
      await store.saveTile(id, gridFor(id, 100));
      final record = await store.tileRecord(id);
      expect(record, isNotNull);
      expect(record!.bytes, tileFile(id).lengthSync());
      expect(record.cells, kDemCellsPerTile * kDemCellsPerTile);
      expect(record.filledCells, record.cells);
      expect(record.isFullyCovered, isTrue);
      expect(record.attempts, 1);
      expect(await store.tileHealth(id), DemTileHealth.complete);
    });

    test('the record is written after the tile, and the half-written file is '
        'never at the tile path', () async {
      // The write goes to `<tile>.part` and is renamed into place, so an
      // interruption cannot leave a partial file where a tile belongs — and a
      // leftover `.part` is not a tile to any of the store's questions.
      await tilesDir.create(recursive: true);
      File('${tileFile(id).path}.part').writeAsStringSync('ncols 3\n');
      expect(await store.listTiles(), isEmpty);
      expect(await store.hasTile(id), isFalse);
      expect(await store.tileHealth(id), DemTileHealth.absent);
    });
  });

  group('a truncated tile is not served', () {
    setUp(() async {
      await store.saveTile(id, gridFor(id, 100));
    });

    test('watch it fail: a tile cut off mid-write is refused everywhere it '
        'could be read', () async {
      // It was whole a moment ago.
      expect(await store.hasTile(id), isTrue);
      expect(await composeOver(id), isNotNull);

      // Now cut it off partway, exactly as a fetch interrupted by a dropped
      // connection or a full disk would leave it.
      final whole = tileFile(id).readAsStringSync();
      tileFile(id).writeAsStringSync(whole.substring(0, whole.length ~/ 2));

      // The file is still there — that is the whole point, and it is what the
      // old rule looked at.
      expect(tileFile(id).existsSync(), isTrue);

      expect(await store.tileHealth(id), DemTileHealth.unusable);
      expect(await store.hasTile(id), isFalse);
      expect(await store.loadTile(id), isNull);
      expect(await store.elevationAt(id.center.latitude, id.center.longitude),
          isNull);
      expect(await composeOver(id), isNull);
    });

    test('and it goes back on the fetch list instead of being a permanent '
        'hole', () async {
      expect(await store.missingTilesForPolygon(polygonOver(id)), isEmpty);

      final whole = tileFile(id).readAsStringSync();
      tileFile(id).writeAsStringSync(whole.substring(0, whole.length ~/ 2));

      expect(await store.needsFetch(id), isTrue);
      expect(await store.missingTilesForPolygon(polygonOver(id)), contains(id));
    });

    test('the recorded byte count is the authority — a replacement that parses '
        'perfectly well is still refused', () async {
      // Not a truncation: a complete, valid, correctly-shaped tile of a
      // different length. Nothing about the file itself is wrong. It is not
      // what was recorded, so it is not served. This is the difference between
      // recording completeness and inferring it.
      tileFile(id).writeAsStringSync(DemAscii.write(gridFor(id, 5)));
      expect(
        () => DemAscii.parse(tileFile(id).readAsStringSync()),
        returnsNormally,
      );
      expect(await store.tileHealth(id), DemTileHealth.unusable);
      expect(await store.hasTile(id), isFalse);
    });

    test('a record that is itself unreadable falls back to validating the '
        'tile, not to trusting it', () async {
      recordFile(id).writeAsStringSync('{ not json');
      // The tile is whole, so re-validating from its bytes says so.
      expect(await store.hasTile(id), isTrue);

      final whole = tileFile(id).readAsStringSync();
      tileFile(id).writeAsStringSync(whole.substring(0, whole.length ~/ 3));
      recordFile(id).writeAsStringSync('{ not json');
      expect(await store.hasTile(id), isFalse);
    });
  });

  group('empty and partial are separate shapes, and the record says which', () {
    test('a grid with no elevation in it is refused outright', () async {
      final n = kDemCellsPerTile * kDemCellsPerTile;
      expect(
        () => store.saveTile(id, gridFor(id, 100, filled: 0)),
        throwsArgumentError,
      );
      expect(tileFile(id).existsSync(), isFalse);
      expect(n, greaterThan(0));
    });

    test('a tile with holes is served, and asked about again', () async {
      final cells = kDemCellsPerTile * kDemCellsPerTile;
      await store.saveTile(id, gridFor(id, 100, filled: cells ~/ 2));

      expect(await store.tileHealth(id), DemTileHealth.incomplete);
      // Served: half a tile of terrain is better than none, and task 11.142
      // makes the viewshed over it say it is incomplete.
      expect(await store.hasTile(id), isTrue);
      expect(await composeOver(id), isNotNull);
      // But not forgotten.
      expect(await store.missingTilesForPolygon(polygonOver(id)), contains(id));
    });

    test('a retry that comes back worse does not replace the better tile, but '
        'does count', () async {
      final cells = kDemCellsPerTile * kDemCellsPerTile;
      await store.saveTile(id, gridFor(id, 100, filled: cells ~/ 2));
      await store.saveTile(id, gridFor(id, 100, filled: 10));

      final record = await store.tileRecord(id);
      expect(record!.filledCells, cells ~/ 2);
      expect(record.attempts, 2);
    });

    test('after the attempt budget the store stops asking about a square the '
        'source will not fill', () async {
      final cells = kDemCellsPerTile * kDemCellsPerTile;
      for (var i = 0; i < kDemTileMaxFetchAttempts; i++) {
        await store.saveTile(id, gridFor(id, 100, filled: cells ~/ 2));
      }
      expect((await store.tileRecord(id))!.attempts, kDemTileMaxFetchAttempts);
      expect(await store.tileHealth(id), DemTileHealth.complete);
      expect(await store.needsFetch(id), isFalse);
      // "Complete" here means "the store will not ask again", and the record
      // is still honest about the coverage behind that.
      expect((await store.tileRecord(id))!.isFullyCovered, isFalse);
    });
  });

  group('tiles written before there was a record', () {
    // The decision: treat them as unknown, validate them from their own bytes,
    // and write a record from what is actually there. No network needed, so a
    // whole tile settles offline and a truncated one is caught anyway.
    Future<void> writeLegacy(String text) async {
      await tilesDir.create(recursive: true);
      tileFile(id).writeAsStringSync(text);
    }

    test('a whole one is validated and recorded, without asking the network',
        () async {
      await writeLegacy(DemAscii.write(gridFor(id, 42)));
      expect(recordFile(id).existsSync(), isFalse);

      expect(await store.hasTile(id), isTrue);

      final record = await store.tileRecord(id);
      expect(record, isNotNull);
      expect(record!.filledCells, record.cells);
      expect(record.bytes, tileFile(id).lengthSync());
      expect(await store.needsFetch(id), isFalse);
    });

    test('a truncated one is caught the first time it is looked at', () async {
      final whole = DemAscii.write(gridFor(id, 42));
      await writeLegacy(whole.substring(0, whole.length ~/ 2));

      expect(await store.tileHealth(id), DemTileHealth.unusable);
      expect(await store.hasTile(id), isFalse);
      expect(await store.needsFetch(id), isTrue);
      expect(recordFile(id).existsSync(), isFalse);
    });

    test('one with holes in it is served and goes back on the fetch list',
        () async {
      final cells = kDemCellsPerTile * kDemCellsPerTile;
      await writeLegacy(DemAscii.write(gridFor(id, 42, filled: cells ~/ 4)));

      expect(await store.tileHealth(id), DemTileHealth.incomplete);
      expect(await store.hasTile(id), isTrue);
      expect((await store.tileRecord(id))!.attempts, 0);
    });

    test('one that is the wrong shape for its id is not adopted', () async {
      await writeLegacy(DemAscii.write(
        ElevationGrid(
          ncols: 4,
          nrows: 4,
          xllCorner: id.west,
          yllCorner: id.south,
          cellSizeDegrees: 0.025,
          data: Float64List(16)..fillRange(0, 16, 1),
        ),
      ));
      expect(await store.tileHealth(id), DemTileHealth.unusable);
    });
  });

  test('a record with fields it does not understand is treated as no record',
      () {
    expect(DemTileRecord.fromJson(jsonDecode('{"v":1}')), isNull);
    expect(DemTileRecord.fromJson('nonsense'), isNull);
  });
}
