/// The one thing this server tells a caller it is otherwise refusing
/// (task 11.60, §4.27).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';

/// **The closed-membership disclosure exemption**, and the only one on the
/// project-scoped read path.
///
/// ## What it is for, in one sentence
///
/// An owner removes somebody; the removed person's device never finds out,
/// because the only request that could carry the news is the request the
/// server is now refusing.
///
/// Everything downstream of that follows: their app shows an amber *"the
/// server is refusing access"* rather than *"you were removed"*, and the
/// Delete control on their copy of the project does nothing — because the
/// exemption that lets a departed member delete their own copy
/// (`MutationExemption.departedMember`) reads the **local** membership rows,
/// and locally they are still a member. Task 11.57 measured that;
/// `test/e2e/membership_cycle_matrix_e2e_test.dart` asserted it in both
/// halves.
///
/// So this hands them the one row that changes both answers: **their own
/// membership row, as the server holds it, with the stint closed.** The
/// device merges it through the ordinary pull path, the departed-member
/// exemption is then satisfied by local evidence, and deleting works through
/// the path that already exists. No second deletion mechanism, and no screen
/// wording that has to guess at a cause.
///
/// ## Why this is a trust boundary and not a query
///
/// It is a **read that answers a caller the server is otherwise refusing**,
/// which is the shape existence oracles are made of (§4.13, and Gate C's
/// finding B2). It is inventory entry 28 in `SECURITY_SCOPE_AND_EXIT.md`,
/// added there **before this file existed**, and **Hardened on 2026-08-29 by
/// task 11.49**, which attacked it live: `scripts/verify_11_49_server_reads.py`
/// probes 7–11. The oracle probes were themselves watched to fail against a
/// server deliberately rebuilt with this scoping removed
/// (`scripts/verify_11_49_broken_control.py`).
///
/// The property that has to hold is not "this returns little". It is:
///
/// > **A caller who holds no closed membership row on the named project
/// > cannot tell a project that does not exist from one that exists and is
/// > not theirs.**
///
/// Three things make that true, and none of them is this function being
/// small:
///
/// 1. **The key is a row only the server can produce.** The disclosure fires
///    on a `Project_Memberships` row for `(project_id, the session's
///    user_id)`. Nothing a prober sends creates one — the row is written by an
///    owner's authorized push, or by `JoinService.approve`. A caller who was
///    never on the project gets [rowsFor] returning empty, and therefore the
///    identical refusal, for a real project and a fabricated one alike.
/// 2. **The lookup runs on every refusal**, not only the ones that will
///    succeed. `sync_routes.dart` calls this before deciding, so the refusal
///    branch is not shorter than the disclosure branch.
/// 3. **[ProjectAuthorizer.resolve] stopped returning early for a project
///    that does not exist** (same task). Before, `absent` cost one query and
///    `none` cost two; adding a third query to the refusal path would have
///    been building on that difference.
///
/// **Point 3 was necessary and was not sufficient, and task 11.72 measured
/// the difference.** Equal query *counts* are not equal *work*: the second of
/// those two queries used to read every membership row of the project, so a
/// real project's refusal was about 54 microseconds slower than a fictional
/// one's on a Linux runner — and slower still the more members it had. That is
/// fixed in [ProjectAuthorizer.resolve] rather than here; this function was
/// measured in the same pass and contributes nothing, because it returns no
/// rows for any caller the exemption is not for, which is exactly what it is
/// designed to do. See Security Model §4.13, "The clock is a channel too.
///
/// `server/test/security/closed_membership_disclosure_test.dart` demonstrates
/// this rather than asserting it — full response bytes compared, from a caller
/// who *can* reach the exemption on one project and must still learn nothing
/// about the ids they hold no row for. **The file name matters here**: three
/// documents and this comment named a `existence_oracle_test.dart` that has
/// never existed, which task 11.49 found and corrected — a citation to a file
/// nobody can open is a claim nobody can check.
///
/// ## What may cross, and what may not
///
/// One table, one person, and only rows whose stint is over. Not the
/// `Projects` row, so not the project's name. Not anybody else's membership,
/// so not who else is on it. Not one row of project data.
///
/// **What the row does carry, said plainly rather than waved past:**
/// `end_date` — when the stint ended — and `last_modified_by`, which names the
/// account that ended it. `end_date` *is* the news, so it cannot go. Blanking
/// `last_modified_by` was considered and rejected: a row that differs from the
/// server's copy is a row this device disagrees with the server about forever,
/// which is the second-representation defect `packages/tritrack_sync` exists
/// to prevent. §4.27 records the residual — a removed member learns which
/// account removed them, an id they almost always already hold, and whose
/// `Users` row is **not** delivered here, so a genuinely new one resolves to
/// no name on their device.
///
/// ## Deliberately not a general seam
///
/// One function, one call site, in a file named after the exemption — the same
/// discipline as `SyncService.insertServerAuthoredRow`, and for the same
/// reason: a second caller should turn up in a grep rather than hide behind a
/// permissive default. **This project's findings come from exemptions.** If
/// you are about to add a second call site, that is the moment to re-read
/// §4.27 and the entry-28 verdict, not after.
abstract final class ClosedMembershipDisclosure {
  /// Rows the caller's own **ended** stints on [projectId] are recorded in, in
  /// wire shape; empty when there are none, which is every caller this
  /// exemption is not for.
  ///
  /// "Ended" is `end_date IS NOT NULL OR deleted_at IS NOT NULL`, which is
  /// exactly the pair [resolveProjectRole] skips a row on — one spelling of
  /// "this stint is over", so this cannot come to disagree with the check that
  /// refused the request in the first place. Both are also
  /// `SyncTable.deactivationColumns` for this table, which is the third place
  /// the same pair is declared and the reason it is read from there.
  ///
  /// **An open row is never returned**, including the fail-closed case where a
  /// `role` string this build cannot interpret leaves somebody with an open
  /// row and no access. That person is refused exactly as before and is not
  /// helped by this; it is a smaller gap than the one being closed and §4.27
  /// records it rather than closing it quietly.
  ///
  /// Server-only bookkeeping is stripped for the same reason
  /// `SyncService.pull` strips it: `server_seq` is the server's own clock and
  /// `received_at`/`clock_skew_flag` are its observations, and a client that
  /// stored them would depend on columns Phase 10's invariant 3 forbids it
  /// from requiring.
  ///
  /// [session] must be the caller's open transaction, and [userId] must come
  /// from the validated session rather than from the request body (§4.11) —
  /// this reads a row *because of* who is asking, so a request-supplied id
  /// here would be the whole disclosure handed to anyone.
  static Future<List<Map<String, Object?>>> rowsFor(
    Session session, {
    required String projectId,
    required String userId,
  }) async {
    final table = syncTablesByName[Tables.projectMemberships]!;
    final over = table.deactivationColumns;
    if (over.isEmpty) {
      // A declaration that has gone empty is a bug, not a reason to return
      // nothing: returning nothing would silently un-ship this exemption and
      // put every removed member back where task 11.57 found them, with no
      // error anywhere. Same rule, and same reason, as `SyncService.pull`
      // throwing on a global table with no declared scope.
      throw StateError(
        '${Tables.projectMemberships} declares no deactivationColumns, so '
        'there is no way to ask which stints are over. Declare them in '
        'syncTables — answering "none" would silently withdraw the '
        'closed-membership disclosure (§4.27).',
      );
    }
    // Column names come from the const `syncTables` descriptors, never from a
    // request; both values are bound. Written from the descriptor rather than
    // spelled out so that a third way to end a stint arrives here as well as
    // in `resolveProjectRole`, instead of leaving this reading a two-column
    // definition of "over" while the authorization check reads a three-column
    // one.
    final ended = over.map((column) => '$column IS NOT NULL').join(' OR ');
    final result = await session.execute(
      'SELECT * FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND user_id = $2 '
      'AND ($ended) '
      'ORDER BY server_seq',
      parameters: [projectId, userId],
    );
    return [
      for (final row in result)
        Map<String, Object?>.of(row.toColumnMap())
          ..remove('server_seq')
          ..remove('received_at')
          ..remove('clock_skew_flag'),
    ];
  }
}
