// A very small PNG reader and writer, so the screenshot review needs no
// third-party image package.
//
// **Why hand-rolled rather than `package:image`.** This runs on a plain Dart
// SDK against a repository whose standing rule is that every dependency is
// pinned and reviewed, and the whole job is: read the handful of PNG shapes
// the Flutter engine emits, and write one. Everything else a general image
// library does is surface this does not need.
//
// **It refuses what it does not understand.** Interlaced, palettised,
// grayscale and 1/2/4-bit images all throw rather than being guessed at. A
// comparison run over pixels this file misread would report "unchanged" for
// two different screens, which is the exact failure a screenshot check exists
// to prevent — so not understanding a file is an error, never a pass.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An 8-bit RGBA raster.
class Raster {
  Raster(this.width, this.height, this.rgba);

  final int width;
  final int height;

  /// `width * height * 4` bytes, row-major, R,G,B,A.
  final Uint8List rgba;
}

class PngFormatException implements Exception {
  PngFormatException(this.message);
  final String message;
  @override
  String toString() => 'PngFormatException: $message';
}

const List<int> _signature = [137, 80, 78, 71, 13, 10, 26, 10];

/// Decodes a non-interlaced 8- or 16-bit truecolour PNG (with or without
/// alpha) to 8-bit RGBA.
Raster decodePng(Uint8List bytes) {
  for (var i = 0; i < _signature.length; i++) {
    if (i >= bytes.length || bytes[i] != _signature[i]) {
      throw PngFormatException('not a PNG (bad signature)');
    }
  }

  var offset = 8;
  int? width, height, bitDepth, colorType;
  final idat = BytesBuilder();
  var sawIend = false;

  while (offset + 8 <= bytes.length) {
    final length = _readUint32(bytes, offset);
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    if (dataEnd + 4 > bytes.length) {
      throw PngFormatException('chunk $type runs past the end of the file');
    }
    switch (type) {
      case 'IHDR':
        width = _readUint32(bytes, dataStart);
        height = _readUint32(bytes, dataStart + 4);
        bitDepth = bytes[dataStart + 8];
        colorType = bytes[dataStart + 9];
        if (bytes[dataStart + 10] != 0) {
          throw PngFormatException('unsupported compression method');
        }
        if (bytes[dataStart + 11] != 0) {
          throw PngFormatException('unsupported filter method');
        }
        if (bytes[dataStart + 12] != 0) {
          throw PngFormatException('interlaced PNGs are not supported');
        }
      case 'IDAT':
        idat.add(bytes.sublist(dataStart, dataEnd));
      case 'IEND':
        sawIend = true;
    }
    offset = dataEnd + 4;
    if (sawIend) break;
  }

  if (width == null || height == null) {
    throw PngFormatException('no IHDR chunk');
  }
  if (colorType != 2 && colorType != 6) {
    throw PngFormatException(
        'unsupported colour type $colorType (only truecolour, with or '
        'without alpha)');
  }
  if (bitDepth != 8 && bitDepth != 16) {
    throw PngFormatException('unsupported bit depth $bitDepth');
  }

  final channels = colorType == 6 ? 4 : 3;
  final bytesPerSample = bitDepth! ~/ 8;
  final bytesPerPixel = channels * bytesPerSample;
  final stride = width * bytesPerPixel;

  final inflated = Uint8List.fromList(
    ZLibCodec().decode(idat.takeBytes()),
  );
  final expected = (stride + 1) * height;
  if (inflated.length < expected) {
    throw PngFormatException(
        'image data is $expected bytes short of a full raster');
  }

  final raw = Uint8List(stride * height);
  var src = 0;
  for (var y = 0; y < height; y++) {
    final filter = inflated[src++];
    final rowStart = y * stride;
    for (var x = 0; x < stride; x++) {
      final current = inflated[src + x];
      final a = x >= bytesPerPixel ? raw[rowStart + x - bytesPerPixel] : 0;
      final b = y > 0 ? raw[rowStart - stride + x] : 0;
      final c = (x >= bytesPerPixel && y > 0)
          ? raw[rowStart - stride + x - bytesPerPixel]
          : 0;
      final int value;
      switch (filter) {
        case 0:
          value = current;
        case 1:
          value = current + a;
        case 2:
          value = current + b;
        case 3:
          value = current + ((a + b) >> 1);
        case 4:
          value = current + _paeth(a, b, c);
        default:
          throw PngFormatException('unknown row filter $filter on row $y');
      }
      raw[rowStart + x] = value & 0xFF;
    }
    src += stride;
  }

  final rgba = Uint8List(width * height * 4);
  for (var pixel = 0; pixel < width * height; pixel++) {
    final from = pixel * bytesPerPixel;
    final to = pixel * 4;
    for (var channel = 0; channel < 3; channel++) {
      // 16-bit samples are truncated to their high byte, which is what the
      // difference between two screenshots is measured in anyway.
      rgba[to + channel] = raw[from + channel * bytesPerSample];
    }
    rgba[to + 3] = channels == 4
        ? raw[from + 3 * bytesPerSample]
        : 255;
  }
  return Raster(width, height, rgba);
}

/// Encodes [raster] as an 8-bit PNG, dropping alpha when it is fully opaque.
///
/// Filter type 0 on every row: simple, and the deflate pass does the work.
Uint8List encodePng(Raster raster) {
  var opaque = true;
  for (var i = 3; i < raster.rgba.length; i += 4) {
    if (raster.rgba[i] != 255) {
      opaque = false;
      break;
    }
  }
  final channels = opaque ? 3 : 4;
  final stride = raster.width * channels;
  final raw = Uint8List((stride + 1) * raster.height);
  var dst = 0;
  for (var y = 0; y < raster.height; y++) {
    raw[dst++] = 0;
    for (var x = 0; x < raster.width; x++) {
      final from = (y * raster.width + x) * 4;
      for (var channel = 0; channel < channels; channel++) {
        raw[dst++] = raster.rgba[from + channel];
      }
    }
  }

  final out = BytesBuilder();
  out.add(_signature);
  final ihdr = BytesBuilder()
    ..add(_uint32(raster.width))
    ..add(_uint32(raster.height))
    ..addByte(8)
    ..addByte(opaque ? 2 : 6)
    ..addByte(0)
    ..addByte(0)
    ..addByte(0);
  out.add(_chunk('IHDR', ihdr.takeBytes()));
  out.add(_chunk(
    'IDAT',
    Uint8List.fromList(ZLibCodec(level: 9).encode(raw)),
  ));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

int _readUint32(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

Uint8List _uint32(int value) => Uint8List(4)
  ..[0] = (value >> 24) & 0xFF
  ..[1] = (value >> 16) & 0xFF
  ..[2] = (value >> 8) & 0xFF
  ..[3] = value & 0xFF;

Uint8List _chunk(String type, Uint8List data) {
  final body = BytesBuilder()
    ..add(ascii.encode(type))
    ..add(data);
  final bodyBytes = body.takeBytes();
  return Uint8List.fromList([
    ..._uint32(data.length),
    ...bodyBytes,
    ..._uint32(_crc32(bodyBytes)),
  ]);
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
