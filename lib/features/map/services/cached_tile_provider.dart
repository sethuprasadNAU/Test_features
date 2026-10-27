import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../../../core/net/request_deadline.dart';
import 'tile_cache.dart';
import 'tile_fetch_health.dart';
import 'tile_sources.dart';
import 'tile_user_agent.dart';

/// A [TileProvider] that serves cached tiles from disk when present, and
/// otherwise fetches from the network and caches the result — so tiles
/// downloaded ahead of time via [OfflineTileDownloader] (or simply viewed
/// once while online) are available offline afterwards, without depending on
/// `flutter_map_tile_caching` (its `latlong2` constraint conflicts with the
/// version pinned here; see the Phase 5 memory note).
class CachedTileProvider extends TileProvider {
  /// **Every live tile in the app carries [tileUserAgent], and it is set here
  /// rather than at the six `TileLayer` call sites** (task 11.134 item 1).
  ///
  /// It used to come from each site's `userAgentPackageName:`, which produced
  /// `flutter_map (edu.nau.tritrack)` — measured, not assumed. That named the
  /// library before the app and carried no contact, and it was one forgotten
  /// argument away from `flutter_map (unknown)` on any new map screen. A rule
  /// that lives in the provider cannot be got wrong by the seventh call site.
  ///
  /// `flutter_map` sets its own header with `putIfAbsent`, so what is passed
  /// here wins and `userAgentPackageName` becomes inert. The argument is gone
  /// from all six sites; `tile_user_agent_test.dart` holds it gone, and holds
  /// every `TileLayer` in `lib/` to this provider.
  CachedTileProvider({required this.source, Map<String, String>? headers})
      : super(headers: {...tileRequestHeaders(), ...?headers});

  final TileSource source;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = TileCache.buildUrl(source, coordinates.z, coordinates.x, coordinates.y);
    return _CachedTileImage(
      url: url,
      sourceId: source.id,
      z: coordinates.z,
      x: coordinates.x,
      y: coordinates.y,
      headers: headers,
    );
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  const _CachedTileImage({
    required this.url,
    required this.sourceId,
    required this.z,
    required this.x,
    required this.y,
    required this.headers,
  });

  final String url;
  final String sourceId;
  final int z;
  final int x;
  final int y;
  final Map<String, String> headers;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final file = await TileCache.tileFile(sourceId, z, x, y);
    Uint8List bytes;
    if (await file.exists()) {
      bytes = await file.readAsBytes();
    } else {
      // Both outcomes are reported to [TileFetchHealth] — a refused request
      // and a dead network look identical on screen (nothing appears), and
      // the map is the only place that can say so. A cache hit above is
      // deliberately silent: it is not evidence about the network.
      final http.Response response;
      // **Bounded, like every other request this app makes** (task 11.61).
      // `http.get` builds a client per call and closes it, and set no limit of
      // its own — so a tile host that accepted the connection and went quiet
      // held this image stream open forever on Android, Windows and Linux, and
      // for a minute on iOS. Nothing said so either: [TileFetchHealth] is only
      // told about a failure, so the tile band task 11.135 built stayed silent
      // for exactly as long as the request never ended. Same client-per-call
      // shape as before, so nothing about pooling or lifetime changes.
      final client = withRequestDeadlines(http.Client());
      try {
        response = await client.get(Uri.parse(url), headers: headers);
      } catch (_) {
        TileFetchHealth.instance.recordNetworkFailure();
        rethrow;
      } finally {
        client.close();
      }
      if (response.statusCode != 200) {
        TileFetchHealth.instance.recordNetworkFailure();
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: Uri.parse(url),
        );
      }
      TileFetchHealth.instance.recordNetworkSuccess();
      bytes = response.bodyBytes;
      unawaited(_writeToCache(file, bytes));
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  Future<void> _writeToCache(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    } on FileSystemException {
      // Best-effort: a failed cache write shouldn't affect the tile that's
      // already been decoded and shown.
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage &&
      other.sourceId == sourceId &&
      other.z == z &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(sourceId, z, x, y);
}
