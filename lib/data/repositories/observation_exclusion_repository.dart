import 'package:tritrack_sync/tritrack_sync.dart';
import '../../core/text/role_labels.dart';

import '../models/observation_exclusion.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

/// Reads and writes the marks that take an observation out of position
/// estimation (task 11.7): superseded by a better record, or excluded by an
/// owner as bad data.
///
/// **Nothing in this class ever writes an `Observations` row.** That is the
/// whole design — see `Tables.observationExclusions`. A test asserts it
/// (`test/data/repositories/observation_exclusion_repository_test.dart`)
/// rather than leaving it to this comment, because a future task will
/// otherwise reach for the simpler-looking "just let owners edit the row."
class ObservationExclusionRepository extends BaseRepository {
  ObservationExclusionRepository(super.db)
    : super(
        table: Tables.observationExclusions,
        pk: const ['exclusion_id', 'project_id'],
        // Task 11.15: was [MutationRule.author]. A mark whose author left the
        // project was permanent under that rule — see the rule's own doc.
        rule: MutationRule.authorOrOwner,
      );

  /// Records [exclusion], after checking that [ObservationExclusion.userId]
  /// may make a mark of that kind in that project.
  ///
  /// The permission check is here rather than in the rule table because the
  /// rule table answers a question about a *stored* row, and on an insert
  /// there isn't one — the same gap `BaseRepository.insertRow` documents.
  Future<void> insert(ObservationExclusion exclusion) async {
    await assertMayMark(
      exclusion.projectId,
      exclusion.kind,
      MutationActor.user(exclusion.userId),
    );
    await insertRow(exclusion.toColumns());
  }

  /// Throws [UnauthorizedMutation] unless [actor] may make a [kind] mark in
  /// [projectId]. Exposed so a screen can ask before offering the control,
  /// which is what stops a button rendering enabled and failing at the tap
  /// (task 11.12's whole subject).
  ///
  /// **The two kinds sit on different rungs of the role gradient, and the
  /// difference is the point of task 11.7:**
  ///
  /// - [ObservationExclusionKind.superseded] is contributor-level, on
  ///   *anyone's* observation. Editing an observation is author-only and stays
  ///   that way, so superseding is the only way a teammate can correct a
  ///   colleague's bearing at all. Restricting it to your own rows would leave
  ///   the feature unable to do the job it exists for, and would leave the
  ///   two-people-one-observation case — where the record you must retire is
  ///   the *other* person's — with no answer. It is safe at this rung because
  ///   it destroys nothing: the original survives intact, the replacement is
  ///   attributed to whoever recorded it, and the mark is reversible.
  /// - [ObservationExclusionKind.excluded] is owner-only. It removes evidence
  ///   without putting anything in its place, which is the "data quality" rung
  ///   the role gradient reserves for owners.
  ///
  /// A standing this device cannot resolve permits, on the same "defer to
  /// the server" contract [assertRoleMayWrite] states: this SQLite file may
  /// legitimately hold a project with no membership row for this user — a
  /// restored backup, one created offline. A project the device can see the
  /// user is **not on** — a colleague's import — is refused (task 11.237).
  Future<void> assertMayMark(
    String projectId,
    ObservationExclusionKind kind,
    MutationActor actor,
  ) async {
    if (actor.isReplication) return;
    final standing = await projectStandingFor(projectId, actor.userId);
    final ProjectRole role;
    switch (standing) {
      case UnknownStanding():
        return;
      case NotAMemberStanding():
        throw UnauthorizedMutation.notAMember(
          table: table,
          rowId: projectId,
          rule: rule,
          actorUserId: actor.userId,
        );
      case MemberStanding(role: final held):
        role = held;
    }
    final permitted = switch (kind) {
      ObservationExclusionKind.superseded => role.mayWriteProjectData,
      ObservationExclusionKind.excluded => role == ProjectRole.owner,
    };
    if (permitted) return;
    throw UnauthorizedMutation(
      table: table,
      rowId: projectId,
      rule: rule,
      actorUserId: actor.userId,
      permitted: switch (kind) {
        ObservationExclusionKind.superseded =>
          'a contributor or owner of this project (you are ${role.withArticle})',
        ObservationExclusionKind.excluded =>
          'an owner of this project (you are ${role.withArticle})',
      },
    );
  }

  /// Every live mark in [projectId], newest first.
  Future<List<ObservationExclusion>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'created_at DESC',
    );
    return rows.map(ObservationExclusion.fromRow).toList();
  }

  /// The live marks in [projectId], keyed by the observation each one takes
  /// out of analysis — the shape the solver's input filter wants.
  ///
  /// An observation can carry more than one mark (two people can independently
  /// judge the same bearing bad). The newest wins for display; for the solver
  /// it makes no difference, since any live mark takes the row out.
  Future<Map<String, ObservationExclusion>> activeByObservation(
    String projectId,
  ) async {
    final marks = await findByProject(projectId);
    final byObservation = <String, ObservationExclusion>{};
    for (final mark in marks.reversed) {
      byObservation[mark.observationId] = mark;
    }
    return byObservation;
  }

  /// The most recently withdrawn mark for each observation in [projectId]
  /// that has ever had one, keyed by the observation it took out of analysis
  /// — task 11.18's "this was marked, then un-marked" history.
  ///
  /// Newest tombstone (by [SyncMeta.deletedAt], not [SyncMeta.createdAt])
  /// wins per observation, the same "last write in the loop wins" convention
  /// [activeByObservation] uses. An observation can appear here **and** in
  /// [activeByObservation] at once: withdrawing a mark and then marking the
  /// same observation again leaves one tombstoned row and one live one, both
  /// worth showing — the live state, and that it happened before.
  Future<Map<String, ObservationExclusion>> withdrawnByObservation(
    String projectId,
  ) async {
    final rows = await findByProject(projectId, includeDeleted: true);
    final withdrawn = [
      for (final row in rows)
        if (row.sync.isDeleted) row,
    ]..sort((a, b) => a.sync.deletedAt!.compareTo(b.sync.deletedAt!));
    return {for (final mark in withdrawn) mark.observationId: mark};
  }

  /// Withdraws [exclusion] — the undo of a supersede or an exclusion.
  ///
  /// Tombstones the mark rather than deleting it, so the reversal itself
  /// merges between devices instead of resurrecting on the next sync.
  ///
  /// **Two checks, because withdrawing asks two questions (task 11.15).**
  /// [assertMayMark] answers the *rung* one — an exclusion is owner-only to
  /// make and therefore owner-only to undo, which is also what the server's
  /// `RowAuthorizer._authorizeExclusionKind` enforces, so the two sides agree.
  /// [MutationRule.authorOrOwner], applied by [softDeleteByKey], answers the
  /// *whose* one: the person who made the mark, or any current owner. Neither
  /// subsumes the other, and leaving either out is a live bug — without the
  /// first a demoted contributor could undo an owner's exclusion, without the
  /// second a departed author's mistake is permanent.
  Future<int> withdraw(
    ObservationExclusion exclusion, {
    required MutationActor actor,
    String? deviceId,
  }) async {
    await assertMayMark(exclusion.projectId, exclusion.kind, actor);
    return softDeleteByKey(
      {
        'exclusion_id': exclusion.exclusionId,
        'project_id': exclusion.projectId,
      },
      actor: actor,
      deviceId: deviceId,
    );
  }
}
