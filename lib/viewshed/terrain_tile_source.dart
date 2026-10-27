import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A decoded terrain-RGB (Mapzen/AWS "terrarium") elevation tile: a 256×256
/// slippy tile whose pixels encode elevation in their R/G/B channels.
///
/// Terrarium encoding: `elevation_m = (R * 256 + G + B / 256) - 32768`. Tiles
/// are served publicly (no API key / quota) from the AWS Open Data
/// "elevation-tiles-prod" bucket, so downloading elevation is just fetching
/// image tiles — the same speed and mechanics as map tiles, which is why this
/// replaced the point-query DEM source (that was ~3 min and ~600 API calls
/// per 0.1° tile).
class TerrainTile {
  TerrainTile(this._image);

  final img.Image _image;

  int get width => _image.width;
  int get height => _image.height;

  /// Decoded elevation (m) at pixel ([px], [py]), clamped into bounds.
  double elevationAtPixel(int px, int py) {
    final x = px.clamp(0, _image.width - 1);
    final y = py.clamp(0, _image.height - 1);
    final p = _image.getPixel(x, y);
    return (p.r * 256.0) + p.g + (p.b / 256.0) - 32768.0;
  }

  /// Decodes PNG [bytes] into a [TerrainTile], or null if they aren't a valid
  /// image (e.g. an error page returned with a 200).
  static TerrainTile? decode(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) return null;
    return TerrainTile(image);
  }
}

/// URL template for the public AWS terrarium tiles.
abstract final class TerrainTiles {
  /// The zoom used to sample elevation. z12 ≈ 38 m/px at the equator (finer at
  /// higher latitudes) — comfortably finer than the ~90 m DEM cell size, so
  /// downsampling into the DEM grid never invents detail. A 0.1° DEM tile
  /// overlaps at most ~2×2 terrarium tiles at this zoom.
  static const int samplingZoom = 12;

  static String url(int z, int x, int y) =>
      'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/$z/$x/$y.png';
}
