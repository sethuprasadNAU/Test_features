import 'dart:math' as math;

import '../../../localization/coordinate_projection.dart';
import '../../../viewshed/dem_tile_store.dart' show kMetersPerDegreeLatitude;
import '../../../viewshed/elevation_grid.dart';
import 'geo_math.dart';

/// The terrain along a straight line between two points: the elevations the
/// chart draws, and the total climb and total descent along it.
///
/// **Total climb answers "how hard is this walk", so it is the sum of every
/// rise and every fall along the line — not the net change between the ends.**
/// A walk that ends where it started has a net change of zero and can still be
/// a hard day.
///
/// ## Why the sampling is the part that decides whether the number is true
///
/// A sum of rises is only ever as complete as the samples it is made of.
/// Every gully between two samples **does not exist** as far as the sum is
/// concerned, so a profile sampled at a fixed number of points reports a
/// smaller and smaller fraction of the real climb as the line gets longer:
/// the chart's old fixed 41 points is a reading every 5 m on a 200 m line and
/// **one every 500 m on a 20 km line**, printed beside a distance that is
/// exact. The under-report is silent and it is worst exactly where the number
/// matters most.
///
/// So the sampling here is **derived from the DEM's own grid** — see
/// [demGroundSpacingMeters] — and is never coarser than it. The opposite
/// worry is small and it is worth saying so, because it is the reason this
/// needs no smoothing pass: [ElevationGrid.elevationAt] is **bilinear**, so
/// the surface between DEM posts is a smooth interpolation rather than a
/// jittery one, and over-sampling it cannot manufacture climb the way
/// over-sampling a GPS track does. **The rule is one-sided: never coarser
/// than the grid.** Anything finer is merely wasted work.
class TerrainProfile {
  const TerrainProfile({
    required this.elevations,
    required this.distanceMeters,
    required this.bearingDeg,
    required this.sampleSpacingMeters,
    required this.ascentMeters,
    required this.descentMeters,
    required this.hasGaps,
  });

  /// Elevation (m) at each sample from the start point to the end point
  /// inclusive, evenly spaced along the line. `null` where the DEM has no
  /// value — a tile that was never downloaded, or a no-data cell.
  ///
  /// **The chart draws this same list**, so the picture and the totals are one
  /// measurement rather than two that can disagree.
  final List<double?> elevations;

  final double distanceMeters;
  final double bearingDeg;

  /// The ground distance between two consecutive samples, in meters.
  final double sampleSpacingMeters;

  /// Total climb: every rise along the line, added up.
  final double ascentMeters;

  /// Total descent: every fall along the line, added up.
  final double descentMeters;

  /// Whether any sample had no elevation. When true the totals are for the
  /// parts of the line that do have elevation, and the panel says so — a
  /// total quietly summed over half a line is the under-reporting defect this
  /// class exists to prevent, arriving by a different road.
  final bool hasGaps;

  /// Whether any sample at all carried an elevation.
  bool get hasAnyData => elevations.any((e) => e != null);

  /// How many samples the line was measured at.
  int get sampleCount => elevations.length;
}

/// **The smallest run of same-direction change that is counted as real.**
///
/// This is **a field judgement made against the source data's accuracy
/// specification, not a value derived from it.** The DEM is sampled from
/// terrarium terrain tiles, whose global coverage is chiefly SRTM. SRTM's
/// specified vertical accuracy is 16 m absolute and **10 m relative**, both
/// at 90% confidence; the relative figure is the one that matters here,
/// because a climb is a *difference* between two nearby elevations and a
/// shared bias cancels out of a difference. A run smaller than 10 m cannot,
/// in principle, be told apart from the source's own error.
///
/// **Michael chose 5 m anyway, 2026-09-09, having read that cost.** He walks
/// country with rolling eight-metre knolls, and at 10 m every one of them
/// reported as flat — a real feature of the ground the app was silently
/// discarding. At 5 m those knolls are counted. The trade he accepted: a
/// climb between 5 m and 10 m may now include some of the DEM's own noise
/// rather than being wholly real terrain, so a total built from many such
/// small runs is somewhat less trustworthy than it was at the cautious
/// value. Counting every wiggle (threshold near zero) would report climb
/// that is not there on every walk, with no way for a reader to tell which
/// kind of number they are looking at — 5 m is a point between that failure
/// and the one 10 m had.
///
/// If this is moved again, say what it now catches and what it now adds, the
/// way this paragraph does — a number with a citation and no reason, or a
/// reason and no citation, is fine; a number with neither is not.
const double kTerrainReliefThresholdMeters = 5.0;

/// **The DEM's own ground spacing at [atLatitudeDeg], in meters** — the
/// coarsest step [sampleTerrainProfile] is allowed to take.
///
/// [ElevationGrid.cellSizeDegrees] is square in *degrees*, so on the ground a
/// cell is `cellSize × 111320 m` north-south and that times `cos(latitude)`
/// east-west: at 60° north the posts along an east-west line are half as far
/// apart as the posts along a north-south one. The smaller of the two is
/// returned, because a step that is fine enough for the north-south spacing
/// would step straight over posts on an east-west line.
///
/// **Derived from the grid rather than typed as a number.** The app's DEM is
/// ~90 m today (`kDemCellSizeMeters`, snapped to divide a 0.1° tile evenly);
/// the terrarium tiles it is sampled *from* are ~38 m/px at z12, which is a
/// fact about the source and not about the grid this walks over. Reading it
/// off the grid means the sampling follows the store if that ever changes.
double demGroundSpacingMeters(
  ElevationGrid grid, {
  required double atLatitudeDeg,
}) {
  final northSouth = grid.cellSizeDegrees * kMetersPerDegreeLatitude;
  final cosLat = math.cos(atLatitudeDeg.abs() * math.pi / 180.0).abs();
  // Guard the poles: cos → 0 would make the step zero and the sample count
  // unbounded. 0.01 is ~89.4° latitude, past any field site this app has.
  final eastWest = northSouth * math.max(cosLat, 0.01);
  return math.min(northSouth, eastWest);
}

/// Samples the terrain between [from] and [to] on [grid] and sums the climb
/// and the descent along it.
///
/// The step is [demGroundSpacingMeters] at whichever end is nearer a pole (the
/// finer of the two, so the step is never coarser than the grid anywhere along
/// the line), and the sample count is `ceil(distance / step) + 1`.
///
/// **The result depends on the two points and the grid and on nothing else** —
/// not on the height of the panel it will be shown in, not on the width of the
/// chart that draws it. Two people holding phones of different sizes over the
/// same two points get the same number, which is the least a number printed
/// next to an exact distance owes its reader.
///
/// **No sample cap, and that is a measurement rather than an oversight.** At
/// the DEM's ~90 m spacing a 20 km line is **274 samples, sampled and summed
/// in about 1 ms**, and a 89 km line — longer than any single downloaded area
/// this app composes — is **1,215 samples in about 5 ms**, both measured in
/// `test/features/map/terrain_profile_cost_test.dart` on a development
/// machine. Nothing there asked for a cap. A cap would also have to be
/// **visible on screen**: a total silently computed from a coarser line than
/// the one drawn is exactly the defect above, arriving as a performance
/// decision instead of an accident.
TerrainProfile sampleTerrainProfile({
  required GeoPoint from,
  required GeoPoint to,
  required ElevationGrid grid,
  double thresholdMeters = kTerrainReliefThresholdMeters,
}) {
  final line = distanceAndBearing(from, to);
  final spacing = demGroundSpacingMeters(
    grid,
    atLatitudeDeg: math.max(from.latitude.abs(), to.latitude.abs()),
  );
  // At least one interval, so a zero-length line still has two ends to draw.
  final intervals = math.max(1, (line.distanceMeters / spacing).ceil());

  final elevations = <double?>[];
  for (var i = 0; i <= intervals; i++) {
    final p = i == 0
        ? from
        : i == intervals
            ? to
            : destinationPoint(
                from,
                line.bearingDeg,
                line.distanceMeters * i / intervals,
              );
    elevations.add(grid.elevationAt(p.latitude, p.longitude));
  }

  final relief = reliefOfProfile(elevations, thresholdMeters: thresholdMeters);
  return TerrainProfile(
    elevations: elevations,
    distanceMeters: line.distanceMeters,
    bearingDeg: line.bearingDeg,
    sampleSpacingMeters:
        intervals == 0 ? 0 : line.distanceMeters / intervals,
    ascentMeters: relief.ascentMeters,
    descentMeters: relief.descentMeters,
    hasGaps: elevations.any((e) => e == null),
  );
}

/// Total climb and total descent over a list of elevation samples, ignoring
/// runs smaller than [thresholdMeters].
///
/// **Small runs are ignored by accumulating, never by discarding a step.** The
/// obvious implementation — drop any step-to-step change under the threshold —
/// throws away a real slow climb: a hundred samples rising 3 m each is a 300 m
/// ascent that would report as zero. Here the reference elevation stays put
/// until the change away from it clears the threshold, and then **the whole
/// run from that reference is committed**, so the slow climb is counted in
/// full and only genuine wiggle is dropped.
///
/// Once a direction is established, every further step that way is committed
/// as it happens; the threshold is only asked about a *reversal*. That makes
/// the answer exact on a monotone slope — the totals for a straight climb are
/// the climb, not the climb rounded down to a multiple of the threshold.
///
/// **A gap breaks the run.** Nothing is known about the ground either side of
/// missing terrain, and crediting the difference across it as a climb would be
/// inventing the one thing the DEM did not say. [TerrainProfile.hasGaps]
/// carries that fact to the panel.
({double ascentMeters, double descentMeters}) reliefOfProfile(
  List<double?> samples, {
  double thresholdMeters = kTerrainReliefThresholdMeters,
}) {
  var ascent = 0.0;
  var descent = 0.0;

  // The elevation the current run is measured from: the last committed point,
  // which is the extreme reached in the current direction.
  double? reference;
  // 0 = no direction established yet, 1 = climbing, -1 = descending.
  var direction = 0;

  for (final sample in samples) {
    if (sample == null) {
      // Missing terrain: start again on the far side of the hole.
      reference = null;
      direction = 0;
      continue;
    }
    final ref = reference;
    if (ref == null) {
      reference = sample;
      continue;
    }
    final change = sample - ref;
    if (direction > 0 && change > 0) {
      ascent += change;
      reference = sample;
    } else if (direction < 0 && change < 0) {
      descent += -change;
      reference = sample;
    } else if (change >= thresholdMeters) {
      ascent += change;
      reference = sample;
      direction = 1;
    } else if (-change >= thresholdMeters) {
      descent += -change;
      reference = sample;
      direction = -1;
    }
    // Otherwise: a movement smaller than the threshold, against the
    // established direction or with none established. The reference stays
    // where it is, so a run that keeps going the same way is still counted in
    // full once it clears the threshold.
  }

  return (ascentMeters: ascent, descentMeters: descent);
}
