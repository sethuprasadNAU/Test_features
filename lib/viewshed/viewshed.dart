import 'dart:math' as math;
import 'dart:typed_data';

import '../localization/coordinate_projection.dart';
import 'elevation_grid.dart';

/// Tuning for a viewshed computation. Sensible defaults are baked in; the doc
/// left the numerics open, so every choice here is explicit and documented.
class ViewshedConfig {
  const ViewshedConfig({
    this.maxRangeMeters = 35000.0,
    this.observerHeightMeters = 1.7,
    this.targetHeightMeters = 0.0,
    this.refractionCoefficient = 4.0 / 3.0,
    this.earthRadiusMeters = LocalTangentProjection.earthRadiusMeters,
    this.rayStepFraction = 0.5,
  })  : assert(maxRangeMeters > 0),
        assert(refractionCoefficient > 0),
        assert(rayStepFraction > 0 && rayStepFraction <= 1);

  /// Maximum reception range (m). A cell is only ever "visible" if it's within
  /// this radius: these VHF transmitters are weak, and the user usually knows
  /// their practical reception distance in the current conditions, so range —
  /// not just line-of-sight — bounds the result. Doubles as the DEM crop
  /// radius for memory safety.
  ///
  /// **35 km, task 11.87** — Michael's field report of trackers picking up a
  /// VHF collar at around 35 km in good conditions from elevation (mountain
  /// top down into a valley), the same figure behind the map's 40 km bearing-
  /// drag ceiling (`_maxBearingRangeMeters`). It is deliberately *not* padded
  /// with that control's extra margin: the drag ceiling is a display bound
  /// (how far someone may usefully draw a line of possible bearing), while
  /// this bounds an actual physical prediction ("could I have heard the
  /// collar from here"), so the honest number is the reported range itself,
  /// not twice it.
  ///
  /// This was 10 km before task 11.87, chosen without a field measurement
  /// behind it. Raising it costs real compute — the line-of-sight sweep is
  /// O(range²) — measured on a desktop (M-series Mac, not a phone) with a
  /// synthetic DEM at this app's fixed 90 m cell size
  /// ([kDemCellSizeMeters]): 10 km ≈ 41 ms, 35 km ≈ 344 ms, 40 km ≈ 454 ms.
  /// A phone is slower than the desktop this was measured on, but the
  /// computation already runs off the UI thread ([computeViewshedInBackground])
  /// behind a progress bar and a 20-second timeout with a clear failure
  /// message, so a few hundred milliseconds to a couple of seconds is a
  /// visible wait, not a stall or a crash.
  final double maxRangeMeters;

  /// Height of the receiver/antenna above ground at the observer (m). Added to
  /// the DEM ground elevation.
  ///
  /// **Not wired to any observation's `altitude_agl`.** This comment used to
  /// say it was; task 11.67 measured it and it never has been — the only
  /// caller is the Main Map's tap-to-predict, which reads a slider on that
  /// screen (0–122 m, default 1.7). A viewshed is asked about an arbitrary
  /// point on the map, not about a stored record, so there is no observation
  /// to read a height from. 1.7 m is a held-antenna default.
  final double observerHeightMeters;

  /// Height added to each target cell's terrain for the visibility test (m).
  /// A collared animal's transmitter sits ~ground level, so 0 by default.
  final double targetHeightMeters;

  /// Atmospheric-refraction coefficient k. The line of sight is tested against
  /// an *effective* earth radius k·R, which bends the horizon outward. k = 4/3
  /// is the standard value for VHF/UHF radio propagation (the doc calls this
  /// "signal propagation modeling"); k = 1 is pure geometric/optical LOS.
  final double refractionCoefficient;

  /// Mean earth radius (m) before the refraction factor.
  final double earthRadiusMeters;

  /// Ray-marching step as a fraction of a cell's ground size. Smaller =
  /// more accurate terrain profile, slower.
  final double rayStepFraction;

  /// Effective earth radius (m) used for the curvature drop.
  double get effectiveEarthRadius => refractionCoefficient * earthRadiusMeters;
}

/// Outcome of a viewshed attempt. Degenerate inputs never crash or emit NaN —
/// they set a status and return an empty visibility raster, so the UI can show
/// a clear message (the doc: "handle taps outside downloaded DEM coverage
/// gracefully — clear message, not a crash").
enum ViewshedStatus {
  /// A visibility raster was produced.
  computed,

  /// The observer point is outside the DEM's coverage.
  observerOutOfCoverage,

  /// The DEM had no usable elevation at the observer.
  noElevationData,
}

/// The result of a viewshed: a visible/not-visible raster aligned to [grid]
/// (the cropped DEM window actually used), plus the observer's resolved
/// position and elevation and a few summary stats.
class ViewshedResult {
  ViewshedResult({
    required this.status,
    required this.grid,
    required this.visible,
    this.observerRow = -1,
    this.observerCol = -1,
    this.observerGroundElevation,
    this.observerEyeElevation,
    this.visibleCellCount = 0,
  });

  /// A refused/empty result of a given [status] (no raster).
  factory ViewshedResult.empty(ViewshedStatus status, ElevationGrid grid) =>
      ViewshedResult(
        status: status,
        grid: grid,
        visible: Uint8List(0),
      );

  final ViewshedStatus status;

  /// The (cropped) DEM the raster is aligned to. Row/col indexing and
  /// georeferencing match this grid exactly, so the UI can place the overlay.
  final ElevationGrid grid;

  /// Row-major visibility flags (1 = visible), length `grid.nrows*grid.ncols`,
  /// or empty when [status] isn't [ViewshedStatus.computed].
  final Uint8List visible;

  final int observerRow;
  final int observerCol;

  /// DEM ground elevation at the observer (m).
  final double? observerGroundElevation;

  /// Observer eye/antenna elevation = ground + observer height (m).
  final double? observerEyeElevation;

  final int visibleCellCount;

  bool get hasResult => status == ViewshedStatus.computed;

  /// **How much of the terrain this answer was actually worked out from**,
  /// 0 to 1 — task 11.142.
  ///
  /// A DEM tile that failed to download leaves a hole, and the sweep above
  /// stops a ray at a hole exactly as it stops one at the edge of coverage.
  /// Everything past that hole is therefore reported *not visible*, which is
  /// the same raster a hill would produce. **A viewshed drawn from part of the
  /// terrain is still useful to somebody who knows that is what it is; one
  /// presented as complete is a claim about where an animal could be heard
  /// from.** So the number travels with the result and the screen says so.
  ///
  /// 1.0 means every cell of [grid] carried an elevation. Nothing here decides
  /// what counts as "enough" — that is the caller's sentence to write.
  double get terrainCoverageFraction => grid.dataCoverageFraction;

  /// True when [grid] has at least one cell with no elevation in it, so this
  /// answer is about part of the terrain rather than all of it.
  bool get terrainIsIncomplete => terrainCoverageFraction < 1.0;

  double get visibleFraction {
    if (visible.isEmpty) return 0;
    return visibleCellCount / visible.length;
  }

  /// Whether the cell at ([lat],[lon]) is inside the computed area and visible.
  bool isVisibleAt(double lat, double lon) {
    if (!hasResult || !grid.contains(lat, lon)) return false;
    final fc = (lon - grid.lonOfCol(0)) / grid.cellSizeDegrees;
    final fr = (grid.latOfRow(0) - lat) / grid.cellSizeDegrees;
    final c = fc.round().clamp(0, grid.ncols - 1);
    final r = fr.round().clamp(0, grid.nrows - 1);
    return visible[r * grid.ncols + c] == 1;
  }
}

/// Computes a terrain line-of-sight viewshed from an observer point.
///
/// Method: a **radial line-of-sight sweep**. One ray is cast from the observer
/// to every cell on the perimeter of the (cropped) DEM window; adjacent
/// perimeter cells are ≤1 cell apart, so every interior cell is crossed by at
/// least one ray. Marching outward along a ray, we track the greatest vertical
/// angle any nearer terrain has subtended; a cell is visible iff its own
/// (curvature-corrected, target-height-raised) angle clears that running
/// maximum. This is the standard "real-time" viewshed — O(radius²), exact
/// along each ray — and matches the doc's "coarse = fast, sufficient for
/// signal propagation modeling."
///
/// Vertical angles use the effective-earth curvature drop d²/(2·kR): a cell at
/// ground distance d has its elevation effectively lowered by that amount
/// relative to the observer's tangent plane, so distant terrain correctly
/// falls below the horizon.
abstract final class ViewshedComputer {
  static ViewshedResult compute(
    ElevationGrid fullGrid,
    double observerLat,
    double observerLon, {
    ViewshedConfig config = const ViewshedConfig(),
  }) {
    if (!fullGrid.contains(observerLat, observerLon)) {
      return ViewshedResult.empty(
          ViewshedStatus.observerOutOfCoverage, fullGrid);
    }

    final grid =
        fullGrid.cropToRadius(observerLat, observerLon, config.maxRangeMeters) ??
            fullGrid;

    final groundAtObserver = grid.elevationAt(observerLat, observerLon);
    if (groundAtObserver == null) {
      return ViewshedResult.empty(ViewshedStatus.noElevationData, grid);
    }
    final observerEye = groundAtObserver + config.observerHeightMeters;

    final projection = LocalTangentProjection(
      GeoPoint(observerLat, observerLon),
    );

    // Observer cell (nearest) in the cropped grid.
    final obsFc =
        (observerLon - grid.lonOfCol(0)) / grid.cellSizeDegrees;
    final obsFr =
        (grid.latOfRow(0) - observerLat) / grid.cellSizeDegrees;
    final obsCol = obsFc.round().clamp(0, grid.ncols - 1);
    final obsRow = obsFr.round().clamp(0, grid.nrows - 1);

    final visible = Uint8List(grid.nrows * grid.ncols);
    visible[obsRow * grid.ncols + obsCol] = 1; // observer sees itself
    var visibleCount = 1;

    // Ground size of one cell (m) = R·Δθ, for the ray-march step.
    final cellMeters = config.earthRadiusMeters *
        grid.cellSizeDegrees *
        math.pi /
        180.0;
    final stepMeters = math.max(cellMeters * config.rayStepFraction, 1.0);
    final curvatureDenom = 2.0 * config.effectiveEarthRadius;

    // Collect the perimeter cells of the cropped grid.
    void sweepTo(int pr, int pc) {
      final targetLat = grid.latOfRow(pr);
      final targetLon = grid.lonOfCol(pc);
      final target = projection.forward(GeoPoint(targetLat, targetLon));
      final rayLen = math.sqrt(target.east * target.east +
          target.north * target.north);
      if (rayLen < 1e-6) return;

      final dirE = target.east / rayLen;
      final dirN = target.north / rayLen;
      final reach = math.min(rayLen, config.maxRangeMeters);
      final steps = (reach / stepMeters).ceil();

      var maxAngle = double.negativeInfinity;
      for (var i = 1; i <= steps; i++) {
        final d = math.min(i * stepMeters, reach);
        final e = dirE * d;
        final n = dirN * d;
        final geo = projection.inverse(PlanarPoint(e, n));
        final terrain = grid.elevationAt(geo.latitude, geo.longitude);
        if (terrain == null) {
          // Ran off coverage / into a hole: nearer terrain still occludes, but
          // we can't test this sample — stop extending this ray.
          break;
        }

        final drop = (d * d) / curvatureDenom; // effective-earth curvature
        final terrainAngle = (terrain - drop - observerEye) / d;
        final targetAngle =
            (terrain + config.targetHeightMeters - drop - observerEye) / d;

        // Mark the nearest cell to this sample visible if it clears the
        // horizon established by nearer terrain and is within range.
        final fc = (geo.longitude - grid.lonOfCol(0)) / grid.cellSizeDegrees;
        final fr = (grid.latOfRow(0) - geo.latitude) / grid.cellSizeDegrees;
        final c = fc.round().clamp(0, grid.ncols - 1);
        final r = fr.round().clamp(0, grid.nrows - 1);
        final idx = r * grid.ncols + c;

        if (d <= config.maxRangeMeters &&
            targetAngle >= maxAngle &&
            visible[idx] == 0) {
          visible[idx] = 1;
          visibleCount++;
        }

        if (terrainAngle > maxAngle) maxAngle = terrainAngle;
      }
    }

    for (var c = 0; c < grid.ncols; c++) {
      sweepTo(0, c); // north edge
      sweepTo(grid.nrows - 1, c); // south edge
    }
    for (var r = 0; r < grid.nrows; r++) {
      sweepTo(r, 0); // west edge
      sweepTo(r, grid.ncols - 1); // east edge
    }

    return ViewshedResult(
      status: ViewshedStatus.computed,
      grid: grid,
      visible: visible,
      observerRow: obsRow,
      observerCol: obsCol,
      observerGroundElevation: groundAtObserver,
      observerEyeElevation: observerEye,
      visibleCellCount: visibleCount,
    );
  }
}
