import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import '../models/project_membership.dart';
import '../models/sync_meta.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

/// Thrown when a mutation would leave a project with no open `owner`
/// membership at all (task 11.1).
///
/// Unlike [UnauthorizedMutation], this **is** a user-facing error: the person
/// hitting it is an owner doing something they are entitled to do, in a
/// project where it happens to be the last thing holding management together.
/// The plan calls for refusing "with an explanation rather than leaving an
/// unmanageable project", and [message] is that explanation — a project with
/// no owner has nobody who can add one, and on a laptop server there is no
/// privileged operator to appeal to.
class LastOwnerRemoval implements Exception {
  const LastOwnerRemoval(this.projectId);

  final String projectId;

  String get message =>
      'This is the project\'s last owner. Make someone else an owner first — '
      'a project with no owner cannot be managed, and nobody can restore it.';

  @override
  String toString() => 'LastOwnerRemoval($projectId): $message';
}

/// Thrown when somebody tries to leave a project they hold no open membership
/// of (task 11.28).
///
/// A user-facing error like [LastOwnerRemoval] rather than a bug like
/// [UnauthorizedMutation]: the ordinary way to see it is a stale screen — an
/// owner removed you, or you left on your other phone, and the sync that
/// carried that arrived between the list rendering and your tap.
class NotAProjectMember implements Exception {
  const NotAProjectMember(this.projectId, this.userId);

  final String projectId;
  final String userId;

  String get message =>
      'You are not currently a member of this project, so there is nothing to '
      'leave. It may have been synced from another device.';

  @override
  String toString() => 'NotAProjectMember($projectId, $userId): $message';
}

/// Why an insert into `Project_Memberships` is allowed to happen (task 11.2).
///
/// **Phase 8 deliberately does not authorize inserts.** `BaseRepository`'s rule
/// check runs against a *stored* row, so on an insert there is nothing to
/// compare and the mutation affects zero rows — harmless for every table where
/// creating a row means adding your own field data.
///
/// It is not harmless here, because **in this table the insert *is* the
/// grant.** Task 11.1 noticed that and hand-checked the actor inside what was
/// then `ProjectMembershipRepository.grantOwner`; task 11.2's brief flagged
/// that letting somebody in would be a second insert needing the same
/// treatment, and that nothing would fail loudly if it were forgotten. A
/// second hand-check is the shape the "fix the class, not the instance" rule
/// exists to refuse — so instead of adding one, **every** insert into this
/// table now has to name the authority it is acting under, and the repository
/// verifies it.
///
/// There are exactly three:
///
/// - [bootstrapOwner] — the row that makes a project's creator its owner. Only
///   valid while the project has no open owner membership at all, and only for
///   the user `Projects.owner_user_id` already records. It cannot hand
///   ownership to anyone else and cannot be replayed against a project that
///   already has an owner.
/// - [byOwner] — an existing owner inserting a role for somebody else.
///   **Task 11.62 deleted `grantOwner`, this door's only production caller**:
///   it named a stranger on an insert, which [_authorizeNaming] refuses
///   unconditionally on the server, so the insert half could never land
///   through a real sync push. Promoting an *existing* member to owner —
///   the half that did work — is `MembershipProvider.changeRole`, an
///   ordinary update. `byOwner` itself is kept: it is still what the tests
///   below use to seed a membership row honestly, and deleting a door that
///   several unrelated test files depend on to model "an owner added this
///   row" is a larger change than this task's scope.
/// - [replication] — a row that was decided somewhere else and is being
///   written here verbatim. **This one checks nothing**, exactly like
///   `MutationActor.replication`, and for the same stated reason: replication
///   genuinely does write rows this device had no part in authorizing, and a
///   named door that has to be typed out with a reason is better than a
///   permissive default nobody can grep for. Production replication does not
///   use it — `ProjectMerger._upsert` writes raw, below the repository — so
///   its only callers today are tests seeding state that arrived by merge.
///
/// **There is deliberately no door for a join approval or a re-admission.**
/// The server writes that membership row itself — from the request's own
/// `project_id` and the role the owner chose at that moment (task 11.81,
/// `JoinService`) — and this device receives it through an ordinary pull. See
/// `SyncService.insertServerAuthoredRow` for why that is the safer half of the
/// trade. Rows arriving by pull or by backup merge do not pass through this
/// repository at all — `ProjectMerger._upsert` writes raw, inside its own
/// transaction, exactly as it does for every other table.
///
/// **None of this is a security boundary.** Client-side checks stop honest
/// paths; a hostile device edits its own SQLite and pushes. The boundary is the
/// server's, in `RowAuthorizer`, and task 11.3 completes it. This is here so
/// the app cannot be *wrong*, which is a different and also necessary thing.
sealed class MembershipInsertAuthority {
  const MembershipInsertAuthority();

  /// The creator's own owner row, on a project that has no owner yet.
  const factory MembershipInsertAuthority.bootstrapOwner() = _BootstrapOwner;

  /// [actor] is already an owner of the project the row names.
  const factory MembershipInsertAuthority.byOwner(MutationActor actor) =
      _ByOwner;

  /// The row was authorized elsewhere and is being replicated verbatim.
  /// [reason] is required so every use has to say what "elsewhere" was.
  const factory MembershipInsertAuthority.replication(String reason) =
      _Replication;
}

class _BootstrapOwner extends MembershipInsertAuthority {
  const _BootstrapOwner();
}

class _ByOwner extends MembershipInsertAuthority {
  const _ByOwner(this.actor);
  final MutationActor actor;
}

class _Replication extends MembershipInsertAuthority {
  const _Replication(this.reason);
  final String reason;
}

class ProjectMembershipRepository extends BaseRepository {
  ProjectMembershipRepository(super.db)
    : super(
        table: Tables.projectMemberships,
        pk: const ['membership_id', 'project_id'],
        // Only a project owner may change a membership row (task 8.4).
        // Task 11.1 moved "owner" from `Projects.owner_user_id` to the
        // project's open `owner` memberships; [resolveProjectOwners] keeps
        // 8.4's bootstrap concern answered by falling back to the column when
        // the table names no owner, so authorizing a membership mutation
        // still never *requires* a membership row to exist yet.
        rule: MutationRule.projectOwner,
      );

  /// Inserts [membership] under a named [authority].
  ///
  /// See [MembershipInsertAuthority] for why this table's insert needs one at
  /// all when no other table's does. Throws [UnauthorizedMutation] when the
  /// authority does not hold.
  ///
  /// **The authority is the whole of the gate here.** `BaseRepository.insertRow`
  /// would also run the role gradient against the row's `last_modified_by`,
  /// which on every other table is a sound stand-in for the acting user. On
  /// this table it is not: a [MembershipInsertAuthority.byOwner] row is
  /// written *by the owner* and *about the member*, and the audit column may
  /// legitimately name either — so the row cannot say who is acting, and
  /// [_requireAuthority] has already re-derived the permission from the person
  /// who can. Since task 11.237 the gradient also refuses somebody the device
  /// can see is not on the project; asked of the row's audit name on a grant,
  /// that would refuse the very row that makes them one. Written directly
  /// once the authority holds, with the same abort-on-conflict as
  /// `insertRow`.
  Future<void> insert(
    ProjectMembership membership, {
    required MembershipInsertAuthority authority,
  }) async {
    await _requireAuthority(membership, authority);
    await db.insert(
      table,
      membership.toColumns(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<void> _requireAuthority(
    ProjectMembership membership,
    MembershipInsertAuthority authority,
  ) async {
    final projectId = membership.projectId;
    switch (authority) {
      case _Replication(:final reason):
        // Checks nothing, on purpose. See [MembershipInsertAuthority].
        assert(reason.isNotEmpty, 'a replication insert must state its origin');
        return;
      case _ByOwner(:final actor):
        if (await isOwner(projectId, actor.userId ?? '')) return;
        throw UnauthorizedMutation(
          table: table,
          rowId: '$projectId/${membership.userId}',
          rule: rule,
          actorUserId: actor.userId,
          permitted: (await ownersOf(projectId)).join(', '),
        );
      case _BootstrapOwner():
        // Two conditions, and both matter. "No open owner yet" is what stops
        // this being replayable against an established project; "names the
        // recorded creator" is what stops it granting ownership to anyone
        // else. Either alone would leave a way in.
        final creator = await _creatorOf(projectId);
        final claimsOwner = isOpenOwnerMembership(membership.toColumns());
        if (claimsOwner &&
            creator != null &&
            membership.userId == creator &&
            (await openOwnerships(projectId)).isEmpty) {
          return;
        }
        throw UnauthorizedMutation(
          table: table,
          rowId: '$projectId/${membership.userId}',
          rule: rule,
          actorUserId: membership.userId,
          permitted: creator ?? '',
        );
    }
  }

  Future<String?> _creatorOf(String projectId) async {
    final projects = await db.query(
      Tables.projects,
      columns: ['owner_user_id'],
      where: 'project_id = ?',
      whereArgs: [projectId],
      limit: 1,
    );
    return projects.isEmpty ? null : projects.first['owner_user_id'] as String?;
  }

  /// Ensures [projectId] has an open owner membership, backfilling or
  /// promoting the recorded creator's row if it does not (task 8.4,
  /// corrected by 11.1 — see `_ensureOwnerMembership` in
  /// `app_context_provider.dart`, this method's one caller, for why the
  /// check runs on every project load and for the two ways "does the
  /// creator have any open row" gets ownership transfer wrong).
  ///
  /// Idempotent: returns immediately once any open owner membership exists.
  ///
  /// **Promotes, never duplicates (task 11.10).** If the creator already
  /// holds an open membership of some other role — exactly what a demotion,
  /// or a merge landing mid-transfer, can leave — this promotes that row to
  /// owner in place rather than inserting a second one. A second insert is
  /// what `idx_memberships_one_open` (schema v8) now refuses outright, and
  /// what the one-open-membership-per-project invariant forbade regardless;
  /// this repair path inserting one anyway, unconditionally, was the bug
  /// that index turned from silent to loud. Both the promotion and the
  /// fresh insert bypass ordinary authorization
  /// (`MutationActor.replication` / [MembershipInsertAuthority
  /// .bootstrapOwner]) for the reason [_BootstrapOwner] documents: there is
  /// by definition no current owner to authorize the write, which is the
  /// whole condition under which this method does anything at all.
  ///
  /// **Does not resurrect a closed row (task 11.280).** "No open row" is
  /// ambiguous between two states this method used to treat as one: a
  /// pre-8.4 database that has never had a membership row at all (the case
  /// this method exists for), and a creator whose own row was just closed —
  /// by leaving, or by another owner removing them. Task 11.60 taught the
  /// device to learn the second one from a `200` or a `403`'s disclosure
  /// pull; this method, called from every project load, was silently undoing
  /// that lesson by treating the closed row's absence-of-an-open-one exactly
  /// like the never-had-one case and re-inserting a fresh, open, local-only
  /// owner row — so a removed owner's own device kept putting them back on
  /// the project it had just been told they left, and `SyncFailureCause
  /// .membershipEnded` could never be reached again. **If the creator holds
  /// any row for this project, closed or open, this method leaves it alone**
  /// — only a creator with no row here at all is a true backfill case.
  Future<void> ensureOwnerMembership({
    required String projectId,
    required DateTime creationDate,
    required DateTime now,
    String? deviceId,
  }) async {
    if ((await openOwnerships(projectId)).isNotEmpty) return;
    final creator = await _creatorOf(projectId);
    if (creator == null) return;

    final existing = await findForUser(projectId, creator);
    if (existing != null) {
      await update(
        existing.copyWith(role: ProjectRole.owner),
        actor: const MutationActor.replication(
          "task 8.4/11.1 owner-membership repair: promoting the creator's "
          'existing open row instead of opening a second one for the same '
          'person (task 11.10)',
        ),
        deviceId: deviceId,
      );
      return;
    }

    // The creator has no *open* row. Before inserting one, tell "never had a
    // row" (the true backfill case) apart from "has a closed row" (they left,
    // or were removed, and this repair must not put them back).
    final priorRows = await findByProject(projectId, includeDeleted: true);
    if (priorRows.any((m) => m.userId == creator)) return;

    await insert(
      ProjectMembership(
        membershipId: const Uuid().v4(),
        projectId: projectId,
        userId: creator,
        joinDate: creationDate,
        role: ProjectRole.owner,
        sync: SyncMeta.initial(
          now: now,
          modifiedBy: creator,
          originDeviceId: deviceId,
        ),
      ),
      authority: const MembershipInsertAuthority.bootstrapOwner(),
    );
  }

  /// A row is identified by its id *within a project* since task 10.35 — the
  /// same id may legitimately exist in another project, so [projectId] is not
  /// a filter but half the key.
  Future<ProjectMembership?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'membership_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : ProjectMembership.fromRow(row);
  }

  Future<List<ProjectMembership>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'join_date',
    );
    return rows.map(ProjectMembership.fromRow).toList();
  }

  /// [userId]'s current (not-yet-ended) membership on [projectId], or null
  /// if they aren't a member. "Current" means `end_date IS NULL` — per the
  /// model doc, a membership is deactivated by setting `end_date`, not by
  /// the soft-delete tombstone, so a past span with an end date correctly
  /// doesn't count even though it isn't deleted.
  Future<ProjectMembership?> findForUser(
    String projectId,
    String userId,
  ) async {
    final rows = await findRows(
      where: 'project_id = ? AND user_id = ? AND end_date IS NULL',
      whereArgs: [projectId, userId],
    );
    return rows.isEmpty ? null : ProjectMembership.fromRow(rows.first);
  }

  /// **Whether this device's own records say [userId] has left [projectId]**
  /// — a closed stint and no open one. **The one derivation of "have I left
  /// this project"** (task 11.305); `SyncController` asks it on every path
  /// that can say so, and `departedProjectIds` asks it for the whole list.
  ///
  /// Three states, and only one of them is a departure:
  ///
  /// - **An open row** — still a member, as far as this device knows. A
  ///   server refusal against this is *access refused*: an owner may have
  ///   removed them and the pull that would say so is the request being
  ///   refused, or something is wrong with the server. This device cannot
  ///   tell which, so it must not claim either.
  /// - **A closed row and no open one** — they left, or an owner removed them
  ///   and this device has already been told. **This is the only answer that
  ///   is `true`.**
  /// - **No row at all** — this device has never recorded them on the
  ///   project. Not a departure: a purely local project has rows for nobody,
  ///   and a project left linked by a different account's session has none
  ///   for the person now signed in. Until task 11.305 the sync round read
  ///   this third state as the second, so a second account's first automatic
  ///   round unlinked the first account's project and told the newcomer
  ///   *"You're no longer on this project"* about one they were never on —
  ///   while `SyncController.build`, asking its own copy of the question,
  ///   already required the closed row. Two derivations of one question, and
  ///   the wider one acted. `sign_out_leaves_sync_state_test.dart` holds the
  ///   case.
  ///
  /// A tombstoned row counts as closed: [findForUser] excludes tombstones, so
  /// a row soft-deleted by a merge reads here exactly as an ended one does.
  Future<bool> hasDeparted(String projectId, String userId) async {
    if (await findForUser(projectId, userId) != null) return false;
    final all = await findByProject(projectId, includeDeleted: true);
    return all.any((m) => m.userId == userId);
  }

  /// Every membership row of [projectId] — ended and tombstoned ones
  /// included, because [resolveProjectOwners] is what filters them.
  Future<List<Map<String, Object?>>> _allMembershipRows(String projectId) =>
      findRows(
        where: 'project_id = ?',
        whereArgs: [projectId],
        includeDeleted: true,
      );

  /// The users who currently own [projectId] (task 11.1). Any number, all with
  /// identical rights.
  ///
  /// This is the authorization question `Projects.owner_user_id` used to
  /// answer. It routes through the shared [resolveProjectOwners] so this
  /// device, every other device, and the server cannot disagree about it.
  Future<Set<String>> ownersOf(
    String projectId, {
    String? creatorUserId,
  }) async {
    var creator = creatorUserId;
    if (creator == null) {
      final projects = await db.query(
        Tables.projects,
        columns: ['owner_user_id'],
        where: 'project_id = ?',
        whereArgs: [projectId],
        limit: 1,
      );
      creator = projects.isEmpty
          ? null
          : projects.first['owner_user_id'] as String?;
    }
    return resolveProjectOwners(
      membershipRows: await _allMembershipRows(projectId),
      creatorUserId: creator,
    );
  }

  /// Whether [userId] is one of [projectId]'s current owners.
  Future<bool> isOwner(String projectId, String userId) async =>
      (await ownersOf(projectId)).contains(userId);

  /// The open `owner` membership rows of [projectId].
  Future<List<ProjectMembership>> openOwnerships(String projectId) async {
    final rows = await _allMembershipRows(projectId);
    return [
      for (final row in rows)
        if (isOpenOwnerMembership(row)) ProjectMembership.fromRow(row),
    ];
  }

  Future<int> update(
    ProjectMembership membership, {
    required MutationActor actor,
    String? deviceId,
  }) async {
    await _guardLastOwner(membership);
    return updateByKey(
      {
        'membership_id': membership.membershipId,
        'project_id': membership.projectId,
      },
      membership.toColumns(),
      actor: actor,
      deviceId: deviceId,
    );
  }

  @override
  Future<int> softDeleteByKey(
    Map<String, Object?> key, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    MutationExemption? exemption,
  }) async {
    final existing = await findRowByKey(key);
    if (existing != null && isOpenOwnerMembership(existing)) {
      await _guardLastOwnerRemoval(
        projectId: existing['project_id'] as String,
        membershipId: existing['membership_id'] as String,
      );
    }
    return super.softDeleteByKey(
      key,
      actor: actor,
      deviceId: deviceId,
      now: now,
      // Passed through rather than dropped. No exemption today names this
      // table — [MutationExemption.departedMember] refuses any table but
      // `Projects` — but an override that silently discards an argument its
      // supertype acts on is a trap for whoever adds the second one.
      exemption: exemption,
    );
  }

  /// Ends [membership]'s stint by setting `end_date`.
  ///
  /// **Promoting somebody *to* owner is `MembershipProvider.changeRole`**, an
  /// ordinary update to a membership row the caller already has in hand.
  /// Task 11.62 deleted `grantOwner`, which used to live here as this
  /// method's paired "half one": it inserted a fresh membership row naming
  /// somebody who was not yet a member, at the `owner` role, and
  /// [_authorizeNaming] on the server refuses any client-pushed insert that
  /// names somebody other than the caller, unconditionally — so that branch
  /// could never succeed against a real server. Nothing in the app ever
  /// called it: the promotion-of-an-existing-member branch it also handled
  /// duplicated `changeRole`, and adding somebody new as an owner outright is
  /// an invitation issued at the `owner` role, which the server authors
  /// itself and delivers by an ordinary pull — never a client push, so it
  /// never meets this refusal at all.
  ///
  /// Refused with [LastOwnerRemoval] if it is the project's last open owner
  /// membership — see [_guardLastOwner], which [update] applies. Sets
  /// `end_date` rather than tombstoning or nulling anything, because the
  /// record of the stint is the point (task 11.2's lifecycle rule).
  Future<void> endMembership(
    ProjectMembership membership, {
    required MutationActor actor,
    required DateTime now,
    String? deviceId,
  }) => update(
    membership.copyWith(endDate: now),
    actor: actor,
    deviceId: deviceId,
  );

  /// **Leaving a project: the only door out for somebody who is not an owner
  /// (task 11.28).**
  ///
  /// Ends the **caller's own** open membership of [projectId] by setting
  /// `end_date`, and returns the row as it now stands.
  ///
  /// ## Why this is a separate method rather than an argument to
  /// [endMembership]
  ///
  /// Because of what it cannot be asked to do. [endMembership] takes the row
  /// to end, so "end somebody else's" is a value away; this takes a project
  /// and an actor and **finds the row itself**, from the actor's own id. There
  /// is no parameter that names a row, a membership id or another user, so the
  /// call that ends a colleague's stint through this path cannot be written.
  /// Task 11.9 spent eighteen probes on this surface and the mistake it was
  /// looking for is an exception that also reaches other people's rows; the
  /// cheapest way not to make it is to have nowhere to put the other person's
  /// id.
  ///
  /// ## The two rules it must not break, and where each is enforced
  ///
  /// - **A project cannot be left with no owner.** [_guardLastOwnerRemoval]
  ///   runs before the write, so the last owner is refused with
  ///   [LastOwnerRemoval] and told to make somebody else an owner first — the
  ///   same refusal, with the same message, an owner gets for removing
  ///   themselves. The server refuses it independently
  ///   (`RowAuthorizer._authorizeOwnerRemoval`), including the case this
  ///   device cannot see: two owners leaving from two offline devices.
  /// - **This must not become a way to remove anybody but yourself.** Above,
  ///   plus [isSelfDeparture], which is asserted here against the row this
  ///   method built and enforced again at the boundary against the row that
  ///   actually arrives.
  ///
  /// ## Why the write skips the table's rule
  ///
  /// `Project_Memberships` is [MutationRule.projectOwner]: an owner writes it
  /// and nobody else. That is right for every other write to this table and
  /// wrong for exactly this one, so the rule is replaced — not relaxed — by
  /// the narrower [isSelfDeparture], which the server applies to the same
  /// write. See [BaseRepository.updateByKeyUnderNarrowerRule].
  ///
  /// Throws [NotAProjectMember] if the caller holds no open membership,
  /// [LastOwnerRemoval] if they are the last owner, and [ArgumentError] if
  /// [actor] is a replication actor (replication does not "leave" anything;
  /// it writes rows decided elsewhere).
  Future<ProjectMembership> leaveProject({
    required String projectId,
    required MutationActor actor,
    required DateTime now,
    String? deviceId,
  }) async {
    final userId = actor.userId;
    if (userId == null || userId.isEmpty) {
      throw ArgumentError.value(
        actor,
        'actor',
        'leaving a project is something a person does; a replication actor '
            'has nobody to leave as',
      );
    }
    final mine = await findForUser(projectId, userId);
    if (mine == null) throw NotAProjectMember(projectId, userId);
    // **Only an owner can be the last one.** Guarding unconditionally reads as
    // the safer choice and is not: `_guardLastOwnerRemoval` refuses when no
    // *other* open owner row exists, and for a contributor on a project whose
    // owner row has not been backfilled yet there are none at all — so an
    // unconditional guard would refuse a contributor's departure with
    // "you are the last owner", which is both wrong and confusing. Same
    // condition [_guardLastOwner] applies for the same reason: a row that does
    // not currently confer ownership has none to take away.
    if (isOpenOwnerMembership(mine.toColumns())) {
      await _guardLastOwnerRemoval(
        projectId: projectId,
        membershipId: mine.membershipId,
      );
    }

    final departed = mine.copyWith(endDate: now.toUtc());
    // Asserted rather than assumed. The row above was built from the stored
    // one by changing a single field, so this cannot fail — which is the
    // point: if a future edit to this method makes it fail, it fails here,
    // loudly, on this device, instead of becoming a row the server refuses
    // and holds forever. That silent-divergence outcome is the defect task
    // 11.28 exists to end, so reintroducing it must not be quiet.
    if (!isSelfDeparture(
      table: table,
      callerUserId: userId,
      existing: mine.toColumns(),
      incoming: departed.toColumns(),
    )) {
      throw StateError(
        'leaveProject built a write that is not a self-departure for '
        '$userId on $projectId — refusing to send the server a row it will '
        'refuse',
      );
    }

    await updateByKeyUnderNarrowerRule(
      {'membership_id': mine.membershipId, 'project_id': projectId},
      departed.toColumns(),
      actor: actor,
      because:
          'task 11.28: a person may end their own open membership row and '
          'nothing else (isSelfDeparture), which is narrower than this '
          "table's projectOwner rule rather than an exception to it",
      deviceId: deviceId,
    );
    return departed;
  }

  /// Refuses an update that would take [membership]'s ownership away when it
  /// is the project's last. Covers all three ways a row stops conferring
  /// ownership — `end_date`, the tombstone, and a demoted `role` — because
  /// [isOpenOwnerMembership] is the single definition of what confers it.
  Future<void> _guardLastOwner(ProjectMembership membership) async {
    final stored = await findRowByKey({
      'membership_id': membership.membershipId,
      'project_id': membership.projectId,
    }, includeDeleted: true);
    if (stored == null || !isOpenOwnerMembership(stored)) return;
    if (isOpenOwnerMembership(membership.toColumns())) return;
    await _guardLastOwnerRemoval(
      projectId: membership.projectId,
      membershipId: membership.membershipId,
    );
  }

  Future<void> _guardLastOwnerRemoval({
    required String projectId,
    required String membershipId,
  }) async {
    final others = (await openOwnerships(
      projectId,
    )).where((m) => m.membershipId != membershipId);
    if (others.isEmpty) throw LastOwnerRemoval(projectId);
  }
}
