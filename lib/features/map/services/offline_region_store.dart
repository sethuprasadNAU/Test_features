import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../../../viewshed/dem_tile_store.dart';
import '../models/offline_region.dart';
import 'geo_polygon.dart';
import 'offline_tile_downloader.dart' show TileXY;
import 'tile_cache.dart';

/// Abstraction over "is this map tile on disk, how big is it, and remove it"
/// so [OfflineRegionStore.reconcileWithDisk] and
/// [OfflineRegionStore.deleteRegion] can be tested without a real tile cache.
/// The default [TileCacheCounter] is backed by [TileCache].
abstract class TileCounter {
  Future<bool> tileExists(String sourceId, int z, int x, int y);
  Future<int> tileSizeBytes(String sourceId, int z, int x, int y);

  /// Removes the tile's file if it is there. Returns the bytes freed (0 when
  /// there was nothing to remove).
  Future<int> deleteTile(String sourceId, int z, int x, int y);
}

/// [TileCounter] backed by the real on-disk [TileCache].
class TileCacheCounter implements TileCounter {
  const TileCacheCounter();

  @override
  Future<bool> tileExists(String sourceId, int z, int x, int y) async =>
      (await TileCache.tileFile(sourceId, z, x, y)).exists();

  @override
  Future<int> tileSizeBytes(String sourceId, int z, int x, int y) async {
    final file = await TileCache.tileFile(sourceId, z, x, y);
    return await file.exists() ? file.length() : 0;
  }

  @override
  Future<int> deleteTile(String sourceId, int z, int x, int y) async {
    final file = await TileCache.tileFile(sourceId, z, x, y);
    if (!await file.exists()) return 0;
    final bytes = await file.length();
    await file.delete();
    return bytes;
  }
}

/// What [OfflineRegionStore.deleteRegion] removed.
class RegionDeleteResult {
  const RegionDeleteResult({
    required this.tilesDeleted,
    required this.bytesFreed,
    required this.tilesKeptForOthers,
  });

  /// Files actually removed.
  final int tilesDeleted;

  /// Bytes those files held.
  final int bytesFreed;

  /// Tiles the deleted area covered that were left on disk because another
  /// area still covers them.
  final int tilesKeptForOthers;
}

/// What [OfflineRegionStore.eraseInPolygon] removed and kept.
class EraseResult {
  const EraseResult({
    required this.tilesDeleted,
    required this.demDeleted,
    required this.tilesKept,
    required this.demKept,
    required this.keptForIds,
  });

  /// Map tile files actually removed, across every source.
  final int tilesDeleted;

  /// DEM tile files actually removed.
  final int demDeleted;

  /// Map tiles the drawn shape reached that were left on disk because a
  /// saved area still covers them.
  final int tilesKept;

  /// DEM tiles the drawn shape reached that were left on disk because a
  /// saved area still covers them.
  final int demKept;

  /// Ids of the saved areas any of [tilesKept]/[demKept] were kept for.
  final Set<String> keptForIds;

  /// [tilesKept] + [demKept] — what a person is told was kept, without
  /// caring which kind.
  int get totalKept => tilesKept + demKept;
}

/// Persists the offline-coverage manifest (a list of [OfflineRegion]) to
/// `<base>/offline_regions.json`.
///
/// This manifest is the source of truth the UI reads to tell users exactly
/// what they have downloaded, so it must never lie. Two safeguards:
/// - All writes are serialized through an in-memory queue so concurrent
///   downloads updating progress can't interleave and corrupt the JSON.
/// - [reconcileWithDisk] recomputes every region's completion from what is
///   actually on disk, downgrading to `partial` / dropping empty regions.
///
/// **Tiles belong to no area.** Map tiles live in one tree, one file per
/// (source, zoom, x, y), and DEM tiles in one directory, one file per 0.1°
/// square; an area is only a polygon in this manifest. So two areas that
/// overlap hold the same files, and the file is on disk once. Everything
/// below that reasons about "this area's tiles" is reasoning about a set
/// that other areas may also claim — which is why [deleteRegion] subtracts
/// every other area first, and why [reconcileWithDisk] records how much of
/// an area's footprint is shared. Task 11.230.
///
/// [baseDirectory] is injectable for tests; defaults to the application
/// support directory.
class OfflineRegionStore {
  OfflineRegionStore({this.baseDirectory});

  /// Root under which `offline_regions.json` lives. Injected in tests.
  final Directory? baseDirectory;

  Future<void> _writeQueue = Future<void>.value();

  Future<File> _file() async {
    final base = baseDirectory ??
        Directory((await getApplicationSupportDirectory()).path);
    return File('${base.path}/offline_regions.json');
  }

  /// Runs [action] after any in-flight write completes, so writes never
  /// interleave. Returns [action]'s result.
  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = _writeQueue.then((_) => action());
    // Keep the queue alive even if this action throws, so a failed write
    // doesn't wedge every subsequent one.
    _writeQueue = completer.then((_) {}, onError: (_) {});
    return completer;
  }

  Future<List<OfflineRegion>> loadAll() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final text = await file.readAsString();
    if (text.trim().isEmpty) return [];
    final list = jsonDecode(text) as List<Object?>;
    return [
      for (final e in list)
        OfflineRegion.fromJson(e as Map<String, Object?>),
    ];
  }

  Future<void> _writeAll(List<OfflineRegion> regions) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert([for (final r in regions) r.toJson()]),
    );
  }

  /// Inserts [region] or replaces the existing one with the same id.
  Future<void> upsert(OfflineRegion region) => _serialize(() async {
        final regions = await loadAll();
        final i = regions.indexWhere((r) => r.id == region.id);
        if (i >= 0) {
          regions[i] = region;
        } else {
          regions.add(region);
        }
        await _writeAll(regions);
      });

  /// Removes the region with [id], if present. **Touches no tile file** —
  /// this forgets an area; [deleteRegion] is what frees its storage.
  Future<void> remove(String id) => _serialize(() async {
        final regions = await loadAll()
          ..removeWhere((r) => r.id == id);
        await _writeAll(regions);
      });

  /// Gives the region with [id] a new [name]. A null or blank name clears it,
  /// and the list falls back to the kind's generic label. No-op for an
  /// unknown id.
  Future<void> rename(String id, String? name, {DateTime? now}) =>
      _serialize(() async {
        final regions = await loadAll();
        final i = regions.indexWhere((r) => r.id == id);
        if (i < 0) return;
        final trimmed = name?.trim();
        // `copyWith` cannot set a field back to null, so rebuild.
        final r = regions[i];
        regions[i] = OfflineRegion(
          id: r.id,
          kind: r.kind,
          name: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
          polygon: r.polygon,
          sourceId: r.sourceId,
          minZoom: r.minZoom,
          maxZoom: r.maxZoom,
          cellSizeMeters: r.cellSizeMeters,
          tileTotal: r.tileTotal,
          tileCompleted: r.tileCompleted,
          status: r.status,
          sizeBytes: r.sizeBytes,
          sharedBytes: r.sharedBytes,
          sharedWithIds: r.sharedWithIds,
          createdAt: r.createdAt,
          updatedAt: now ?? DateTime.now(),
        );
        await _writeAll(regions);
      });

  // --- Which tiles an area covers ------------------------------------------

  /// Every map tile [region] covers, across its own zoom range. Empty for a
  /// DEM region or one with no zoom range.
  static Set<TileXY> tilesOf(OfflineRegion region) {
    if (region.kind != OfflineRegionKind.tiles) return const {};
    return GeoPolygon.tilesInPolygon(
      polygon: region.polygon,
      zoomLevels: _zoomRange(region.minZoom, region.maxZoom),
    ).toSet();
  }

  /// The map tiles [region] covers that **no other tile area in [all] with
  /// the same tile source** also covers — the files deleting [region] may
  /// remove.
  ///
  /// Same source only, because a tile from a different source is a different
  /// file (`tiles/<sourceId>/...`) and cannot be shared. [all] may include
  /// [region] itself; it is skipped by id. The other areas' zoom ranges are
  /// honoured as written: an area covering zooms 12–14 does not protect a
  /// zoom-15 tile over the same ground, because it never counted that tile
  /// as its own and its completeness does not depend on it.
  static Set<TileXY> tilesNoOtherAreaCovers(
    OfflineRegion region,
    Iterable<OfflineRegion> all,
  ) {
    if (region.kind != OfflineRegionKind.tiles) return const {};
    return _tilesNoAreaCovers(
      tilesOf(region),
      region.sourceId ?? '',
      all,
      excludeId: region.id,
    );
  }

  /// The map tiles across [zoomLevels] within [polygon] that **no area in
  /// [all] with tile source [sourceId]** covers — the same rule as
  /// [tilesNoOtherAreaCovers], generalised to a shape a person drew rather
  /// than a saved area. Used by the Offline Data Map's Erase tool (task
  /// 11.231), which is not deleting one of [all] — it may not even overlap
  /// one.
  static Set<TileXY> tilesInPolygonNoAreaCovers({
    required List<LatLng> polygon,
    required List<int> zoomLevels,
    required String sourceId,
    required Iterable<OfflineRegion> all,
  }) =>
      _tilesNoAreaCovers(
        GeoPolygon.tilesInPolygon(polygon: polygon, zoomLevels: zoomLevels)
            .toSet(),
        sourceId,
        all,
      );

  static Set<TileXY> _tilesNoAreaCovers(
    Set<TileXY> mine,
    String sourceId,
    Iterable<OfflineRegion> all, {
    String? excludeId,
  }) {
    if (mine.isEmpty) return mine;
    final claimed = <TileXY>{};
    for (final other in all) {
      if (other.id == excludeId) continue;
      if (other.kind != OfflineRegionKind.tiles) continue;
      if (other.sourceId != sourceId) continue;
      claimed.addAll(tilesOf(other));
    }
    return mine.difference(claimed);
  }

  /// The DEM tiles [region] covers that no other DEM area in [all] also
  /// covers. "Covers" is [DemTileStore.tilesIntersectingPolygon] — the same
  /// rule the download and [reconcileWithDisk] use, so what an area is
  /// credited with and what it protects are one set.
  static Set<DemTileId> demTilesNoOtherAreaCovers(
    OfflineRegion region,
    Iterable<OfflineRegion> all,
    DemTileStore demStore,
  ) {
    if (region.kind != OfflineRegionKind.dem) return const {};
    return _demTilesNoAreaCovers(
      demStore.tilesIntersectingPolygon(region.polygon).toSet(),
      all,
      demStore,
      excludeId: region.id,
    );
  }

  /// The DEM tiles intersecting [polygon] that no area in [all] also covers
  /// — [demTilesNoOtherAreaCovers] generalised to a drawn shape rather than
  /// a saved area, for the Erase tool. Task 11.231.
  static Set<DemTileId> demTilesInPolygonNoAreaCovers({
    required List<LatLng> polygon,
    required Iterable<OfflineRegion> all,
    required DemTileStore demStore,
  }) =>
      _demTilesNoAreaCovers(
        demStore.tilesIntersectingPolygon(polygon).toSet(),
        all,
        demStore,
      );

  /// Ids of tile areas in [all] that still cover at least one tile in
  /// [reached] — what the Offline Data Map's Erase tool names as "kept for"
  /// when a drawn shape overlaps a saved area. Task 11.231.
  static Set<String> tileAreaIdsCovering(
    Set<TileXY> reached,
    String sourceId,
    Iterable<OfflineRegion> all,
  ) {
    final ids = <String>{};
    for (final r in all) {
      if (r.kind != OfflineRegionKind.tiles) continue;
      if (r.sourceId != sourceId) continue;
      if (tilesOf(r).intersection(reached).isNotEmpty) ids.add(r.id);
    }
    return ids;
  }

  /// Ids of DEM areas in [all] that still cover at least one tile in
  /// [reached] — the DEM half of [tileAreaIdsCovering]. Task 11.231.
  static Set<String> demAreaIdsCovering(
    Set<DemTileId> reached,
    Iterable<OfflineRegion> all,
    DemTileStore demStore,
  ) {
    final ids = <String>{};
    for (final r in all) {
      if (r.kind != OfflineRegionKind.dem) continue;
      if (demStore
          .tilesIntersectingPolygon(r.polygon)
          .toSet()
          .intersection(reached)
          .isNotEmpty) {
        ids.add(r.id);
      }
    }
    return ids;
  }

  static Set<DemTileId> _demTilesNoAreaCovers(
    Set<DemTileId> mine,
    Iterable<OfflineRegion> all,
    DemTileStore demStore, {
    String? excludeId,
  }) {
    if (mine.isEmpty) return mine;
    final claimed = <DemTileId>{};
    for (final other in all) {
      if (other.id == excludeId) continue;
      if (other.kind != OfflineRegionKind.dem) continue;
      claimed.addAll(demStore.tilesIntersectingPolygon(other.polygon));
    }
    return mine.difference(claimed);
  }

  // --- Delete ---------------------------------------------------------------

  /// Frees the storage of the area with [id] **without touching a tile any
  /// other area still covers**, drops its manifest entry, and reconciles.
  ///
  /// The other areas are read from the manifest *now*, not from anything
  /// recorded when the area was made — areas are added and removed after
  /// that. A tile no area claims at all is fair game: panning the map writes
  /// into the same tree (`cached_tile_provider.dart`), so the cache holds
  /// tiles nobody asked for by name, and those are unowned and re-downloadable
  /// (task 11.230's brief says so in as many words; this is not a bug).
  ///
  /// Returns what was removed. An unknown [id] removes nothing.
  Future<RegionDeleteResult> deleteRegion({
    required String id,
    required TileCounter tileCounter,
    required DemTileStore demStore,
    DateTime? now,
  }) async {
    // Not inside `_serialize`: the file walk below can be long, and the
    // manifest writes it needs (`remove`, `reconcileWithDisk`) each take the
    // queue themselves.
    final regions = await loadAll();
    final region = regions.where((r) => r.id == id).firstOrNull;
    if (region == null) {
      return const RegionDeleteResult(
        tilesDeleted: 0,
        bytesFreed: 0,
        tilesKeptForOthers: 0,
      );
    }

    var deleted = 0;
    var bytes = 0;
    var kept = 0;
    switch (region.kind) {
      case OfflineRegionKind.tiles:
        final src = region.sourceId ?? '';
        final mine = tilesOf(region);
        final victims = tilesNoOtherAreaCovers(region, regions);
        kept = mine.length - victims.length;
        for (final t in victims) {
          final freed = await tileCounter.deleteTile(src, t.z, t.x, t.y);
          if (freed > 0) {
            deleted++;
            bytes += freed;
          }
        }
      case OfflineRegionKind.dem:
        final mine = demStore.tilesIntersectingPolygon(region.polygon);
        final victims = demTilesNoOtherAreaCovers(region, regions, demStore);
        kept = mine.length - victims.length;
        for (final t in victims) {
          final size = await demStore.tileSizeBytes(t);
          if (size == 0) continue;
          deleted += await demStore.deleteTiles([t]);
          bytes += size;
        }
    }

    await remove(id);
    await reconcileWithDisk(
      tileCounter: tileCounter,
      demStore: demStore,
      now: now,
    );
    return RegionDeleteResult(
      tilesDeleted: deleted,
      bytesFreed: bytes,
      tilesKeptForOthers: kept,
    );
  }

  /// The Offline Data Map's "Erase" tool: deletes every map tile and DEM
  /// square a drawn [polygon] reaches — **across every source in
  /// [tileSources]**, since a person erasing a shape does not pick one
  /// basemap first — **except what a saved area still covers**, and
  /// reconciles the manifest afterward.
  ///
  /// Task 11.231: before this, Erase deleted everything under the shape with
  /// no check for a saved area, so drawing a shape that crossed one silently
  /// made that area Partial. Now it uses the same neighbour-aware rule
  /// [deleteRegion] uses for the per-area delete, generalised (via
  /// [tilesInPolygonNoAreaCovers]/[demTilesInPolygonNoAreaCovers]) to a
  /// polygon that is not itself one of the saved areas — Erase's own use, a
  /// pan-cached tile no area claims, still goes.
  ///
  /// [tileSources] is `(sourceId, maxZoom)` for every basemap this build
  /// offers — deliberately not just the one on screen, matching the old
  /// behaviour of erasing every source under the shape.
  Future<EraseResult> eraseInPolygon({
    required List<LatLng> polygon,
    required List<({String sourceId, int maxZoom})> tileSources,
    required TileCounter tileCounter,
    required DemTileStore demStore,
    DateTime? now,
  }) async {
    final regions = await loadAll();
    final keptForIds = <String>{};

    var tilesDeleted = 0;
    var tilesKept = 0;
    for (final source in tileSources) {
      final zoomLevels = [for (var z = 1; z <= source.maxZoom; z++) z];
      final reached =
          GeoPolygon.tilesInPolygon(polygon: polygon, zoomLevels: zoomLevels)
              .toSet();
      if (reached.isEmpty) continue;
      final victims = tilesInPolygonNoAreaCovers(
        polygon: polygon,
        zoomLevels: zoomLevels,
        sourceId: source.sourceId,
        all: regions,
      );
      tilesKept += reached.length - victims.length;
      keptForIds.addAll(
        tileAreaIdsCovering(reached, source.sourceId, regions),
      );
      for (final t in victims) {
        final freed =
            await tileCounter.deleteTile(source.sourceId, t.z, t.x, t.y);
        if (freed > 0) tilesDeleted++;
      }
    }

    final demReached = demStore.tilesIntersectingPolygon(polygon).toSet();
    final demVictims = demTilesInPolygonNoAreaCovers(
      polygon: polygon,
      all: regions,
      demStore: demStore,
    );
    final demKept = demReached.length - demVictims.length;
    if (demKept > 0) {
      keptForIds.addAll(demAreaIdsCovering(demReached, regions, demStore));
    }
    final demDeleted = await demStore.deleteTiles(demVictims);

    await reconcileWithDisk(tileCounter: tileCounter, demStore: demStore, now: now);
    return EraseResult(
      tilesDeleted: tilesDeleted,
      demDeleted: demDeleted,
      tilesKept: tilesKept,
      demKept: demKept,
      keptForIds: keptForIds,
    );
  }

  // --- Reconcile ------------------------------------------------------------

  /// Recomputes every region's completion from disk truth:
  /// - tiles: counts existing tile files among the region's
  ///   [GeoPolygon.tilesInPolygon] via [tileCounter];
  /// - dem: counts existing DEM tiles among those intersecting the polygon.
  ///
  /// Updates `tileTotal`/`tileCompleted`/`sizeBytes`, sets `status` to
  /// `complete` (all present), `partial` (some), and DROPS regions with zero
  /// remaining coverage. [now] stamps `updatedAt` on changed regions
  /// (defaults to [DateTime.now]).
  ///
  /// Also records, per region, how much of its `sizeBytes` is held by a tile
  /// some other region covers too (`sharedBytes`) and which regions those
  /// are (`sharedWithIds`) — the numbers the "Offline Data" list and the
  /// delete confirmation use to say what a delete would really free. The
  /// per-tile sizes are read once here and reused, so this costs the set
  /// arithmetic and no second walk of the disk.
  Future<void> reconcileWithDisk({
    required TileCounter tileCounter,
    required DemTileStore demStore,
    DateTime? now,
  }) =>
      _serialize(() async {
        final stamp = now ?? DateTime.now();
        final regions = await loadAll();

        // Pass 1 — what is on disk, per region. Keys are `Object` so one
        // map shape serves both kinds: a `TileXY` prefixed by its source
        // for map tiles, a `DemTileId` for elevation. A key only ever
        // collides with a key of the same kind, since the two types are
        // never equal to each other.
        final present = <String, Map<Object, int>>{};
        final wantCount = <String, int>{};
        for (final region in regions) {
          final have = <Object, int>{};
          switch (region.kind) {
            case OfflineRegionKind.tiles:
              final src = region.sourceId ?? '';
              final want = tilesOf(region);
              for (final t in want) {
                if (await tileCounter.tileExists(src, t.z, t.x, t.y)) {
                  have[_SourcedTile(src, t)] =
                      await tileCounter.tileSizeBytes(src, t.z, t.x, t.y);
                }
              }
              wantCount[region.id] = want.length;
            case OfflineRegionKind.dem:
              final want = demStore.tilesIntersectingPolygon(region.polygon);
              for (final id in want) {
                // Task 11.143: a tile file being there is not the same as the
                // tile being there. A region holding a half-written tile is
                // `partial`, and saying so is what gets it re-downloaded.
                if (await demStore.hasTile(id)) {
                  have[id] = await demStore.tileSizeBytes(id);
                }
              }
              wantCount[region.id] = want.length;
          }
          present[region.id] = have;
        }

        // Pass 2 — completion, and what each region shares with the others.
        // "Shares" is over tiles actually on disk: a tile neither area has
        // fetched yet is not storage, so it is not shared storage.
        final kept = <OfflineRegion>[];
        for (final region in regions) {
          final have = present[region.id]!;
          final total = wantCount[region.id]!;
          final completed = have.length;

          // Zero remaining coverage → drop the region entirely.
          if (completed == 0) continue;

          var size = 0;
          var shared = 0;
          final sharedWith = <String>[];
          final othersByKey = <Object, bool>{};
          for (final other in regions) {
            if (other.id == region.id || other.kind != region.kind) continue;
            final theirs = present[other.id]!;
            var overlaps = false;
            for (final key in theirs.keys) {
              if (have.containsKey(key)) {
                othersByKey[key] = true;
                overlaps = true;
              }
            }
            if (overlaps) sharedWith.add(other.id);
          }
          for (final entry in have.entries) {
            size += entry.value;
            if (othersByKey.containsKey(entry.key)) shared += entry.value;
          }

          final status = completed >= total
              ? OfflineRegionStatus.complete
              : OfflineRegionStatus.partial;

          final changed = region.tileTotal != total ||
              region.tileCompleted != completed ||
              region.sizeBytes != size ||
              region.sharedBytes != shared ||
              !_sameIds(region.sharedWithIds, sharedWith) ||
              region.status != status;

          kept.add(changed
              ? region.copyWith(
                  tileTotal: total,
                  tileCompleted: completed,
                  sizeBytes: size,
                  sharedBytes: shared,
                  sharedWithIds: sharedWith,
                  status: status,
                  updatedAt: stamp,
                )
              : region);
        }

        await _writeAll(kept);
      });

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _zoomRange(int? minZoom, int? maxZoom) {
    if (minZoom == null || maxZoom == null || maxZoom < minZoom) {
      return const [];
    }
    return [for (var z = minZoom; z <= maxZoom; z++) z];
  }
}

/// A map tile plus the source it belongs to — the identity of one file in
/// the tile tree, so [OfflineRegionStore.reconcileWithDisk] can tell a tile
/// shared between two areas from the same coordinates at two sources.
class _SourcedTile {
  const _SourcedTile(this.sourceId, this.tile);
  final String sourceId;
  final TileXY tile;

  @override
  bool operator ==(Object other) =>
      other is _SourcedTile && other.sourceId == sourceId && other.tile == tile;

  @override
  int get hashCode => Object.hash(sourceId, tile);
}
