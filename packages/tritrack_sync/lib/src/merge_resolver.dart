/// Pure last-write-wins conflict resolution over the six sync columns every
/// row carries. Kept free of any database/model dependency so the decision
/// rule can be reasoned about and tested in isolation — it is the single point
/// that decides which of two divergent copies of the same row survives a
/// merge, shared verbatim between the app's client-side merge and the
/// server's merge of pushed rows so the two can never disagree.
///
/// The rule (technical doc: "last-write-wins/conflict detection" via
/// `revision` + `updated_at`):
///   1. Higher `revision` wins. `revision` increments on every edit, so it is
///      the primary monotonic clock.
///   2. Tie on revision → later `updated_at` wins.
///   3. Tie on both → higher `origin_device_id` wins (a deterministic, if
///      arbitrary, tiebreak so the same two inputs always merge the same way
///      regardless of which device runs the merge). Null sorts lowest.
///   4. Fully identical sync state → no change (incoming does not win; the
///      local row is already equivalent).
///
/// A tombstone (`deleted_at != null`) is *not* special here: it rides along as
/// part of whichever row wins. So the latest edit — delete or un-delete —
/// wins, and a stale delete can never resurrect or bury a newer live edit.
abstract final class MergeResolver {
  /// True if [incoming] should overwrite [local] under last-write-wins. Both
  /// maps are raw column-maps; only the sync columns are consulted.
  static bool incomingWins(
    Map<String, Object?> incoming,
    Map<String, Object?> local,
  ) => compare(incoming, local) > 0;

  /// Orders two rows by the merge clock: positive if [a] is newer than [b],
  /// negative if older, 0 if equivalent. Same ordering [incomingWins] uses.
  static int compare(Map<String, Object?> a, Map<String, Object?> b) {
    final revA = _revision(a);
    final revB = _revision(b);
    if (revA != revB) return revA > revB ? 1 : -1;

    final tsA = _updatedAt(a);
    final tsB = _updatedAt(b);
    final tsCmp = tsA.compareTo(tsB);
    if (tsCmp != 0) return tsCmp > 0 ? 1 : -1;

    final devCmp = _deviceId(a).compareTo(_deviceId(b));
    if (devCmp != 0) return devCmp > 0 ? 1 : -1;

    return 0;
  }

  static int _revision(Map<String, Object?> row) {
    final v = row['revision'];
    return v is int ? v : 0;
  }

  /// `updated_at` is stored as an ISO-8601 UTC string with a `Z` designator;
  /// for a fixed format that is also lexical order, but we parse to be robust
  /// to differing sub-second precision. A missing/invalid value sorts oldest.
  static DateTime _updatedAt(Map<String, Object?> row) {
    final v = row['updated_at'];
    if (v is String) {
      final parsed = DateTime.tryParse(v);
      if (parsed != null) return parsed.toUtc();
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  static String _deviceId(Map<String, Object?> row) {
    final v = row['origin_device_id'];
    return v is String ? v : '';
  }
}
