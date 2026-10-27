import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/net/request_deadline.dart';
import '../features/map/services/offline_tile_downloader.dart' show SlippyMap;
import 'dem_tile_store.dart';
import 'elevation_grid.dart';
import 'terrain_tile_source.dart';

/// Builds one canonical DEM tile ([DemTileId.gridSpec]) by fetching the public
/// terrarium terrain-RGB tiles that overlap it, decoding their pixels to
/// elevation, and sampling them onto the DEM grid.
///
/// This replaced a per-point elevation API (OpenTopoData): a 0.1° DEM tile is
/// now ~4 fast image GETs with no API quota, instead of ~154 rate-limited
/// batch queries. The grid it returns is bit-for-bit the shape
/// [DemTileStore.saveTile] expects, so nothing downstream (compose, viewshed)
/// changes.
/// A cache of decoded terrain-RGB tiles, shared across a sequence of
/// [DemTileFetcher.fetchTile] calls that fill one region.
///
/// Adjacent 0.1° DEM tiles overlap in which z12 terrarium tiles cover them
/// (task 11.281 measured 72 DEM tiles needing only 143 distinct terrarium
/// tiles, not 380). Without a cache spanning the whole region fill, each
/// overlapping terrarium tile is re-fetched by every DEM tile that needs it,
/// because [DemTileFetcher.fetchTile] otherwise starts from an empty lookup
/// on every call. Pass one `TerrainTileCache` into every call in a region
/// fill's loop; do not share one across unrelated fills, since a stale
/// cached failure (a tile that couldn't be fetched) is remembered as `null`
/// for the cache's whole lifetime.
class TerrainTileCache {
  final Map<String, TerrainTile?> _tiles = {};
}

abstract final class DemTileFetcher {
  /// Fetches and returns the elevation grid for [id], conformed to
  /// `id.gridSpec()`. Cells whose terrain tile couldn't be fetched/decoded are
  /// left as [ElevationGrid.noDataValue] (a single missing terrarium tile
  /// leaves a gap rather than failing the whole DEM tile). Does not save —
  /// the caller decides whether to persist a partial result.
  ///
  /// [cache], when given, is checked before fetching each overlapping
  /// terrarium tile and filled in as new ones are fetched — pass the same
  /// [TerrainTileCache] across a loop of calls that fill one region so a
  /// terrarium tile shared by adjacent DEM tiles is fetched once.
  static Future<ElevationGrid> fetchTile(
    DemTileId id, {
    http.Client? client,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    TerrainTileCache? cache,
  }) async {
    // Bounded at the same seam as every other request (task 11.61). A terrain
    // tile is a small request; a source that goes quiet mid-fetch now leaves a
    // gap in the DEM, which this method already handles, instead of stopping
    // the download of a whole area on a socket nobody was going to close.
    final httpClient = client ?? withRequestDeadlines(http.Client());
    final spec = id.gridSpec();
    const z = TerrainTiles.samplingZoom;

    // Which terrarium tiles overlap this DEM tile's extent.
    final needed = SlippyMap.tilesForBounds(
      minLat: id.south,
      minLon: id.west,
      maxLat: id.north,
      maxLon: id.east,
      zoomLevels: const [z],
    );

    // Fetch + decode each overlapping terrain tile once, keyed by "x,y" — or
    // reuse it from [cache] if an earlier call in the same region fill
    // already fetched it.
    final tiles = cache?._tiles ?? <String, TerrainTile?>{};
    var fetched = 0;
    onProgress?.call(0, needed.length);
    for (final t in needed) {
      if (isCancelled?.call() ?? false) break;
      final key = '${t.x},${t.y}';
      if (!tiles.containsKey(key)) {
        tiles[key] = await _fetchTerrainTile(httpClient, z, t.x, t.y);
      }
      fetched++;
      onProgress?.call(fetched, needed.length);
    }

    // Matches ElevationGrid's default noDataValue; cells with no terrain tile
    // stay as gaps.
    const noData = -9999.0;
    final data = Float64List(spec.ncols * spec.nrows)
      ..fillRange(0, spec.ncols * spec.nrows, noData);

    // Sample every DEM cell center from the terrain tile it falls in. Uses the
    // exact (non-linear) Web Mercator inverse per pixel so cells line up with
    // the source imagery rather than assuming a tile is linear in latitude.
    for (var r = 0; r < spec.nrows; r++) {
      final lat = spec.yllCorner + (spec.nrows - r - 0.5) * spec.cellSizeDegrees;
      final fracY = SlippyMap.latToTileYFrac(lat, z);
      final tileY = fracY.floor();
      final py = ((fracY - tileY) * 256).floor();
      for (var c = 0; c < spec.ncols; c++) {
        final lon = spec.xllCorner + (c + 0.5) * spec.cellSizeDegrees;
        final fracX = SlippyMap.lonToTileXFrac(lon, z);
        final tileX = fracX.floor();
        final tile = tiles['$tileX,$tileY'];
        if (tile == null) continue; // leave as noData
        final px = ((fracX - tileX) * 256).floor();
        data[r * spec.ncols + c] = tile.elevationAtPixel(px, py);
      }
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

  static Future<TerrainTile?> _fetchTerrainTile(
    http.Client client,
    int z,
    int x,
    int y,
  ) async {
    try {
      final response = await client.get(Uri.parse(TerrainTiles.url(z, x, y)));
      if (response.statusCode != 200) return null;
      return TerrainTile.decode(response.bodyBytes);
    } catch (_) {
      return null;
    }
  }
}
