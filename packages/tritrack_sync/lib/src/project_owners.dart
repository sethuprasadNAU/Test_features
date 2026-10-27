/// Who owns a project (task 11.1).
///
/// Task 8.4 answered this with `Projects.owner_user_id`, deliberately: no
/// ownership-transfer feature existed, so the column and `Project_Memberships`
/// could not diverge, and making the enforcement boundary depend on a second
/// table's population state was the failure mode 8.1 warned about. Task 11.1
/// changes both halves of that premise — ownership transfers now, and there is
/// more than one owner — so the authorization source moves to **`role='owner'`
/// rows in `Project_Memberships` with `end_date IS NULL`**, any number of them,
/// all with identical rights.
///
/// `Projects.owner_user_id` is **retained as a creator/audit record** and as
/// the bootstrap fallback below. It is no longer the authorization source.
///
/// The *resolution* lives here, in the shared package, for the reason
/// [tableMutationRules] does: a client and a server that disagree about who
/// owns a project disagree about who may manage it, and one definition means
/// the disagreement cannot exist. Only the row-fetching differs between the two
/// (sqflite vs. Postgres); the decision made from those rows is this function.
library;

/// The `Project_Memberships.role` value that confers ownership.
///
/// Named rather than spelled out at each use because the client's push
/// predicate has to say it in SQL (`SyncEngine._pendingClause`), and a literal
/// matched in two languages is the pair that drifts.
const String ownerMembershipRole = 'owner';

/// The users who currently own the project, given its membership rows.
///
/// [membershipRows] must be every `Project_Memberships` row for one project —
/// including ended and tombstoned ones, which this filters. Filtering here
/// rather than in each caller's `WHERE` clause is what makes the two sides
/// provably agree: a query that forgets `deleted_at IS NULL` is a difference
/// this function cannot have.
///
/// [creatorUserId] is the project's `Projects.owner_user_id`. It is used
/// **only** when the membership table names no open owner at all, which is not
/// a hypothetical:
///
/// - Projects created before task 8.4 adopted `Project_Memberships`, on a
///   device whose lazy backfill has not run yet.
/// - The window inside a first publish (task 10.9), where the server authorizes
///   every row of a batch *before* writing any of them — so the batch's own
///   `Projects` row is not yet stored when its `Project_Memberships` row is
///   being judged.
///
/// Falling back rather than failing closed keeps both of those working
/// unchanged. It cannot be used to *regain* ownership after a transfer: a
/// transfer leaves at least one open owner membership by construction (the
/// last-owner guard refuses anything else), so the fallback is unreachable
/// whenever a real owner exists.
Set<String> resolveProjectOwners({
  required Iterable<Map<String, Object?>> membershipRows,
  required String? creatorUserId,
}) {
  final owners = <String>{
    for (final row in membershipRows)
      if (isOpenOwnerMembership(row))
        if (row['user_id'] case final String userId) userId,
  };
  if (owners.isNotEmpty) return owners;
  return creatorUserId == null ? const {} : {creatorUserId};
}

/// Whether one `Project_Memberships` row currently confers ownership.
///
/// Three columns, all of which must hold, and each of which has bitten this
/// project once already:
///
/// - `role = 'owner'` — the gradient's top rung.
/// - `end_date IS NULL` — a membership is deactivated by setting `end_date`,
///   not by tombstoning (see the model doc and `SyncTable.deactivationColumns`
///   for `Project_Memberships`, which lists both for exactly this reason).
/// - `deleted_at IS NULL` — the ordinary soft-delete tombstone, which the
///   `end_date` convention does not replace.
bool isOpenOwnerMembership(Map<String, Object?> row) =>
    row['role'] == ownerMembershipRole &&
    row['end_date'] == null &&
    row['deleted_at'] == null;
