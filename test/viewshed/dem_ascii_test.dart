import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/viewshed/dem_ascii.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

void main() {
  test('parses a corner-referenced ASCII grid header and data', () {
    const text = '''
ncols 3
nrows 2
xllcorner -111.0
yllcorner 35.0
cellsize 0.01
NODATA_value -9999
1 2 3
4 5 6
''';
    final grid = DemAscii.parse(text);
    expect(grid.ncols, 3);
    expect(grid.nrows, 2);
    expect(grid.xllCorner, -111.0);
    expect(grid.yllCorner, 35.0);
    expect(grid.cellSizeDegrees, 0.01);
    // Row 0 is the northmost; (0,0) is the NW cell.
    expect(grid.rawAt(0, 0), 1);
    expect(grid.rawAt(1, 2), 6);
    expect(grid.rawAt(0, 0)! < grid.rawAt(1, 2)!, isTrue);
  });

  test('converts a center-referenced origin to the corner convention', () {
    const text = '''
ncols 1
nrows 1
xllcenter -111.0
yllcenter 35.0
cellsize 0.02
42
''';
    final grid = DemAscii.parse(text);
    // Corner = center − half a cell.
    expect(grid.xllCorner, closeTo(-111.0 - 0.01, 1e-12));
    expect(grid.yllCorner, closeTo(35.0 - 0.01, 1e-12));
  });

  test('round-trips through write → parse', () {
    final original = ElevationGrid(
      ncols: 3,
      nrows: 2,
      xllCorner: -111.5,
      yllCorner: 35.25,
      cellSizeDegrees: 0.005,
      data: Float64List.fromList([10, 20, 30, 40, 50, 60]),
    );
    final reparsed = DemAscii.parse(DemAscii.write(original));
    expect(reparsed.ncols, original.ncols);
    expect(reparsed.nrows, original.nrows);
    expect(reparsed.xllCorner, closeTo(original.xllCorner, 1e-9));
    expect(reparsed.yllCorner, closeTo(original.yllCorner, 1e-9));
    expect(reparsed.cellSizeDegrees, closeTo(original.cellSizeDegrees, 1e-9));
    for (var i = 0; i < original.data.length; i++) {
      expect(reparsed.data[i], closeTo(original.data[i], 1e-9));
    }
  });

  test('throws on a truncated data section', () {
    const text = '''
ncols 3
nrows 3
xllcorner 0
yllcorner 0
cellsize 1
1 2 3 4 5
''';
    expect(() => DemAscii.parse(text), throwsFormatException);
  });
}
