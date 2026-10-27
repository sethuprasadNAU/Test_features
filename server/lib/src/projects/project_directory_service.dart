/// Server side of "which projects belong to me" (task 10.9).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';

/// Most rows `GET /projects/mine` will return (task 11.64, finding P-1).
///
/// The same bound, for the same reason, that [maxListedSessions] puts on
/// `GET /auth/sessions`: the row count is caller-influenced. A signed-in
/// caller can publish projects, so "how many rows does this query return" is
/// a number they choose, and an unbounded `SELECT` on a route every signed-in
/// device can call is task 10.56's finding in a place that sweep did not look
/// (see [RateLimitPolicy.projectListPerUser] for why it did not).
///
/// **What happens if it ever bites, stated plainly rather than assumed away.**
/// A person with more than 200 open memberships would not see the two hundred
/// and first in the app's project list, and could not join it from a new
/// device through that screen. That is a real loss of function, not a silent
/// security win, and it is the reason the number is 200 rather than the
/// sessions route's 100: a field season's worth of projects is single digits,
/// a decade of them is double, and 200 is past any honest use while still
/// being a bound. If a real person ever reaches it, the fix is paging, not a
/// larger constant.
const int maxListedProjects = 200;

class ProjectDirectoryService {
  const ProjectDirectoryService(this.session);

  final Session session;

  /// Every project [userId] has an open membership in, joined against the
  /// project's own row for its name and owner.
  ///
  /// Driven off `Project_Memberships` rather than `Projects.owner_user_id`
  /// alone: `ProjectExporter.collect` uploads the owner's membership row as
  /// part of every publish (task 8.4 already guarantees one exists locally),
  /// so this single query already returns the right set in Phase 10 and needs
  /// no change at all when Phase 11 adds real non-owner members — only the
  /// role values returned will diversify.
  ///
  /// **`m.deleted_at IS NULL` added by task 11.2.** A membership is normally
  /// ended by `end_date`, and this list checked only that — so a *tombstoned*
  /// membership still listed its project here, while `ProjectAuthorizer`
  /// (which checks both) refused every sync request for it. The person would
  /// have seen a project they could not join, with no explanation available to
  /// either of them. Harmless in Phase 10, where nobody's membership ever
  /// ended; the third clause of `isOpenOwnerMembership` exists because this
  /// table has two ways out and forgetting one is the mistake it keeps
  /// inviting.
  ///
  /// **The columns this selects are the whole of what the route may
  /// return** — Security Model §4.28, written by task 11.64 because until then
  /// no document said, which is what made "does `/projects/mine` leak?"
  /// unanswerable rather than merely unanswered. A column added here is a
  /// disclosure decision, and `project_directory_field_set_test.dart` fails
  /// until §4.28 records it. **The fifth, `destroy_at`, was added by task
  /// 11.290 and §4.28 records why**: an owner scheduled the project's
  /// destruction, and every member's records go with it, so the date is
  /// addressed to exactly the people this query returns rows for.
  ///
  /// [limit] bounds the result for the reason [maxListedProjects] gives. The
  /// `ORDER BY` is not cosmetic: without one, *which* projects a truncated
  /// page drops would be whatever the planner happened to emit, so the same
  /// caller could get a different subset on two consecutive reads.
  Future<List<ProjectSummary>> listFor(
    String userId, {
    int limit = maxListedProjects,
  }) async {
    final result = await session.execute(
      'SELECT p.project_id, p.project_name, p.owner_user_id, m.role, '
      'd.destroy_at '
      'FROM ${quoted(Tables.projectMemberships)} m '
      'JOIN ${quoted(Tables.projects)} p ON p.project_id = m.project_id '
      // A scheduled-but-not-executed destruction, or nothing. An executed
      // one has no `Projects` row left to join, so it never appears here.
      'LEFT JOIN project_destruction d ON d.project_id = p.project_id '
      'AND d.executed_at IS NULL '
      r'WHERE m.user_id = $1 AND m.end_date IS NULL '
      'AND m.deleted_at IS NULL AND p.deleted_at IS NULL '
      'ORDER BY p.project_name, p.project_id '
      r'LIMIT $2',
      parameters: [userId, limit],
    );
    return [
      for (final row in result)
        ProjectSummary(
          projectId: row[0]! as String,
          projectName: row[1]! as String,
          ownerUserId: row[2]! as String,
          role: row[3]! as String,
          destroyAt: (row[4] as DateTime?)?.toUtc(),
        ),
    ];
  }

  /// Every project [userId] deleted from a device that this server still
  /// holds as a tombstone — the rows of `GET /projects/deleted/mine`
  /// (task 11.292).
  ///
  /// **The narrow set, and why each clause is there.** [listFor] above leaves
  /// a tombstoned project out for everybody (`p.deleted_at IS NULL`), which
  /// is right for a list of projects to sync and wrong as the only list there
  /// is: since task 11.289 an owner's in-app delete reaches the server as a
  /// tombstone with every record intact, and nothing could then name it.
  /// This query is that complement, held to three conditions at once:
  ///
  /// 1. **The caller holds an open `owner` membership in it** — the same
  ///    membership join [listFor] uses, narrowed to the owner role. So every
  ///    row here is one `_requireOwner` will admit to the deletion routes,
  ///    which is what makes the listing actionable rather than a report. A
  ///    creator whose only claim is `Projects.owner_user_id` with no
  ///    membership row is not listed, exactly as [listFor] would not list
  ///    them; the two lists stay one definition of "your projects".
  /// 2. **The row is tombstoned** — `p.deleted_at IS NOT NULL`. A destroyed
  ///    project has no `Projects` row left and cannot appear.
  /// 3. **The caller sent the tombstone** — `p.last_modified_by = $1`. The
  ///    server verified that name on the update (§4.17: an audit name on an
  ///    update must be the caller's), so *"you deleted this"* is the caller's
  ///    own fact, which is the strongest of §4.28's two footings. A co-owner
  ///    who did not delete it is not told about it here; a tombstone with no
  ///    audit name (a build older than the stamp) is not listed either, and
  ///    the operator path in `server/README.md` is the reach for both.
  ///
  /// **The general listing this deliberately is not** — every tombstoned
  /// project the caller can see, or every tombstoned project on the server —
  /// is refused in Security Model §4.28: that is a question about the
  /// server's history rather than about the caller's own projects, and §4.13's
  /// reopen trigger names that shape.
  ///
  /// The columns are the whole of what the route may return; §4.28's second
  /// table is derived from [DeletedProjectSummary.toJson] by
  /// `project_directory_field_set_test.dart`. Same bound and same ordering
  /// discipline as [listFor], for the same reasons.
  Future<List<DeletedProjectSummary>> listDeletedFor(
    String userId, {
    int limit = maxListedProjects,
  }) async {
    final result = await session.execute(
      'SELECT p.project_id, p.project_name, p.deleted_at, d.destroy_at '
      '$_deletedByCaller '
      'ORDER BY p.deleted_at DESC, p.project_id '
      r'LIMIT $3',
      parameters: [userId, ownerMembershipRole, limit],
    );
    return [
      for (final row in result)
        DeletedProjectSummary(
          projectId: row[0]! as String,
          projectName: row[1]! as String,
          // Stored as the device's text stamp; the validator bounded it to a
          // timestamp on the way in, so this reads back. `tryParse` rather
          // than `parse` so one unreadable row could never refuse the list.
          deletedAt: DateTime.tryParse(row[2]! as String)?.toUtc(),
          destroyAt: (row[3] as DateTime?)?.toUtc(),
        ),
    ];
  }

  /// Whether [projectId] is one [listDeletedFor] would list for [userId] —
  /// **the gate on restoring it** (task 11.302).
  ///
  /// **The same three conditions, from the same text, not a second copy of
  /// them.** Both queries are built from [_deletedByCaller], so the people
  /// who may restore a project and the people shown it on the join screen's
  /// *Deleted from your devices, still on the server* section cannot drift
  /// apart: a clause added to one is added to the other.
  /// `deleted_project_directory_test.dart` asserts it the same way, reading
  /// what each caller may do off the listing's own answer for them.
  ///
  /// **Why the listing's population and not `_requireOwner`'s**, which is
  /// wider — any open owner: a restore undoes a *particular* person's act,
  /// and the author clause is what lets the server say *"you deleted this"*
  /// on its strongest footing (Security Model §4.28.1). A co-owner who did
  /// not delete it is not shown the project here and may not restore it
  /// here; §4.28.1 records that decision and what reopens it.
  Future<bool> isDeletedBy(String userId, String projectId) async {
    final result = await session.execute(
      'SELECT 1 $_deletedByCaller '
      r'AND p.project_id = $3',
      parameters: [userId, ownerMembershipRole, projectId],
    );
    return result.isNotEmpty;
  }

  /// The `FROM … WHERE` of "a project [userId] deleted that the server still
  /// holds": `$1` is the caller's user id and `$2` the owner role. The three
  /// conditions are explained on [listDeletedFor]; this is the one place
  /// they are written.
  static final String _deletedByCaller =
      'FROM ${quoted(Tables.projectMemberships)} m '
      'JOIN ${quoted(Tables.projects)} p ON p.project_id = m.project_id '
      'LEFT JOIN project_destruction d ON d.project_id = p.project_id '
      'AND d.executed_at IS NULL '
      r'WHERE m.user_id = $1 AND m.role = $2 AND m.end_date IS NULL '
      'AND m.deleted_at IS NULL '
      r'AND p.deleted_at IS NOT NULL AND p.last_modified_by = $1';
}
