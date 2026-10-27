import 'package:tritrack_sync/tritrack_sync.dart';

import '../models/observation.dart';
import '../models/observation_exclusion.dart';

/// Which observations position estimation is allowed to count (task 11.7).
///
/// **Why this is a function and not a `where` clause at the solve site.** The
/// Lenth maximum-likelihood solver treats every bearing it is handed as an
/// independent line of evidence, and the confidence ellipse it reports shrinks
/// with the number of them. Counting both a corrected bearing and the bearing
/// it corrects would therefore report a *tighter* answer than the data
/// supports — a wrong position that looks more precise than a right one, which
/// is the worst failure this feature can produce. There is exactly one place
/// that decides the solver's input, it is this one, and it is directly
/// testable: a test can solve the eligible set and the naive set and watch the
/// ellipse differ.
///
/// The rule is deliberately simple and conservative: **a live mark takes its
/// observation out, full stop.** In particular an observation does not come
/// back if the record superseding it is later deleted — the person who said
/// "this bearing is wrong" said so about the bearing, not about the
/// replacement, and silently re-admitting evidence somebody retired is the
/// direction that over-counts. Withdrawing the mark is how it comes back, and
/// that is a deliberate act with a name on it.
abstract final class AnalysisEligibility {
  /// The subset of [observations] position estimation may count, given the
  /// project's live marks keyed by observation id (see
  /// `ObservationExclusionRepository.activeByObservation`).
  ///
  /// Order is preserved, so a caller's sort survives.
  static List<Observation> eligible(
    List<Observation> observations,
    Map<String, ObservationExclusion> marksByObservation,
  ) => [
    for (final o in observations)
      if (!marksByObservation.containsKey(o.observationId)) o,
  ];

  /// Whether [observation] is out of analysis, and the one-line reason why —
  /// what the Log and Team tabs show on the row, since 11.7 requires an
  /// excluded observation to stay visible **with its state shown** rather than
  /// disappear.
  ///
  /// Returns null when the observation counts normally.
  static String? withheldReason(
    Observation observation,
    Map<String, ObservationExclusion> marksByObservation,
  ) {
    final mark = marksByObservation[observation.observationId];
    if (mark == null) return null;
    final because = mark.reason == null || mark.reason!.trim().isEmpty
        ? ''
        : ' — ${mark.reason!.trim()}';
    return switch (mark.kind) {
      ObservationExclusionKind.superseded =>
        'Superseded by a later record; not counted in position estimates'
            '$because',
      ObservationExclusionKind.excluded =>
        'Excluded from position estimates by an owner$because',
    };
  }
}
