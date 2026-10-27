import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../features/map/services/geo_polygon.dart';
import 'dem_ascii.dart';
import 'elevation_grid.dart';

/// The single, fixed DEM resolution for the whole app. There is no longer a
/// resolution slider: every DEM tile is generated and merged at this cell
/// size, so tiles always share a grid and compose without resampling.
const double kDemCellSizeMeters = 90.0;

/// Meters per degree of latitude (WGS84 mean); the same constant used across
/// the viewshed/localization code to convert the fixed metric resolution to
/// the degree-based grid the ASCII-Grid format stores.
const double kMetersPerDegreeLatitude = 111320.0;

/// Side length of a DEM tile, in degrees. Tiles snap to this global lattice:
/// a tile's SW corner is always an integer multiple of this value.
const double kDemTileSizeDegrees = 0.1;

/// Number of grid cells along each edge of a DEM tile.
///
/// Grid-alignment scheme (this is the load-bearing decision):
/// - Tiles are 0.1° squares snapped to a global lattice (SW corner at a
///   multiple of 0.1°).
/// - We want cells of ~[kDemCellSizeMeters]. Rather than use the raw metric
///   cell size (which does not divide 0.1° evenly and would leave tile edges
///   mid-cell), we pick the nearest whole number of cells per tile edge and
///   derive the cell size from THAT: `cellSize = 0.1° / cellsPerTile`.
/// - Because every tile is exactly `cellsPerTile` cells wide/tall and every
///   tile corner is a multiple of 0.1°, the per-tile grids of all tiles are
///   sub-grids of one global lattice with origin at (lon 0, lat 0) and step
///   [kDemCellSizeDegrees]. Adjacent tiles therefore line up cell-for-cell
///   and [DemTileStore.composeForBounds] can concatenate them by pure block
///   placement — no interpolation, no seams.
final int kDemCellsPerTile =
    (kDemTileSizeDegrees / (kDemCellSizeMeters / kMetersPerDegreeLatitude)).round();

/// Canonical cell size in degrees, derived so an integer number of cells
/// exactly fills a 0.1° tile. Slightly different from the raw metric value
/// (~89.8 m vs 90 m) — that is intentional and keeps the grid seamless.
final double kDemCellSizeDegrees = kDemTileSizeDegrees / kDemCellsPerTile;

/// Canonical grid specification a DEM tile must be generated to, so the
/// fetcher (Phase B) and this store agree cell-for-cell.
class DemGridSpec {
  const DemGridSpec({
    required this.xllCorner,
    required this.yllCorner,
    required this.ncols,
    required this.nrows,
    required this.cellSizeDegrees,
  });

  final double xllCorner;
  final double yllCorner;
  final int ncols;
  final int nrows;
  final double cellSizeDegrees;
}

/// Integer grid index of a fixed 0.1° DEM tile:
/// `latIndex = floor(lat / 0.1)`, `lonIndex = floor(lon / 0.1)`.
class DemTileId {
  const DemTileId(this.latIndex, this.lonIndex);

  /// The tile that contains ([lat],[lon]).
  factory DemTileId.forLatLon(double lat, double lon) => DemTileId(
        (lat / kDemTileSizeDegrees).floor(),
        (lon / kDemTileSizeDegrees).floor(),
      );

  final int latIndex;
  final int lonIndex;

  double get south => latIndex * kDemTileSizeDegrees;
  double get west => lonIndex * kDemTileSizeDegrees;
  double get north => south + kDemTileSizeDegrees;
  double get east => west + kDemTileSizeDegrees;

  LatLng get center =>
      LatLng(south + kDemTileSizeDegrees / 2, west + kDemTileSizeDegrees / 2);

  /// The exact grid every tile with this id must use.
  DemGridSpec gridSpec() => DemGridSpec(
        xllCorner: west,
        yllCorner: south,
        ncols: kDemCellsPerTile,
        nrows: kDemCellsPerTile,
        cellSizeDegrees: kDemCellSizeDegrees,
      );

  @override
  bool operator ==(Object other) =>
      other is DemTileId &&
      other.latIndex == latIndex &&
      other.lonIndex == lonIndex;

  @override
  int get hashCode => Object.hash(latIndex, lonIndex);

  @override
  String toString() => 'DemTileId($latIndex, $lonIndex)';
}

/// How many times the store will re-fetch a tile that arrived with holes in
/// it before it stops asking.
///
/// A tile can be short of elevation for two different reasons and the store
/// cannot tell them apart: the network blipped (asking again fixes it), or the
/// source has no data for that square (asking again never will). Retrying
/// forever would re-download the same holes on every viewshed; retrying never
/// is the defect task 11.143 exists to close. Three attempts is the compromise,
/// and it is a recorded count rather than a clock so the behaviour does not
/// depend on when the person happens to open the app.
const int kDemTileMaxFetchAttempts = 3;

/// **What the store has recorded about one tile file.** Written only after the
/// tile file has been closed and renamed into place, and it — never the file's
/// existence — is what says whether that tile is here.
///
/// Task 11.143. Before this record, "a file exists at this path" meant "this
/// tile is downloaded", so a fetch interrupted halfway through left a file the
/// store trusted forever and never asked for again.
///
/// [bytes] is the exact length of the tile file as it was written. A file whose
/// current length differs from it was not finished, and is refused.
///
/// **What this covers and what it does not.** A *truncated* tile is caught by
/// [bytes]. An *empty* tile — every cell noData, which is what a wholly failed
/// fetch produces — is caught by [filledCells], which is zero. A *partial* tile
/// is caught by [filledCells] being short of [cells], which leaves it usable
/// but on the fetch list. **A tile corrupted in place without changing its
/// length is not caught by this record**; most such damage still fails
/// [DemAscii.parse], because the format is numeric text and a damaged token
/// stops it, but a digit changed to another digit is not detectable without a
/// checksum and this record deliberately does not carry one — hashing every
/// tile on the compose path is a cost paid on every viewshed against a failure
/// nobody has seen.
class DemTileRecord {
  const DemTileRecord({
    required this.bytes,
    required this.cells,
    required this.filledCells,
    required this.attempts,
  });

  /// Length of the tile file, in bytes, at the moment it was written.
  final int bytes;

  /// Cells in the tile's grid (`ncols * nrows`).
  final int cells;

  /// Cells that carry an elevation rather than noData.
  final int filledCells;

  /// How many times a fetch has been persisted for this tile.
  final int attempts;

  /// Fraction of the tile that carries elevation, 0 to 1.
  double get coverage => cells == 0 ? 0 : filledCells / cells;

  /// Whether every cell carries an elevation.
  bool get isFullyCovered => cells > 0 && filledCells >= cells;

  Map<String, Object?> toJson() => {
        'v': 1,
        'bytes': bytes,
        'cells': cells,
        'filled': filledCells,
        'attempts': attempts,
      };

  /// Parses a record, or null if [json] is not one this version understands.
  /// A record that cannot be read is not an error: the tile is then treated
  /// exactly like a tile that never had one.
  static DemTileRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final bytes = json['bytes'];
    final cells = json['cells'];
    final filled = json['filled'];
    final attempts = json['attempts'];
    if (bytes is! int || cells is! int || filled is! int || attempts is! int) {
      return null;
    }
    return DemTileRecord(
      bytes: bytes,
      cells: cells,
      filledCells: filled,
      attempts: attempts,
    );
  }
}

/// What the store knows about a tile, from its recorded completeness rather
/// than from the file being there.
enum DemTileHealth {
  /// No file for this tile.
  absent,

  /// A file is there and must not be served: it is not the length that was
  /// recorded for it (an interrupted write), it will not parse, or it carries
  /// no elevation at all.
  unusable,

  /// Usable, but short of elevation and worth asking the source about again.
  incomplete,

  /// Usable and the store will not ask again — either every cell is filled,
  /// or it has been fetched [kDemTileMaxFetchAttempts] times and this is the
  /// best the source has given. [DemTileStore.tileRecord]'s coverage says
  /// which.
  complete;

  /// Whether a tile in this state may be read and composed into a DEM.
  bool get isUsable => this == incomplete || this == complete;

  /// Whether the download path should try this tile again.
  bool get needsFetch => this != complete;
}

/// A tiled, accumulating DEM store. Replaces the single-file-per-project
/// [DemRepository] model: elevation is downloaded once per geographic tile and
/// reused across projects. Tiles live at
/// `<base>/dem_tiles/<latIndex>_<lonIndex>.asc` and all share the global grid
/// defined by [kDemCellSizeDegrees], so [composeForBounds] merges them into a
/// single seamless [ElevationGrid].
///
/// [baseDirectory] can be injected for tests; it defaults to the real
/// application-support directory.
class DemTileStore {
  DemTileStore({this.baseDirectory});

  /// Root under which the `dem_tiles/` directory lives. Injected in tests;
  /// defaults to the application-support directory when null.
  final Directory? baseDirectory;

  static const double _noData = -9999.0;
  static final RegExp _fileName = RegExp(r'^(-?\d+)_(-?\d+)\.asc$');

  Future<Directory> _root() async {
    final base = baseDirectory ??
        Directory((await getApplicationSupportDirectory()).path);
    return Directory('${base.path}/dem_tiles');
  }

  Future<File> _fileFor(DemTileId id) async {
    final root = await _root();
    return File('${root.path}/${id.latIndex}_${id.lonIndex}.asc');
  }

  /// The completeness record beside tile [id]'s file. Named so
  /// [listTiles]'s pattern cannot mistake it for a tile.
  Future<File> _recordFileFor(DemTileId id) async {
    final root = await _root();
    return File('${root.path}/${id.latIndex}_${id.lonIndex}.asc.json');
  }

  /// DEM tile files currently on disk, whether or not they are usable — this
  /// is the housekeeping view (size, eviction, counting), not the coverage
  /// question. Ask [hasTile] or [tileHealth] about a tile you mean to read.
  Future<List<DemTileId>> listTiles() async {
    final root = await _root();
    if (!await root.exists()) return const [];
    final ids = <DemTileId>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final m = _fileName.firstMatch(name);
      if (m != null) {
        ids.add(DemTileId(int.parse(m.group(1)!), int.parse(m.group(2)!)));
      }
    }
    return ids;
  }

  /// **Whether tile [id] is here and may be served.** Not "a file exists at
  /// its path" — that is the question task 11.143 stopped asking, because a
  /// fetch interrupted halfway through answers it yes forever.
  Future<bool> hasTile(DemTileId id) async => (await tileHealth(id)).isUsable;

  /// Whether the download path should fetch tile [id] — it is missing,
  /// unusable, or short of elevation and not yet out of attempts.
  Future<bool> needsFetch(DemTileId id) async =>
      (await tileHealth(id)).needsFetch;

  /// The recorded completeness of tile [id], or null if there is no record —
  /// either no tile, or one written before this store recorded anything (see
  /// [tileHealth], which backfills).
  Future<DemTileRecord?> tileRecord(DemTileId id) async {
    final file = await _recordFileFor(id);
    if (!await file.exists()) return null;
    try {
      return DemTileRecord.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      // An unreadable record is the same as no record: the tile gets
      // re-validated from its own bytes below.
      return null;
    }
  }

  Future<void> _writeRecord(DemTileId id, DemTileRecord record) async {
    final file = await _recordFileFor(id);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(record.toJson()));
  }

  Future<void> _deleteRecord(DemTileId id) async {
    final file = await _recordFileFor(id);
    if (await file.exists()) await file.delete();
  }

  /// **What the store knows about tile [id], read from what was recorded when
  /// it was written.**
  ///
  /// A tile written before this record existed — every tile already on a
  /// device when task 11.143 shipped — has no record, and **the decision is to
  /// treat it as unknown rather than as trusted or as junk**: it is validated
  /// here from its own bytes (parse it, count the cells that carry elevation)
  /// and a record is written from what is actually on disk. That costs one
  /// parse per legacy tile, once, and needs no network, so a tile that is
  /// whole settles offline and a tile that was truncated is caught without
  /// anyone having to be online to find out. **Deleting them unread was the
  /// alternative and it is worse:** it would throw away the only elevation a
  /// person has in the field to punish a missing record, for a defect most of
  /// those tiles do not have. **Trusting them was the other alternative and it
  /// is worse too:** it would leave exactly this defect in place, permanently,
  /// on the only devices that currently have it.
  Future<DemTileHealth> tileHealth(DemTileId id) async {
    final file = await _fileFor(id);
    if (!await file.exists()) return DemTileHealth.absent;
    var record = await tileRecord(id);
    record ??= await _backfillRecord(id, file);
    if (record == null) return DemTileHealth.unusable;
    if (record.bytes != await file.length()) return DemTileHealth.unusable;
    if (record.filledCells <= 0) return DemTileHealth.unusable;
    if (record.isFullyCovered || record.attempts >= kDemTileMaxFetchAttempts) {
      return DemTileHealth.complete;
    }
    return DemTileHealth.incomplete;
  }

  /// Builds a record for a tile that has none, from the tile itself. Returns
  /// null — meaning unusable — when the file will not parse, is the wrong
  /// shape for its id, or carries no elevation.
  Future<DemTileRecord?> _backfillRecord(DemTileId id, File file) async {
    final ElevationGrid grid;
    try {
      grid = DemAscii.parse(await file.readAsString());
    } catch (_) {
      // A truncated tile stops here: the parser counts values and a short
      // file has too few.
      return null;
    }
    final spec = id.gridSpec();
    if (grid.ncols != spec.ncols || grid.nrows != spec.nrows) return null;
    final filled = grid.filledCellCount;
    if (filled <= 0) return null;
    final record = DemTileRecord(
      bytes: await file.length(),
      cells: grid.ncols * grid.nrows,
      filledCells: filled,
      // Zero: a legacy tile short of elevation is asked about again, on the
      // same budget as one fetched today.
      attempts: 0,
    );
    await _writeRecord(id, record);
    return record;
  }

  /// Size in bytes of tile [id]'s file, or 0 if it isn't on disk.
  Future<int> tileSizeBytes(DemTileId id) async {
    final file = await _fileFor(id);
    return await file.exists() ? file.length() : 0;
  }

  /// Number of DEM tile *files* currently on disk.
  ///
  /// Deliberately a file count and not a usable-tile count: answering the
  /// stricter question would validate every tile on the device, which for a
  /// tile written before task 11.143 means parsing it, and this is called from
  /// the pre-trip checklist where that could be hundreds of tiles at once.
  /// [hasTile] is the question to ask about a tile you are about to use.
  Future<int> tileCount() async => (await listTiles()).length;

  /// Loads tile [id]'s grid, or null if it isn't downloaded — or is on disk
  /// but not what was recorded for it (a half-written tile is not served).
  Future<ElevationGrid?> loadTile(DemTileId id) async {
    if (!await hasTile(id)) return null;
    final file = await _fileFor(id);
    return DemAscii.parse(await file.readAsString());
  }

  /// Elevation (m) at a single point, read from the one tile that contains it,
  /// or null if that tile isn't downloaded (or the cell is noData). Cheaper
  /// than [composeForBounds] for one-off lookups like an observation's
  /// auto-filled elevation.
  Future<double?> elevationAt(double lat, double lon) async {
    final grid = await loadTile(DemTileId.forLatLon(lat, lon));
    return grid?.elevationAt(lat, lon);
  }

  /// Persists [grid] as tile [id], then records what was written. The grid
  /// must match [id]'s [gridSpec] so the global alignment holds; a mismatch
  /// throws rather than silently corrupting the merge, and so does a grid with
  /// no elevation in it at all.
  ///
  /// A re-fetch that came back with *less* elevation than the tile already on
  /// disk does not replace it — but it does count as an attempt, so a square
  /// the source cannot fill is not asked about forever.
  Future<void> saveTile(DemTileId id, ElevationGrid grid) async {
    final spec = id.gridSpec();
    const tol = 1e-6;
    final aligned = grid.ncols == spec.ncols &&
        grid.nrows == spec.nrows &&
        (grid.cellSizeDegrees - spec.cellSizeDegrees).abs() < tol &&
        (grid.xllCorner - spec.xllCorner).abs() < tol &&
        (grid.yllCorner - spec.yllCorner).abs() < tol;
    if (!aligned) {
      throw ArgumentError(
        'Grid does not match DemTileId $id gridSpec '
        '(expected ${spec.ncols}x${spec.nrows} @ ${spec.cellSizeDegrees}° '
        'from ${spec.xllCorner},${spec.yllCorner}).',
      );
    }

    final filled = grid.filledCellCount;
    if (filled <= 0) {
      // A wholly failed fetch comes back as a grid of the right shape with
      // nothing in it (task 11.142). Writing it would create the very thing
      // this store no longer allows: a file that reads as coverage.
      throw ArgumentError(
        'Refusing to save DemTileId $id: the grid carries no elevation.',
      );
    }

    final existing = await tileRecord(id);
    final attempts = (existing?.attempts ?? 0) + 1;
    if (existing != null &&
        existing.filledCells > filled &&
        (await tileHealth(id)).isUsable) {
      // A retry that came back with less than what is already on disk. Keep
      // the better tile, but count the attempt, so a square the source will
      // never fill completely stops being asked about.
      await _writeRecord(
        id,
        DemTileRecord(
          bytes: existing.bytes,
          cells: existing.cells,
          filledCells: existing.filledCells,
          attempts: attempts,
        ),
      );
      return;
    }

    final file = await _fileFor(id);
    await file.parent.create(recursive: true);

    // Order matters. The record goes last, after the bytes are on disk and
    // renamed into place, so an interruption anywhere in the middle leaves a
    // tile with no record — which [tileHealth] validates from the file itself
    // rather than trusting. The rename makes a half-written file at the tile's
    // own path unlikely; the record is what makes it *detectable*, and that is
    // the part being relied on.
    final record = await _recordFileFor(id);
    if (await record.exists()) await record.delete();
    final temp = File('${file.path}.part');
    await temp.writeAsString(DemAscii.write(grid), flush: true);
    await temp.rename(file.path);

    await _writeRecord(
      id,
      DemTileRecord(
        bytes: await file.length(),
        cells: grid.ncols * grid.nrows,
        filledCells: filled,
        attempts: attempts,
      ),
    );
  }

  /// Tiles whose 0.1° square overlaps the bounds rectangle.
  List<DemTileId> tilesIntersectingBounds({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
  }) {
    // Epsilon pulls a max edge that lands exactly on a tile boundary back into
    // the lower tile, so touching an edge doesn't drag in a spurious tile row.
    const eps = 1e-9;
    final latLo = (minLat / kDemTileSizeDegrees).floor();
    final latHi = ((maxLat - eps) / kDemTileSizeDegrees).floor();
    final lonLo = (minLon / kDemTileSizeDegrees).floor();
    final lonHi = ((maxLon - eps) / kDemTileSizeDegrees).floor();
    final ids = <DemTileId>[];
    for (var la = latLo; la <= latHi; la++) {
      for (var lo = lonLo; lo <= lonHi; lo++) {
        ids.add(DemTileId(la, lo));
      }
    }
    return ids;
  }

  /// Tiles whose 0.1° square intersects [polygon] (bbox candidates filtered by
  /// a rectangle/polygon overlap test — used to decide what to fetch, so it
  /// errs toward inclusion at the edges).
  List<DemTileId> tilesIntersectingPolygon(List<LatLng> polygon) {
    if (polygon.length < 3) return const [];
    final bb = GeoPolygon.boundingBox(polygon);
    final candidates = tilesIntersectingBounds(
      minLat: bb.minLat,
      minLon: bb.minLon,
      maxLat: bb.maxLat,
      maxLon: bb.maxLon,
    );
    return candidates.where((id) => _tileIntersectsPolygon(id, polygon)).toList();
  }

  bool _tileIntersectsPolygon(DemTileId id, List<LatLng> polygon) {
    // Tile center inside polygon.
    if (GeoPolygon.pointInPolygon(id.center, polygon)) return true;
    // Any tile corner inside polygon.
    final corners = [
      LatLng(id.south, id.west),
      LatLng(id.south, id.east),
      LatLng(id.north, id.west),
      LatLng(id.north, id.east),
    ];
    for (final c in corners) {
      if (GeoPolygon.pointInPolygon(c, polygon)) return true;
    }
    // Any polygon vertex inside the tile rectangle.
    for (final v in polygon) {
      if (v.latitude >= id.south &&
          v.latitude <= id.north &&
          v.longitude >= id.west &&
          v.longitude <= id.east) {
        return true;
      }
    }
    return false;
  }

  /// Intersecting tiles the store still wants — missing, unusable, or short
  /// of elevation with attempts left. **Not "not yet on disk"**: a tile that
  /// arrived half-written is on disk and is exactly what this list must
  /// contain.
  Future<List<DemTileId>> missingTilesForPolygon(List<LatLng> polygon) async {
    final want = tilesIntersectingPolygon(polygon);
    final fetch = <DemTileId>[];
    for (final id in want) {
      if (await needsFetch(id)) fetch.add(id);
    }
    return fetch;
  }

  /// Deletes exactly the tiles in [ids] that are on disk. Returns the number
  /// deleted.
  ///
  /// This is what deleting a saved elevation *area* calls, with the list
  /// already reduced to the tiles no other area covers
  /// (`OfflineRegionStore.demTilesNoOtherAreaCovers`) — task 11.230. It
  /// takes a list rather than a polygon precisely so that decision is made
  /// somewhere that can see the other areas; this store cannot.
  Future<int> deleteTiles(Iterable<DemTileId> ids) async {
    var deleted = 0;
    for (final id in ids) {
      final file = await _fileFor(id);
      if (await file.exists()) {
        await file.delete();
        await _deleteRecord(id);
        deleted++;
      }
    }
    return deleted;
  }

  /// Deletes on-disk tiles intersecting [polygon] — **the same touching rule
  /// [tilesIntersectingPolygon] uses**, i.e. the rule elevation coverage and
  /// the elevation download already use. Returns the number deleted.
  ///
  /// Task 11.231: this used to keep a tile unless its *center* fell inside
  /// the polygon, while coverage credited (and the download fetched) a tile
  /// the polygon merely *touched*. The two rules disagreeing meant erasing
  /// an elevation area's own exact outline left its edge tiles behind, so
  /// the area read Partial instead of gone. One rule now, chosen because
  /// coverage already uses it: a touch rule erases slightly outside the
  /// drawn shape, which is fine for a tile no area claims and is prevented
  /// for one that is claimed by [deleteTiles]'s neighbour-aware callers.
  ///
  /// **Checks no saved area.** This is the Offline Data Map's "Erase" tool —
  /// a person draws a shape and asks for everything under it to go, whether
  /// or not an area claims it. Deleting a saved area goes through
  /// [deleteTiles] with the neighbour-aware list instead.
  Future<int> deleteTilesInPolygon(List<LatLng> polygon) async {
    if (polygon.length < 3) return 0;
    return deleteTiles(tilesIntersectingPolygon(polygon));
  }

  /// Merges every on-disk tile intersecting the bounds into one grid aligned
  /// to the global lattice. The composed extent is the union of all
  /// intersecting tiles (full 0.1° blocks), so it always covers the requested
  /// bounds. Cells belonging to intersecting-but-missing tiles are left as
  /// [_noData] (-9999). Returns null only when no tile intersects at all;
  /// otherwise returns a grid that may contain gaps.
  Future<ElevationGrid?> composeForBounds({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
  }) async {
    final region = tilesIntersectingBounds(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
    );
    if (region.isEmpty) return null;

    // Usable tiles, by their recorded completeness — a tile on disk that is
    // not what was recorded for it is not coverage.
    final have = <DemTileId>{};
    for (final id in region) {
      if (await hasTile(id)) have.add(id);
    }
    if (have.isEmpty) return null;

    var minLatIdx = region.first.latIndex, maxLatIdx = region.first.latIndex;
    var minLonIdx = region.first.lonIndex, maxLonIdx = region.first.lonIndex;
    for (final id in region) {
      minLatIdx = math.min(minLatIdx, id.latIndex);
      maxLatIdx = math.max(maxLatIdx, id.latIndex);
      minLonIdx = math.min(minLonIdx, id.lonIndex);
      maxLonIdx = math.max(maxLonIdx, id.lonIndex);
    }

    final tilesX = maxLonIdx - minLonIdx + 1;
    final tilesY = maxLatIdx - minLatIdx + 1;
    final ncols = tilesX * kDemCellsPerTile;
    final nrows = tilesY * kDemCellsPerTile;
    final data = Float64List(ncols * nrows)..fillRange(0, ncols * nrows, _noData);

    for (var la = minLatIdx; la <= maxLatIdx; la++) {
      for (var lo = minLonIdx; lo <= maxLonIdx; lo++) {
        final id = DemTileId(la, lo);
        if (!have.contains(id)) continue;
        final grid = await loadTile(id);
        if (grid == null) continue;
        if (grid.ncols != kDemCellsPerTile || grid.nrows != kDemCellsPerTile) {
          // Misaligned/legacy tile — skip rather than smear it into the merge.
          continue;
        }
        // Row 0 = northmost. The northmost tile (maxLatIdx) sits at the top.
        final rowOffset = (maxLatIdx - la) * kDemCellsPerTile;
        final colOffset = (lo - minLonIdx) * kDemCellsPerTile;
        for (var lr = 0; lr < kDemCellsPerTile; lr++) {
          final dstRow = rowOffset + lr;
          for (var lc = 0; lc < kDemCellsPerTile; lc++) {
            data[dstRow * ncols + (colOffset + lc)] =
                grid.data[lr * kDemCellsPerTile + lc];
          }
        }
      }
    }

    return ElevationGrid(
      ncols: ncols,
      nrows: nrows,
      xllCorner: minLonIdx * kDemTileSizeDegrees,
      yllCorner: minLatIdx * kDemTileSizeDegrees,
      cellSizeDegrees: kDemCellSizeDegrees,
      data: data,
      noDataValue: _noData,
    );
  }

  /// Composes a grid covering the disc of [radiusMeters] around [center].
  Future<ElevationGrid?> composeForRegion({
    required LatLng center,
    required double radiusMeters,
  }) async {
    final dLat = radiusMeters / kMetersPerDegreeLatitude;
    final cosLat = math.cos(center.latitude * math.pi / 180.0).abs();
    final dLon = radiusMeters / (kMetersPerDegreeLatitude * math.max(cosLat, 1e-6));
    return composeForBounds(
      minLat: center.latitude - dLat,
      minLon: center.longitude - dLon,
      maxLat: center.latitude + dLat,
      maxLon: center.longitude + dLon,
    );
  }

  /// Marks [ids] (those present on disk) as most-recently-used by bumping
  /// their file modification time to now. [enforceCacheLimit] evicts by
  /// modification time, so touching the tiles a user is actively viewing (or
  /// driving through, for the live viewshed) keeps them and lets stale areas
  /// fall out of the cache first. Best-effort: a filesystem that rejects
  /// `setLastModified` is silently ignored.
  Future<void> touchTiles(Iterable<DemTileId> ids) async {
    final now = DateTime.now();
    for (final id in ids) {
      final file = await _fileFor(id);
      if (await file.exists()) {
        try {
          await file.setLastModified(now);
        } catch (_) {
          // ignore: some platforms/filesystems disallow setLastModified.
        }
      }
    }
  }

  /// Total bytes of on-disk tiles that are NOT in [protectedIds] — i.e. the
  /// auto-downloaded (ephemeral) terrain cache, excluding tiles that back a
  /// saved offline region.
  Future<int> unprotectedSizeBytes(Set<DemTileId> protectedIds) async {
    var total = 0;
    for (final id in await listTiles()) {
      if (protectedIds.contains(id)) continue;
      total += await tileSizeBytes(id);
    }
    return total;
  }

  /// Evicts least-recently-modified unprotected tiles until the total size of
  /// unprotected tiles is at most [maxBytes]. Tiles in [protectedIds] (those
  /// covered by a saved offline region) are never counted toward the limit nor
  /// deleted — permanent offline coverage is untouchable. Returns the number
  /// of tiles evicted.
  Future<int> enforceCacheLimit({
    required int maxBytes,
    required Set<DemTileId> protectedIds,
  }) async {
    final entries = <({DemTileId id, int size, DateTime modified})>[];
    var total = 0;
    for (final id in await listTiles()) {
      if (protectedIds.contains(id)) continue;
      final file = await _fileFor(id);
      if (!await file.exists()) continue;
      final stat = await file.stat();
      entries.add((id: id, size: stat.size, modified: stat.modified));
      total += stat.size;
    }
    if (total <= maxBytes) return 0;
    // Oldest modification time first = least-recently-used.
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var evicted = 0;
    for (final e in entries) {
      if (total <= maxBytes) break;
      final file = await _fileFor(e.id);
      if (await file.exists()) {
        await file.delete();
        await _deleteRecord(e.id);
        total -= e.size;
        evicted++;
      }
    }
    return evicted;
  }

  /// Total bytes of all DEM tile files.
  Future<int> sizeBytes() async {
    final root = await _root();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  /// Removes every DEM tile.
  Future<void> deleteAll() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
