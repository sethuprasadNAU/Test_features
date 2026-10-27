import 'dart:typed_data';

import 'elevation_grid.dart';

/// Reads/writes the ESRI ASCII Grid (`.asc`) format into an [ElevationGrid].
///
/// This is a real, widely-supported, trivially-parseable DEM interchange
/// format — a concrete on-ramp and the fixture format for tests — not a
/// commitment to it as *the* download format. The app is DEM-source-agnostic
/// (SRTM, USGS 3DEP, a regional provider, …); whatever the eventual source,
/// converting a tile to ASCII Grid (or adding a sibling parser) is all that's
/// needed to feed the same engine.
///
/// Header (case-insensitive keys), then `nrows` rows of `ncols` whitespace-
/// separated values, northmost row first:
///
///     ncols        <int>
///     nrows        <int>
///     xllcorner    <double>     (or xllcenter)
///     yllcorner    <double>     (or yllcenter)
///     cellsize     <double>
///     NODATA_value <double>     (optional; default -9999)
///     <row 0 …> <row 1 …> …
abstract final class DemAscii {
  static ElevationGrid parse(String text) {
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    int? ncols, nrows;
    double? xll, yll, xCenter, yCenter, cellSize;
    var noData = -9999.0;

    var i = 0;
    String key() => tokens[i].toLowerCase();
    bool isHeaderKey() {
      const keys = {
        'ncols', 'nrows', 'xllcorner', 'yllcorner', 'xllcenter',
        'yllcenter', 'cellsize', 'nodata_value',
      };
      return i < tokens.length && keys.contains(tokens[i].toLowerCase());
    }

    while (isHeaderKey()) {
      final k = key();
      final valueStr = tokens[i + 1];
      i += 2;
      switch (k) {
        case 'ncols':
          ncols = int.parse(valueStr);
        case 'nrows':
          nrows = int.parse(valueStr);
        case 'xllcorner':
          xll = double.parse(valueStr);
        case 'yllcorner':
          yll = double.parse(valueStr);
        case 'xllcenter':
          xCenter = double.parse(valueStr);
        case 'yllcenter':
          yCenter = double.parse(valueStr);
        case 'cellsize':
          cellSize = double.parse(valueStr);
        case 'nodata_value':
          noData = double.parse(valueStr);
      }
    }

    if (ncols == null || nrows == null || cellSize == null) {
      throw const FormatException(
          'ASCII grid header missing ncols/nrows/cellsize');
    }
    // Convert a center-referenced origin to the corner convention.
    final xllCorner = xll ?? ((xCenter ?? 0) - cellSize / 2);
    final yllCorner = yll ?? ((yCenter ?? 0) - cellSize / 2);

    final expected = ncols * nrows;
    final remaining = tokens.length - i;
    if (remaining < expected) {
      throw FormatException(
          'ASCII grid has $remaining values, expected $expected');
    }

    final data = Float64List(expected);
    for (var j = 0; j < expected; j++) {
      data[j] = double.parse(tokens[i + j]);
    }

    return ElevationGrid(
      ncols: ncols,
      nrows: nrows,
      xllCorner: xllCorner,
      yllCorner: yllCorner,
      cellSizeDegrees: cellSize,
      data: data,
      noDataValue: noData,
    );
  }

  /// Serializes [grid] back to ASCII Grid text (round-trips [parse]).
  static String write(ElevationGrid grid) {
    final b = StringBuffer()
      ..writeln('ncols        ${grid.ncols}')
      ..writeln('nrows        ${grid.nrows}')
      ..writeln('xllcorner    ${grid.xllCorner}')
      ..writeln('yllcorner    ${grid.yllCorner}')
      ..writeln('cellsize     ${grid.cellSizeDegrees}')
      ..writeln('NODATA_value ${grid.noDataValue}');
    for (var r = 0; r < grid.nrows; r++) {
      final row = <String>[];
      for (var c = 0; c < grid.ncols; c++) {
        row.add(grid.data[r * grid.ncols + c].toString());
      }
      b.writeln(row.join(' '));
    }
    return b.toString();
  }
}
