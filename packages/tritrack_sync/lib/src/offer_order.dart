/// **The order a device offers tables to the server in** (task 11.43,
/// reopened 2026-08-31).
///
/// ## The rule
///
/// > **A table that names a global id is offered only after the table that
/// > establishes the project's claim on that id.**
///
/// `offer_rules.dart` decides *which rows* a device offers. This file decides
/// *in what order*, and the two are separate questions with separate failure
/// modes: offering a row the server will never take produces a refusal that
/// never clears, while offering a row too early produces one that clears on
/// the next sync. The second is the one this file exists for.
///
/// ## Why the order can matter at all
///
/// A push is one Postgres transaction, and inside it the server lets a row
/// vouch for a later row of the *same* push
/// (`RowAuthorizer._establishedThisPush`). That is why `Tables.all` being
/// FK-safe was, for a long time, thought to be enough.
///
/// It is not enough, because **`ProjectPublisher` sends one table per HTTP
/// request.** A project's whole state does not fit in one request, and the
/// slices have to preserve FK order, so the publisher walks `Tables.all` and
/// sends each table on its own. Every one of those is a separate transaction,
/// and "established in the same push" buys nothing across them: the only thing
/// that vouched for a tag in request *n* was a `Project_Tags` row committed by
/// request *n − 1* or earlier (until task 11.219 — see below).
///
/// **What that cost, on real hardware.** With `Tag_Versions` ordered before
/// `Project_Tags`, every first publish of a project that had a tag version —
/// which is every project with a tag, since task 11.32 gives each tag a
/// version when it is created — had exactly one row refused. The person saw a
/// red banner and a card saying this "is not a case the app expects" and
/// asking them to report it, on the first thing they ever did with a server.
/// It cleared itself about four minutes later, on the next ordinary sync,
/// because by then the link row was committed.
///
/// **Why no test caught it, which is the finding rather than the row.** The
/// client's publisher tests used a fake transport that models no reachability
/// rule, and every server test pushed the tables together in one request. Both
/// were right on their own terms; between them, the sequence the app actually
/// sends had never been executed. That is what
/// [assertOfferOrderEstablishesReachBeforeItIsNeeded] and the replay tests
/// named in the plan entry are for — the assertion so the class cannot come
/// back through a new table, the replay so the sequence itself is exercised.
///
/// ## What establishes reach, derived rather than named
///
/// The one instance this rule ever had was tags, and it is gone. The server's
/// escape for a row naming a **tag** used to be narrow, and narrower than the
/// reachability *pull* computed: `RowAuthorizer._authorizeTagReferences`
/// refused any tag-bearing row whose tag the project did not already reach
/// unless the row was the `Project_Tags` link itself. So the establishing row
/// was the link, and [reachLinkTableFor] derives which table that is from the
/// declarations — the project-scoped table whose primary key is *exactly* its
/// project scope column plus the column feeding that reach set. A link table
/// is the one whose identity **is** the pair "this project, that id".
///
/// **Task 11.219 made tags project-scoped, so no table in `syncTables` has
/// that shape today and [reachLinkTableFor] returns null for the one reach
/// set left.** Nothing here is ordering anything.
///
/// **This file stays anyway, and that is a decision rather than an
/// oversight.** What it guards against is a table landing in a position that
/// looks FK-safe and is not offer-safe — which is exactly how `Tag_Versions`
/// landed in 11.32 and shipped broken for a month, invisible to every test on
/// both sides. The derivation is over the declarations, so the day somebody
/// adds a global id kind back it is ordered without anybody editing this
/// file. A guard whose subject has temporarily gone away is not the same
/// thing as a guard that cannot fail: hand
/// [assertOfferOrderEstablishesReachBeforeItIsNeeded] a bad order and it
/// still refuses it, which is what its own test does.
///
/// ## Why the user reach set is not ordered, said rather than skipped
///
/// There is no link table for [GlobalReachSet.users] — a membership is keyed
/// by its own id, not by (project, user) — and no ordering would help if there
/// were, because §4.17's escape for a row naming a person is clause 1, *"the
/// row names you"*, not reachability. Two consequences, both deliberate:
///
/// - A table whose rows the server keeps its own record of (`Users`,
///   `User_Emails`, `Projects`, `Project_Memberships`) is already restricted
///   by `namingRequirementsForOffering` to rows that name the caller, so
///   clause 1 covers every row this device offers of it. That is why `Users`
///   may be offered first of all, before anything that could reach it.
/// - A **field** table naming a colleague — a replica of their bearing, or of
///   a truth point they found — is offered, refused and held on purpose.
///   §4.17's accepted cost is stated in terms of the person being *told*, and
///   no ordering changes that answer: the refusal is about who signed the row,
///   not about when it arrived.
///
/// So [assertOfferOrderEstablishesReachBeforeItIsNeeded] orders exactly the
/// reach sets that have a link table, and a reach set that grows one later is
/// ordered the same day it does, without anybody editing this file. Where
/// there is no link table it still refuses one shape — a **global** table
/// naming an id it is not vouched for, which is an identity record whose
/// refusal would never clear — and lets project-scoped field data through,
/// because that refusal is the one §4.17 accepts.
library;

import 'offer_rules.dart';
import 'schema_constants.dart';
import 'sync_tables.dart';

/// Whether [table]'s rows *are* the ids in [reach] — the rows being reached,
/// rather than rows that name one.
///
/// True when the table is global, scoped by [reach], and its whole primary key
/// is the scope column: `Users` for
/// [GlobalReachSet.users]. (`Tags` was the other instance until task 11.219
/// made it project-scoped.) Such a table cannot be ordered after the thing
/// that
/// reaches it, because it *is* the thing reached — the server accordingly lets
/// a `Tags` row be created without any project vouching for it (an unlinked
/// tag is a supported state) and treats it as establishing its own id for the
/// rest of the push.
///
/// `User_Emails` is deliberately **not** a subject: it is keyed by its own id
/// and merely *carries* the reached id, which is exactly the distinction
/// `GlobalScope.column` exists to record. (`Tag_Versions` was the second
/// instance until task 11.219 took it off the global list altogether.)
bool isReachSubject(SyncTable table, GlobalReachSet reach) {
  final scope = table.globalScope;
  if (scope == null || scope.reach != reach) return false;
  return table.primaryKey.length == 1 && table.primaryKey.single == scope.column;
}

/// The table whose rows establish a project's claim on a [reach] id — the link
/// table, whose primary key is exactly its project scope column plus the
/// column feeding [reach]. Null when the reach set has no such table.
///
/// Derived rather than named, so a second link table (or a first one for
/// [GlobalReachSet.users]) is picked up by definition. Throws if more than one
/// table has the shape, because then "the establishing row" is ambiguous and
/// the ordering rule below cannot be stated — a silent first-match would be
/// the hand-maintained list this project keeps finding.
///
/// [tables] exists so a test can hand it a deliberately doctored corpus and
/// watch the ordering rule refuse one — the same reason every other assertion
/// in this package takes one. **It stopped being optional with task 11.219**:
/// tags were the only reach set that ever had a link table, so against the
/// real `syncTables` this returns null and the ordering rule has nothing left
/// to order. Without a doctored corpus there would be no way to see it fire
/// at all, which is the shape this project refuses.
SyncTable? reachLinkTableFor(
  GlobalReachSet reach, {
  List<SyncTable> tables = syncTables,
}) {
  final candidates = <SyncTable>[];
  for (final table in tables) {
    final scope = table.projectScopeColumn;
    if (scope == null) continue;
    final columns = reachColumnsFor(table, reach);
    if (columns.isEmpty) continue;
    if (table.primaryKey.toSet().difference({scope, ...columns}).isNotEmpty) {
      continue;
    }
    if (!table.primaryKey.contains(scope)) continue;
    if (!columns.every(table.primaryKey.contains)) continue;
    candidates.add(table);
  }
  if (candidates.length > 1) {
    throw StateError(
      'More than one table is keyed by (project, ${reach.name} id): '
      '${candidates.map((t) => t.name).join(', ')}. The offer order rule needs '
      'one row that establishes a project\'s claim on an id; with two, which '
      'one has to be on the server first is undecided. Say which, here.',
    );
  }
  return candidates.singleOrNull;
}

/// Whether [table] needs the project's claim on [reach] to already be on the
/// server before its rows can be judged.
///
/// False for the reach set's subject and its link table — those are what
/// establish it — and false where the device only ever offers rows naming the
/// caller, because §4.17 clause 1 vouches for those with no lookup at all.
bool tableNeedsEstablishedReach(
  SyncTable table,
  GlobalReachSet reach, {
  List<SyncTable> tables = syncTables,
}) {
  if (reachColumnsFor(table, reach).isEmpty) return false;
  if (isReachSubject(table, reach)) return false;
  if (reachLinkTableFor(reach, tables: tables)?.name == table.name) {
    return false;
  }
  return namingRequirementsForOffering(table).isEmpty;
}

/// Throws if [order] — [Tables.all] unless a test says otherwise — offers a
/// table before the row that establishes the reach it depends on.
///
/// Called from tests on both sides of the wire. **This is the guard that makes
/// the ordering a property rather than a comment**, and the thing it is
/// guarding against is a fourteenth table landing in a position that looks
/// FK-safe and is not offer-safe — which is exactly how `Tag_Versions` landed
/// in 11.32 and shipped broken for a month.
///
/// A reach set with no link table imposes no constraint, and the reason is in
/// this library's header rather than in a silent `continue`: for the user set
/// the escape is naming the caller, and a field row naming a colleague is
/// refused, held and explained on purpose.
///
/// [order] and [tables] are parameters for exactly one reason: a guard nobody
/// has watched fail is not a guard (task 11.45's standing rule). `Tables.all`
/// and `syncTables` are both `const`, so the only way to see this refuse is to
/// hand it something bad. **Until task 11.219 the bad thing was an order** —
/// the real one that shipped, with `Tag_Versions` before the link that
/// vouched for it. With tags project-scoped there is no link table left in
/// the real corpus, so a bad order alone can no longer make this fire and
/// [tables] is what keeps it falsifiable: the test hands it the two-table
/// shape the rule is about and watches it refuse.
void assertOfferOrderEstablishesReachBeforeItIsNeeded({
  List<String> order = Tables.all,
  List<SyncTable> tables = syncTables,
}) {
  final problems = <String>[];
  for (final reach in GlobalReachSet.values) {
    final link = reachLinkTableFor(reach, tables: tables);
    for (final table in tables) {
      if (!tableNeedsEstablishedReach(table, reach, tables: tables)) continue;
      if (link == null) {
        // No link row exists for this set, so no ordering can help. That is
        // fine for **field data** — a bearing or a truth point naming a
        // colleague is refused, held, counted and explained, which is the cost
        // §4.17 states and accepts (`offer_rules.dart`, "Why field data is
        // deliberately not withheld"). It is **not** fine for a global table:
        // a global row about a person, with no project to be data of, is an
        // identity record, and one this device offers without restricting it
        // to rows naming the caller would be refused forever with no
        // self-clearing path at all.
        if (table.projectScopeColumn != null) continue;
        problems.add(
          '${table.name} is a global table naming a ${reach.name} id, nothing '
          'is keyed by (project, ${reach.name} id) to vouch for it, and its '
          'rows are not restricted to ones naming the caller — so a row of it '
          'about anybody else is refused permanently, not merely early. Give '
          'it an offer-time naming requirement (see '
          'namingRequirementsForOffering) or say here why the server takes it '
          'unreached.',
        );
        continue;
      }
      final at = order.indexOf(table.name);
      final establishedAt = order.indexOf(link.name);
      if (at > establishedAt) continue;
      problems.add(
        '${table.name} is offered at position $at, before ${link.name} at '
        '$establishedAt. A publish sends one table per request, so the '
        '${reach.name} id ${table.name} names is not yet reachable when the '
        'server judges it, and every first publish carrying such a row has it '
        'refused. Move ${table.name} after ${link.name} in Tables.all.',
      );
    }
  }
  if (problems.isNotEmpty) {
    throw StateError(
      'The offer order puts a table before the row that vouches for it:\n'
      '${problems.map((p) => '  - $p').join('\n')}',
    );
  }
}
