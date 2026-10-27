import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../../core/net/request_deadline.dart';
import 'tile_cache.dart';
import 'tile_user_agent.dart';
import 'tile_sources.dart';

/// A tile coordinate (slippy-map convention: z/x/y).
///
/// Two values are equal when they name the same tile, so a `Set<TileXY>` is
/// a set of tiles — which is what task 11.230's "the tiles one area covers
/// that no other area covers" needs to be.
class TileXY {
  const TileXY(this.z, this.x, this.y);
  final int z;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is TileXY && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => 'TileXY($z/$x/$y)';
}

/// Standard slippy-map (Web Mercator) tile math — the same convention every
/// provider in [TileSources] and `flutter_map` itself uses.
abstract final class SlippyMap {
  static int lonToTileX(double lonDeg, int z) =>
      (((lonDeg + 180.0) / 360.0) * (1 << z)).floor().clamp(0, (1 << z) - 1);

  static int latToTileY(double latDeg, int z) {
    final latRad = latDeg * math.pi / 180.0;
    final y = (1 -
            math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
        2 *
        (1 << z);
    return y.floor().clamp(0, (1 << z) - 1);
  }

  /// Fractional tile X for [lonDeg] at zoom [z] (the integer part is the tile
  /// column, the fraction locates a point within it). Inverse of [tileXToLon].
  static double lonToTileXFrac(double lonDeg, int z) =>
      (lonDeg + 180.0) / 360.0 * (1 << z);

  /// Fractional tile Y for [latDeg] at zoom [z]. Inverse of [tileYToLat].
  static double latToTileYFrac(double latDeg, int z) {
    final latRad = latDeg * math.pi / 180.0;
    return (1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
        2 *
        (1 << z);
  }

  /// Longitude (degrees) of the left (west) edge of tile column [x] at zoom
  /// [z]. Pass a fractional value (e.g. `x + 0.5`) to get an interior point —
  /// the tile *center* longitude is `tileXToLon(x + 0.5, z)`.
  static double tileXToLon(num x, int z) => x / (1 << z) * 360.0 - 180.0;

  /// Latitude (degrees) of the top (north) edge of tile row [y] at zoom [z].
  /// The tile *center* latitude is `tileYToLat(y + 0.5, z)`. Inverse of
  /// [latToTileY].
  static double tileYToLat(num y, int z) {
    final n = math.pi - 2.0 * math.pi * y / (1 << z);
    return 180.0 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
  }

  /// All tiles covering [minLat]..[maxLat] / [minLon]..[maxLon] at each zoom
  /// in [zoomLevels].
  static List<TileXY> tilesForBounds({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    required List<int> zoomLevels,
  }) {
    final tiles = <TileXY>[];
    for (final z in zoomLevels) {
      final xMin = lonToTileX(minLon, z);
      final xMax = lonToTileX(maxLon, z);
      // Latitude tile Y decreases as latitude increases (north).
      final yMin = latToTileY(maxLat, z);
      final yMax = latToTileY(minLat, z);
      for (var x = xMin; x <= xMax; x++) {
        for (var y = yMin; y <= yMax; y++) {
          tiles.add(TileXY(z, x, y));
        }
      }
    }
    return tiles;
  }
}

/// Outcome of attempting one tile fetch — lets callers tally honest
/// completed/failed counts instead of silently swallowing errors.
enum TileFetchOutcome {
  /// Already on disk; no network request made.
  cached,

  /// Fetched and written this call.
  downloaded,

  /// Network error, non-200 response, or write failure.
  failed,
}

/// Tallied result of a [OfflineTileDownloader.downloadTiles] /
/// [OfflineTileDownloader.downloadRegion] run.
class TileDownloadResult {
  const TileDownloadResult({
    required this.completed,
    required this.failed,
    required this.total,
  });

  /// Cached + successfully downloaded tiles.
  final int completed;

  /// Tiles that errored (network/HTTP/write failure).
  final int failed;

  /// Total tiles attempted.
  final int total;

  /// A region is only fully successful when every tile succeeded.
  bool get isFullSuccess => failed == 0 && completed >= total;
}

/// Downloads and caches map tiles into the shared tile cache — the "Manage
/// Offline Maps" download-by-extent action, and (via [downloadTiles]) the
/// polygon-shaped downloads driven by the app-level download manager.
/// Bounded concurrency and a per-tile skip-if-cached check keep re-runs (e.g.
/// after adding a zoom level) cheap.
abstract final class OfflineTileDownloader {
  static const _concurrency = 6;

  /// Downloads [source]'s tiles for the given bounds/zooms into the shared
  /// tile cache. Calls [onProgress] after each tile attempt (cached hits
  /// count too, so the bar always reaches [total]). Checks [isCancelled]
  /// between tiles and stops early if it returns true. [client] is injectable
  /// for tests; defaults to a plain [http.Client].
  static Future<TileDownloadResult> downloadRegion({
    required TileSource source,
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    required List<int> zoomLevels,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    http.Client? client,
  }) {
    final tiles = SlippyMap.tilesForBounds(
      minLat: minLat,
      minLon: minLon,
      maxLat: maxLat,
      maxLon: maxLon,
      zoomLevels: zoomLevels,
    );
    return downloadTiles(
      tiles: tiles,
      source: source,
      onProgress: onProgress,
      isCancelled: isCancelled,
      client: client,
    );
  }

  /// Same as [downloadRegion] but takes an explicit tile list, so callers
  /// (e.g. a polygon-shaped download) can pass exactly the tiles they want
  /// rather than every tile in a bounding box.
  static Future<TileDownloadResult> downloadTiles({
    required List<TileXY> tiles,
    required TileSource source,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    http.Client? client,
  }) async {
    // **Bounded, like everything else this app sends** (task 11.61). A tile is
    // a small request: 30 seconds for the tile server to say anything, and no
    // byte for 60 aborts it. Before this, a tile host that accepted the
    // connection and then went quiet stalled a region download indefinitely on
    // Android, Windows and Linux, with the progress bar frozen on the tile that
    // hung and nothing saying why.
    //
    // **Deliberately not `createPlatformHttpClient`**, which is the *server*
    // seam and carries decisions that are about the server — App Transport
    // Security, and the refusal of an address this device will not use. A tile
    // host is neither, and moving third-party tile traffic onto NSURLSession is
    // a separate question nobody has asked. What both seams share is the
    // deadline, which is the thing this task owns.
    final httpClient = client ?? withRequestDeadlines(http.Client());
    var done = 0;
    var failed = 0;
    onProgress?.call(done, tiles.length);

    for (var i = 0; i < tiles.length; i += _concurrency) {
      if (isCancelled?.call() ?? false) break;
      final batch = tiles.skip(i).take(_concurrency).toList();
      final outcomes =
          await Future.wait(batch.map((t) => _fetchOne(httpClient, source, t)));
      failed += outcomes.where((o) => o == TileFetchOutcome.failed).length;
      done += batch.length;
      onProgress?.call(done, tiles.length);
    }
    return TileDownloadResult(
      completed: done - failed,
      failed: failed,
      total: tiles.length,
    );
  }

  static Future<TileFetchOutcome> _fetchOne(
    http.Client client,
    TileSource source,
    TileXY t,
  ) async {
    final file = await TileCache.tileFile(source.id, t.z, t.x, t.y);
    if (await file.exists()) return TileFetchOutcome.cached;
    final url = TileCache.buildUrl(source, t.z, t.x, t.y);
    try {
      // **This is the request task 11.134 measured going out as
      // `Dart/3.12 (dart:io)`** — the SDK's default, because nothing passed
      // headers, on the one path in the app that asks for thousands of tiles
      // at six at a time. The OpenStreetMap tile policy names a library
      // default as grounds for blocking, and a block here would present as a
      // region download that silently failed every tile.
      final response =
          await client.get(Uri.parse(url), headers: tileRequestHeaders());
      if (response.statusCode == 200) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes);
        return TileFetchOutcome.downloaded;
      }
      return TileFetchOutcome.failed;
    } catch (_) {
      // A network blip or rate limit shouldn't abort the whole region
      // download; it's reported as failed so the caller can retry, but the
      // batch keeps going.
      return TileFetchOutcome.failed;
    }
  }

  /// Estimated tile count for a region — shown before starting so the user
  /// can choose a smaller extent or fewer zoom levels rather than kicking off
  /// an unexpectedly huge download.
  /// How many tiles [minLat]..[maxLat] × [minLon]..[maxLon] covers at
  /// [zoomLevels] — **counted, never enumerated.**
  ///
  /// **Task 11.103 found this the hard way.** It used to call
  /// `SlippyMap.tilesForBounds(...).length`, which builds the whole list to
  /// measure it. The Offline Data Map's "new selection" seeds a box covering
  /// 60% of whatever is on screen, so a person who has pinched out to see
  /// where they are and then taps it asks this to allocate a `TileXY` for
  /// every tile on the visible planet at zooms 12–16 — on the UI thread. That
  /// is hundreds of millions of objects, and the app does not come back.
  ///
  /// Nothing about the number needed the list. It is one multiplication per
  /// zoom level, and the count is what every caller wanted; the only caller
  /// of the list form is the downloader, which is bounded by a polygon a
  /// person has confirmed. Found because a change to that screen's default
  /// zoom took its own test suite from under a second to four minutes.
  static int estimateTileCount({
    required double minLat,
    required double minLon,
    required double maxLat,
    required double maxLon,
    required List<int> zoomLevels,
  }) {
    var total = 0;
    for (final z in zoomLevels) {
      final across = SlippyMap.lonToTileX(maxLon, z) -
          SlippyMap.lonToTileX(minLon, z) +
          1;
      // Tile Y decreases as latitude increases (north), so max latitude is
      // the smaller Y — the same inversion `tilesForBounds` handles.
      final down =
          SlippyMap.latToTileY(minLat, z) - SlippyMap.latToTileY(maxLat, z) + 1;
      if (across <= 0 || down <= 0) continue;
      total += across * down;
    }
    return total;
  }
}
