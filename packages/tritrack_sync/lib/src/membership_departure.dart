/// **Leaving a project: the one exception to "membership rows are owner-only
/// to write" (task 11.28).**
///
/// Membership rows are [MutationRule.projectOwner] — an owner may write them
/// and nobody else — because in this table the row *is* somebody's rights.
/// That left a real gap, recorded as M8 in `CLAUDE_DOCS/PERMISSIONS_MATRIX.md`
/// and confirmed by task 11.23: **a viewer or a contributor could not get off
/// a project by any means.** They had to ask an owner, and if their device
/// tried anyway the write threw on the device and the server refused the row
/// forever, leaving that device permanently out of step on it.
///
/// Michael decided on 2026-08-22 that a viewer or a contributor may leave, and
/// that no owner confirmation is required. This file is the exception that
/// makes it possible, and it is written to be the narrowest statement of it
/// that can be made:
///
/// > A person may set `end_date` on **their own currently-open membership
/// > row**, changing nothing else about it.
///
/// ## Why this lives in the shared package
///
/// Same reason [resolveProjectOwners] and [tableMutationRules] do: the app's
/// repository layer and the server's `RowAuthorizer` must not be able to
/// disagree about what a departure *is*. A client that thinks a write is a
/// departure and a server that does not is exactly the state task 11.28 exists
/// to end — the device writes a row the server refuses forever. One predicate
/// means the disagreement cannot exist.
///
/// ## The three things it deliberately does not do
///
/// 1. **It does not decide the last-owner question.** A project must never
///    reach zero open owners, and that rule already exists on both sides
///    (`ProjectMembershipRepository._guardLastOwnerRemoval`,
///    `RowAuthorizer._authorizeOwnerRemoval`, including the two-owners-in-one
///    -batch case task 11.9 verified). This predicate is composed *with* that
///    guard, never in place of it — see both call sites, where the guard runs
///    after this says yes.
/// 2. **It never reads the caller's claim about who they are.** The user the
///    row belongs to is read from the **stored** row, never from the incoming
///    one. A caller who rewrote `user_id` to their own id would be refused by
///    the reattribution rule long before this, but the point of reading the
///    stored row is that this predicate does not depend on that being true.
/// 3. **It does not permit ending a membership that is already over**, or
///    reopening one. `end_date` goes from null to set, in that direction only.
library;

import 'schema_constants.dart';
import 'table_columns.dart';

/// The `Project_Memberships` columns a departure is allowed to change.
///
/// **Everything else must be byte-identical to the stored row**, and the set
/// of "everything else" is derived from [tableSpecsByName] rather than listed
/// — so a column added to this table in a future migration lands automatically
/// on the *immutable* side. That direction is the safe one: a new column that
/// nobody thought about cannot be smuggled through a departure, and the day
/// somebody genuinely needs it to move they have to come here and say so.
///
/// This project has paid for the other direction five times (the stale count
/// of synced tables, two governing-column lists, task 10.97's seven named text
/// columns, N-1's three tables, and task 11.32's near-miss); a hand-maintained
/// list of "fields a departure may touch" would be the sixth.
///
/// The four beyond `end_date` are ordinary sync bookkeeping every write bumps:
///
/// - `updated_at`, `revision` — the merge clock. A write that did not move
///   them would not win against the stored row at all.
/// - `last_modified_by` — who performed the change. Task 11.24 requires this
///   to name the caller, and the server enforces that separately
///   (`RowAuthorizer._authorizeNaming`'s `auditUserColumn` branch), which is
///   why it is safe to let it move here.
/// - `origin_device_id` — which of the person's devices did it.
///
/// Note what is **not** here: `role` (leaving must not be a promotion),
/// `deleted_at` (leaving records a stint that ended, it does not erase one),
/// `join_date`, `created_at`, `user_id`, `project_id`, `membership_id`.
const Set<String> departureMutableColumns = {
  'end_date',
  'updated_at',
  'revision',
  'last_modified_by',
  'origin_device_id',
};

/// The `Project_Memberships` columns a departure must leave exactly as found.
///
/// Derived, not listed — see [departureMutableColumns].
Set<String> get departureImmutableColumns => {
  for (final column in tableSpecsByName[Tables.projectMemberships]!.columnNames)
    if (!departureMutableColumns.contains(column)) column,
};

/// Throws if [departureMutableColumns] names a column `Project_Memberships`
/// does not have.
///
/// Called from tests on both sides of the wire, for the reason
/// `assertEveryTableHasAMutationRule` and
/// `assertEveryGlobalTableDeclaresItsScope` are: a set of column names that
/// has never been checked against the schema is a set that silently stops
/// meaning anything the moment a column is renamed. If `end_date` were renamed
/// and this were not caught, every column would land on the immutable side and
/// leaving would simply stop working — a quiet regression, not a loud one.
void assertDepartureColumnsExist({Set<String>? mutableColumns}) {
  final declared = tableSpecsByName[Tables.projectMemberships]!.columnNames
      .toSet();
  final unknown = (mutableColumns ?? departureMutableColumns)
      .where((column) => !declared.contains(column))
      .toList();
  if (unknown.isNotEmpty) {
    throw StateError(
      'departureMutableColumns names ${unknown.join(', ')}, which '
      '${Tables.projectMemberships} does not have. Reconcile it with '
      'tableSpecs — a stale name here silently changes what leaving a project '
      'is allowed to do.',
    );
  }
}

/// Whether writing [incoming] over [existing] is exactly [callerUserId] ending
/// their own open membership stint — and nothing else.
///
/// Returns false for **every** other write, including every write by a person
/// who is not the row's subject. Callers treat a false as "no exception
/// applies", falling back to the ordinary owner rule; they must never treat it
/// as a denial in its own right, because an owner managing somebody else's row
/// is a perfectly legitimate write this predicate has nothing to say about.
///
/// [existing] must be the **stored** row (null for an insert — an insert is
/// never a departure, because there is no stint to end). [incoming] is the row
/// the caller is proposing. [table] is checked so the predicate cannot be
/// applied to the wrong table by accident.
bool isSelfDeparture({
  required String table,
  required String? callerUserId,
  required Map<String, Object?>? existing,
  required Map<String, Object?> incoming,
}) {
  if (table != Tables.projectMemberships) return false;
  // An insert cannot end a stint. It is also the shape that would matter most
  // if it slipped through: an insert into this table *is* a grant.
  if (existing == null) return false;
  if (callerUserId == null || callerUserId.isEmpty) return false;

  // **The whole of "your own, and nobody else's", and it reads the stored
  // row.** What the caller asserts about `user_id` is irrelevant here; the
  // immutability check below is what stops them asserting anything different.
  if (existing['user_id'] != callerUserId) return false;

  // Currently open: an ended or tombstoned stint has nothing to end, and
  // permitting either would make this a way to edit closed history.
  if (existing['end_date'] != null) return false;
  if (existing['deleted_at'] != null) return false;

  // And the write closes it. A non-empty string, because that is how every
  // timestamp column is stored on both sides; anything else is not a
  // departure and falls through to the ordinary rule rather than being
  // tolerated here.
  final endDate = incoming['end_date'];
  if (endDate is! String || endDate.isEmpty) return false;

  // Everything else is exactly as found. This is the clause that stops a
  // departure being a promotion, a tombstone, a re-dated stint, or a move
  // between projects, and it is derived from the schema so it also stops the
  // next column somebody adds.
  for (final column in departureImmutableColumns) {
    if (incoming[column] != existing[column]) return false;
  }
  return true;
}
