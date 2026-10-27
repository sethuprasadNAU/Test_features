import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import 'elevation_grid.dart';
import 'viewshed.dart';

/// Bundles the arguments for [ViewshedComputer.compute] into a single
/// message, since `compute()` (an isolate hop) requires exactly one argument.
/// [ElevationGrid]/[ViewshedConfig] hold only primitive/typed-data fields, so
/// they transfer across the isolate boundary without any extra work.
class ViewshedComputeRequest {
  const ViewshedComputeRequest({
    required this.grid,
    required this.observerLat,
    required this.observerLon,
    required this.config,
  });

  final ElevationGrid grid;
  final double observerLat;
  final double observerLon;
  final ViewshedConfig config;
}

ViewshedResult _computeInIsolate(ViewshedComputeRequest req) =>
    ViewshedComputer.compute(req.grid, req.observerLat, req.observerLon,
        config: req.config);

/// Runs [ViewshedComputer.compute] on a background isolate via [compute] —
/// a full raster sweep is CPU-bound and can take a noticeable fraction of a
/// second, and the doc explicitly calls for a progress indicator rather than
/// a frozen UI during this.
Future<ViewshedResult> computeViewshedInBackground(
  ElevationGrid grid,
  double observerLat,
  double observerLon, {
  ViewshedConfig config = const ViewshedConfig(),
}) {
  return compute(
    _computeInIsolate,
    ViewshedComputeRequest(
      grid: grid,
      observerLat: observerLat,
      observerLon: observerLon,
      config: config,
    ),
  );
}

/// Target resolution of one fine cell, in meters, once the DEM visibility
/// raster is upsampled for [buildViewshedBlurredField] — finer than this and
/// the vector boundary traced from it wouldn't gain any real sub-cell detail
/// worth the extra memory.
const double _targetFineCellMeters = 8.0;

/// Hard cap on [buildViewshedBlurredField]'s width/height, so upsampling a
/// coarse DEM over a huge extent can't blow up memory.
const int _maxFineDimension = 2048;

/// The integer upsample factor [buildViewshedBlurredField] uses to go from
/// `grid`'s native cell size to an ~8 m fine cell, capped so neither output
/// dimension exceeds [_maxFineDimension]. Exposed for tests, which need to
/// independently know the expected output size.
int viewshedUpsampleFactor(ElevationGrid grid) {
  final sourceCellMeters = grid.cellSizeDegrees * 111320.0;
  final target = (sourceCellMeters / _targetFineCellMeters).round();
  final targetClamped = target.clamp(1, 1 << 30);
  final capCols =
      grid.ncols > 0 ? (_maxFineDimension ~/ grid.ncols) : targetClamped;
  final capRows =
      grid.nrows > 0 ? (_maxFineDimension ~/ grid.nrows) : targetClamped;
  final cap = math.min(capCols, capRows);
  return math.min(targetClamped, math.max(cap, 1));
}

/// A continuous (not just 0/1) fine-resolution visibility field, upsampled
/// and blurred from a [ViewshedResult]'s binary raster — [renderViewshedPng]
/// thresholds this back to a flat fill.
///
/// [rows]/[cols] are `result.grid.nrows*factor`/`result.grid.ncols*factor`.
/// [factor] is [viewshedUpsampleFactor]'s output, exposed here so a caller
/// can report it (task 11.87: this is the number that silently falls toward
/// 1 — no smoothing at all — over a large computed extent, and nothing used
/// to say so).
class ViewshedBlurredField {
  const ViewshedBlurredField({
    required this.values,
    required this.rows,
    required this.cols,
    required this.factor,
  });

  /// Row-major, length `rows*cols`. In `[0.0, 1.0]`; `>= 0.5` reads as
  /// "inside" the visible region.
  final Float64List values;
  final int rows;
  final int cols;
  final int factor;

  double at(int row, int col) =>
      values[row.clamp(0, rows - 1) * cols + col.clamp(0, cols - 1)];
}

/// Builds [ViewshedBlurredField] for [result]: the binary visibility raster
/// upsampled by [viewshedUpsampleFactor] (targeting ~8 m rendered cells,
/// capped so the output stays within [_maxFineDimension] per side) via
/// bilinear interpolation of the 0/1 visibility values, then passed through
/// a single 3×3 box blur so the field varies continuously across a few fine
/// cells at the boundary instead of jumping straight from 0 to 1. When the
/// upsample factor collapses to 1 (a large computed extent — see [factor]
/// above), this is just the raw binary raster, cast to a continuous field
/// with no blur to apply.
///
/// A [result] with no computed raster ([ViewshedResult.hasResult] false)
/// yields an all-zero field at [result.grid]'s native size.
ViewshedBlurredField buildViewshedBlurredField(ViewshedResult result) {
  final grid = result.grid;
  final factor = viewshedUpsampleFactor(grid);

  double sourceVisibility(int row, int col) {
    if (row < 0 || row >= grid.nrows || col < 0 || col >= grid.ncols) return 0;
    return result.hasResult && result.visible[row * grid.ncols + col] == 1
        ? 1.0
        : 0.0;
  }

  if (factor <= 1) {
    final values = Float64List(grid.nrows * grid.ncols);
    for (var row = 0; row < grid.nrows; row++) {
      for (var col = 0; col < grid.ncols; col++) {
        values[row * grid.ncols + col] = sourceVisibility(row, col);
      }
    }
    return ViewshedBlurredField(
      values: values,
      rows: grid.nrows,
      cols: grid.ncols,
      factor: factor,
    );
  }

  final fineCols = grid.ncols * factor;
  final fineRows = grid.nrows * factor;

  // Bilinearly interpolate the binary visibility field (1.0/0.0) onto the
  // fine grid. Fine pixel centers are mapped back into the source cell-center
  // index space so a fine cell dead-center on a source cell reproduces that
  // source cell's value exactly.
  final fine = Float64List(fineRows * fineCols);
  for (var fr = 0; fr < fineRows; fr++) {
    final srcR = (fr + 0.5) / factor - 0.5;
    final r0 = srcR.floor();
    final dr = (srcR - r0).clamp(0.0, 1.0);
    final r0c = r0.clamp(0, grid.nrows - 1);
    final r1c = (r0 + 1).clamp(0, grid.nrows - 1);
    for (var fc = 0; fc < fineCols; fc++) {
      final srcC = (fc + 0.5) / factor - 0.5;
      final c0 = srcC.floor();
      final dc = (srcC - c0).clamp(0.0, 1.0);
      final c0c = c0.clamp(0, grid.ncols - 1);
      final c1c = (c0 + 1).clamp(0, grid.ncols - 1);

      final v00 = sourceVisibility(r0c, c0c);
      final v01 = sourceVisibility(r0c, c1c);
      final v10 = sourceVisibility(r1c, c0c);
      final v11 = sourceVisibility(r1c, c1c);

      final top = v00 * (1 - dc) + v01 * dc;
      final bottom = v10 * (1 - dc) + v11 * dc;
      fine[fr * fineCols + fc] = top * (1 - dr) + bottom * dr;
    }
  }

  double fineAt(int row, int col) {
    final rc = row.clamp(0, fineRows - 1);
    final cc = col.clamp(0, fineCols - 1);
    return fine[rc * fineCols + cc];
  }

  final blurred = Float64List(fineRows * fineCols);
  for (var row = 0; row < fineRows; row++) {
    for (var col = 0; col < fineCols; col++) {
      var sum = 0.0;
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          sum += fineAt(row + dr, col + dc);
        }
      }
      blurred[row * fineCols + col] = sum / 9.0;
    }
  }

  return ViewshedBlurredField(
    values: blurred,
    rows: fineRows,
    cols: fineCols,
    factor: factor,
  );
}

/// Renders a [ViewshedResult]'s visibility raster as a flat translucent
/// fill: cells at or past the 0.5 level of [buildViewshedBlurredField] get
/// [argbColor]'s RGB at full (255) alpha, everything else is fully
/// transparent. Any alpha bits in [argbColor] are ignored — overall
/// translucency is applied live by the caller via `OverlayImage.opacity`
/// instead of being baked into the PNG, so that slider spans the full 0→1
/// range rather than compounding with a pre-baked alpha.
///
/// Task 11.87 tried replacing this with a vector-drawn boundary, then a
/// vector-filled polygon (one `flutter_map` `PolygonLayer`, filling the same
/// loops the boundary was traced from). A real device reported the vector
/// fill as "extremely laggy" — consistent with `flutter_map`'s own
/// documented cost for a `Polygon` with a translucent fill (`color`'s alpha
/// not 0 or 1), compounded by re-projecting and re-painting several
/// thousand points every frame during pan/zoom, versus this: a bitmap baked
/// once and then GPU-sampled like any other texture. The vector-tracing
/// code (marching squares, simplification, Chaikin smoothing, polygon
/// grouping) was deleted once Michael confirmed the lag was gone and asked
/// for it to go — see `CLAUDE_DOCS/DEVELOPMENT_PLAN.md` task 11.87's three
/// addenda for the full history, including what a field screenshot found
/// wrong with that approach before performance ended it.
///
/// The rendered PNG covers the same geographic extent as `result.grid`
/// (ready for `flutter_map`'s `OverlayImageLayer` positioned at the grid's
/// lat/lon bounds) — only its pixel dimensions change, from
/// `grid.ncols`×`grid.nrows` to `grid.ncols*factor`×`grid.nrows*factor`
/// (see [buildViewshedBlurredField]/[viewshedUpsampleFactor]).
Uint8List renderViewshedPng(ViewshedResult result, {required int argbColor}) {
  final r = (argbColor >> 16) & 0xFF;
  final g = (argbColor >> 8) & 0xFF;
  final b = argbColor & 0xFF;

  final field = buildViewshedBlurredField(result);
  final image = img.Image(width: field.cols, height: field.rows, numChannels: 4);
  for (var row = 0; row < field.rows; row++) {
    for (var col = 0; col < field.cols; col++) {
      if (field.at(row, col) >= 0.5) {
        image.setPixelRgba(col, row, r, g, b, 255);
      } else {
        image.setPixelRgba(col, row, r, g, b, 0);
      }
    }
  }
  return img.encodePng(image);
}
