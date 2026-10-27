/// Repository-layer authorization for row mutations.
///
/// These are **advisory** controls, not security. Phase One has no server:
/// anyone holding the database or a backup file can edit its contents
/// directly. The point of enforcing here rather than in each screen is that
/// a new screen cannot *accidentally* bypass the rule the way the map's Edit
/// button did, and that the Phase 3 server inherits one coherent model
/// instead of a patchwork of render conditions.
///
/// The rules themselves are documented in
/// `CLAUDE_DOCS/TriTrack_Technical_Context.md`.
///
/// [MutationRule] and the table-to-rule mapping moved to
/// `packages/tritrack_sync` in task 10.10 and are re-exported here, so the
/// server enforces the same table-to-rule assignment this layer advises on
/// rather than a hand-copied second list. What stays app-side is everything
/// specific to *this* enforcement point: [MutationActor] (a repository
/// concept, including the replication bypass) and [UnauthorizedMutation].
library;

import 'package:tritrack_sync/tritrack_sync.dart';

import 'project_standing.dart';

export 'package:tritrack_sync/tritrack_sync.dart' show MutationRule;
export 'project_standing.dart';

/// Who a repository mutation is performed as.
///
/// Every mutating [BaseRepository] method requires one. It serves two
/// purposes at once: it is stamped into the `last_modified_by` audit column,
/// and it is the identity checked against the row's [MutationRule].
class MutationActor {
  /// A person acting through the app.
  const MutationActor.user(String this.userId) : bypassReason = null;

  /// The narrow bypass for writes that legitimately carry *other people's*
  /// rows: `ProjectMerger` and `SharedObservationImporter` replicate
  /// observations authored elsewhere and must preserve the author's sync
  /// clock verbatim.
  ///
  /// Both of those write through raw `DatabaseExecutor` statements inside
  /// their own transaction rather than through a repository, so neither
  /// needs this today. It exists so that if replication is ever routed
  /// through a repository, the exemption is a named, greppable argument at
  /// the call site instead of a permissive default that quietly disables
  /// authorization everywhere.
  const MutationActor.replication(String this.bypassReason) : userId = null;

  /// The acting user's id, or null for a [MutationActor.replication].
  final String? userId;

  /// Why authorization is being skipped, or null for a real user.
  final String? bypassReason;

  bool get isReplication => bypassReason != null;
}

/// **A named, verified reason a write is permitted despite the table's
/// [MutationRule]** (task 11.54).
///
/// Not a bypass. [MutationActor.replication] is the bypass — it checks nothing,
/// by design, because replication genuinely writes rows this device had no part
/// in authorizing. An exemption is the opposite: the repository *re-derives*
/// the condition it names and refuses the write if it does not hold, exactly as
/// `MembershipInsertAuthority` does for the one table whose insert is itself a
/// grant.
///
/// There is one, and adding a second should be as uncomfortable as this one
/// was. Every exemption is a hole in a rule somebody relied on, and a named
/// hole that has to be typed out at the call site is the only kind worth
/// having.
sealed class MutationExemption {
  const MutationExemption();

  /// **Somebody removing their own copy of a project they are no longer on**
  /// (task 11.54).
  ///
  /// `Projects` is [MutationRule.owner], so before this a contributor who left
  /// a project — or was removed from one — could neither use it nor get rid of
  /// it: the leave control correctly disappears once you are off the project,
  /// and the delete control was greyed out because they were never an owner.
  /// The project sat in their list forever. Michael decided on 2026-08-29 that
  /// they may delete it.
  ///
  /// **Why this is safe to permit, and it is not "because it is only local".**
  /// The tombstone this writes is a synced column, so "it stays on this device"
  /// would be a claim about behaviour rather than about a rule. The actual
  /// guarantee is derived: `Projects` is one of the four tables
  /// `offer_rules.dart` classifies as records the server keeps for itself, and
  /// a device offers such a row only when its identity columns name the
  /// signed-in person — or, since task 11.57, when that person is an *open
  /// owner* of the project and the server already holds the row. A departed
  /// member is neither: `owner_user_id` names somebody else and their owner
  /// membership, if they ever had one, is closed. So this write is never
  /// offered and cannot reach anybody else's copy of the project.
  ///
  /// *(Corrected by task 11.289. This used to say a device never offers a
  /// `Projects` row "at all", which was true when written and stopped being
  /// true when 11.57 let an owner's own row through — that is how a rename, or
  /// the owner's own deletion, reaches the server at all. The exemption was
  /// never unsafe; the sentence defending it was.)*
  ///
  /// Verified rather than trusted: the repository checks that this device holds
  /// no open membership for [MutationActor.userId] on [projectId] and does hold
  /// a closed one. A person who is still on the project gets the ordinary
  /// refusal, and so does one who was never on it.
  const factory MutationExemption.departedMember(String projectId) =
      DepartedMemberExemption;

  /// **Somebody removing a read-only snapshot they were never a member of**
  /// (task 11.238).
  ///
  /// A colleague's archive, imported by somebody the project's own membership
  /// rows do not name, lands as a read-only snapshot (task 11.237): every
  /// edit is refused, and the project sits in the list with nothing to do
  /// about it — [MutationExemption.departedMember] does not reach them,
  /// because that exemption is for somebody who *was* a member and no longer
  /// is, and a snapshot holder never was.
  ///
  /// **Why this is safe, argued fresh rather than assumed from the exemption
  /// above.** The same fact makes both safe: `Projects` is one of the four
  /// tables `offer_rules.dart` says a device offers only when the row names
  /// the signed-in person, or when they are an open owner of a project the
  /// server already holds (task 11.57). A snapshot holder is named nowhere in
  /// the row and holds no membership at all, so their delete is never offered
  /// — it is invisible to the server and to every other device, and cannot
  /// touch anybody else's copy of the project, whoever they are. Nothing
  /// about *why* the actor is not on the project changes that; it is a
  /// property of the offer rule, not of the person. A second exemption
  /// resting on the same rule is not a coincidence to be suspicious of — it is
  /// the one thing about `Projects` that makes any local-only delete safe at
  /// all. *(Wording corrected by task 11.289, as above.)*
  ///
  /// **Verified the same way, with one difference that is the whole reason
  /// this is not a copy of [DepartedMemberExemption].** That one asks for no
  /// *open* membership row and at least one *closed* one — they were here and
  /// left. This asks for **no row at all, open or closed** — they were never
  /// here. Getting that backwards would let a departed member masquerade as a
  /// snapshot holder or the reverse; both still resolve to "delete allowed,"
  /// but a repository that cannot tell the two apart is one accident away
  /// from an exemption that no longer means what its name says.
  const factory MutationExemption.snapshotHolder(String projectId) =
      SnapshotHolderExemption;
}

/// See [MutationExemption.departedMember].
class DepartedMemberExemption extends MutationExemption {
  const DepartedMemberExemption(this.projectId);
  final String projectId;
}

/// See [MutationExemption.snapshotHolder].
class SnapshotHolderExemption extends MutationExemption {
  const SnapshotHolderExemption(this.projectId);
  final String projectId;
}

/// Thrown when a [MutationActor] attempts a write the row's [MutationRule]
/// does not permit. A bug in the calling screen, not a user-facing error —
/// screens are expected to render the affordance disabled with a reason, not
/// hidden, in the first place (task 11.12).
class UnauthorizedMutation implements Exception {
  const UnauthorizedMutation({
    required this.table,
    required this.rowId,
    required this.rule,
    required this.actorUserId,
    required this.permitted,
  }) : notAMember = false;

  /// The refusal for a write into a project this device can see the actor is
  /// **not on** — a read-only snapshot (task 11.237). One constructor, so the
  /// three gates that raise it cannot describe it three ways.
  const UnauthorizedMutation.notAMember({
    required this.table,
    required this.rowId,
    required this.rule,
    required this.actorUserId,
  }) : permitted = 'a member of this project (you are not on it)',
       notAMember = true;

  /// Whether this refusal is the snapshot one. A screen that catches this
  /// exception and has a viewer sentence ready shows [notAMemberWriteRefusal]
  /// instead when this is true — see [refusalSentence].
  final bool notAMember;

  /// The sentence to show a person for this refusal: the screen's own
  /// [asViewer] wording for a viewer, or the shared snapshot refusal.
  String refusalSentence({required String asViewer}) =>
      notAMember ? notAMemberWriteRefusal : asViewer;

  final String table;
  final Object rowId;
  final MutationRule rule;
  final String? actorUserId;

  /// Who the rule would have permitted, for the message. A single user id for
  /// [MutationRule.author]; for the ownership rules (task 11.1) the project's
  /// current owners, comma-joined, since there may be several. Null when the
  /// row named nobody at all.
  final String? permitted;

  @override
  String toString() =>
      'UnauthorizedMutation: user $actorUserId may not modify $table row '
      '$rowId (${rule.name} rule; permitted: $permitted)';
}

/// Whether [actorUserId] may edit/delete an [MutationRule.author]-governed
/// row [rowUserId] wrote, and if not, why — task 11.12's combined check for
/// the two screens that offer this affordance (the Log/Team tabs and the
/// map's selection panel).
///
/// Two independent gates compose, in the same order [BaseRepository._authorize]
/// asks them: the role gradient first (a `viewer` may touch nothing, whoever
/// wrote it — including their own rows from before a demotion), then
/// authorship (a `contributor` may change only their own). Both callers must
/// ask exactly this, or a control one of them renders enabled could still be
/// refused at the tap.
({bool canEdit, String? reason}) authorEditVerdict({
  required ProjectStanding standing,
  required String? actorUserId,
  required String rowUserId,
}) {
  final refusal = standing.writeRefusal(
    asViewer:
        'Viewers cannot edit or delete observations — ask an owner to '
        'change your role.',
  );
  if (refusal != null) return (canEdit: false, reason: refusal);
  if (!MutationRule.author.permits(actorUserId, rowUserId)) {
    return (
      canEdit: false,
      reason: 'You can only edit or delete observations you recorded yourself.',
    );
  }
  return (canEdit: true, reason: null);
}

/// Whether [actorUserId] may delete a **"no signal" record** — a
/// [NonDetectionRepository] row — and if not, why. Same two gates as
/// [authorEditVerdict], asked in the same order, because
/// `NonDetectionRepository` carries the identical `MutationRule.author` rule
/// (`non_detection_repository.dart:11`) — this exists only so the wording on
/// screen says "no signal" rather than "observation" (task 11.252).
({bool canEdit, String? reason}) nonDetectionEditVerdict({
  required ProjectStanding standing,
  required String? actorUserId,
  required String rowUserId,
}) {
  final refusal = standing.writeRefusal(
    asViewer:
        'Viewers cannot delete a "no signal" record — ask an owner to '
        'change your role.',
  );
  if (refusal != null) return (canEdit: false, reason: refusal);
  if (!MutationRule.author.permits(actorUserId, rowUserId)) {
    return (
      canEdit: false,
      reason: 'You can only delete a "no signal" record you recorded yourself.',
    );
  }
  return (canEdit: true, reason: null);
}

/// Whether the signed-in user may edit or delete a **truth point** — the
/// record of where somebody physically found the animal or the collar — and if
/// not, why (task 11.92).
///
/// **Authorship is deliberately not asked here, and as of task 11.93 that is a
/// decision rather than an absence.**
///
/// Until 11.93 the reason was simply that `Actual_Tag_Locations` had no author
/// column. **It has one now** — `user_id`, who walked in and found the collar
/// — and this verdict still does not read it. Michael settled that on
/// 2026-08-31: `user_id` records **who found it, which is a fact about the
/// record and not a permission.** His reason is the case the feature exists
/// for — **the person who saw the pride and the person driving the truck may
/// not be the same person** — so requiring the finder to make the correction
/// would mean the only person who can fix a point is the one who was looking
/// through binoculars while somebody else drove.
///
/// `ActualTagLocationRepository` is declared [MutationRule.anyUser] to match,
/// and `truth_point_lifecycle_test.dart` asserts both halves: a contributor who
/// did not find the point can still edit and delete it, and this verdict says
/// so too. Asking authorship on the screen while the repository asks membership
/// is exactly how a control comes to render disabled for a write that would in
/// fact succeed — the mirror image of task 11.12's defect. The role gradient is
/// the whole of the rule, so it is the whole of this verdict.
({bool canEdit, String? reason}) truthPointEditVerdict({
  required ProjectStanding standing,
}) {
  final refusal = standing.writeRefusal(
    asViewer:
        'Viewers cannot change or delete a truth point — ask an owner to '
        'change your role.',
  );
  return (canEdit: refusal == null, reason: refusal);
}

/// Whether [actorUserId] may take an observation out of position estimation,
/// and if not, why — task 11.7's counterpart to [authorEditVerdict], and asked
/// by every screen that offers a supersede or exclude control before it offers
/// one.
///
/// **The two actions sit on different rungs, and the difference is the point.**
///
/// - **Supersede** is contributor-level and applies to *anyone's* observation.
///   Editing an observation is author-only and stays that way (Phase 8), so
///   superseding is the only way one member can correct another's bearing at
///   all. Holding it to your own rows would leave the feature unable to do the
///   job it exists for. It is safe at this rung because it destroys nothing:
///   the original survives with its author and values intact, the replacement
///   carries its own author, and the mark is reversible.
/// - **Exclude** is owner-only. It takes evidence out with nothing offered in
///   its place, which is the "data quality" rung the role gradient reserves
///   for owners.
///
/// This must stay the single source of the answer for both the screen and the
/// repository — `ObservationExclusionRepository.assertMayMark` asks the same
/// question of the database, and a screen that hand-rolled its own version is
/// how a control comes to render enabled and fail at the tap (task 11.12).
({
  bool canSupersede,
  String? supersedeReason,
  bool canExclude,
  String? excludeReason,
})
exclusionVerdict({required ProjectStanding standing, required bool isOwner}) {
  final supersedeRefusal = standing.writeRefusal(
    asViewer:
        'Viewers cannot supersede an observation — ask an owner to change '
        'your role.',
  );
  return (
    canSupersede: supersedeRefusal == null,
    supersedeReason: supersedeRefusal,
    canExclude: isOwner,
    // A snapshot-holder is not an owner, and the owner-only sentence would
    // send them to supersede instead — which the line above has just refused.
    // The snapshot refusal wins, so the two reasons on one row agree.
    excludeReason: isOwner
        ? null
        : standing.isSnapshot
        ? notAMemberWriteRefusal
        : 'Only a project owner can exclude an observation from position '
              'estimates. You can supersede it with a corrected record '
              'instead.',
  );
}

/// Whether the signed-in user may leave [a project] — task 11.28's
/// counterpart to the verdicts above, and the single source of the answer for
/// every screen that offers a "leave this project" control.
///
/// **Anyone who holds an open membership may leave, whatever their role.** A
/// viewer is the person most likely to want off a project, so the role
/// gradient deliberately does not apply — this is the one write to
/// `Project_Memberships` that is not owner-only, and `isSelfDeparture` in the
/// shared package is the exact statement of how narrow it is. Michael decided
/// on 2026-08-22 that no owner confirmation is required, so there is nothing
/// here about asking permission.
///
/// Exactly one thing refuses, and it is not about authorization at all:
/// **the project's last owner cannot walk out of it.** Nobody would be left
/// who could manage membership, change settings, or hand it on, and on a
/// laptop server there is no privileged operator to appeal to. Same rule,
/// same reason and the same message as an owner removing themselves
/// ([LastOwnerRemoval]); it is stated here as well so the control renders
/// disabled with the explanation rather than failing at the tap (task 11.12).
///
/// [isMember] is whether they hold an **open** membership row — `end_date IS
/// NULL` and not tombstoned. False means there is nothing to leave, which
/// happens on a stale screen after somebody else removed them.
({bool canLeave, String? reason}) leaveProjectVerdict({
  required bool isMember,
  required bool isLastOwner,
}) {
  if (!isMember) {
    return (
      canLeave: false,
      reason: 'You are not currently a member of this project.',
    );
  }
  if (isLastOwner) {
    return (
      canLeave: false,
      reason:
          "You are this project's last owner. Make someone else an owner "
          'first — a project with no owner cannot be managed or restored.',
    );
  }
  return (canLeave: true, reason: null);
}

/// Whether [actorUserId] may withdraw an existing mark — task 11.15's
/// counterpart to [exclusionVerdict], and the single source of the answer for
/// every screen that offers a "count in estimates again" control.
///
/// **Withdrawing asks two questions, and both have to be asked here** or the
/// control renders enabled and fails at the tap, which is the whole subject of
/// task 11.12:
///
/// - **The rung.** An exclusion is owner-only to make, so it is owner-only to
///   undo. A supersede is contributor-level either way. This is
///   `ObservationExclusionRepository.assertMayMark` asked ahead of time, and
///   the server's `RowAuthorizer._authorizeExclusionKind` asks the same thing
///   at the boundary.
/// - **Whose mark it is.** [MutationRule.authorOrOwner]: the person who made
///   it, or any current project owner. Before task 11.15 the rule was
///   author-only, so a mark made by someone who then left the project could
///   never be withdrawn by anyone at all — not an owner, not even the
///   observation's own author.
///
/// The screen this replaced asked neither question about the mark: it offered
/// restore to anyone who could supersede, so a contributor was shown a live
/// control for a colleague's mark and got a raw `UnauthorizedMutation` on tap.
({bool canWithdraw, String? reason}) withdrawMarkVerdict({
  required ProjectStanding standing,
  required bool isOwner,
  required String? actorUserId,
  required String markUserId,
  required ObservationExclusionKind markKind,
}) {
  final refusal = standing.writeRefusal(
    asViewer:
        'Viewers cannot change what counts toward estimates — ask an '
        'owner to change your role.',
  );
  if (refusal != null) return (canWithdraw: false, reason: refusal);
  if (markKind == ObservationExclusionKind.excluded && !isOwner) {
    return (
      canWithdraw: false,
      reason:
          'Only a project owner can put an excluded observation back into '
          'position estimates.',
    );
  }
  if (isOwner || markUserId == actorUserId) {
    return (canWithdraw: true, reason: null);
  }
  return (
    canWithdraw: false,
    reason:
        'Only the person who marked this observation, or a project owner, '
        'can make it count again.',
  );
}
