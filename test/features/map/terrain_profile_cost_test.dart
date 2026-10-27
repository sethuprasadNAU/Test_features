import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/terrain_profile.dart';
import 'package:tritrack/localization/coordinate_projection.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

/// Task 11.207 — **the measurement that decides whether the sampling needs a
/// cap, taken before deciding rather than after.**
///
/// Sampling at the DEM's own spacing means the number of samples grows with
/// the line, and the obvious defensive move is to cap it. A cap is also the
/// thing this whole feature exists to avoid: a total silently computed from a
/// coarser line than the one drawn is the under-report, arriving as a
/// performance decision instead of an accident. So the cap does not go in on
/// speculation — this measures the worst case first, and **if one is ever
/// added it has to be visible on screen.**
///
/// **What this asserts and what it only prints.** The sample count is exact
/// arithmetic and is asserted. The elapsed time is a measurement on whatever
/// machine is running the suite and is **printed, never thresholded** — a
/// timing gate at a host's noise floor is a Gate C blocker three re-runs
/// cannot reproduce (the standing rule from task 11.90). The number in the
/// report came from this printout.
void main() {
  /// A grid on the canonical ~90 m DEM cell size covering a whole degree of
  /// longitude — larger than any single downloaded region this app composes,
  /// and enough to hold the longest line two taps can make inside it.
  ElevationGrid wideGrid() {
    const cell = 0.1 / 124;
    const ncols = 1240; // 1.0° of longitude
    const nrows = 248; // 0.2° of latitude
    final data = Float64List(ncols * nrows);
    for (var r = 0; r < nrows; r++) {
      for (var c = 0; c < ncols; c++) {
        // Something with real relief in it, so the run accumulation does
        // work rather than short-circuiting on flat ground.
        data[r * ncols + c] = 1000 + (c % 37) * 11.0 - (r % 13) * 7.0;
      }
    }
    return ElevationGrid(
      ncols: ncols,
      nrows: nrows,
      xllCorner: -112.0,
      yllCorner: 34.9,
      cellSizeDegrees: cell,
      data: data,
    );
  }

  test('a 20 km line — an ordinary long measure — is a few hundred samples',
      () {
    final grid = wideGrid();
    // One run first: the suite is JIT and the app is AOT, so a cold first
    // call measures the compiler rather than the sampling.
    sampleTerrainProfile(
      from: const GeoPoint(34.95, -111.98),
      to: const GeoPoint(34.95, -111.96),
      grid: grid,
    );
    final watch = Stopwatch()..start();
    final profile = sampleTerrainProfile(
      from: const GeoPoint(34.95, -111.98),
      to: const GeoPoint(34.95, -111.76),
      grid: grid,
    );
    watch.stop();

    // ignore: avoid_print
    print('terrain profile: ${(profile.distanceMeters / 1000).round()} km, '
        '${profile.sampleCount} samples '
        '(${profile.sampleSpacingMeters.round()} m apart), '
        '${watch.elapsedMicroseconds} microseconds');

    expect(profile.sampleCount, greaterThan(250));
    expect(profile.sampleCount, lessThan(300));
  });

  test('the largest line that fits in a degree of longitude still is not '
      'worth capping', () {
    // ~91 km at this latitude: a line across the whole of a large downloaded
    // area, which is well beyond what anybody measures by tapping twice.
    final grid = wideGrid();
    // One run first: the suite is JIT and the app is AOT, so a cold first
    // call measures the compiler rather than the sampling.
    sampleTerrainProfile(
      from: const GeoPoint(34.95, -111.98),
      to: const GeoPoint(34.95, -111.96),
      grid: grid,
    );
    final watch = Stopwatch()..start();
    final profile = sampleTerrainProfile(
      from: const GeoPoint(34.95, -111.99),
      to: const GeoPoint(34.95, -111.01),
      grid: grid,
    );
    watch.stop();

    // ignore: avoid_print
    print('terrain profile: ${(profile.distanceMeters / 1000).round()} km, '
        '${profile.sampleCount} samples '
        '(${profile.sampleSpacingMeters.round()} m apart), '
        '${watch.elapsedMicroseconds} microseconds');

    expect(profile.sampleCount, greaterThan(1000));
    expect(
      profile.sampleCount,
      lessThan(1500),
      reason: 'the sample count is the thing a cap would bound, and it is '
          'this — a few thousand bilinear lookups. If this ever grows by an '
          'order of magnitude, re-take the timing beside it before reaching '
          'for a cap, and if a cap goes in, the panel has to say so.',
    );
  });
}
