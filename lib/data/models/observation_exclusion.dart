import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'observation_exclusion.freezed.dart';

/// A record that one observation is out of position estimation (task 11.7).
///
/// **This row, not the observation, carries the mark.** The observation it
/// names is never written by superseding or excluding it: its `user_id`,
/// `last_modified_by` and every measurement column stay exactly as its author
/// left them. That is 11.7's rule, and it is also the only design that
/// survives sync — see `Tables.observationExclusions` for the argument.
///
/// **Reversal is a tombstone.** Undoing a supersede or an exclusion soft-deletes
/// this row (`sync.deletedAt`), which is reversible, attributable, and merges
/// between devices like any other row. Reads exclude tombstones by default, so
/// a withdrawn mark stops affecting the solver everywhere at once.
@freezed
abstract class ObservationExclusion with _$ObservationExclusion {
  const ObservationExclusion._();

  const factory ObservationExclusion({
    required String exclusionId,
    required String projectId,

    /// The observation taken out of analysis.
    required String observationId,

    /// Who marked it — **not** the observation's author, who is untouched and
    /// may be someone else entirely.
    required String userId,
    required ObservationExclusionKind kind,

    /// The observation that replaces [observationId], when [kind] is
    /// [ObservationExclusionKind.superseded]. Null otherwise.
    ///
    /// May name an observation this device does not hold: sync delivers rows
    /// in an order this row cannot constrain. That is inert, not corrupt —
    /// the marked observation is out of analysis either way, which is the
    /// conservative direction (an estimate never counts evidence twice).
    String? supersededByObservationId,

    /// Why, in the marker's own words. Optional, but the Team log shows it:
    /// a data-quality decision nobody can account for later is a provenance
    /// hole of its own.
    String? reason,
    required SyncMeta sync,
  }) = _ObservationExclusion;

  factory ObservationExclusion.fromRow(Map<String, Object?> row) =>
      ObservationExclusion(
        exclusionId: row['exclusion_id'] as String,
        projectId: row['project_id'] as String,
        observationId: row['observation_id'] as String,
        userId: row['user_id'] as String,
        kind: ObservationExclusionKind.fromDb(row['kind'] as String),
        supersededByObservationId:
            row['superseded_by_observation_id'] as String?,
        reason: row['reason'] as String?,
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'exclusion_id': exclusionId,
        'project_id': projectId,
        'observation_id': observationId,
        'user_id': userId,
        'kind': kind.db,
        'superseded_by_observation_id': supersededByObservationId,
        'reason': reason,
        ...sync.toColumns(),
      };
}
