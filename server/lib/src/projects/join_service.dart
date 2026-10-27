/// The project join code and the owner's approval (task 11.81, from task
/// 11.74's design).
///
/// **What this replaces, and why.** Until this task, holding an invite code
/// *was* being a member: you typed it in and the server wrote your membership
/// row. The code was bound to one email address, and that binding was the only
/// thing making an 8-character code safe. Michael decided on 2026-08-30 that
/// per-address invitations do not scale to a real crew, and that joining should
/// work the way joining a group chat works: one code per project, and the owner
/// decides who actually gets in.
///
/// **So holding the code now buys only the right to ask.** A code that leaks
/// stops being a key and becomes an address. The worst case changes from *a
/// stranger is on your project and can read every collar location* to *a
/// stranger appears in your pending list and you tap reject*.
library;

import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';
import '../sync/sync_service.dart';

/// The default team-size limit for a project that has never set one.
///
/// Fifty, and the number is a judgement rather than a constraint: it is far
/// past any field crew this app is built for, and low enough that a code
/// leaking onto a mailing list produces a bounded queue rather than an
/// unbounded one. The owner may change it, including downward past the current
/// head count — nobody is removed, new requests are refused, and the screen has
/// to say that plainly rather than making it look like an error.
const int defaultTeamSizeLimit = 50;

/// The largest number of requests any listing route returns.
///
/// Bounded for the reason `/projects/mine` was given a bound under task 11.64:
/// an unbounded read on an authenticated route is a memory-exhaustion primitive
/// available to anyone with a session, and a route with nothing to validate is
/// not a route with nothing to bound.
const int maxJoinRequestsReturned = 200;

/// Generates join codes.
///
/// `Random.secure()` is the platform CSPRNG. Never `Random()`. `nextInt` is
/// uniform over `[0, n)` for any `n`, so drawing from a 32-character alphabet
/// needs no rejection sampling to stay unbiased.
abstract final class JoinCodes {
  static final Random _random = Random.secure();

  /// A fresh code in canonical form (no hyphen). See `join_code.dart` for the
  /// entropy argument — which was rewritten by this task, because the one it
  /// used to make became false the moment the code stopped being bound to an
  /// address.
  static String generate() => String.fromCharCodes([
    for (var i = 0; i < joinCodeLength; i++)
      joinCodeAlphabet.codeUnitAt(_random.nextInt(joinCodeAlphabet.length)),
  ]);
}

/// Why a join request did not succeed.
enum JoinRequestFailure {
  /// The uniform refusal: wrong code, unknown code, joining switched off, or a
  /// project that has been deleted. One answer, so a code sweep learns nothing.
  codeNotValid,
  alreadyMember,
  alreadyRequested,
  teamFull,
  invalidName,
}

sealed class JoinRequestResult {
  const JoinRequestResult();
}

class JoinRequestAccepted extends JoinRequestResult {
  const JoinRequestAccepted({
    required this.requestId,
    required this.projectName,
  });
  final String requestId;
  final String projectName;
}

class JoinRequestRefused extends JoinRequestResult {
  const JoinRequestRefused(this.failure);
  final JoinRequestFailure failure;
}

/// Why an approval, rejection or re-admission did not happen.
enum JoinDecisionFailure { requestNotOpen, teamFull, notAPastMember }

sealed class JoinDecisionResult {
  const JoinDecisionResult();
}

class JoinDecisionApplied extends JoinDecisionResult {
  const JoinDecisionApplied({required this.userId, required this.email});

  /// Who the decision was about — carried out so the route can audit it.
  final String userId;
  final String email;
}

class JoinDecisionRefused extends JoinDecisionResult {
  const JoinDecisionRefused(this.failure);
  final JoinDecisionFailure failure;
}

class JoinService {
  JoinService({
    required this.session,
    required this.sync,
    DateTime Function()? clock,
    String Function()? newId,
  }) : _clock = clock ?? DateTime.now,
       _newId = newId ?? _uuidV4;

  /// Must be a session inside an open transaction. Approval decides the request
  /// and writes the membership it grants as one unit: a request marked approved
  /// with no membership to show for it is a person the owner believes they let
  /// in and who cannot sync.
  final Session session;

  /// Writes the granted membership row. See
  /// [SyncService.insertServerAuthoredRow] for why the server, and not the
  /// joining device, is what creates it.
  final SyncService sync;

  final DateTime Function() _clock;
  final String Function() _newId;

  DateTime get _now => _clock().toUtc();

  // ---- The owner's side ----------------------------------------------------

  /// [projectId]'s join settings, or the fail-closed default when no row exists.
  ///
  /// **The absent row means joining is OFF and this method must never create
  /// one.** Every project that existed before task 11.81 has no row, so a "read
  /// creates it, enabled" convenience here would have silently opened every one
  /// of them. `join_service_test.dart` asserts both halves: that a project with
  /// no row reports joining off, and that reading it writes nothing.
  Future<JoinSettings> settingsFor(String projectId) async {
    final result = await session.execute(
      'SELECT code, joining_enabled, team_size_limit, rotated_at '
      r'FROM project_join_settings WHERE project_id = $1',
      parameters: [projectId],
    );
    final counts = await _counts(projectId);
    if (result.isEmpty) {
      return JoinSettings(
        projectId: projectId,
        joiningEnabled: false,
        teamSizeLimit: defaultTeamSizeLimit,
        memberCount: counts.members,
        pendingCount: counts.pending,
      );
    }
    final row = result.first;
    return JoinSettings(
      projectId: projectId,
      // Readable, per Security Model §4.2.1 — the one named exception to
      // §4.2's plaintext rule, and it is written down there rather than here.
      code: row[0] as String?,
      joiningEnabled: row[1]! as bool,
      teamSizeLimit: row[2]! as int,
      rotatedAt: (row[3] as DateTime?)?.toIso8601String(),
      memberCount: counts.members,
      pendingCount: counts.pending,
    );
  }

  /// Turns joining on or off and sets the team-size limit.
  ///
  /// **Switching joining on mints the first code if there is not one**, because
  /// an owner who has switched joining on and has no code to hand out is in a
  /// state with no way forward that the screen could explain.
  ///
  /// **Switching joining off leaves pending requests alone**, and they can
  /// still be approved. Switching off is not a way to clear the queue and is
  /// not described as one — clearing is offered only behind a rotation.
  Future<JoinSettings> updateSettings({
    required String projectId,
    required String updatedBy,
    bool? joiningEnabled,
    int? teamSizeLimit,
  }) async {
    final now = _now;
    await _ensureRow(projectId, now, updatedBy);
    if (joiningEnabled != null) {
      await session.execute(
        r'UPDATE project_join_settings SET joining_enabled = $1, '
        r'updated_at = $2, updated_by = $3 WHERE project_id = $4',
        parameters: [joiningEnabled, now, updatedBy, projectId],
      );
      if (joiningEnabled) {
        await session.execute(
          r'UPDATE project_join_settings SET code = $1, rotated_at = $2, '
          r'rotated_by = $3 WHERE project_id = $4 AND code IS NULL',
          parameters: [JoinCodes.generate(), now, updatedBy, projectId],
        );
      }
    }
    if (teamSizeLimit != null) {
      await session.execute(
        r'UPDATE project_join_settings SET team_size_limit = $1, '
        r'updated_at = $2, updated_by = $3 WHERE project_id = $4',
        parameters: [teamSizeLimit, now, updatedBy, projectId],
      );
    }
    return settingsFor(projectId);
  }

  /// Mints a new code, and optionally clears undecided requests.
  ///
  /// **Pending requests survive by default.** Rotation is how an owner responds
  /// to a code they no longer trust, and the people already in the queue are
  /// usually the crew they meant to admit — throwing them out would make the
  /// safe action expensive, which is how it comes not to be taken.
  ///
  /// **Cleared requests are marked, not deleted** (`decision = 'cleared'`), so
  /// the person's own status read tells them their request is gone rather than
  /// leaving them staring at "pending" forever.
  Future<RotateJoinCodeResponse> rotateCode({
    required String projectId,
    required String rotatedBy,
    required bool clearPending,
  }) async {
    final now = _now;
    await _ensureRow(projectId, now, rotatedBy);
    final code = JoinCodes.generate();
    await session.execute(
      r'UPDATE project_join_settings SET code = $1, rotated_at = $2, '
      r'rotated_by = $3, updated_at = $2, updated_by = $3 '
      r'WHERE project_id = $4',
      parameters: [code, now, rotatedBy, projectId],
    );
    var cleared = 0;
    if (clearPending) {
      final result = await session.execute(
        r"UPDATE project_join_requests SET decided_at = $1, decided_by = $2, "
        r"decision = 'cleared' WHERE project_id = $3 AND decided_at IS NULL "
        'RETURNING request_id',
        parameters: [now, rotatedBy, projectId],
      );
      cleared = result.length;
    }
    return RotateJoinCodeResponse(code: code, clearedPending: cleared);
  }

  /// The project's join requests, newest first, pending ones first.
  ///
  /// Decided ones are included — an owner needs to see that they rejected
  /// somebody last week rather than wondering whether the request vanished —
  /// and the whole set is bounded by [maxJoinRequestsReturned].
  Future<List<JoinRequestSummary>> listRequests(String projectId) async {
    final result = await session.execute(
      'SELECT request_id, project_id, email, claimed_name, requested_at, '
      'decision, decided_at FROM project_join_requests '
      r'WHERE project_id = $1 '
      'ORDER BY (decided_at IS NULL) DESC, requested_at DESC '
      r'LIMIT $2',
      parameters: [projectId, maxJoinRequestsReturned],
    );
    return [
      for (final row in result)
        JoinRequestSummary(
          requestId: row[0]! as String,
          projectId: row[1]! as String,
          email: row[2]! as String,
          claimedName: row[3] as String?,
          requestedAt: (row[4]! as DateTime).toIso8601String(),
          decision: row[5] as String?,
          decidedAt: (row[6] as DateTime?)?.toIso8601String(),
        ),
    ];
  }

  /// Approves one request and writes the membership it grants.
  ///
  /// **One request at a time, and there is deliberately no bulk approve or bulk
  /// reject** (design §2.5, Michael's reasoning): an accidental "reject all"
  /// forces every legitimate requester to ask again and be contacted
  /// individually, and that accident is far likelier than the flood it would
  /// defend against. The more probable failure wins.
  ///
  /// **Nothing in the request body shapes the membership row.** The project
  /// comes from the request's own `project_id`, the user from its own
  /// `user_id`, and the role from what the owner chose *at this moment* — never
  /// from the code, which carries no role at all. That is what makes a leaked
  /// code uninteresting: it cannot be a leaked *owner* code, because there is
  /// no such thing. It is also the property `_authorizeGrantingInsert`'s note
  /// says must be preserved, and the reason approval needs no permissive branch
  /// in `RowAuthorizer`.
  ///
  /// **The limit is not checked here**, and that is a consequence of counting
  /// pending requests toward it rather than an omission: approving converts a
  /// pending request into a member and leaves the total unchanged.
  ///
  /// The decision is taken by one conditional `UPDATE` whose `WHERE` carries
  /// every reason it could fail, the same shape `AuthService.redeem` uses — so
  /// two owners approving the same request at the same instant cannot both
  /// succeed.
  Future<JoinDecisionResult> approve({
    required String projectId,
    required String requestId,
    required ProjectRole role,
    required String decidedBy,
    required String? deviceId,
  }) async {
    final now = _now;
    // Savepoint before the deciding UPDATE, for task 11.10's reason: any
    // statement error poisons the enclosing transaction and is rethrown from
    // `runTx` even if caught here, so `ROLLBACK TO SAVEPOINT` is the only thing
    // that lets this method return a typed refusal rather than an opaque 500.
    // Placed before the UPDATE and not only around the insert, so that losing
    // the race also leaves the request undecided rather than marked approved
    // with no membership behind it.
    const savepoint = 'join_approve';
    await session.execute('SAVEPOINT $savepoint');
    try {
      final decided = await session.execute(
        r"UPDATE project_join_requests SET decided_at = $1, decided_by = $2, "
        r"decision = 'approved' WHERE request_id = $3 AND project_id = $4 "
        'AND decided_at IS NULL RETURNING user_id, email',
        parameters: [now, decidedBy, requestId, projectId],
      );
      if (decided.isEmpty) {
        // Not this project's, already decided, or never existed — one answer,
        // so an owner of A cannot probe for B's request ids.
        return const JoinDecisionRefused(JoinDecisionFailure.requestNotOpen);
      }
      final userId = decided.first[0]! as String;
      final email = decided.first[1]! as String;
      await _grantMembership(
        projectId: projectId,
        userId: userId,
        email: email,
        role: role,
        deviceId: deviceId,
        now: now,
      );
      return JoinDecisionApplied(userId: userId, email: email);
    } on ServerException catch (e) {
      // `idx_memberships_one_open` is the backstop for the race the reads
      // above cannot close: two approvals for the same person landing at once.
      // Anything but 23505 (unique_violation) is a real failure.
      if (e.code != '23505') rethrow;
      await session.execute('ROLLBACK TO SAVEPOINT $savepoint');
      return const JoinDecisionRefused(JoinDecisionFailure.requestNotOpen);
    }
  }

  /// Rejects one request. Writes no membership and discloses nothing.
  Future<JoinDecisionResult> reject({
    required String projectId,
    required String requestId,
    required String decidedBy,
  }) async {
    final result = await session.execute(
      r"UPDATE project_join_requests SET decided_at = $1, decided_by = $2, "
      r"decision = 'rejected' WHERE request_id = $3 AND project_id = $4 "
      'AND decided_at IS NULL RETURNING user_id, email',
      parameters: [_now, decidedBy, requestId, projectId],
    );
    if (result.isEmpty) {
      return const JoinDecisionRefused(JoinDecisionFailure.requestNotOpen);
    }
    return JoinDecisionApplied(
      userId: result.first[0]! as String,
      email: result.first[1]! as String,
    );
  }

  /// Puts a **past member** of [projectId] back on it, with no code and no
  /// request (design §1.5).
  ///
  /// This is what "re-invite a past member" became. A field tech who was on
  /// last season's project coming back is ordinary, and under the old flow the
  /// owner had to send somebody they already trust a code and wait for them to
  /// redeem it.
  ///
  /// **One condition makes it safe, and it is the whole design:** the named
  /// person must already hold a **closed** membership row on this project and
  /// **no open one**. That discloses nothing (the owner can already see them on
  /// their own members screen), grants nothing new (they were already in), and
  /// means the route **cannot add a stranger** — it can only reverse a removal
  /// the owner themselves made. The bound comes from the project's own history
  /// rather than from a list somebody maintains.
  ///
  /// It **counts toward the team-size limit** like everything else, and it
  /// writes a **new** membership row rather than nulling `end_date` on the old
  /// one — the record of the prior stint is the point of keeping it.
  Future<JoinDecisionResult> readmit({
    required String projectId,
    required String userId,
    required ProjectRole role,
    required String decidedBy,
    required String? deviceId,
  }) async {
    final now = _now;
    final open = await session.execute(
      'SELECT 1 FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND user_id = $2 '
      'AND end_date IS NULL AND deleted_at IS NULL LIMIT 1',
      parameters: [projectId, userId],
    );
    final closed = await session.execute(
      'SELECT 1 FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND user_id = $2 '
      'AND (end_date IS NOT NULL OR deleted_at IS NOT NULL) LIMIT 1',
      parameters: [projectId, userId],
    );
    if (open.isNotEmpty || closed.isEmpty) {
      // "Already on the project" and "never was" draw the same refusal. The
      // owner can distinguish them by looking at their own members screen, and
      // one answer means this route cannot be used to ask questions about a
      // user id.
      return const JoinDecisionRefused(JoinDecisionFailure.notAPastMember);
    }
    final counts = await _counts(projectId);
    final limit = await _limitFor(projectId);
    if (counts.members + counts.pending >= limit) {
      return const JoinDecisionRefused(JoinDecisionFailure.teamFull);
    }
    final email = await authenticatedEmailOf(userId) ?? '';
    const savepoint = 'join_readmit';
    await session.execute('SAVEPOINT $savepoint');
    try {
      await _grantMembership(
        projectId: projectId,
        userId: userId,
        email: email,
        role: role,
        deviceId: deviceId,
        now: now,
      );
      return JoinDecisionApplied(userId: userId, email: email);
    } on ServerException catch (e) {
      if (e.code != '23505') rethrow;
      await session.execute('ROLLBACK TO SAVEPOINT $savepoint');
      return const JoinDecisionRefused(JoinDecisionFailure.notAPastMember);
    }
  }

  // ---- The requester's side -------------------------------------------------

  /// The address the server has authenticated for [userId], or null if that
  /// account is gone.
  ///
  /// **This is the only address a join request is allowed to carry.** It comes
  /// from `auth_accounts`, whose row is created on proof of mailbox control
  /// (§4.2), and never from a request. The requester's *name* is
  /// caller-supplied and is presented differently for exactly that reason.
  Future<String?> authenticatedEmailOf(String userId) async {
    final result = await session.execute(
      r'SELECT email FROM auth_accounts WHERE user_id = $1',
      parameters: [userId],
    );
    return result.isEmpty ? null : result.first.first as String?;
  }

  /// Records a request to join whichever project [rawCode] names.
  ///
  /// **This grants nothing.** It creates a row an owner will look at. The
  /// refusals are uniform — a wrong code, an unknown one, one for a project
  /// with joining switched off, and one for a deleted project are a single
  /// answer — with three deliberate exceptions that carry real information to
  /// the person and disclose nothing they do not already know about themselves:
  /// they are already a member, they have already asked, or the team is full.
  ///
  /// [claimedName] is bounded here by the **same** rule `Users.first_name`
  /// carries (`RowValidator.isWellFormedPersonName` plus
  /// `TextBound.personName.maxLength`), rather than by a second set written for
  /// this route. An empty or absent name is accepted and stored as null: the
  /// email is what identifies, and a missing name must render as absent rather
  /// than break approval.
  Future<JoinRequestResult> request({
    required String rawCode,
    required String userId,
    required String authenticatedEmail,
    required String? claimedName,
    required String? deviceId,
  }) async {
    final code = canonicalizeJoinCode(rawCode);
    // A malformed code is refused exactly like a wrong one, and never reaches
    // the database — which also means it cannot be used to time the lookup.
    if (code == null) {
      return const JoinRequestRefused(JoinRequestFailure.codeNotValid);
    }
    final name = _normalizeName(claimedName);
    if (name is _InvalidName) {
      return const JoinRequestRefused(JoinRequestFailure.invalidName);
    }

    final found = await session.execute(
      'SELECT project_id, team_size_limit FROM project_join_settings '
      r'WHERE code = $1 AND joining_enabled = TRUE',
      parameters: [code],
    );
    if (found.isEmpty) {
      return const JoinRequestRefused(JoinRequestFailure.codeNotValid);
    }
    final projectId = found.first[0]! as String;
    final limit = found.first[1]! as int;

    // The project must still be there and not tombstoned. A code outliving its
    // project is not something the caller can act on, so it draws the uniform
    // refusal rather than a message about a project they cannot see.
    final project = await session.execute(
      'SELECT project_name FROM ${quoted(Tables.projects)} '
      r'WHERE project_id = $1 AND deleted_at IS NULL',
      parameters: [projectId],
    );
    if (project.isEmpty) {
      return const JoinRequestRefused(JoinRequestFailure.codeNotValid);
    }
    final projectName = project.first.first! as String;

    final open = await session.execute(
      'SELECT 1 FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND user_id = $2 '
      'AND end_date IS NULL AND deleted_at IS NULL LIMIT 1',
      parameters: [projectId, userId],
    );
    if (open.isNotEmpty) {
      return const JoinRequestRefused(JoinRequestFailure.alreadyMember);
    }

    final counts = await _counts(projectId);
    if (counts.members + counts.pending >= limit) {
      return const JoinRequestRefused(JoinRequestFailure.teamFull);
    }

    // Task 11.10's shape: the unique partial index decides "one pending request
    // per person", not a read followed by a write. The read above is only for
    // the friendlier refusal; losing the race lands here and is refused
    // identically.
    const savepoint = 'join_request';
    await session.execute('SAVEPOINT $savepoint');
    final requestId = _newId();
    try {
      await session.execute(
        'INSERT INTO project_join_requests '
        '(request_id, project_id, user_id, email, claimed_name, project_name, '
        r' requested_at, device_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
        parameters: [
          requestId,
          projectId,
          userId,
          normalizeEmail(authenticatedEmail),
          (name as _ValidName).value,
          // Frozen here, deliberately (task 11.79). The name this person is
          // shown from now on is the one the project had when they asked. A
          // live join handed a renamed project's new name to somebody the
          // owner had already turned down — and renaming "Field season" to
          // something specific is exactly when that matters.
          projectName,
          _now,
          deviceId,
        ],
      );
    } on ServerException catch (e) {
      if (e.code != '23505') rethrow;
      await session.execute('ROLLBACK TO SAVEPOINT $savepoint');
      return const JoinRequestRefused(JoinRequestFailure.alreadyRequested);
    }
    return JoinRequestAccepted(requestId: requestId, projectName: projectName);
  }

  /// The caller's own requests, newest first.
  ///
  /// **Keyed on the session's user id and nothing else** — there is no field on
  /// this route by which a caller could name somebody else. It exists so a
  /// rejected person is told rather than left waiting forever, which is the
  /// defect task 11.60 exists to have fixed for removed members.
  ///
  /// **The project's name comes from the request row, not from the project**
  /// (task 11.79). It was frozen there when the request was made, so a project
  /// renamed afterwards does not hand its new name to somebody who was turned
  /// down. The `Projects` join that remains decides only whether the project
  /// still exists — a request whose project has since been deleted is dropped
  /// rather than rendered against a project nobody can reach. `COALESCE` covers
  /// rows written before this column existed and backfilled by
  /// `alterProjectJoinRequests`; it is a fallback, not the path.
  ///
  /// **`project_id` is returned for an approved request and for nothing else**
  /// (task 11.83). The requester's device cannot link and sync a project it
  /// cannot name, and before this the news that somebody had been let in
  /// arrived with no way to act on it — so the last mile was a manual tap
  /// nothing told them to make. Withholding it from pending and rejected
  /// requests keeps this route where inventory entry 29 left it: an approved
  /// requester is a member and `GET /projects/mine` hands them the same id, so
  /// nothing here is disclosed that the caller could not already read; anybody
  /// the owner has not admitted still learns no project identifier.
  Future<List<MyJoinRequest>> myRequests(String userId) async {
    final result = await session.execute(
      'SELECT r.request_id, COALESCE(r.project_name, p.project_name), '
      'r.requested_at, r.decision, '
      'r.decided_at, r.project_id FROM project_join_requests r '
      'JOIN ${quoted(Tables.projects)} p ON p.project_id = r.project_id '
      r'WHERE r.user_id = $1 AND p.deleted_at IS NULL '
      'ORDER BY r.requested_at DESC '
      r'LIMIT $2',
      parameters: [userId, maxJoinRequestsReturned],
    );
    return [
      for (final row in result)
        MyJoinRequest(
          requestId: row[0]! as String,
          projectName: row[1]! as String,
          requestedAt: (row[2]! as DateTime).toIso8601String(),
          decision: row[3] as String?,
          decidedAt: (row[4] as DateTime?)?.toIso8601String(),
          projectId: row[3] == joinDecisionApproved ? row[5]! as String : null,
        ),
    ];
  }

  // ---- Internals -------------------------------------------------------------

  /// Writes the membership row, and makes the new member's identity reachable
  /// first. Shared by [approve] and [readmit] so the two cannot drift.
  Future<void> _grantMembership({
    required String projectId,
    required String userId,
    required String email,
    required ProjectRole role,
    required String? deviceId,
    required DateTime now,
  }) async {
    final stamp = now.toIso8601String();
    await _makeIdentityReachable(userId: userId, email: email);
    await sync
        .insertServerAuthoredRow(syncTablesByName[Tables.projectMemberships]!, {
          'membership_id': _newId(),
          'project_id': projectId,
          'user_id': userId,
          'join_date': stamp,
          'end_date': null,
          'role': role.db,
          'created_at': stamp,
          'updated_at': stamp,
          'deleted_at': null,
          'revision': 0,
          'last_modified_by': userId,
          'origin_device_id': deviceId,
        });
  }

  /// Makes the new member's identity both **present** and **deliverable**
  /// before a membership row names them.
  ///
  /// **This step is not optional, and the design says so in as many words.**
  /// Two failures, one cause: a project that has just widened its reach needs
  /// the newly-reachable global rows to actually arrive at the other members'
  /// devices, and neither the row existing nor the row being reachable is
  /// enough on its own.
  ///
  /// **Present.** Somebody joining their first project has an `auth_accounts`
  /// row and no `Users` row at all — their profile is synced data and reaches
  /// the server only when their device next pushes, which is after this.
  /// Meanwhile `Project_Memberships.user_id` is a foreign key into `Users`, so
  /// without this the approval fails at commit.
  ///
  /// **Deliverable.** The commoner case is that their `Users` row has been here
  /// for weeks from another project. It becomes *reachable* the moment the
  /// membership exists — and it is below every existing member's cursor, so it
  /// is never delivered again. The owner's next pull would then carry a
  /// membership row naming somebody whose `Users` row is missing, and the
  /// client's own foreign key would refuse the whole page: one late-joining
  /// teammate stops that device syncing, not just that row.
  ///
  /// **It asserts nothing about who they are, deliberately.** The names are
  /// left empty because the server does not know them and must not invent one
  /// on the row that attributes field observations (§4.17).
  ///
  /// **And note what it does *not* do with the claimed name from the request:
  /// nothing.** It would be easy, and it would be wrong. That name is
  /// caller-supplied text whose only job is to help an owner recognise somebody
  /// at the moment of approval; writing it onto the synced `Users` row would
  /// turn a claim into the app's record of who recorded an observation, which
  /// is exactly the harm §4.17 is about. The person's own device pushes their
  /// real profile on its first sync and that is what everyone sees.
  ///
  /// `updated_at` is the epoch and `revision` is 0, which is what makes the
  /// placeholder harmless rather than merely apologetic: under `MergeResolver`'s
  /// ordering every real row beats it, including one written years ago on a
  /// phone that has been offline all season.
  Future<void> _makeIdentityReachable({
    required String userId,
    required String email,
  }) async {
    final existing = await session.execute(
      'SELECT 1 FROM ${quoted(Tables.users)} WHERE user_id = \$1',
      parameters: [userId],
    );
    if (existing.isEmpty) {
      final epoch = DateTime.fromMillisecondsSinceEpoch(
        0,
        isUtc: true,
      ).toIso8601String();
      await sync.insertServerAuthoredRow(syncTablesByName[Tables.users]!, {
        'user_id': userId,
        'first_name': '',
        'last_name': '',
        'email': email,
        'created_at': epoch,
        'updated_at': epoch,
        'deleted_at': null,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': null,
      });
    } else {
      await sync.refreshServerSeqFor(syncTablesByName[Tables.users]!, {
        'user_id': userId,
      });
    }
    await sync.refreshServerSeqFor(syncTablesByName[Tables.userEmails]!, {
      'user_id': userId,
    });
  }

  /// Open memberships of every role — the owner included — and undecided
  /// requests.
  ///
  /// **Both halves count toward the team-size limit**, which is why they are
  /// counted together here rather than in two places that could disagree. An
  /// owner seeing "40 members, limit 50" and a refusal needs the pending number
  /// to make sense of it, so the screen gets both.
  Future<({int members, int pending})> _counts(String projectId) async {
    final members = await session.execute(
      'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND end_date IS NULL AND deleted_at IS NULL',
      parameters: [projectId],
    );
    final pending = await session.execute(
      'SELECT count(*) FROM project_join_requests '
      r'WHERE project_id = $1 AND decided_at IS NULL',
      parameters: [projectId],
    );
    return (
      members: (members.first.first! as int),
      pending: (pending.first.first! as int),
    );
  }

  Future<int> _limitFor(String projectId) async {
    final result = await session.execute(
      r'SELECT team_size_limit FROM project_join_settings WHERE project_id = $1',
      parameters: [projectId],
    );
    return result.isEmpty ? defaultTeamSizeLimit : result.first.first! as int;
  }

  /// Creates the settings row if it is not there, with joining **off**.
  ///
  /// Only ever called from an owner's own write. Never from a read — see
  /// [settingsFor].
  Future<void> _ensureRow(
    String projectId,
    DateTime now,
    String updatedBy,
  ) async {
    await session.execute(
      'INSERT INTO project_join_settings '
      '(project_id, joining_enabled, team_size_limit, created_at, updated_at, '
      r' updated_by) VALUES ($1, FALSE, $2, $3, $3, $4) '
      'ON CONFLICT (project_id) DO NOTHING',
      parameters: [projectId, defaultTeamSizeLimit, now, updatedBy],
    );
  }

  /// Bounds the claimed name by the **same** rule `Users.first_name` carries.
  ///
  /// Trimmed, then empty becomes null — a person who typed nothing and a person
  /// who typed spaces are the same person, and both must render as *absent*
  /// rather than as a placeholder somebody could mistake for a name.
  Object _normalizeName(String? raw) {
    if (raw == null) return const _ValidName(null);
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const _ValidName(null);
    if (trimmed.length > TextBound.personName.maxLength ||
        !RowValidator.isWellFormedPersonName(trimmed)) {
      return const _InvalidName();
    }
    return _ValidName(trimmed);
  }
}

class _ValidName {
  const _ValidName(this.value);
  final String? value;
}

class _InvalidName {
  const _InvalidName();
}

/// A v4 UUID from the platform CSPRNG.
String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
