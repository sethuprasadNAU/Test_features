/// Project-level access: may this session touch this project at all?
/// (task 10.10)
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';

/// How a caller relates to a project — **the role gradient, resolved** (task
/// 11.3).
///
/// Through Phase 10 this was `absent / owner / member / none`, where `member`
/// meant "holds an open membership row" and said nothing about what kind. Task
/// 11.2 made non-owner members real and gave them roles, so `member` is now
/// two rungs: a `contributor` who may add to the project's record and a
/// `viewer` who may read it and nothing else.
///
/// **This enum is the caller's relationship, not the row's permission.** It
/// answers "may you touch this project, and how much" once per request;
/// [RowAuthorizer] then answers "may you write this particular row" per row,
/// against the same rule table the app uses. Both are needed — see
/// [ProjectAuthorizer].
enum ProjectAccess {
  /// The project does not exist on the server yet.
  absent,

  /// The caller is one of the project's current owners — an open `owner`
  /// membership row, or `Projects.owner_user_id` where the membership table
  /// names no owner at all. See [resolveProjectOwners], which is the same
  /// answer [RowAuthorizer] and the client's `BaseRepository` use.
  ///
  /// **Task 11.1 moved this off `owner_user_id`.** It was the column through
  /// Phase 10; now it is the fallback, so an owner who received the project by
  /// transfer resolves here and the creator who handed it on does not.
  owner,

  /// The caller holds an open `contributor` membership: they may record in the
  /// project and edit or delete **their own** rows, which is the rule table's
  /// job rather than this enum's.
  contributor,

  /// The caller holds an open `viewer` membership: read the project, change
  /// nothing. Sync is permitted because pull is a read; every mutating row of
  /// a push is refused by [RowAuthorizer], one row at a time rather than as a
  /// blanket `403`, so the device holds and explains each refusal (task 10.28)
  /// instead of losing it — and so a viewer can still push the one thing that
  /// is theirs rather than the project's: their own `Users` profile row.
  viewer,

  /// No relationship at all — never a member, a closed stint, a tombstoned
  /// membership, or an open membership whose `role` this build cannot
  /// interpret. The last of those fails closed deliberately: an unrecognised
  /// role must not be read as the permissive one.
  none;

  /// Whether the caller may **write** the project's own data, as opposed to
  /// merely reading it.
  ///
  /// The gradient's write gate, and the server-side half of "a `viewer` who can
  /// write because only the UI stopped them is not a viewer." It says nothing
  /// about *which* rows — a contributor passes here and is still held to their
  /// own by [MutationRule.author], and to non-authorization-state tables by
  /// [MutationRule.projectOwner].
  ///
  /// [absent] is false. The first-publish case that needs a write to a project
  /// the server does not hold is granted explicitly and narrowly in
  /// `createSyncRouter`, which substitutes [owner] for the duration of a push
  /// that establishes the project — the same seam [permitsSync] documents
  /// below.
  bool get permitsProjectWrite => this == owner || this == contributor;

  /// Whether the caller may read/write the project's rows through sync.
  ///
  /// **[absent] does not count, and used to (task 10.21).** Permitting it was
  /// reasoned about only as "there is nothing there to disclose", which is true
  /// of the *rows* and false of the fact itself: a nonexistent project passed
  /// the gate, found nothing, and answered `200` with an empty page, while an
  /// existing-but-forbidden one answered `403`. That difference is a working
  /// existence oracle, and §4.13 names it as its first `Violated by:` case —
  /// "wrong project, wrong user, and nonexistent are indistinguishable from
  /// outside". Project ids are v4 UUIDs, so this is not blind enumeration; it
  /// is confirmation, of an id that reached the attacker through a `TT1:`
  /// payload, an export, a screenshot, or a support ticket. Confirming a
  /// project is on this server is the reconnaissance §2.1 and §2.4 are about.
  ///
  /// Publish (task 10.9) is the case [absent] was permitted *for*, and it is
  /// preserved somewhere more specific: `createSyncRouter` permits a push that
  /// **establishes** the project — one carrying a valid `Projects` row for this
  /// id naming the caller as owner — and a push carrying no rows of that
  /// project at all. Both are unobservable to a prober, because both answer a
  /// real project and a fabricated one identically. See that file for the seam
  /// in full.
  ///
  /// Every other route treats "does not exist" and "not yours" as the same
  /// answer, which is the whole of §4.13's requirement.
  /// **A `viewer` counts here and that is the point.** Reading is the whole of
  /// what a viewer was granted, so pull and ack must work for them; the
  /// gradient is applied to *writes*, by [permitsProjectWrite] above. Gating
  /// sync itself on write rights would make "read the project" unreachable.
  bool get permitsSync => this == owner || this == contributor || this == viewer;
}

/// Resolves a caller's relationship to a project.
///
/// **Replaces task 10.9's `ProjectAccessGuard`**, which was an explicitly
/// temporary stand-in mounted so that 10.9's routes were not reachable without
/// *some* check. This is the real thing: it answers the project-level question
/// ("may you touch this project at all"), while [RowAuthorizer] answers the
/// row-level one ("may you write this particular row"). Both are needed —
/// project access alone would let a project's owner rewrite another person's
/// global `Users` row, and row rules alone would let a stranger probe a
/// project they have no relationship to.
abstract final class ProjectAuthorizer {
  static Future<ProjectAccess> resolve(
    Session session, {
    required String projectId,
    required String userId,
  }) async {
    // **Both statements return a result whose *size* does not depend on the
    // project** — that is what this shape is for, and it is task 11.72's
    // finding (§4.13, §20.6).
    //
    // ## What was wrong with reading the whole membership table
    //
    // Task 11.60 made a project that does not exist and a project that is
    // somebody else's cost the *same two queries*, because a skipped statement
    // is observable from outside. It never measured whether the two were then
    // actually the same length, and they were not: the second statement used
    // to be `WHERE project_id = $1` with no user filter, so a real project
    // returned one row per member and a fictional one returned none. Fetching,
    // transporting and decoding those rows is work, and work is time.
    //
    // Measured on a clean Linux runner by
    // `scripts/verify_11_49_server_reads.py` probe 7: the refusal for a real
    // project ran **about 54 microseconds slower**, sign positive in 9 of 9
    // trials over three separate runs, while the probe's own null pair (two
    // fictional ids, whose true difference is zero) flipped sign every run.
    // A developer's Mac cannot resolve that; a runner can, and the beta server
    // is a Linux machine.
    //
    // **And it was not a single bit.** `server/test/security/`
    // `authorization_timing_test.dart` measures this function directly and
    // found the cost rising with the project's membership count — roughly
    // +7 microseconds at one member, +17 at three, +71 at twenty, sign
    // unanimous at both of the last two. So the leak was never only "this id
    // is real"; it was a monotone reading of *how many people are on the
    // project*, available to a caller with no access to it. Equalising the
    // absent-versus-forbidden pair alone would have made the probe green and
    // left that untouched, which is the instance rather than the class.
    //
    // ## What the two statements below actually ask
    //
    // 1. **The facts about the project, as exactly one row whatever the id
    //    is.** Three scalar subqueries: the creator column, whether the
    //    project row exists at all, and whether *anybody* holds an open owner
    //    membership. `EXISTS` yields one boolean either way, so a project with
    //    two hundred members and an id that names nothing produce
    //    byte-identical result sets.
    // 2. **Only the caller's own membership rows.** For any caller who is not
    //    a member this is empty — for a real project and a fabricated one
    //    alike, which is the pair §4.13 is about. It is bounded by one
    //    person's own rejoin history rather than by the size of the team.
    //
    // **What this does not claim.** Not constant time — it is a database read.
    // An index probe that finds a row does a heap fetch and one that finds
    // nothing does not, and measured on a GitHub runner that residual is
    // **+5.0 microseconds** on the real-versus-fictional pair against a
    // per-id noise floor of 4.1 microseconds on the same run. It is accepted
    // in writing in §4.13, and `authorization_timing_test.dart` bounds it
    // rather than asserting it away.
    //
    // ## Why this still gives [resolveProjectRole] the answer it needs
    //
    // That function needs two things, and neither needs other people's rows:
    // whether *this* caller holds an open owner row, and — only when the
    // membership table names no open owner **at all** — the creator fallback.
    // So `creatorUserId` is passed only when `has_open_owner` is false, which
    // is exactly when [resolveProjectOwners] would have fallen back. When
    // somebody else owns the project, both formulations answer "not an owner":
    // the old one because the owner set does not contain the caller, this one
    // because the fallback is suppressed and the caller's own rows carry no
    // open owner row. `authorization_timing_test.dart` checks that equivalence
    // against the old whole-table formulation over a matrix of memberships,
    // rather than leaving it as an argument in a comment.
    final openClause = _openMembershipClause;
    final facts = await session.execute(
      'SELECT '
      '(SELECT owner_user_id FROM ${quoted(Tables.projects)} '
      r'WHERE project_id = $1) AS creator_user_id, '
      'EXISTS (SELECT 1 FROM ${quoted(Tables.projects)} '
      r'WHERE project_id = $1) AS project_exists, '
      'EXISTS (SELECT 1 FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND role = $2 '
      'AND $openClause) AS has_open_owner',
      parameters: [projectId, ownerMembershipRole],
    );

    // Task 11.3: one shared resolution, not a local re-derivation. The app's
    // repository layer calls the same function over its own rows, so the two
    // sides cannot disagree about someone's role the way they could about
    // ownership before task 11.1 hoisted [resolveProjectOwners]. It also
    // carries the two answers a hand-written query keeps getting wrong: the
    // creator fallback for a project whose membership table names no open
    // owner, and an unrecognised `role` string resolving to null rather than
    // to a guess.
    //
    // **Run before the [ProjectAccess.absent] branch below, not after, and
    // that ordering is deliberate (task 11.60).** This used to be `if
    // (project.isEmpty) return ProjectAccess.absent;` on the line above, so a
    // project id that names nothing cost one query and a project id that names
    // somebody else's project cost two. §4.13 requires those two to be
    // indistinguishable "from outside", and a status code and a body are not
    // the only things visible from outside — the amount of work done is too,
    // and it is the channel §4.13's own history (task 10.29, finding D-1) says
    // this section keeps being caught by.
    final own = await session.execute(
      'SELECT user_id, role, end_date, deleted_at '
      'FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND user_id = $2',
      parameters: [projectId, userId],
    );

    final about = facts.first.toColumnMap();
    if (about['project_exists'] != true) return ProjectAccess.absent;

    final role = resolveProjectRole(
      membershipRows: own.map((row) => row.toColumnMap()).toList(),
      // Null unless the membership table names no open owner at all, which is
      // exactly when [resolveProjectOwners] falls back to the creator.
      creatorUserId: about['has_open_owner'] == true
          ? null
          : about['creator_user_id'] as String?,
      userId: userId,
    );
    return switch (role) {
      ProjectRole.owner => ProjectAccess.owner,
      ProjectRole.contributor => ProjectAccess.contributor,
      ProjectRole.viewer => ProjectAccess.viewer,
      // Not a member, a closed stint, a tombstoned row, or a role this build
      // cannot interpret. All four are the same answer from outside (§4.13),
      // and all four are the safe one.
      null => ProjectAccess.none,
    };
  }

  /// `end_date IS NULL AND deleted_at IS NULL`, written from the declaration
  /// rather than spelled out.
  ///
  /// This is [isOpenOwnerMembership]'s "still open" half, expressed in SQL so
  /// that the `has_open_owner` probe above can be a boolean instead of a table
  /// scan. Saying it twice in two languages is the drift this project keeps
  /// finding, so it is **derived from `SyncTable.deactivationColumns`** — the
  /// same declaration [ClosedMembershipDisclosure.rowsFor] builds its "this
  /// stint is over" clause from, and its exact negation. A third way to end a
  /// membership arrives in both places or in neither.
  ///
  /// Column names come from the const `syncTables` descriptors, never from a
  /// request.
  static String get _openMembershipClause {
    final over = syncTablesByName[Tables.projectMemberships]!
        .deactivationColumns;
    if (over.isEmpty) {
      // Same rule, and same reason, as [ClosedMembershipDisclosure.rowsFor]:
      // an empty declaration is a bug, and answering "every row is open"
      // would silently promote every ended membership back to a live one.
      throw StateError(
        '${Tables.projectMemberships} declares no deactivationColumns, so '
        'there is no way to ask which memberships are still open. Declare '
        'them in syncTables — answering "all of them" would hand ownership '
        'back to everyone whose stint has ended.',
      );
    }
    return over.map((column) => '$column IS NULL').join(' AND ');
  }
}
