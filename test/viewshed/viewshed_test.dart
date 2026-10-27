import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';
import 'package:tritrack/viewshed/viewshed.dart';

/// Near-equator cell size so a degree of lon ≈ a degree of lat ≈ 111320 m,
/// and 1 cell ≈ 30 m — coarse, per the doc's "10–50 m, coarse = fast."
const _cellDeg = 30.0 / 111320.0;
const _metersPerDeg = 111320.0;

/// Builds a grid anchored at the equator/prime-meridian (SW corner at 0,0)
/// with elevation supplied by `elev(row, col)` (row 0 = northmost).
ElevationGrid gridFrom({
  required int nrows,
  required int ncols,
  required double Function(int r, int c) elev,
  double cellDeg = _cellDeg,
}) {
  final data = Float64List(nrows * ncols);
  for (var r = 0; r < nrows; r++) {
    for (var c = 0; c < ncols; c++) {
      data[r * ncols + c] = elev(r, c);
    }
  }
  return ElevationGrid(
    ncols: ncols,
    nrows: nrows,
    xllCorner: 0,
    yllCorner: 0,
    cellSizeDegrees: cellDeg,
    data: data,
  );
}

/// Longitude `metersEast` east of longitude [fromLon] near the equator.
double lonEastOf(double fromLon, double metersEast) =>
    fromLon + metersEast / _metersPerDeg;

void main() {
  group('ElevationGrid', () {
    test('bilinear interpolation returns the midpoint average of a ramp', () {
      // Elevation rises linearly with column: e = 10*c.
      final grid = gridFrom(nrows: 3, ncols: 3, elev: (r, c) => 10.0 * c);
      // Halfway (in lon) between col 0 (e=0) and col 1 (e=10), on a row center.
      final lonMid = (grid.lonOfCol(0) + grid.lonOfCol(1)) / 2;
      final e = grid.elevationAt(grid.latOfRow(1), lonMid);
      expect(e, isNotNull);
      expect(e!, closeTo(5.0, 1e-6));
    });

    test('elevationAt returns null outside coverage', () {
      final grid = gridFrom(nrows: 3, ncols: 3, elev: (r, c) => 100);
      expect(grid.elevationAt(10, 10), isNull);
      expect(grid.contains(10, 10), isFalse);
    });

    test('nodata corners fall back to the valid neighbours, not a crash', () {
      final grid = gridFrom(
        nrows: 2,
        ncols: 2,
        elev: (r, c) => (r == 0 && c == 0) ? -9999.0 : 100.0,
      );
      // Sampling near the hole still yields a finite value from the others.
      final e = grid.elevationAt(grid.latOfRow(0), grid.lonOfCol(0));
      expect(e, isNotNull);
      expect(e!.isFinite, isTrue);
    });

    test('cropToRadius shrinks the grid and stays within the original', () {
      final grid = gridFrom(nrows: 200, ncols: 200, elev: (r, c) => 0);
      final centerLat = grid.latOfRow(100);
      final centerLon = grid.lonOfCol(100);
      final cropped = grid.cropToRadius(centerLat, centerLon, 300)!;
      expect(cropped.nrows, lessThan(grid.nrows));
      expect(cropped.ncols, lessThan(grid.ncols));
      expect(cropped.contains(centerLat, centerLon), isTrue);
      expect(cropped.west, greaterThanOrEqualTo(grid.west));
      expect(cropped.east, lessThanOrEqualTo(grid.east));
    });

    test('cropToRadius returns null when the center is outside coverage', () {
      final grid = gridFrom(nrows: 10, ncols: 10, elev: (r, c) => 0);
      expect(grid.cropToRadius(10, 10, 500), isNull);
    });
  });

  group('ViewshedComputer — flat terrain', () {
    test('everything within a small flat extent is visible', () {
      final grid = gridFrom(nrows: 40, ncols: 40, elev: (r, c) => 100);
      final result = ViewshedComputer.compute(
        grid,
        grid.latOfRow(20),
        grid.lonOfCol(20),
      );
      expect(result.status, ViewshedStatus.computed);
      // ~1.2 km extent, well inside the ~5 km flat horizon → nearly all cells.
      expect(result.visibleFraction, greaterThan(0.9));
    });

    test('maxRange caps visibility even when line-of-sight is clear', () {
      final grid = gridFrom(nrows: 5, ncols: 60, elev: (r, c) => 100);
      final obsLat = grid.latOfRow(2);
      final obsLon = grid.lonOfCol(2);
      final result = ViewshedComputer.compute(
        grid, obsLat, obsLon,
        config: const ViewshedConfig(maxRangeMeters: 500),
      );
      // Due east along the observer's row: in-range visible, out-of-range not.
      expect(result.isVisibleAt(obsLat, lonEastOf(obsLon, 300)), isTrue);
      expect(result.isVisibleAt(obsLat, lonEastOf(obsLon, 800)), isFalse);
    });
  });

  group('ViewshedComputer — earth curvature / refraction', () {
    // On flat terrain the horizon sits at d* = sqrt(2·k·R·h).
    // h = 1.5 m: k=1 → ~4.37 km, k=4/3 → ~5.05 km.
    ElevationGrid flatLongGrid() =>
        gridFrom(nrows: 5, ncols: 450, elev: (r, c) => 200);

    test('4/3-earth refraction sees past the geometric (k=1) horizon', () {
      final grid = flatLongGrid();
      final obsLat = grid.latOfRow(2);
      final obsLon = grid.lonOfCol(2);
      const cfg1 = ViewshedConfig(
          maxRangeMeters: 12000, refractionCoefficient: 1.0);
      const cfg43 = ViewshedConfig(maxRangeMeters: 12000); // default 4/3

      final geometric = ViewshedComputer.compute(grid, obsLat, obsLon, config: cfg1);
      final radio = ViewshedComputer.compute(grid, obsLat, obsLon, config: cfg43);

      final probeLon = lonEastOf(obsLon, 4700); // between the two horizons
      expect(geometric.isVisibleAt(obsLat, probeLon), isFalse,
          reason: '4700 m is past the ~4.37 km geometric horizon');
      expect(radio.isVisibleAt(obsLat, probeLon), isTrue,
          reason: '4700 m is inside the ~5.05 km 4/3-earth horizon');

      // Refraction can only reveal more, never less.
      expect(radio.visibleCellCount,
          greaterThanOrEqualTo(geometric.visibleCellCount));
    });

    test('flat ground beyond the horizon is not visible; near ground is', () {
      final grid = flatLongGrid();
      final obsLat = grid.latOfRow(2);
      final obsLon = grid.lonOfCol(2);
      final result = ViewshedComputer.compute(
        grid, obsLat, obsLon,
        config: const ViewshedConfig(maxRangeMeters: 12000),
      );
      expect(result.isVisibleAt(obsLat, lonEastOf(obsLon, 3000)), isTrue);
      expect(result.isVisibleAt(obsLat, lonEastOf(obsLon, 8000)), isFalse);
    });
  });

  group('ViewshedComputer — occlusion', () {
    // Flat ground (elev 0) with a single tall wall column; observer to its west.
    ElevationGrid wallGrid() => gridFrom(
          nrows: 5,
          ncols: 40,
          elev: (r, c) => c == 20 ? 50.0 : 0.0,
        );
    ElevationGrid flatGrid() => gridFrom(nrows: 5, ncols: 40, elev: (r, c) => 0);

    test('a ridge casts a shadow that flat ground does not', () {
      final wall = wallGrid();
      final flat = flatGrid();
      final obsLat = wall.latOfRow(2);
      final obsLon = wall.lonOfCol(2);
      const cfg = ViewshedConfig(maxRangeMeters: 5000);

      final withWall = ViewshedComputer.compute(wall, obsLat, obsLon, config: cfg);
      final noWall = ViewshedComputer.compute(flat, obsLat, obsLon, config: cfg);

      final beforeWall = wall.lonOfCol(10);
      final wallTop = wall.lonOfCol(20);
      final behindWall = wall.lonOfCol(30);

      // Near side and the ridge crest are visible.
      expect(withWall.isVisibleAt(obsLat, beforeWall), isTrue);
      expect(withWall.isVisibleAt(obsLat, wallTop), isTrue);
      // Ground behind the ridge is shadowed...
      expect(withWall.isVisibleAt(obsLat, behindWall), isFalse);
      // ...but the very same cell is visible with no ridge in the way.
      expect(noWall.isVisibleAt(obsLat, behindWall), isTrue);
    });

    test('raising the observer above the ridge reveals the shadowed ground', () {
      final wall = wallGrid();
      final obsLat = wall.latOfRow(2);
      final obsLon = wall.lonOfCol(2);
      final behindWall = wall.lonOfCol(30);

      final low = ViewshedComputer.compute(
        wall, obsLat, obsLon,
        config: const ViewshedConfig(maxRangeMeters: 5000),
      );
      final high = ViewshedComputer.compute(
        wall, obsLat, obsLon,
        config: const ViewshedConfig(
            maxRangeMeters: 5000, observerHeightMeters: 200),
      );
      expect(low.isVisibleAt(obsLat, behindWall), isFalse);
      expect(high.isVisibleAt(obsLat, behindWall), isTrue);
    });
  });

  group('ViewshedComputer — degenerate inputs never crash', () {
    test('observer outside the DEM returns a typed status, no raster', () {
      final grid = gridFrom(nrows: 10, ncols: 10, elev: (r, c) => 100);
      final result = ViewshedComputer.compute(grid, 45, 45);
      expect(result.status, ViewshedStatus.observerOutOfCoverage);
      expect(result.hasResult, isFalse);
      expect(result.visible, isEmpty);
      expect(result.isVisibleAt(45, 45), isFalse);
    });

    test('result raster contains no NaN and the count matches the flags', () {
      final grid = gridFrom(
        nrows: 30,
        ncols: 30,
        elev: (r, c) => 100 + 5.0 * math.sin(c / 3.0) + 3.0 * r,
      );
      final result = ViewshedComputer.compute(
        grid, grid.latOfRow(15), grid.lonOfCol(15));
      expect(result.status, ViewshedStatus.computed);
      final ones = result.visible.where((v) => v == 1).length;
      expect(ones, result.visibleCellCount);
      expect(result.observerGroundElevation!.isFinite, isTrue);
      expect(result.observerEyeElevation!.isFinite, isTrue);
    });
  });
}
