import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import '../../core/text/role_labels.dart';
import 'mutation_authorization.dart';
import 'project_role_lookup.dart';

/// Shared persistence behavior for every table, centralizing the two things
/// the technical doc insists on getting right everywhere:
///
/// 1. **Soft-delete convention.** Reads exclude tombstoned rows
///    (`deleted_at IS NULL`) by default; there are no hard deletes (a hard
///    delete would resurrect on the next merge). [softDeleteById] sets the
///    tombstone instead of removing the row.
/// 2. **Revision/timestamp bookkeeping.** [updateById] and [softDeleteById]
///    bump `revision` and set `updated_at` atomically in SQL (no
///    read-modify-write race), which is what last-write-wins merge relies on.
/// 3. **Authorization.** Every mutation names its [MutationActor], which is
///    both stamped into `last_modified_by` and checked against the table's
///    [MutationRule] — so a screen that forgets to gate an affordance still
///    can't write another user's row. Advisory only, not security; see
///    `mutation_authorization.dart`.
///
/// Typed repositories extend this and add model &lt;-&gt; row mapping.
class BaseRepository {
  BaseRepository(
    this.db, {
    required this.table,
    required this.pk,
    required this.rule,
  });

  /// Either the app's [Database] or a [Transaction] running inside it.
  ///
  /// Widened from [Database] by task 10.94 (finding M-2), which needed the tag
  /// CSV commit loop to be one transaction instead of N independent writes.
  /// The same widening [ProjectMerger] and [SharedObservationImporter] already
  /// take — nothing in this class ever needed more than [DatabaseExecutor]
  /// (query, rawQuery, insert, rawUpdate), so a repository composed into a
  /// caller's transaction is the shape that was always available and never
  /// reachable.
  final DatabaseExecutor db;
  final String table;

  /// Who is allowed to mutate rows of this table.
  final MutationRule rule;

  /// The table's primary-key columns, in declaration order — mirroring
  /// `SyncTable.primaryKey` for the same table.
  ///
  /// This became a list in task 10.35, when the six project-scoped data tables
  /// were re-keyed `(<id>, project_id)`. Before that a single id identified a
  /// row anywhere in the database; now it identifies one only *within a
  /// project*, and the same id may legitimately appear in two of them — that
  /// is the whole point of the change, since a shared observation keeps the
  /// sender's id and lands in the receiver's own project.
  ///
  /// Everything below therefore builds its `WHERE` from the whole key. A
  /// partial key here would not fail; it would quietly match the wrong
  /// project's row, which for [_authorize] means authorizing against the wrong
  /// project's owner.
  final List<String> pk;

  /// `col = ? AND …` over the full primary key, with the values in matching
  /// order.
  ///
  /// Throws [ArgumentError] if [key] is not exactly the primary key. That is
  /// deliberate and is the point of the method: the failure mode this replaced
  /// was a *silent* one, so an incomplete key has to be an error rather than a
  /// narrower query.
  (String, List<Object?>) _keyClause(Map<String, Object?> key) {
    if (key.length != pk.length || !pk.every(key.containsKey)) {
      throw ArgumentError.value(
        key.keys.toList(),
        'key',
        'must be exactly $table\'s primary key $pk',
      );
    }
    return (
      pk.map((c) => '$c = ?').join(' AND '),
      [for (final column in pk) key[column]],
    );
  }

  /// The single-column form of [_keyClause], for tables that still have one.
  ///
  /// `pk.single` throws a [StateError] on a composite-key table, which is the
  /// intended behaviour: it turns "this call site was never updated for
  /// project-scoped keys" into an immediate, obvious failure instead of a
  /// query that returns some other project's row.
  Map<String, Object?> _singleKey(Object id) => {pk.single: id};

  /// Columns the repository manages; callers must not set these directly on
  /// an update (they'd clobber audit/merge state).
  static const _managedColumns = {
    'created_at',
    'updated_at',
    'deleted_at',
    'revision',
    'last_modified_by',
    'origin_device_id',
  };

  String _nowUtc(DateTime? now) => DbCodec.encodeUtc(now ?? DateTime.now());

  /// Inserts a fully-formed row (including its sync columns). Aborts on PK
  /// conflict rather than silently replacing.
  ///
  /// **Authorized for the role gradient only (task 11.3), not by the rule
  /// table.** Phase 8 deliberately authorizes no inserts here — [_authorize]
  /// runs against a *stored* row, and on an insert there isn't one — and that
  /// stays true. What is checked is the coarser question the gradient asks: a
  /// `viewer` may write nothing in the project this row belongs to, and
  /// creating a row is writing. Without this a viewer's device would record
  /// happily and pile up a refusal per row on every sync, which is a worse way
  /// to learn you are read-only than being told at the point of the tap.
  ///
  /// See [actorOf] for why the acting user is read off the row.
  Future<void> insertRow(Map<String, Object?> columns) async {
    await assertRoleMayWrite(columns[_projectScopeColumn], actorOf(columns));
    await db.insert(table, columns, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// The column scoping this table's rows to a project, or null for the three
  /// global tables. Read from the shared descriptor rather than declared again
  /// here, so this and the server's `RowAuthorizer` cannot disagree about which
  /// tables belong to a project.
  String? get _projectScopeColumn =>
      syncTablesByName[table]?.projectScopeColumn;

  /// Who an *insert* is being performed as, taken from the row's
  /// `last_modified_by`.
  ///
  /// [insertRow] takes no [MutationActor] and this does not add one: doing so
  /// would mean threading an argument through eleven repositories and every
  /// screen that creates a record, for a check that is advisory on this side of
  /// the wire. The column is a sound stand-in **on an insert specifically** —
  /// every model's `SyncMeta.initial` stamps it with the user creating the row,
  /// and nothing replicates *other people's* rows through a repository
  /// (`ProjectMerger` and `SharedObservationImporter` both write raw statements
  /// inside their own transaction, which is also why they were never subject to
  /// the rule table).
  ///
  /// A null or non-string value yields a null actor, which permits — see
  /// [assertRoleMayWrite].
  /// Subclass-facing: not private only so a repository with a
  /// table-specific rule can reuse it. See [TagRepository].
  MutationActor actorOf(Map<String, Object?> columns) {
    final value = columns['last_modified_by'];
    return value is String && value.isNotEmpty
        ? MutationActor.user(value)
        : const MutationActor.replication('row names no acting user');
  }

  /// **The role gradient, client-side (task 11.3).**
  ///
  /// Throws [UnauthorizedMutation] when [actor]'s role in [projectId]'s project
  /// is `viewer` — read the project, change nothing — **or, since task 11.237,
  /// when this device can see that [actor] is not on the project at all.**
  ///
  /// ## It denies on `viewer`, on *not a member*, and on nothing else
  ///
  /// The server refuses a caller with no role. Until 11.237 this did not,
  /// because a `null` role covered two situations that only one answer could
  /// be given for: a local SQLite file legitimately contains projects the
  /// device has no membership row for — one restored from a backup, one
  /// created offline and never published, one whose owner membership row has
  /// not been backfilled yet — and refusing those would make the app
  /// read-only on data it is the only holder of. **Every one of those is
  /// answered by the creator fallback** (`Projects.owner_user_id` names the
  /// person) or by having no `Projects` row here at all, and both still
  /// permit: [ProjectStanding.unknown] is *when the device has not been told a
  /// rung, defer to the server*.
  ///
  /// What is refused now is the case the `null` used to hide: **the project's
  /// row and its membership rows are here, and none of them is this
  /// person's.** That is a colleague's archive imported by somebody who is not
  /// on the team. Michael decided (2026-09-13) it is a read-only snapshot,
  /// because an edit that can never leave the device looks like contributing
  /// and is not. The refusal names the way in — see
  /// [notAMemberWriteRefusal].
  ///
  /// A role string this build does not recognise resolves to
  /// [ProjectStanding.unknown] and therefore permits *here* — and is refused
  /// by the server, which is the right way round for an advisory check
  /// against an authoritative one.
  /// Subclass-facing: not private only so a repository with a
  /// table-specific rule can reuse it. See [TagRepository].
  Future<void> assertRoleMayWrite(
    Object? projectId,
    MutationActor actor,
  ) async {
    if (actor.isReplication) return;
    if (projectId is! String || projectId.isEmpty) return;
    final standing = await projectStandingFor(projectId, actor.userId);
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
      case MemberStanding(:final role):
        if (role.mayWriteProjectData) return;
        throw UnauthorizedMutation(
          table: table,
          rowId: projectId,
          rule: rule,
          actorUserId: actor.userId,
          permitted:
              'a contributor or owner of this project '
              '(you are ${role.withArticle})',
        );
    }
  }

  /// [actorUserId]'s standing in [projectId] — their role, *not a member*, or
  /// *this device cannot say*. See [ProjectStanding] for the three, and
  /// [readProjectStanding] for how they are read.
  /// Subclass-facing: not private only so a repository with a
  /// table-specific rule can reuse it. See [TagRepository].
  ///
  /// The query itself is [readProjectStanding], hoisted out of this method by
  /// task 11.19 (as `readProjectRole`, then) so `SharedObservationImporter` —
  /// which writes raw statements inside its own transaction and has no
  /// repository to ask — resolves an answer from the same rows, by the same
  /// rule, as the write guard above and the screens above.
  Future<ProjectStanding> projectStandingFor(
    String projectId,
    String? actorUserId,
  ) => readProjectStanding(db, projectId: projectId, userId: actorUserId);

  /// Fetches one row by primary key. Excludes tombstoned rows unless
  /// [includeDeleted].
  Future<Map<String, Object?>?> findRowByKey(
    Map<String, Object?> key, {
    bool includeDeleted = false,
  }) async {
    final (clause, args) = _keyClause(key);
    final rows = await db.query(
      table,
      where: includeDeleted ? clause : '$clause AND deleted_at IS NULL',
      whereArgs: args,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// [findRowByKey] for a table whose primary key is a single column. Throws
  /// on a composite-key table — see [_singleKey].
  Future<Map<String, Object?>?> findRowById(
    Object id, {
    bool includeDeleted = false,
  }) => findRowByKey(_singleKey(id), includeDeleted: includeDeleted);

  /// Fetches rows, always filtering out tombstones unless [includeDeleted].
  /// A caller-supplied [where] is AND-combined with the tombstone filter.
  Future<List<Map<String, Object?>>> findRows({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
    bool includeDeleted = false,
  }) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (!includeDeleted) clauses.add('deleted_at IS NULL');
    if (where != null) {
      clauses.add('($where)');
      if (whereArgs != null) args.addAll(whereArgs);
    }
    return db.query(
      table,
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: orderBy,
      limit: limit,
    );
  }

  /// Throws [UnauthorizedMutation] if [actor] may not mutate the row [key]
  /// identifies under this table's [rule]. A missing row passes: there's
  /// nothing to authorize against, and the mutation itself will affect zero
  /// rows.
  ///
  /// The full key matters here more than anywhere else in this class. Under an
  /// ownership rule this reads the row's `project_id` and then resolves *that*
  /// project's owners; keyed on the bare id, a row id that also exists in
  /// another project would resolve the wrong project's owners and authorize the
  /// mutation against them. [_keyClause] makes a partial key impossible rather
  /// than merely unlikely.
  Future<void> _authorize(
    Map<String, Object?> key,
    MutationActor actor, {
    MutationExemption? exemption,
  }) async {
    if (actor.isReplication) return;
    if (exemption != null && await _exemptionHolds(exemption, key, actor)) {
      return;
    }

    final scope = _projectScopeColumn;
    // Two columns, not one: task 11.15's [MutationRule.authorOrOwner] needs
    // both halves of its disjunction off the same row — the project whose
    // owners govern, *and* the user the row names. Every other rule leaves one
    // of them null.
    final projectColumn = rule.projectColumn;
    final userColumn = rule.userColumn;
    if (scope == null && projectColumn == null && userColumn == null) return;

    final (clause, args) = _keyClause(key);
    // Tombstoned rows included deliberately: [restoreByKey] targets exactly
    // those, and a tombstone doesn't transfer ownership.
    final rows = await db.query(
      table,
      columns: {?scope, ?projectColumn, ?userColumn}.toList(),
      where: clause,
      whereArgs: args,
      limit: 1,
    );
    if (rows.isEmpty) return;

    // **The role gradient, before anything about this row (task 11.3).** A
    // `viewer` is refused every row of the project, whoever wrote it — which
    // includes rows they wrote themselves before their role changed. Asked
    // first because it is not a question about the row: it has the same answer
    // for all of them, and it is what the [MutationRule.anyUser] tables have
    // instead of a rule, since that rule singles nobody out.
    if (scope != null) {
      await assertRoleMayWrite(rows.first[scope], actor);
    }
    if (projectColumn == null && userColumn == null) return;

    final authorUserId = userColumn == null
        ? null
        : _governingValue(rows.first, userColumn);
    if (rule.resolvesProjectOwners) {
      // Task 11.1: the permitted set includes that project's current owners,
      // not the single user named in `Projects.owner_user_id` — see
      // [resolveProjectOwners], whose answer this and the server's
      // `RowAuthorizer` both compare against. Task 11.15: for
      // [MutationRule.authorOrOwner] it also includes [authorUserId], which is
      // why that is passed rather than left to a default.
      final projectId = projectColumn == null
          ? null
          : _governingValue(rows.first, projectColumn);
      final owners = projectId == null ? null : await _projectOwners(projectId);
      if (rule.permittedByOwners(
        actor.userId,
        owners: owners,
        authorUserId: authorUserId,
      )) {
        return;
      }
      throw UnauthorizedMutation(
        table: table,
        rowId: pk.map((c) => key[c]).join('/'),
        rule: rule,
        actorUserId: actor.userId,
        permitted: [?authorUserId, ...?owners].join(', '),
      );
    }
    if (rule.permits(actor.userId, authorUserId)) return;
    throw UnauthorizedMutation(
      table: table,
      rowId: pk.map((c) => key[c]).join('/'),
      rule: rule,
      actorUserId: actor.userId,
      permitted: authorUserId,
    );
  }

  /// The current owners of [projectId], or null if this device holds no such
  /// project. Null and empty mean different things — see
  /// [MutationRule.permittedByOwners].
  Future<Set<String>?> _projectOwners(String projectId) async {
    final projectRows = await db.query(
      Tables.projects,
      columns: ['owner_user_id'],
      where: 'project_id = ?',
      whereArgs: [projectId],
      limit: 1,
    );
    if (projectRows.isEmpty) return null;
    // Every membership row of the project, ended and tombstoned ones included:
    // [resolveProjectOwners] does that filtering, so this side cannot drift
    // from the server's by forgetting a clause.
    final memberships = await db.query(
      Tables.projectMemberships,
      columns: ['user_id', 'role', 'end_date', 'deleted_at'],
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    return resolveProjectOwners(
      membershipRows: memberships,
      creatorUserId: _governingValue(projectRows.first, 'owner_user_id'),
    );
  }

  /// Task 10.67: was a naked `row[column] as String?` at both call sites —
  /// the client-side sibling of the exact shape `RowAuthorizer._governingValue`
  /// had server-side before task 10.64 fixed it there. A non-null, wrong-typed
  /// governing column already *failed closed* here (the cast throws rather
  /// than silently defaulting to `null`, which `MutationRule.permits` reads as
  /// "nothing to deny" — so this was never the authorization-bypass shape
  /// 10.64 found), but it failed closed with an unlabeled `TypeError` rather
  /// than a message naming what went wrong. Named explicitly for the same
  /// reason 10.64 gave: relying on the cast's *incidental* throwing behavior
  /// is fragile — a future refactor that adds a `??` "helpful" default in
  /// front of this cast would silently reintroduce the bypass, where an
  /// explicit check makes the failure mode a documented decision instead of
  /// an accident of `as`'s semantics.
  ///
  /// The body moved to [governingUserId] in task 11.19, which needed the same
  /// guard off a bare [DatabaseExecutor] — see [readProjectRole]. Delegating
  /// rather than copying is the whole reason it moved.
  String? _governingValue(Map<String, Object?> row, String column) =>
      governingUserId(row, column, table: table);

  /// Updates the domain columns of a row, bumping `revision` and touching
  /// `updated_at`. Managed columns in [columns] are ignored. No-op on an
  /// already-tombstoned row. Returns rows affected.
  ///
  /// Throws [UnauthorizedMutation] if [actor] isn't permitted to modify the
  /// row (see [rule]).
  Future<int> updateByKey(
    Map<String, Object?> key,
    Map<String, Object?> columns, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    bool includeDeleted = false,
  }) async {
    await _authorize(key, actor);
    return _writeUpdate(
      key,
      columns,
      actor: actor,
      deviceId: deviceId,
      now: now,
      includeDeleted: includeDeleted,
    );
  }

  /// [updateByKey] for a write whose permission the calling repository has
  /// **already decided, under a rule narrower than this table's** — not a
  /// rule that is merely different, and never one that is broader.
  ///
  /// **There is exactly one caller in the app and there is meant to be exactly
  /// one:** `ProjectMembershipRepository.leaveProject` (task 11.28), where a
  /// person ends their own membership row. `Project_Memberships` is
  /// [MutationRule.projectOwner], so the table's rule refuses everyone but an
  /// owner; the narrower rule the caller applies instead — the shared
  /// [isSelfDeparture] predicate, which the server applies to the same write
  /// — permits one column on one row that names the caller and nothing else.
  ///
  /// **Why this exists rather than a new [MutationActor] kind.** An actor that
  /// skips authorization is skipped *everywhere*, on every table, for the
  /// lifetime of the object — that is [MutationActor.replication], and it is
  /// the shape this project already keeps at arm's length with a required
  /// reason string. A per-call door is smaller: it names one write, at one
  /// call site, and [because] makes every use say what rule it applied
  /// instead. `test/security/narrow_rule_bypass_test.dart` asserts the call
  /// sites stay countable rather than trusting this paragraph.
  ///
  /// None of this is a security boundary — the client's checks never are. The
  /// boundary is `RowAuthorizer`, which judges the same write independently
  /// against the same shared predicate.
  Future<int> updateByKeyUnderNarrowerRule(
    Map<String, Object?> key,
    Map<String, Object?> columns, {
    required MutationActor actor,
    required String because,
    String? deviceId,
    DateTime? now,
  }) {
    assert(because.isNotEmpty, 'a narrower-rule write must name the rule');
    return _writeUpdate(
      key,
      columns,
      actor: actor,
      deviceId: deviceId,
      now: now,
    );
  }

  /// [includeDeleted] lets a write reach a tombstoned row. **Off by
  /// default and rarely right**: an edit to a removed row is usually a stale
  /// screen writing to something the person already took away. The one
  /// caller today is `TagRepository.setIndividual` (task 11.241), because a
  /// collar removed from a project was still worn by its animal, and a merge
  /// that re-pointed only the live collars would leave the removed one
  /// naming an animal that no longer exists.
  Future<int> _writeUpdate(
    Map<String, Object?> key,
    Map<String, Object?> columns, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    bool includeDeleted = false,
  }) async {
    final (clause, keyArgs) = _keyClause(key);
    final modifiedBy = actor.userId;
    // Every key column is stripped, not just the id. `project_id` is an
    // ordinary domain column in each model's `toColumns()`, so before task
    // 10.35 re-keyed these tables it was written on every update; now it is
    // half the primary key and writing it would move the row between projects.
    final domain = Map.of(columns)
      ..removeWhere((c, _) => _managedColumns.contains(c) || pk.contains(c));

    final sets = <String>[];
    final args = <Object?>[];
    domain.forEach((key, value) {
      sets.add('$key = ?');
      args.add(value);
    });
    sets.add('updated_at = ?');
    args.add(_nowUtc(now));
    sets.add('revision = revision + 1');
    if (modifiedBy != null) {
      sets.add('last_modified_by = ?');
      args.add(modifiedBy);
    }
    if (deviceId != null) {
      sets.add('origin_device_id = ?');
      args.add(deviceId);
    }
    args.addAll(keyArgs);

    return db.rawUpdate(
      'UPDATE $table SET ${sets.join(', ')} WHERE $clause'
      '${includeDeleted ? '' : ' AND deleted_at IS NULL'}',
      args,
    );
  }

  /// [updateByKey] for a single-column-key table. Throws on a composite key —
  /// see [_singleKey].
  Future<int> updateById(
    Object id,
    Map<String, Object?> columns, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) => updateByKey(
    _singleKey(id),
    columns,
    actor: actor,
    deviceId: deviceId,
    now: now,
  );

  /// Soft-deletes (tombstones) a row: sets `deleted_at`, bumps `revision`,
  /// touches `updated_at`. No-op if already tombstoned. Returns rows affected.
  ///
  /// Throws [UnauthorizedMutation] if [actor] isn't permitted to modify the
  /// row (see [rule]).
  Future<int> softDeleteByKey(
    Map<String, Object?> key, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    MutationExemption? exemption,
  }) async {
    await _authorize(key, actor, exemption: exemption);
    final (clause, keyArgs) = _keyClause(key);
    final modifiedBy = actor.userId;
    final ts = _nowUtc(now);
    return db.rawUpdate(
      'UPDATE $table SET deleted_at = ?, updated_at = ?, revision = revision + 1, '
      'last_modified_by = COALESCE(?, last_modified_by), '
      'origin_device_id = COALESCE(?, origin_device_id) '
      'WHERE $clause AND deleted_at IS NULL',
      [ts, ts, modifiedBy, deviceId, ...keyArgs],
    );
  }

  /// [softDeleteByKey] for a single-column-key table. Throws on a composite
  /// key — see [_singleKey].
  Future<int> softDeleteById(
    Object id, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    MutationExemption? exemption,
  }) => softDeleteByKey(
    _singleKey(id),
    actor: actor,
    deviceId: deviceId,
    now: now,
    exemption: exemption,
  );

  /// Clears a tombstone (undo of [softDeleteByKey]), bumping `revision`.
  ///
  /// Throws [UnauthorizedMutation] if [actor] isn't permitted to modify the
  /// row (see [rule]).
  Future<int> restoreByKey(
    Map<String, Object?> key, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    MutationExemption? exemption,
  }) async {
    await _authorize(key, actor, exemption: exemption);
    final (clause, keyArgs) = _keyClause(key);
    final modifiedBy = actor.userId;
    final ts = _nowUtc(now);
    return db.rawUpdate(
      'UPDATE $table SET deleted_at = NULL, updated_at = ?, revision = revision + 1, '
      'last_modified_by = COALESCE(?, last_modified_by), '
      'origin_device_id = COALESCE(?, origin_device_id) '
      'WHERE $clause AND deleted_at IS NOT NULL',
      [ts, modifiedBy, deviceId, ...keyArgs],
    );
  }

  /// [restoreByKey] for a single-column-key table. Throws on a composite key —
  /// see [_singleKey].
  Future<int> restoreById(
    Object id, {
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
    MutationExemption? exemption,
  }) => restoreByKey(
    _singleKey(id),
    actor: actor,
    deviceId: deviceId,
    now: now,
    exemption: exemption,
  );

  /// Whether [exemption] genuinely holds for this write.
  ///
  /// **The whole difference between an exemption and a bypass.** Every branch
  /// here re-derives the condition the call site claimed, from this device's
  /// own rows, and a claim that does not hold falls through to the ordinary
  /// [UnauthorizedMutation]. See [MutationExemption].
  Future<bool> _exemptionHolds(
    MutationExemption exemption,
    Map<String, Object?> key,
    MutationActor actor,
  ) async {
    switch (exemption) {
      case DepartedMemberExemption(:final projectId):
        final userId = actor.userId;
        if (userId == null) return false;
        // The exemption is about one project, and the row being written has to
        // be that project's. Without this, a departed member of *any* project
        // could name it while deleting a different one.
        if (table != Tables.projects || key['project_id'] != projectId) {
          return false;
        }
        // `end_date IS NULL AND deleted_at IS NULL` is what "still a member"
        // means everywhere else in this app — see
        // `ProjectMembershipRepository.findForUser`, whose clause this
        // mirrors. A tombstoned stint is not an open one.
        final open = await db.query(
          Tables.projectMemberships,
          columns: const ['membership_id'],
          where:
              'project_id = ? AND user_id = ? AND end_date IS NULL '
              'AND deleted_at IS NULL',
          whereArgs: [projectId, userId],
          limit: 1,
        );
        if (open.isNotEmpty) return false;
        // And they must have been a member at some point. "No open membership"
        // is also true of every project somebody has never joined, and this
        // exemption is not a licence to delete one of those.
        final ever = await db.query(
          Tables.projectMemberships,
          columns: const ['membership_id'],
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [projectId, userId],
          limit: 1,
        );
        return ever.isNotEmpty;

      case SnapshotHolderExemption(:final projectId):
        final userId = actor.userId;
        if (userId == null) return false;
        if (table != Tables.projects || key['project_id'] != projectId) {
          return false;
        }
        // The one difference from `DepartedMemberExemption` above, and the
        // whole reason this is not the same case with a different name: no
        // row at all, open or closed. A departed member has a closed one; a
        // snapshot holder has none, because they were never on the project.
        final anyRow = await db.query(
          Tables.projectMemberships,
          columns: const ['membership_id'],
          where: 'project_id = ? AND user_id = ?',
          whereArgs: [projectId, userId],
          limit: 1,
        );
        return anyRow.isEmpty;
    }
  }
}
