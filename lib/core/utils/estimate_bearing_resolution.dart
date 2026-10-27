/// Which of a position estimate's `observation_ids_used` are bearings that
/// exist in this project today, and what to say about the rest — task
/// 11.259.
///
/// A season clone carries `observation_ids_used` across on purpose (see the
/// doc comment on `_createEstimatedPositions` in `lib/data/db/schema.dart`):
/// those bearings stay in last season's project, so an id on this list can
/// name a bearing that is simply not here. Resolving against the ids this
/// device actually holds — rather than trusting the list's length — is what
/// keeps a display honest in both the fully-carried case (none resolve) and
/// the partial case (a bearing recorded new this season, estimate never
/// recomputed): the count shown is always "how many of these bearings are
/// on this map", never the raw length of the stored list.
class EstimateBearingResolution {
  const EstimateBearingResolution({
    required this.resolvedIds,
    required this.totalCount,
  });

  factory EstimateBearingResolution.of(
    List<String> observationIdsUsed,
    Set<String> localObservationIds,
  ) =>
      EstimateBearingResolution(
        resolvedIds: {
          for (final id in observationIdsUsed)
            if (localObservationIds.contains(id)) id,
        },
        totalCount: observationIdsUsed.length,
      );

  /// The ids from `observation_ids_used` that name a bearing this device
  /// holds — safe to highlight, safe to count.
  final Set<String> resolvedIds;

  /// The stored list's length, including ids that resolve to nothing here.
  /// Never shown directly — see [label].
  final int totalCount;

  int get resolvedCount => resolvedIds.length;

  /// True when every one of the estimate's bearings is elsewhere: a wholly
  /// carried-over estimate, computed in a season this project doesn't hold.
  bool get isFullyCarried => totalCount > 0 && resolvedCount == 0;

  /// What to say about the bearing count. Never "0 $noun" — that would claim
  /// the estimate came from nothing, which is false; it came from bearings
  /// that are simply elsewhere. [noun] is the surrounding screen's own word
  /// for a bearing (e.g. "bearings used", "observations").
  String label(String noun) =>
      isFullyCarried ? 'computed in an earlier season' : '$resolvedCount $noun';
}
