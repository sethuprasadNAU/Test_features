import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tritrack/viewshed/elevation_grid.dart';
import 'package:tritrack/viewshed/viewshed.dart';
import 'package:tritrack/viewshed/viewshed_overlay.dart';

ElevationGrid flatGrid({int n = 10}) => ElevationGrid(
      ncols: n,
      nrows: n,
      xllCorner: -111.7,
      yllCorner: 35.1,
      cellSizeDegrees: 30.0 / 111320.0,
      data: Float64List(n * n)..fillRange(0, n * n, 100.0),
    );

void main() {
  group('buildViewshedBlurredField', () {
    test('visible cells read >= 0.5, invisible cells read < 0.5', () {
      final grid = flatGrid();
      final result = ViewshedComputer.compute(
        grid, grid.latOfRow(5), grid.lonOfCol(5),
        config: const ViewshedConfig(maxRangeMeters: 100),
      );
      expect(result.hasResult, isTrue);

      final resultGrid = result.grid;
      final factor = viewshedUpsampleFactor(resultGrid);
      expect(factor, greaterThan(1)); // sanity: this test grid should upsample

      final field = buildViewshedBlurredField(result);
      expect(field.rows, resultGrid.nrows * factor);
      expect(field.cols, resultGrid.ncols * factor);
      expect(field.factor, factor);

      // The observer's own cell is always visible.
      final fineCol = result.observerCol * factor + factor ~/ 2;
      final fineRow = result.observerRow * factor + factor ~/ 2;
      expect(field.at(fineRow, fineCol), greaterThanOrEqualTo(0.5));

      // A cell clearly outside the (small, range-limited) visible region is
      // not.
      expect(field.at(0, 0), lessThan(0.5));
    });

    test('an empty (refused) result yields an all-below-0.5 field, not a '
        'crash', () {
      final grid = flatGrid();
      final result = ViewshedComputer.compute(grid, 0, 0); // outside coverage
      expect(result.hasResult, isFalse);

      final field = buildViewshedBlurredField(result);
      // hasResult is false, so no visible cells exist to drive upsampling
      // decisions either way; either dimension convention is fine here as
      // long as nothing reads as "inside".
      expect(field.rows % grid.nrows, 0);
      expect(field.cols % grid.ncols, 0);
      for (var r = 0; r < field.rows; r++) {
        for (var c = 0; c < field.cols; c++) {
          expect(field.at(r, c), lessThan(0.5));
        }
      }
    });
  });

  group('renderViewshedPng', () {
    test('visible cells get the given color; the rest are transparent', () {
      final grid = flatGrid();
      final result = ViewshedComputer.compute(
        grid, grid.latOfRow(5), grid.lonOfCol(5),
        config: const ViewshedConfig(maxRangeMeters: 100),
      );
      expect(result.hasResult, isTrue);

      const argb = 0x4D966EDC; // ~30% alpha, matches the app's viewshed token
      final png = renderViewshedPng(result, argbColor: argb);
      final decoded = img.decodePng(png)!;

      // The PNG is upsampled for a smoother baked edge: dimensions are an
      // integer multiple of the (possibly range-cropped) result grid, not
      // equal to it.
      final resultGrid = result.grid;
      final factor = viewshedUpsampleFactor(resultGrid);
      expect(factor, greaterThan(1)); // sanity: this test grid should upsample
      expect(decoded.width, resultGrid.ncols * factor);
      expect(decoded.height, resultGrid.nrows * factor);

      // The observer's own cell is always visible, so its fine-grid center
      // pixel gets the fill color at full alpha.
      final fineCol = result.observerCol * factor + factor ~/ 2;
      final fineRow = result.observerRow * factor + factor ~/ 2;
      final ownPixel = decoded.getPixel(fineCol, fineRow);
      // Alpha is always baked at full opacity — overall translucency is
      // applied live via OverlayImage.opacity instead, so this stays 255
      // regardless of the ~30% alpha embedded in argb.
      expect(ownPixel.a, 255);
      expect(ownPixel.r, (argb >> 16) & 0xFF);
      expect(ownPixel.g, (argb >> 8) & 0xFF);
      expect(ownPixel.b, argb & 0xFF);

      // A pixel clearly outside the (small, range-limited) visible region is
      // transparent.
      final outsidePixel = decoded.getPixel(0, 0);
      expect(outsidePixel.a, 0);
    });

    test('an empty (refused) result renders as fully transparent, not a crash', () {
      final grid = flatGrid();
      final result = ViewshedComputer.compute(grid, 0, 0); // outside coverage
      expect(result.hasResult, isFalse);

      final png = renderViewshedPng(result, argbColor: 0x4D966EDC);
      final decoded = img.decodePng(png)!;
      // hasResult is false, so no visible cells exist to drive upsampling
      // decisions either way; either dimension convention is fine here as
      // long as everything is transparent. Just assert it's a multiple of
      // the source grid (as the factor formula guarantees) and fully blank.
      expect(decoded.width % grid.ncols, 0);
      expect(decoded.height % grid.nrows, 0);
      for (final pixel in decoded) {
        expect(pixel.a, 0);
      }
    });
  });

  group('computeViewshedInBackground', () {
    test('matches a direct (in-process) compute call', () async {
      final grid = flatGrid();
      final lat = grid.latOfRow(5);
      final lon = grid.lonOfCol(5);

      final direct = ViewshedComputer.compute(grid, lat, lon);
      final backgrounded = await computeViewshedInBackground(grid, lat, lon);

      expect(backgrounded.status, direct.status);
      expect(backgrounded.visibleCellCount, direct.visibleCellCount);
      expect(backgrounded.visible, direct.visible);
    });
  });
}
