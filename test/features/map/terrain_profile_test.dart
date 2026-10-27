import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/terrain_profile.dart';
import 'package:tritrack/localization/coordinate_projection.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

/// Task 11.207 — the total climb and total descent shown beside the distance.
///
/// **The number is a measurement, and every way it can be wrong is quiet.**
/// It is printed next to a distance that is exact, in a box, and nothing on
/// screen distinguishes a climb summed over every metre of the line from one
/// summed over a tenth of it. So the assertions here are about *exact*
/// answers over terrain whose answer is known by construction — a test that
/// only checks the total is positive would pass against the defect this whole
/// task exists to remove.
void main() {
  group('the run threshold ignores noise without losing a real climb', () {
    test('a monotone climb is reported in full, not rounded to the threshold',
        () {
      // Twenty 3 m steps: every single step is below the 10 m threshold, and
      // together they are a 60 m climb. **The obvious implementation — drop
      // any step smaller than the threshold — reports zero here**, which is
      // the reason the accumulation is written the way it is.
      final samples = [for (var i = 0; i <= 20; i++) 100.0 + i * 3.0];
      final relief = reliefOfProfile(samples, thresholdMeters: 10);
      expect(relief.ascentMeters, closeTo(60, 1e-9));
      expect(relief.descentMeters, closeTo(0, 1e-9));
    });

    test('a ramp up and back down gives both totals exactly', () {
      final samples = <double?>[
        for (var i = 0; i <= 10; i++) 100.0 + i * 20.0, // 100 → 300
        for (var i = 1; i <= 5; i++) 300.0 - i * 30.0, // 300 → 150
      ];
      final relief = reliefOfProfile(samples, thresholdMeters: 10);
      expect(relief.ascentMeters, closeTo(200, 1e-9));
      expect(relief.descentMeters, closeTo(150, 1e-9));
    });

    test('a wiggle smaller than the threshold is not counted', () {
      // Flat ground with ±4 m of DEM noise on it. Counting this would put a
      // climb on a walk across a car park.
      final samples = <double?>[
        1000, 1004, 998, 1002, 996, 1003, 1000, 997, 1001,
      ];
      final relief = reliefOfProfile(samples, thresholdMeters: 10);
      expect(relief.ascentMeters, 0);
      expect(relief.descentMeters, 0);
    });

    test('a reversal larger than the threshold is counted from the extreme',
        () {
      // Up 50, down 30, up 40. Every leg clears the threshold, so all three
      // are real and none of them is lost to the hysteresis.
      final samples = <double?>[0, 50, 20, 60];
      final relief = reliefOfProfile(samples, thresholdMeters: 10);
      expect(relief.ascentMeters, closeTo(90, 1e-9));
      expect(relief.descentMeters, closeTo(30, 1e-9));
    });

    test('a gap breaks the run rather than being credited as a climb', () {
      // The ground either side of missing terrain is unknown, so the 500 m
      // step across the hole is not a 500 m climb — it is no information.
      final samples = <double?>[100, 110, 120, null, 620, 630];
      final relief = reliefOfProfile(samples, thresholdMeters: 10);
      expect(relief.ascentMeters, closeTo(30, 1e-9),
          reason: '20 m before the hole and 10 m after it, and nothing '
              'credited across it');
      expect(relief.descentMeters, 0);
    });
  });

  group('the sampling is derived from the DEM and never coarser than it', () {
    /// A grid on the canonical DEM lattice whose elevation is a function of
    /// longitude alone, so bilinear interpolation reproduces it exactly
    /// wherever the function is linear.
    ElevationGrid gridOf(DemTileId id, double Function(double lon) elevation) {
      final spec = id.gridSpec();
      final data = Float64List(spec.ncols * spec.nrows);
      for (var r = 0; r < spec.nrows; r++) {
        for (var c = 0; c < spec.ncols; c++) {
          final lon = spec.xllCorner + (c + 0.5) * spec.cellSizeDegrees;
          data[r * spec.ncols + c] = elevation(lon);
        }
      }
      return ElevationGrid(
        ncols: spec.ncols,
        nrows: spec.nrows,
        xllCorner: spec.xllCorner,
        yllCorner: spec.yllCorner,
        cellSizeDegrees: spec.cellSizeDegrees,
        data: data,
      );
    }

    /// **A ramp up, a plateau, then a ramp down — with a known answer.**
    ///
    /// The plateau is what makes the answer *exact* rather than nearly right:
    /// bilinear interpolation cuts the corner at a fold, so a sharp apex
    /// between two samples would be read a little low and the totals would
    /// only be close. Over a plateau wider than the sample step, every sample
    /// in it reads exactly 400 m, and both endpoints sit inside a linear
    /// stretch where bilinear is exact.
    ///
    /// Rising 10000 m per degree from lon -111.70, flat at 400 m between
    /// -111.66 and -111.64, then falling 7500 m per degree.
    double tent(double lon) {
      if (lon <= -111.66) return (lon + 111.70) * 10000.0;
      if (lon <= -111.64) return 400.0;
      return 400.0 - (lon + 111.64) * 7500.0;
    }

    final grid = gridOf(const DemTileId(350, -1117), tent);
    // Both ends sit in a linear stretch: 200 m at the start, 250 m at the end.
    const from = GeoPoint(35.02, -111.68);
    const to = GeoPoint(35.02, -111.62);

    test('a synthetic DEM with a known answer gives it exactly', () {
      final profile = sampleTerrainProfile(from: from, to: to, grid: grid);
      expect(profile.elevations.first, closeTo(200, 1e-6));
      expect(profile.elevations.last, closeTo(250, 1e-6));
      expect(profile.ascentMeters, closeTo(200, 1e-6),
          reason: '200 m at the start up to a 400 m plateau');
      expect(profile.descentMeters, closeTo(150, 1e-6),
          reason: '400 m plateau down to 250 m at the end');
      expect(profile.hasGaps, isFalse);
    });

    test('the step is the DEM cell, at the finer of the two ground spacings',
        () {
      final profile = sampleTerrainProfile(from: from, to: to, grid: grid);
      final northSouth = grid.cellSizeDegrees * kMetersPerDegreeLatitude;
      final eastWest = northSouth * math.cos(35.02 * math.pi / 180);

      // The east-west spacing is the smaller one at this latitude, and it is
      // the one a step must not exceed: a line running east-west crosses DEM
      // posts that much apart.
      expect(
        demGroundSpacingMeters(grid, atLatitudeDeg: 35.02),
        closeTo(eastWest, 1e-6),
      );
      expect(
        profile.sampleSpacingMeters,
        lessThanOrEqualTo(eastWest),
        reason: 'the sampling must never be coarser than the DEM itself — '
            'every gully between two samples does not exist as far as the '
            'sum is concerned',
      );
      expect(profile.sampleSpacingMeters, greaterThan(eastWest / 2),
          reason: 'and finer than the grid buys nothing, so it should not be '
              'wildly finer either');
      expect(northSouth, greaterThan(eastWest));
    });

    test('the answer depends on the two points and the grid and nothing else',
        () {
      // **The same two points must always give the same answer** — the panel
      // it is shown in has a draggable height and the chart a variable width,
      // and neither is an input to this.
      final a = sampleTerrainProfile(from: from, to: to, grid: grid);
      final b = sampleTerrainProfile(from: from, to: to, grid: grid);
      expect(b.ascentMeters, a.ascentMeters);
      expect(b.descentMeters, a.descentMeters);
      expect(b.sampleCount, a.sampleCount);
    });

    test('a fixed sample count under-reports a long line, and by how much',
        () {
      // **The defect being removed, reproduced.** The chart used to take 41
      // samples whatever the line's length: a reading every 5 m on a 200 m
      // line and one every 500 m on a 20 km one. The terrain here is ridges
      // about 1.1 km apart, which the ~74 m DEM sampling resolves easily and
      // 41 points across 20 km cannot see at all — and the under-report is
      // silent, printed beside a distance that is exact.
      const ridgePeriodDeg = 0.008;
      double ridges(double lon) {
        final phase = ((lon + 112.0) / ridgePeriodDeg) % 1.0;
        return 400.0 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
      }

      // A grid wide enough for a 20 km line, on the canonical cell size.
      const cell = 0.1 / 124;
      const ncols = 500;
      const nrows = 124;
      final data = Float64List(ncols * nrows);
      for (var r = 0; r < nrows; r++) {
        for (var c = 0; c < ncols; c++) {
          data[r * ncols + c] = ridges(-112.0 + (c + 0.5) * cell);
        }
      }
      final wide = ElevationGrid(
        ncols: ncols,
        nrows: nrows,
        xllCorner: -112.0,
        yllCorner: 34.9,
        cellSizeDegrees: cell,
        data: data,
      );

      const west = GeoPoint(34.95, -111.98);
      const east = GeoPoint(34.95, -111.76); // ~20 km at this latitude
      final atDemSpacing =
          sampleTerrainProfile(from: west, to: east, grid: wide);

      final fixed = <double?>[
        for (var i = 0; i <= 40; i++)
          wide.elevationAt(
            west.latitude,
            west.longitude + (east.longitude - west.longitude) * i / 40,
          ),
      ];
      final fixedRelief = reliefOfProfile(fixed);

      printOnFailure(
        'line ${(atDemSpacing.distanceMeters / 1000).toStringAsFixed(1)} km: '
        'DEM-spaced ${atDemSpacing.ascentMeters.round()} m over '
        '${atDemSpacing.sampleCount} samples '
        '(${atDemSpacing.sampleSpacingMeters.round()} m apart); '
        '41-point ${fixedRelief.ascentMeters.round()} m '
        '(${(atDemSpacing.distanceMeters / 40).round()} m apart)',
      );

      // The ridges are 400 m peak to trough and there are ~18 of them across
      // this line, so the real climb is several thousand metres.
      expect(atDemSpacing.ascentMeters, greaterThan(8000),
          reason: 'sampled at the DEM cell, the ridges are all there');
      expect(
        fixedRelief.ascentMeters,
        lessThan(atDemSpacing.ascentMeters / 2),
        reason: 'this is the under-report: 41 points across 20 km step over '
            'most of the terrain, and nothing on screen would say so',
      );
    });
  });
}
