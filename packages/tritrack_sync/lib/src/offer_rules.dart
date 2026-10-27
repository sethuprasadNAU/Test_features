/// **What a device may offer the server at all** (task 11.43).
///
/// ## The rule
///
/// > **A device offers the server every row of the project except the records
/// > the server keeps for itself.** Who somebody *is*, and what they *may do*,
/// > are the server's own records: it writes them from that person's
/// > authenticated sign-in and from their own redemption of an invitation, and
/// > it will not take another device's word for either. Everything else — every
/// > bearing, every tag, every estimate — the device offers, and where the
/// > server refuses one it is held, named and explained exactly as before.
///
/// It is a rule and not a list of tables on purpose. Four weeks running, the
/// finding on this project has been a hand-kept list that a new table walked
/// past (10.66's standing criterion). The classification below is read off the
/// declarations a new table cannot be added without making — its
/// [MutationRule] (no default; `assertEveryTableHasAMutationRule`) and its
/// [SyncTable.projectScopeColumn] / [SyncTable.globalScope]
/// (`assertEveryGlobalTableDeclaresItsScope`) — so table fourteen lands on one
/// side or the other by definition rather than by somebody remembering.
/// [assertOfferRulesClassifyEveryTable] fails loudly if it cannot be read.
///
/// ## Why this had to exist
///
/// **Found on real hardware, 2026-08-27.** Publishing a project two people had
/// touched offered the teammate's `Users` row, their `User_Emails` history and
/// their `Project_Memberships` row. Every one of those is a row the server
/// refuses *unconditionally* — see the safety property below — so a first
/// publish produced a permanent-looking "records aren't on the server" warning
/// every time. Task 11.41 made those warnings visible and recoverable; this is
/// the other half, which is to stop offering the server something it will
/// always refuse.
///
/// ## The safety property, which is what makes withholding legitimate
///
/// **Nothing withheld here could ever have been accepted.** §4.17 of the
/// security model permits a row to name someone other than the caller on one
/// condition — clause 2, "this project already reaches them" — and that clause
/// applies only where [MutationRule.vouchesForAForeignName] is true. Every
/// table this file withholds a foreign-named row of has it false, so the
/// server's answer for such a row is `deny(namesForeignUser)` with no lookup
/// and no dependence on server state. Withholding is therefore exactly the set
/// of unconditional denials: it can never suppress a row that would have gone
/// through, and there is no version of "try again later" in which it would.
///
/// ## Where that property was false, and the correction (task 11.57)
///
/// The paragraph above is true of an **insert** and was applied to updates as
/// well, where it does not hold. `RowAuthorizer._authorizeNaming` refuses a
/// foreign name on an insert; on an update it asks only whether the name has
/// *changed*. So an owner ending a member's stint — the row names the member,
/// unchanged, and the owner is entitled to write it — was withheld by a rule
/// whose justification did not cover it, and **the removal never left the
/// owner's device.** Measured against the real server on 2026-08-29; the person
/// stayed a member for good, and because the push's pending count is computed
/// from this same rule, nothing anywhere said so. See
/// [namingRequirementsForOffering] for the waiver that closes it and the three
/// things that bound it.
///
/// ## Why field data is deliberately *not* withheld
///
/// `Observations`, `Non_Detections` and `Observation_Exclusions` also name an
/// author, and a replica of a colleague's bearing is refused by exactly the
/// same rule. Those are still offered, still refused and still held — because
/// they are field records the server has no other way to obtain, and §4.17's
/// accepted cost is stated in terms of the user being *told*: *"nothing is
/// lost meanwhile — the held-row store keeps every refused row on the device,
/// counts it against 'everything is synced', and explains it."* Withholding
/// one would turn a visible, self-clearing wait into a silent omission, which
/// is the trade §4.17 made the held-row store to avoid.
///
/// That is the whole of the distinction, and it is the reason the classifier
/// asks two questions rather than one: authorization state is never field
/// data, and a row that names an author is field data **unless it has no
/// project to be field data of**.
library;

import 'mutation_rules.dart';
import 'sync_tables.dart';

/// Whether [table] holds records the server keeps for itself — a person's
/// identity, or their rights — rather than records of the field.
///
/// True for exactly four tables, and derived rather than named:
///
/// - `Projects` and `Project_Memberships`, because
///   [MutationRule.isAuthorizationState] is what "their rights" means. The
///   server writes a membership row itself when an invitation is redeemed, out
///   of the invitation's own `project_id` and `role` and the authenticated
///   session's `user_id`; no part of it comes from a request body, which is
///   why the sync path never needed an exemption for it.
/// - `Users` and `User_Emails`, because they name an author
///   ([MutationRule.namesRowAuthor]) and have no project to be data *of*
///   ([SyncTable.projectScopeColumn] is null). A global row about a person is
///   that person's identity record. The server creates a placeholder one at
///   redemption — carrying the address it authenticated, and deliberately no
///   invented name — and the real one arrives when that person's own device
///   pushes it under a rule that permits it.
bool serverKeepsItsOwnRecordOf(SyncTable table) {
  final rule = tableMutationRules[table.name];
  // A table with no declared rule is not this file's to judge.
  // `assertEveryTableHasAMutationRule` is the check that says so loudly;
  // answering "false" here defers to it rather than inventing a second answer.
  if (rule == null) return false;
  if (rule.isAuthorizationState) return true;
  return rule.namesRowAuthor && table.projectScopeColumn == null;
}

/// One naming requirement a row must satisfy before a device will offer it:
/// the column that must name the signed-in user, and whether **owning the
/// project** waives that requirement.
typedef OfferNamingRequirement = ({String column, bool waivedByOwnership});

/// The naming requirements [table] imposes on a row before a device will offer
/// it to the server — empty when the row is the device's to send whoever it
/// names.
///
/// [SyncTable.userColumns] and not [SyncTable.identityUserColumns]: the audit
/// column is included because §4.17 is stated over the wider set and the server
/// enforces it over the wider set. A `Users` row whose `last_modified_by` names
/// somebody else is refused just as firmly as one whose `user_id` does.
///
/// **Task 11.47 relaxed the audit column and this list is deliberately not
/// affected**, which is worth stating because the two look like they should
/// move together. [MutationRule.replicatesAForeignAuditName] is true only
/// where [MutationRule.vouchesForAForeignName] is, and every table
/// [serverKeepsItsOwnRecordOf] returns true for is governed by `author`,
/// `owner` or `projectOwner` — so all four have it false and their audit
/// column is still checked at the boundary. The sentence above still holds
/// exactly as written; there is no table this function withholds whose audit
/// name the server would now take.
///
/// ## The ownership waiver, and the defect it closes (task 11.57)
///
/// Until 2026-08-29 this was a flat rule — *every* one of these columns had to
/// name the caller — and its stated safety property was that **nothing
/// withheld could ever have been accepted.** Measured against the real server,
/// that property is false for one shape, and the shape is the whole of one
/// direction of the membership cycle:
///
/// > An owner ends a member's stint, or changes their role. The row names the
/// > *member* in `user_id`, so the flat rule withheld it — silently, and not
/// > even counted as waiting, because the push's pending count is computed from
/// > this same rule. **The removal never left the owner's device.** The person
/// > stayed a member on the server for good: still syncing, still counted, and
/// > no invitation could ever be issued to them because the server correctly
/// > said they were already on it.
///
/// The server has always accepted that write. `RowAuthorizer._authorizeNaming`
/// refuses a foreign name on an **insert** into these tables; on an *update* it
/// asks only that the name has not *changed* (`reattribution`) and that the
/// audit column names the caller (`unattributedChange`). An owner ending
/// somebody else's stint changes neither. So the flat rule was withholding a
/// write the server was waiting for.
///
/// The waiver is therefore: **an identity column need not name the caller when
/// the caller owns the project the row belongs to and the server already holds
/// the row.** Four things bound it, and each is doing work:
///
/// 1. **Only where there is a project to own.** `Users` and `User_Emails` are
///    global ([SyncTable.projectScopeColumn] is null); nobody owns them, and
///    they keep the flat rule. This is what stops the waiver becoming "an owner
///    may push a colleague's identity record".
/// 2. **Never the audit column.** `last_modified_by` must name the caller
///    whatever else is true, because it is a claim about who made *this*
///    change.
/// 3. **Only where the server already holds the row**, which is the clause that
///    keeps this an *update*. The server's refusal of a foreign name is
///    unconditional on an **insert**, so widening past that would put the
///    original property back in the state it was measured false in — merely
///    facing the other way. It is also what keeps task 11.43's headline closed:
///    a first publish of a project whose owner added a teammate locally has no
///    receipt for that membership row, so the row is still withheld and the
///    publish still produces no refused record. The evidence is
///    `Sync_Row_Receipts`, which records a row the server **delivered** as well
///    as one it accepted — so an owner who has pulled a member's row has the
///    receipt that makes their removal of that member offerable.
/// 4. **Ownership is the caller's, resolved from open owner memberships**, not
///    a claim in the row. See `resolveProjectOwners`, whose creator fallback is
///    deliberately not mirrored by the callers: the waiver only ever widens
///    what is offered, so omitting a case can withhold nothing that was
///    previously sent.
///
/// **What is still withheld, said plainly rather than discovered:** an owner
/// *inserting* a membership row for somebody else — which is
/// `ProjectMembershipRepository.grantOwner`, and has no caller in the app today
/// — has no receipt and is not offered. The server would refuse it, so nothing
/// is lost; but an ownership transfer that cannot reach the server also does
/// not currently say so anywhere, and that is a gap this task recorded rather
/// than closed.
List<OfferNamingRequirement> namingRequirementsForOffering(SyncTable table) {
  if (!serverKeepsItsOwnRecordOf(table)) return const [];
  final ownable = table.projectScopeColumn != null;
  return [
    for (final column in table.userColumns)
      (
        column: column,
        waivedByOwnership: ownable && column != auditUserColumn,
      ),
  ];
}

/// Whether a device signed in as [callerUserId] may offer [row] of [table].
///
/// [callerOwnsTheProject] answers *"is the caller an open owner of the project
/// this row belongs to?"* and [serverAlreadyHoldsThisRow] answers *"has this
/// row ever been on the server?"* — read from `Sync_Row_Receipts`, which is
/// written both when the server accepts a row and when it delivers one. Both
/// are consulted only for the requirements [namingRequirementsForOffering]
/// marks waivable, and both are required rather than defaulted so a new call
/// site has to answer them rather than inherit an answer.
///
/// A null value in a governed column permits, on the same contract
/// [MutationRule.permits] states: there is nothing to single out, so nothing to
/// deny. A null [callerUserId] — no session — denies every governed row, which
/// is the fail-closed direction and unreachable in practice, since a push
/// without a session never leaves the device.
bool mayOfferRow(
  SyncTable table,
  Map<String, Object?> row,
  String? callerUserId, {
  required bool callerOwnsTheProject,
  required bool serverAlreadyHoldsThisRow,
}) {
  final waived = callerOwnsTheProject && serverAlreadyHoldsThisRow;
  for (final requirement in namingRequirementsForOffering(table)) {
    final named = row[requirement.column];
    if (named == null) continue;
    if (named == callerUserId) continue;
    if (requirement.waivedByOwnership && waived) continue;
    return false;
  }
  return true;
}

/// Throws if any table in [syncTables] cannot be classified, which today can
/// only mean it has no [MutationRule].
///
/// Called from tests on both sides of the wire, alongside
/// [assertEveryTableHasAMutationRule]. The point is the same: a table added
/// without a rule must fail a test rather than quietly fall on the permissive
/// side of this file's question.
void assertOfferRulesClassifyEveryTable() {
  final unclassifiable = [
    for (final table in syncTables)
      if (!tableMutationRules.containsKey(table.name)) table.name,
  ];
  if (unclassifiable.isNotEmpty) {
    throw StateError(
      'Cannot decide whether the server keeps its own record of: '
      '${unclassifiable.join(', ')}. Every table needs a MutationRule before '
      'this file can say whether a device may offer its rows.',
    );
  }
}
