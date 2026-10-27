import '../localization/angles.dart';

/// **A heading steady enough to turn a map by** — task 11.315's *facing up*.
///
/// A phone's compass wobbles by a few degrees from sample to sample even held
/// still, and a map turned by every sample shakes. Michael asked for facing up
/// to be smoothed so it does not. Two things do that here, and both are
/// circular so a heading that crosses north is not averaged through south:
///
/// 1. **An exponential moving average** — each sample moves the smoothed
///    heading [weight] of the way towards it, along the short way round.
/// 2. **A dead band** — [shouldApply] says whether the smoothed heading has
///    moved at least [deadBandDeg] from the last one the map was turned to,
///    so a phone held still produces no turning at all.
///
/// **This is display only.** The bearing a sweep records is read from the raw
/// heading, exactly as the Record screen's RANGE button reads it; smoothing a
/// measurement would move it towards where the phone *was* pointing.
///
/// **Nothing animates towards the smoothed value.** Entry 41 in the defect
/// vocabulary: animating in response to something that is itself changing
/// produces the jitter it was meant to remove. The map is set to this value,
/// once per sample.
class HeadingSmoother {
  HeadingSmoother({this.weight = 0.2, this.deadBandDeg = 1.0});

  /// How far each sample pulls the smoothed heading towards itself, 0 to 1.
  /// The compass delivers tens of samples a second, so 0.2 settles a turn in
  /// well under a second while taking the edge off a few degrees of wobble.
  final double weight;

  /// The smallest change in the smoothed heading worth turning the map for.
  final double deadBandDeg;

  double? _smoothed;
  double? _applied;

  /// The current smoothed heading, or null before the first sample or after
  /// [reset].
  double? get value => _smoothed;

  /// Folds [rawDeg] in and returns the new smoothed heading. The first sample
  /// after a [reset] is taken as it is — easing in from nothing would turn
  /// the map through a direction the phone never pointed.
  double add(double rawDeg) {
    final current = _smoothed;
    if (current == null) {
      return _smoothed = Angles.normalizeDegrees(rawDeg);
    }
    final delta = Angles.shortestDifferenceDegrees(current, rawDeg);
    return _smoothed = Angles.normalizeDegrees(current + delta * weight);
  }

  /// Whether the map should be turned to [value] now: true for the first
  /// value, and afterwards only once it has moved [deadBandDeg] or more from
  /// the last value this returned true for.
  bool shouldApply() {
    final current = _smoothed;
    if (current == null) return false;
    final last = _applied;
    if (last != null &&
        Angles.shortestDifferenceDegrees(last, current).abs() < deadBandDeg) {
      return false;
    }
    _applied = current;
    return true;
  }

  /// Forgets everything — for when the compass stops giving a heading, so
  /// that when it resumes the map goes straight to the new heading.
  void reset() {
    _smoothed = null;
    _applied = null;
  }
}
