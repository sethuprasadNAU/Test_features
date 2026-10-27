import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'tile_sources.dart';

/// Disk layout and size/clear helpers for cached map tiles, shared by the
/// live [CachedTileProvider] (`cached_tile_provider.dart`) and the region
/// downloader (`offline_tile_downloader.dart`). Tiles live under
/// `<app support>/tiles/<sourceId>/<z>/<x>/<y>.png`.
abstract final class TileCache {
  static Future<Directory> rootDir() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/tiles');
  }

  static Future<File> tileFile(String sourceId, int z, int x, int y) async {
    final root = await rootDir();
    return File('${root.path}/$sourceId/$z/$x/$y.png');
  }

  /// Total bytes cached, optionally scoped to one [sourceId].
  static Future<int> sizeBytes({String? sourceId}) async {
    final root = await rootDir();
    final dir = sourceId == null ? root : Directory('${root.path}/$sourceId');
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// Number of cached tile files, optionally scoped to one [sourceId].
  static Future<int> tileCount({String? sourceId}) async {
    final root = await rootDir();
    final dir = sourceId == null ? root : Directory('${root.path}/$sourceId');
    if (!await dir.exists()) return 0;
    var count = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) count++;
    }
    return count;
  }

  /// Deletes cached tiles, optionally scoped to one [sourceId]. No undo —
  /// unlike a single record, a bulk tile cache is trivially re-downloadable,
  /// so the UI asks for confirmation but doesn't offer to restore it.
  static Future<void> clear({String? sourceId}) async {
    final root = await rootDir();
    final dir = sourceId == null ? root : Directory('${root.path}/$sourceId');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  /// Builds the tile URL for [source] at (z,x,y), substituting `{s}` with a
  /// deterministic subdomain pick (matches flutter_map's own scheme, so the
  /// same tile downloaded here or fetched live lands in the same cache file
  /// regardless of which subdomain served it).
  static String buildUrl(TileSource source, int z, int x, int y) {
    var url = source.urlTemplate
        .replaceAll('{z}', z.toString())
        .replaceAll('{x}', x.toString())
        .replaceAll('{y}', y.toString());
    if (source.subdomains.isNotEmpty) {
      final s = source.subdomains[(x + y) % source.subdomains.length];
      url = url.replaceAll('{s}', s);
    }
    return url;
  }
}
