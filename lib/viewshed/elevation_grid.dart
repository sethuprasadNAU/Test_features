import 'dart:math' as math;
import 'dart:typed_data';

import '../localization/coordinate_projection.dart';

/// A georeferenced digital elevation model (DEM): a regular grid of terrain
/// elevations (meters) over a WGS84 lat/lon extent.
///
/// Storage/convention (matches the ESRI ASCII Grid standard, which is what
/// [DemAscii] parses):
/// - Cells are square in *degrees* (`cellSizeDegrees` for both axes). At a
///   given latitude a degree of longitude is shorter than a degree of
///   latitude; that anisotropy is handled downstream by projecting to meters
///   via [LocalTangentProjection], never here.
/// - Data is row-major with **row 0 = northmost**, columns increasing east —
///   the order elevation files are written in.
/// - [xllCorner]/[yllCorner] are the lon/lat of the lower-left (SW) corner of
///   the lower-left cell (not the cell center).
///
/// The DEM *source* (SRTM, USGS 3DEP, a regional provider, …) is intentionally
/// not modeled here: the app is provider-agnostic, so anything that can be
/// turned into an in-memory grid feeds the same engine.
class ElevationGrid {
  ElevationGrid({
    required this.ncols,
    required this.nrows,
    required this.xllCorner,
    required this.yllCorner,
    required this.cellSizeDegrees,
    required this.data,
    this.noDataValue = -9999.0,
  })  : assert(ncols > 0 && nrows > 0, 'grid must be non-empty'),
        assert(cellSizeDegrees > 0, 'cell size must be positive'),
        assert(data.length == ncols * nrows,
            'data length must equal ncols*nrows');

  final int ncols;
  final int nrows;

  /// Longitude of the SW corner of the SW-most cell.
  final double xllCorner;

  /// Latitude of the SW corner of the SW-most cell.
  final double yllCorner;

  /// Cell size in degrees (both axes).
  final double cellSizeDegrees;

  /// Elevations (m), row-major, row 0 = northmost. NaN or [noDataValue] mark
  /// gaps.
  final Float64List data;

  final double noDataValue;

  /// Longitude of the center of column [c].
  double lonOfCol(int c) => xllCorner + (c + 0.5) * cellSizeDegrees;

  /// Latitude of the center of row [r] (row 0 is the northmost).
  double latOfRow(int r) =>
      yllCorner + (nrows - r - 0.5) * cellSizeDegrees;

  double get west => xllCorner;
  double get east => xllCorner + ncols * cellSizeDegrees;
  double get south => yllCorner;
  double get north => yllCorner + nrows * cellSizeDegrees;

  bool _isNoData(double v) => v == noDataValue || v.isNaN;

  /// Raw elevation at integer cell [r],[c], or null if out of bounds / nodata.
  double? rawAt(int r, int c) {
    if (r < 0 || r >= nrows || c < 0 || c >= ncols) return null;
    final v = data[r * ncols + c];
    return _isNoData(v) ? null : v;
  }

  /// **How much of this grid actually carries an elevation**, 0 to 1.
  ///
  /// Task 11.142. A composed DEM is not all-or-nothing: a tile that failed to
  /// download is a hole, and [ViewshedComputer] treats a hole the same way it
  /// treats the edge of the world — the ray stops. So a viewshed over a grid
  /// with holes is a real answer about part of the terrain, and it is
  /// indistinguishable from an answer about all of it unless somebody
  /// measures. This is the measurement.
  ///
  /// Counted over the whole grid rather than sampled, because the caller uses
  /// it to decide whether to tell a person their prediction is incomplete and
  /// a sample can be wrong about that.
  double get dataCoverageFraction {
    if (data.isEmpty) return 0;
    return filledCellCount / data.length;
  }

  /// **How many cells actually carry an elevation.** The integer behind
  /// [dataCoverageFraction], because [DemTileStore] records this number in a
  /// tile's completeness record and a fraction re-derived from a stored
  /// double is a comparison that can go wrong at the edges.
  int get filledCellCount {
    var present = 0;
    for (final v in data) {
      if (!_isNoData(v)) present++;
    }
    return present;
  }

  /// Whether ([lat],[lon]) falls within the grid's geographic extent.
  bool contains(double lat, double lon) =>
      lon >= west && lon <= east && lat >= south && lat <= north;

  /// Bilinearly-interpolated elevation at ([lat],[lon]) in meters, or null if
  /// the point is outside coverage or surrounded by nodata.
  ///
  /// Used both to auto-populate an observation's `elevation` from the DEM and
  /// to sample terrain along a line of sight in [ViewshedComputer]. Points
  /// just past the cell-center band at the edges are clamped inward rather
  /// than returning null, so the very rim of the grid stays usable.
  double? elevationAt(double lat, double lon) {
    if (!contains(lat, lon)) return null;

    // Fractional cell indices where integer (r,c) lands on a cell center.
    final fc = (lon - lonOfCol(0)) / cellSizeDegrees;
    final fr = (latOfRow(0) - lat) / cellSizeDegrees;

    final c0 = fc.floor().clamp(0, ncols - 1);
    final r0 = fr.floor().clamp(0, nrows - 1);
    final c1 = (c0 + 1).clamp(0, ncols - 1);
    final r1 = (r0 + 1).clamp(0, nrows - 1);

    final dc = (fc - c0).clamp(0.0, 1.0);
    final dr = (fr - r0).clamp(0.0, 1.0);

    final v00 = rawAt(r0, c0);
    final v01 = rawAt(r0, c1);
    final v10 = rawAt(r1, c0);
    final v11 = rawAt(r1, c1);

    // If some corners are nodata, fall back to the average of the valid ones
    // (a small hole shouldn't blow a whole line of sight away). All nodata →
    // null.
    final present = [v00, v01, v10, v11].whereType<double>().toList();
    if (present.isEmpty) return null;
    if (present.length < 4) {
      return present.reduce((a, b) => a + b) / present.length;
    }

    final top = v00! * (1 - dc) + v01! * dc;
    final bottom = v10! * (1 - dc) + v11! * dc;
    return top * (1 - dr) + bottom * dr;
  }

  /// Returns a sub-grid covering the disc of [radiusMeters] around
  /// ([centerLat],[centerLon]), clipped to this grid's extent — the
  /// memory-safety crop the technical doc calls for ("crop the DEM to a
  /// radius around the observer before computing so a large project doesn't
  /// exhaust memory"). Returns null if the center is outside coverage.
  ElevationGrid? cropToRadius(
    double centerLat,
    double centerLon,
    double radiusMeters,
  ) {
    if (!contains(centerLat, centerLon)) return null;

    // Meters → degrees. Latitude is ~uniform; longitude shrinks with cos(lat).
    const metersPerDegLat = 111320.0;
    final dLat = radiusMeters / metersPerDegLat;
    final cosLat = math.cos(centerLat * math.pi / 180.0).abs();
    final dLon = radiusMeters / (metersPerDegLat * math.max(cosLat, 1e-6));

    final latN = math.min(centerLat + dLat, north - 1e-12);
    final latS = math.max(centerLat - dLat, south + 1e-12);
    final lonW = math.max(centerLon - dLon, west + 1e-12);
    final lonE = math.min(centerLon + dLon, east - 1e-12);

    int rowOf(double lat) =>
        ((latOfRow(0) - lat) / cellSizeDegrees).floor().clamp(0, nrows - 1);
    int colOf(double lon) =>
        ((lon - lonOfCol(0)) / cellSizeDegrees).floor().clamp(0, ncols - 1);

    final rowStart = rowOf(latN); // north → smaller row index
    final rowEnd = rowOf(latS);
    final colStart = colOf(lonW);
    final colEnd = colOf(lonE);

    final newRows = rowEnd - rowStart + 1;
    final newCols = colEnd - colStart + 1;
    final sub = Float64List(newRows * newCols);
    for (var r = 0; r < newRows; r++) {
      final srcRow = rowStart + r;
      for (var c = 0; c < newCols; c++) {
        sub[r * newCols + c] = data[srcRow * ncols + (colStart + c)];
      }
    }

    return ElevationGrid(
      ncols: newCols,
      nrows: newRows,
      xllCorner: xllCorner + colStart * cellSizeDegrees,
      yllCorner: yllCorner + (nrows - 1 - rowEnd) * cellSizeDegrees,
      cellSizeDegrees: cellSizeDegrees,
      data: sub,
      noDataValue: noDataValue,
    );
  }
}
