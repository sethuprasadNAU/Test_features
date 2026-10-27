/// Server-side push/pull/ack (task 10.7).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../authz/row_authorizer.dart';
import '../db/postgres_database.dart';
import '../schema/postgres_schema.dart';
import 'project_reachability.dart';
import 'revision_anomaly_log.dart';
import 'revision_plausibility.dart';
import 'row_merge.dart';
import 'server_seq.dart';

/// One row that lost last-write-wins, for reporting upward.
class LostRow {
  const LostRow({
    required this.table,
    required this.primaryKey,
    required this.serverRow,
  });

  final String table;
  final String primaryKey;

  /// The server copy that won, so 10.12 can tell the user what replaced their
  /// edit rather than only that something did.
  final Map<String, Object?> serverRow;
}

/// Result of applying a push.
class PushResult {
  const PushResult({
    required this.outcomes,
    required this.lost,
    required this.applied,
    required this.highestServerSeq,
    this.refusals = const {},
    this.interlockRefusals = const {},
  });

  final Map<String, SyncRowOutcome> outcomes;
  final List<LostRow> lost;
  final int applied;
  final int? highestServerSeq;

  /// Why a row was refused, keyed as [outcomes] is, for the refusals that can
  /// say (task 11.124).
  ///
  /// **Written at exactly one of the sites that record an `invalid` outcome:**
  /// the one holding a [RowIssue] list, which is the only one that knows
  /// anything. The others — a row with no usable key, and a write the database
  /// itself rejected — genuinely do not know which part was wrong, so they add
  /// nothing here and the device falls back to task 11.122's honest default.
  /// Nothing writes a detail beside an `unauthorized` outcome; see
  /// [SyncPushResponse.refusals] for why that is a security bound rather than
  /// an omission.
  final Map<String, RowRefusal> refusals;

  /// Which shared rule about the project's other rows refused a row, keyed
  /// as [outcomes] is — task 11.267's second channel, for the refusals a
  /// [RowRefusal] cannot answer. See [SyncPushResponse.interlockRefusals].
  final Map<String, String> interlockRefusals;
}

/// The reachable ids a global table's [GlobalScope] narrows it to.
///
/// **This used to be a hand-written map of table name to filter, and task
/// 11.32 removed it.** Its miss branch was `continue`, so a global table
/// nobody had added to it was never delivered by pull at all — silently, with
/// no error and nothing in a log. The scope is now declared on the table
/// descriptor itself, where `assertEveryGlobalTableDeclaresItsScope` makes
/// omitting it a failing test rather than a table that quietly never arrives.
/// `RowAuthorizer._mayKnowRowExists`, which its own comment admitted was a
/// hand-maintained mirror of the old map, now reads the same declaration.
List<String> reachableIdsFor(GlobalScope scope, ProjectReachability reach) =>
    switch (scope.reach) {
      GlobalReachSet.users => reach.users.toList(),
    };

class SyncService {
  SyncService({required this.session, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Must be a session inside an open transaction — the `server_seq` allocator
  /// depends on holding its row lock until *this* transaction commits, and a
  /// partially applied push would leave the cursor able to advance past
  /// unmerged rows.
  final Session session;

  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  /// Savepoint name for one row's write (task 10.46, finding G-5).
  ///
  /// Postgres aborts the **whole enclosing transaction** on any statement
  /// error, so without a savepoint here, one row with a missing `NOT NULL`
  /// column or a value `RowValidator` does not type-check (it leaves that to
  /// the database, by design — see its header) would fail the write, poison
  /// every statement after it, and turn a batch of nine good rows and one bad
  /// one into a `500` that lands none of them. `RowValidator` catches what it
  /// knows to check; this catches whatever the database itself enforces, and
  /// reports the same [SyncRowOutcome.invalid] either way — the caller cannot
  /// tell which check caught it, which is the point: both mean "malformed",
  /// not "the server broke".
  static const String _rowWriteSavepoint = 'tritrack_row_write';

  /// Runs [write] — an `_insert` or `_update` — inside its own savepoint,
  /// returning whether it succeeded. A single name is reused across rows
  /// rather than minted per row: each call fully resolves (RELEASE or
  /// ROLLBACK TO) before the next one starts, so nothing is ever ambiguous
  /// about which savepoint a resolution targets, and reuse costs nothing a
  /// unique name would have bought.
  Future<bool> _tryWrite(Future<void> Function() write) async {
    await session.execute('SAVEPOINT $_rowWriteSavepoint');
    try {
      await write();
      await session.execute('RELEASE SAVEPOINT $_rowWriteSavepoint');
      return true;
    } catch (_) {
      // Deliberately catch-all, for the same reason `attemptPublish` in
      // sync_routes.dart is: whatever the database's exact exception type,
      // this row failed to write, and its message may carry column *values*
      // (§4.7 rule 6 — no row content in anything that reaches a client or a
      // log a client could read).
      await session.execute('ROLLBACK TO SAVEPOINT $_rowWriteSavepoint');
      return false;
    }
  }

  /// Applies pushed rows, merging each with the **shared** `MergeResolver`.
  ///
  /// Every row is read, compared in Dart, and written — rather than expressed
  /// as one clever `INSERT … ON CONFLICT … WHERE incoming.revision > …`. That
  /// SQL version is faster and is forbidden: it would be a second
  /// implementation of the merge rule, and a client and server that disagree
  /// about who wins produce split-brain, where two devices converge on
  /// different states depending on which synced through the server. Avoiding
  /// that is the entire reason `packages/tritrack_sync` exists.
  ///
  /// Rows are applied in `Tables.all` order so parents precede children.
  /// Foreign keys are deferred to commit anyway (task 10.5), so this is for
  /// legibility rather than correctness — but it also means a batch that is
  /// internally inconsistent fails as a whole rather than half-landing.
  /// [authorizer] enforces the shared rule table (task 10.10). Required rather
  /// than optional on purpose: an overload that authorized nothing would be
  /// the easiest possible way to reintroduce an unauthorized write path.
  Future<PushResult> applyPush({
    required String projectId,
    required SyncRows rows,
    required RowAuthorizer authorizer,
    String? deviceId,
  }) async {
    final outcomes = <String, SyncRowOutcome>{};
    final refusals = <String, RowRefusal>{};
    final interlockRefusals = <String, String>{};
    final lost = <LostRow>[];
    final pending =
        <({SyncTable table, Map<String, Object?> row, String key})>[];
    // The `Deployments` rows this page has already decided to write, by
    // `deployment_id` — what the interlock checks the next one against, on
    // top of the store. See [_overlapsAStoredDeployment].
    final decidedDeployments = <String, DeploymentInterval>{};

    // Decide everything first, so the number of sequence values needed is known
    // before the counter is touched. One counter bump per push rather than one
    // per row keeps the serialisation window as short as possible.
    for (final table in syncTables) {
      for (final row in rows[table.name] ?? const []) {
        final key = _rowKey(table, row);
        if (key == null) {
          outcomes['${table.name}/?'] = SyncRowOutcome.invalid;
          continue;
        }
        final reference = '${table.name}/$key';

        final issues = RowValidator.validate(table.name, row);
        if (issues.isNotEmpty) {
          outcomes[reference] = SyncRowOutcome.invalid;
          // Derived in the shared package so this server and the suite's fake
          // server cannot answer differently — see [RowRefusal.fromIssues].
          // `RowIssue.message` deliberately does not go on the wire: it can
          // quote a column *value*, and no server prose reaches a client
          // screen (§4.13).
          final refusal = RowRefusal.fromIssues(issues);
          if (refusal != null) refusals[reference] = refusal;
          continue;
        }
        pending.add((table: table, row: row, key: key));
      }
    }

    // **Two rows for one primary key in the same push (task 11.221).** Until
    // this check the first row landed, Postgres refused the second on the key,
    // and because `outcomes` is keyed by the reference both rows share the
    // second verdict overwrote the first — so the push answered `applied: 1`
    // beside a lone `invalid` for that key, and the client could not tell
    // which of its two rows had been taken. Every row sharing a key is
    // refused as `invalid` and none is applied; the rest of the push is
    // untouched, because task 10.46 removed "one bad row fails the whole
    // push" and this does not bring it back.
    //
    // **Decided from the push's own contents alone.** Nothing here reads a
    // stored row, so a refusal cannot leak whether the server holds that key
    // (§4.13) — the sender already knows both rows, because it sent them.
    final seen = <String>{};
    final duplicated = <String>{};
    for (final item in pending) {
      final reference = '${item.table.name}/${item.key}';
      if (!seen.add(reference)) duplicated.add(reference);
    }
    if (duplicated.isNotEmpty) {
      pending.removeWhere(
        (item) => duplicated.contains('${item.table.name}/${item.key}'),
      );
      for (final reference in duplicated) {
        outcomes[reference] = SyncRowOutcome.invalid;
      }
    }

    final decisions =
        <
          ({
            SyncTable table,
            Map<String, Object?> row,
            String key,
            MergeDecision decision,
          })
        >[];
    for (final item in pending) {
      final existing = await _findRow(item.table, item.row);
      final decision = RowMerge.decide(
        incoming: item.row,
        existing: existing,
        receivedAt: _now,
      );
      // Authorization runs *after* the merge decision and *before* any write,
      // because whether a push is a mutation at all is what decides whether it
      // needs permission — see [RowAuthorizer]'s doc comment.
      final verdict = await authorizer.authorizeWrite(
        table: item.table,
        incoming: item.row,
        existing: existing,
        changesStoredRow: decision.changesStoredRow,
      );
      if (!verdict.isAllowed) {
        outcomes['${item.table.name}/${item.key}'] =
            SyncRowOutcome.unauthorized;
        continue;
      }
      // **Michael's interlock, at the boundary** (task 11.243, design §6).
      // The device refuses an overlapping deployment at the point of the
      // link; this refuses one arriving from a device that did not, because
      // *a rule enforced on one device is a rule about that device, not about
      // the record*. `DeploymentInterlock` is the shared function both sides
      // call, so there is no second implementation to disagree with the
      // first.
      //
      // **Here rather than in `RowValidator`** because an overlap is a fact
      // about the project's *other* rows and that validator sees one row at a
      // time by design. Here rather than in `RowAuthorizer` because it is not
      // a question about permission: the caller is entitled to write this
      // row, and the row is wrong.
      if (item.table.name == Tables.deployments && decision.changesStoredRow) {
        if (await _overlapsAStoredDeployment(
          projectId,
          item.row,
          decidedSoFar: decidedDeployments.values,
        )) {
          outcomes['${item.table.name}/${item.key}'] = SyncRowOutcome.invalid;
          // **No `RowRefusal` code**, and that is still deliberate rather
          // than an omission (task 11.267). Every code in that vocabulary is
          // derived from a column's declared bound (see `RowRefusal`'s bound
          // 1); an interlock is not a bound, and a code picked by hand at a
          // refusal site is the hand-maintained list that type exists to
          // avoid.
          //
          // **What was wrong until task 11.267 was the sentence this leaned
          // on** — "the device that sent this already refuses the same row
          // locally and owns the sentence." A row written under an earlier,
          // looser tolerance and never re-checked locally (task 11.263's own
          // history) reaches here without ever having been refused on this
          // device, so nobody owned the sentence and the person got the
          // honest-default copy with an irrelevant remedy attached.
          //
          // The fix is not a `RowRefusal` code: it is telling the device
          // *which shared rule* fired, via `DeploymentInterlock.ruleId`
          // below, so it can run that same rule against its own stored rows
          // — which is everything the rule needs — and produce the same
          // sentence a local link attempt would have.
          interlockRefusals['${item.table.name}/${item.key}'] =
              DeploymentInterlock.ruleId;
          continue;
        }
        if (DeploymentInterlock.intervalFromRow(item.row) case final it?) {
          decidedDeployments[it.deploymentId] = it;
        }
      }
      decisions.add((
        table: item.table,
        row: item.row,
        key: item.key,
        decision: decision,
      ));
    }

    final changing = decisions.where((d) => d.decision.changesStoredRow).length;
    SeqBlock? block;
    if (changing > 0) {
      block = await ServerSeq.reserve(
        PostgresSeqCounterStore(session),
        changing,
      );
    }
    final sequence = block?.values.iterator;

    var applied = 0;
    final anomalies = RevisionAnomalyLog(session);

    /// Records one revision anomaly against the row it is about (task 11.159).
    ///
    /// **Nothing here changes what was stored.** It runs after the write it
    /// describes, in the same transaction, so the register and the row it names
    /// commit or roll back together.
    Future<void> noteAnomaly(
      SyncTable table,
      String key,
      RevisionVerdict verdict,
      RevisionSighting observedAs,
    ) => anomalies.record(
      projectId: projectId,
      tableName: table.name,
      rowKey: key,
      verdict: verdict,
      observedAs: observedAs,
      userId: authorizer.userId,
      deviceId: deviceId,
    );

    for (final item in decisions) {
      final reference = '${item.table.name}/${item.key}';
      final decision = item.decision;

      switch (decision.action) {
        case MergeAction.skip:
          // The stored row is unchanged, so its `server_seq` is deliberately
          // NOT bumped — bumping on a no-op would redeliver an unchanged row
          // to every other device on their next pull, forever.
          outcomes[reference] = SyncRowOutcome.lostToServer;
          // The row that won is one nobody can overtake: this push is a
          // person's correction being discarded permanently, and it is the
          // only way a pin that predates this detection becomes visible.
          // An *incoming* row that is itself unexplainable but merely lost is
          // deliberately not recorded — it changed nothing, and the register
          // says "rows on this server that are pinned", not "pushes that were
          // odd".
          if (decision.blockingRowVerdict case final verdict?) {
            await noteAnomaly(
              item.table,
              item.key,
              verdict,
              RevisionSighting.blocking,
            );
          }
          final serverRow = await _findRow(item.table, item.row);
          if (serverRow != null &&
              await authorizer.canDisclose(table: item.table, row: serverRow)) {
            lost.add(
              LostRow(
                table: item.table.name,
                primaryKey: item.key,
                serverRow: serverRow,
              ),
            );
          }
        case MergeAction.insert:
          sequence!.moveNext();
          final wrote = await _tryWrite(
            () => _insert(item.table, item.row, sequence.current, decision),
          );
          if (wrote) {
            outcomes[reference] = SyncRowOutcome.inserted;
            applied++;
            if (decision.revisionVerdict case final verdict?) {
              await noteAnomaly(
                item.table,
                item.key,
                verdict,
                RevisionSighting.arriving,
              );
            }
          } else {
            outcomes[reference] = SyncRowOutcome.invalid;
          }
        case MergeAction.update:
          sequence!.moveNext();
          final wrote = await _tryWrite(
            () => _update(item.table, item.row, sequence.current, decision),
          );
          if (wrote) {
            outcomes[reference] = SyncRowOutcome.updated;
            applied++;
            if (decision.revisionVerdict case final verdict?) {
              await noteAnomaly(
                item.table,
                item.key,
                verdict,
                RevisionSighting.arriving,
              );
            }
            final losing = decision.losingRow;
            if (losing != null &&
                await authorizer.canDisclose(table: item.table, row: losing)) {
              lost.add(
                LostRow(
                  table: item.table.name,
                  primaryKey: item.key,
                  serverRow: losing,
                ),
              );
            }
          } else {
            outcomes[reference] = SyncRowOutcome.invalid;
          }
      }
    }

    return PushResult(
      outcomes: outcomes,
      refusals: refusals,
      interlockRefusals: interlockRefusals,
      lost: lost,
      applied: applied,
      // Until task 11.221 this could be a higher number than the push's own
      // block: a `Project_Tags` insert re-stamped the linked tag's `server_seq`
      // above it so teammates past their cursor still received the tag (task
      // 11.3). Task 11.219 retired that table — a tag is created *inside* its
      // project, so it is reachable from the moment it has a `server_seq` and
      // was never below a reader's cursor while unreachable. Nothing widens a
      // project's reach for a tag any more, so there is no moment to re-stamp
      // at, and the push's own block is the highest sequence it produced. (The
      // same mechanism for *people* — `refreshServerSeqFor` — is live and is
      // called by `JoinService` when somebody joins.)
      highestServerSeq: block?.last,
    );
  }

  /// One page of the delta stream: rows with `server_seq >` [cursor].
  ///
  /// Ordered by `server_seq` globally rather than per table, so a page boundary
  /// never splits the stream in a way that could skip a row. Because
  /// `server_seq` assignment is commit-ordered (task 10.5), a reader that can
  /// see sequence *n* can see everything below it — which is what makes
  /// `> cursor` safe at all.
  Future<({SyncRows rows, int nextCursor, int remaining})> pull({
    required String projectId,
    required int cursor,
    required int batchSize,
  }) async {
    final limit = batchSize.clamp(1, maxSyncBatchSize);

    // Gather candidate rows per table above the cursor, then take the globally
    // lowest `limit` of them. Querying per table and merging is more work than
    // one UNION, but it keeps every statement simple and parameterised, and the
    // row counts here are bounded by `limit` per table.
    final candidates = <({String table, int seq, Map<String, Object?> row})>[];
    var total = 0;

    // Which global rows this project may see at all. Computed once and reused
    // for every global table below — see [ProjectReachability].
    final reachable = await ProjectReachability.resolve(
      session,
      projectId: projectId,
    );

    for (final table in syncTables) {
      final scope = table.projectScopeColumn;
      // Only the *column name* is interpolated, and it comes from `syncTables`
      // — a const list of literals, never from a request. Every value is bound.
      final String where;
      final List<Object?> parameters;
      if (scope != null) {
        where = 'server_seq > \$1 AND $scope = \$2';
        parameters = <Object?>[cursor, projectId];
      } else {
        // A global table: no `project_id` to filter on, so it is narrowed to
        // the ids this project actually references instead of being returned
        // wholesale. Restricting by id list rather than joining keeps the
        // statement simple and fully parameterised.
        //
        // A global table with no declared scope is a bug, not a row to skip:
        // skipping is what made a missing entry invisible before task 11.32.
        // `assertEveryGlobalTableDeclaresItsScope` is the build-time half;
        // this is the run-time one.
        final scopeG = table.globalScope;
        if (scopeG == null) {
          throw StateError(
            '${table.name} is global but declares no GlobalScope, so pull '
            'cannot narrow it to this project. Declare one in syncTables — '
            'skipping it would mean the table silently never syncs.',
          );
        }
        final ids = reachableIdsFor(scopeG, reachable);
        if (ids.isEmpty) continue;
        where = 'server_seq > \$1 AND ${scopeG.column} = ANY(\$2)';
        parameters = <Object?>[cursor, ids];
      }

      final countResult = await session.execute(
        'SELECT count(*) FROM ${quoted(table.name)} WHERE $where',
        parameters: parameters,
      );
      total += (countResult.first.first! as int);

      // Fetching `limit` per table is enough to find the globally lowest
      // `limit`: a row outside a table's own lowest `limit` cannot be inside
      // the global lowest `limit`.
      final result = await session.execute(
        'SELECT * FROM ${quoted(table.name)} WHERE $where '
        'ORDER BY server_seq LIMIT \$${parameters.length + 1}',
        parameters: [...parameters, limit],
      );
      for (final row in result) {
        final map = row.toColumnMap();
        final seq = map['server_seq'] as int?;
        if (seq == null) continue;
        candidates.add((table: table.name, seq: seq, row: map));
      }
    }

    candidates.sort((a, b) => a.seq.compareTo(b.seq));
    final page = candidates.take(limit).toList();

    final rows = <String, List<Map<String, Object?>>>{};
    for (final item in page) {
      // Server-only bookkeeping never crosses the wire: `server_seq` is the
      // server's own clock, `received_at` and `clock_skew_flag` are its
      // observations. A client that stored them would be depending on columns
      // that Phase 10's invariant 3 forbids it from requiring.
      final clean = Map<String, Object?>.of(item.row)
        ..remove('server_seq')
        ..remove('received_at')
        ..remove('clock_skew_flag');
      rows.putIfAbsent(item.table, () => []).add(clean);
    }

    final nextCursor = page.isEmpty ? cursor : page.last.seq;
    return (rows: rows, nextCursor: nextCursor, remaining: total - page.length);
  }

  /// Writes one row the **server itself** authored, allocating a `server_seq`
  /// so the next pull delivers it like any other row.
  ///
  /// ## Why this exists, and why it is not an authorization bypass
  ///
  /// Every other write on this server comes off the wire and is judged by
  /// [RowAuthorizer]. This one does not come off the wire. Its single caller is
  /// `JoinService.approve`, which builds a `Project_Memberships` row out of
  /// values the server owns — the `project_id` and `role` returned by the
  /// statement that consumed the invitation, and the `user_id` of the
  /// authenticated session. Nothing in the request shapes the row, so there is
  /// nothing for a row-level check to check.
  ///
  /// **The alternative was worse, which is the argument for this one.** The
  /// other way to create a membership on redemption is to let the joining
  /// device push it and teach [RowAuthorizer] to permit a membership insert
  /// backed by a redeemed invitation. That hands the attacker the pen: the
  /// pushed row would name its own role, its own user and its own project, and
  /// the authorizer would have to prove each one matched the invitation. Here
  /// the grant is transcribed from the invitation and the client never gets to
  /// propose one — so the push path can keep refusing **every** membership
  /// insert from a non-owner, with no exemption to get subtly wrong. Task 11.3
  /// enforces exactly that.
  ///
  /// Deliberately not a general "trusted write" seam. It takes one row, has one
  /// call site, and is named so that a second one is visible in a grep rather
  /// than hidden behind a permissive default.
  ///
  /// Must be called inside the caller's open transaction: the `server_seq`
  /// allocator's correctness is the row lock it holds until *that* transaction
  /// commits (task 10.5).
  Future<void> insertServerAuthoredRow(
    SyncTable table,
    Map<String, Object?> row,
  ) async {
    final block = await ServerSeq.reserve(PostgresSeqCounterStore(session), 1);
    // No skew flag: the row's timestamps are this server's own clock reading,
    // so there is no device clock to classify against it.
    await _insert(
      table,
      row,
      block.first,
      const MergeDecision(action: MergeAction.insert, skewFlag: null),
    );
  }

  /// **Clears a project's tombstone on the server's own authority** — the
  /// write behind an owner's *restore* (task 11.302). Returns whether a
  /// tombstone was there to clear.
  ///
  /// ## Why the server writes this row rather than a device pushing it
  ///
  /// A device *can* un-delete a project by pushing its own `Projects` row
  /// with `deleted_at` cleared and the revision bumped — that is the Projects
  /// list's UNDO, and it still works while the device holds the row. **The
  /// person who needs a restore is often not holding it**: a new phone, a
  /// reinstall, or the join screen of a device that never had the project.
  /// There is no row on that device to push, and inventing one from the
  /// listing's four fields would overwrite the project's real name, extent
  /// and settings with guesses. So the server edits the row it already has,
  /// changing the one column the delete changed and the merge clock beside
  /// it, and nothing else.
  ///
  /// ## What it writes, and why each part is needed
  ///
  /// - **`deleted_at = NULL`** — the delete being undone.
  /// - **`revision + 1`.** Every device that holds the project holds the
  ///   tombstone at the server's current revision — the deleting device sent
  ///   it, every other device pulled it — and [MergeResolver] reads revision
  ///   first. Without the bump the restored row would tie, fall to the
  ///   timestamp, and could lose to the tombstone already on the phone; with
  ///   it, it wins everywhere.
  /// - **`updated_at`, `last_modified_by`, `origin_device_id`** — the
  ///   server's clock and the restoring owner, so the row says who brought it
  ///   back (§4.17: an audit name is the actor's, never borrowed).
  /// - **A fresh `server_seq`.** Every member's cursor is past the tombstone;
  ///   a restore left at the tombstone's sequence number would sit below all
  ///   of them and reach nobody. This is [refreshServerSeqFor]'s problem in a
  ///   second place, and the same answer.
  ///
  /// Written through [_update], the one statement every pushed row goes
  /// through, so the columns stamped here are exactly the columns a push
  /// stamps. `WHERE deleted_at IS NOT NULL` is re-checked by reading the row
  /// first: a project already live is left alone, so a repeated restore never
  /// re-delivers the row to every device.
  ///
  /// Like [insertServerAuthoredRow], deliberately narrow — one table, one
  /// column's worth of change, named so a second server-authored update is
  /// visible in a grep. **The caller decides who may do this**; see
  /// `ProjectDirectoryService.isDeletedBy`. Must run inside the caller's open
  /// transaction, for the `server_seq` allocator's row lock (task 10.5).
  Future<bool> restoreTombstonedProject({
    required String projectId,
    required String restoredBy,
    required String? deviceId,
  }) async {
    final table = syncTablesByName[Tables.projects]!;
    final existing = await session.execute(
      'SELECT * FROM ${quoted(table.name)} '
      r'WHERE project_id = $1 AND deleted_at IS NOT NULL FOR UPDATE',
      parameters: [projectId],
    );
    if (existing.isEmpty) return false;
    final row = existing.first.toColumnMap();
    final block = await ServerSeq.reserve(PostgresSeqCounterStore(session), 1);
    await _update(
      table,
      {
        ...row,
        'deleted_at': null,
        'revision': (row['revision'] as int? ?? 0) + 1,
        'updated_at': _now.toIso8601String(),
        'last_modified_by': restoredBy,
        'origin_device_id': deviceId,
      },
      block.first,
      // The server's own clock, as for [insertServerAuthoredRow]: there is
      // no device clock here to classify.
      const MergeDecision(action: MergeAction.update, skewFlag: null),
    );
    return true;
  }

  /// Re-stamps the `server_seq` of every row of [table] matching [where], so
  /// rows already below a device's cursor re-enter its delta window. Returns
  /// the highest `server_seq` assigned, or null if nothing moved.
  ///
  /// ## The problem this solves, which is not obvious
  ///
  /// [ProjectReachability] narrows *which* global rows a pull may deliver; the
  /// `server_seq > cursor` window decides *when*. A global row can satisfy the
  /// first only after a device's cursor has already passed it — a colleague's
  /// `Users` row that has been on the server for a month and becomes reachable
  /// to a project the day they join it. Reachable, and never in anyone's window
  /// again.
  ///
  /// The consequence is worse than a missing row. The owner's next pull carries
  /// a `Project_Memberships` row naming somebody whose `Users` row is not
  /// there, and the **client's** foreign key refuses it — so one late-joining
  /// teammate stops that device syncing at all, not just that row.
  /// `project_reachability.dart` recorded this as "deliberately left for Phase
  /// 11" because Phase 10 had no way to widen a project's reach. Granting a
  /// membership is that way, so the operation that widens the reach is what
  /// puts the newly-reachable rows back in the stream.
  ///
  /// [column] is always a literal from a table descriptor, never request input;
  /// [value] is bound.
  ///
  /// Re-delivering to devices that already hold the row is harmless — the merge
  /// is idempotent and answers `lostToServer` on a re-offer. This is a one-time
  /// bump per grant, not the per-no-op bump `applyPush` deliberately avoids,
  /// which would redeliver an unchanged row forever.
  Future<int?> refreshServerSeqFor(
    SyncTable table,
    Map<String, Object?> where,
  ) async {
    final predicate = [
      for (var i = 0; i < where.length; i++)
        '${where.keys.elementAt(i)} = \$${i + 1}',
    ].join(' AND ');
    final keys = table.primaryKey.join(', ');
    final found = await session.execute(
      'SELECT $keys FROM ${quoted(table.name)} WHERE $predicate',
      parameters: where.values.toList(),
    );
    if (found.isEmpty) return null;

    final block = await ServerSeq.reserve(
      PostgresSeqCounterStore(session),
      found.length,
    );
    final sequence = block.values.iterator;
    for (final row in found) {
      sequence.moveNext();
      final keyPredicate = [
        for (var i = 0; i < table.primaryKey.length; i++)
          '${table.primaryKey[i]} = \$${i + 3}',
      ].join(' AND ');
      await session.execute(
        'UPDATE ${quoted(table.name)} '
        r'SET server_seq = $1, received_at = $2 '
        'WHERE $keyPredicate',
        parameters: [sequence.current, _now, ...row],
      );
    }
    return block.last;
  }

  /// Whether [row] — a `Deployments` row this push wants to store — would put
  /// two collars on one animal, or one collar on two animals, for any moment
  /// at all (the one-day allowance was withdrawn by task 11.263, design
  /// §6a). See `DeploymentInterlock`, which is the rule; this supplies the
  /// project's other rows and nothing else.
  ///
  /// **A bare day is read in this process's zone, which is not the writer's.**
  /// The interlock tells a date-only end from a timed one by whether it sits
  /// at local midnight; in the shipped container that is UTC midnight, so a
  /// day written on an Arizona phone reads here as 07:00 — a time. What that
  /// costs, in both directions, is written on `DeploymentInterlock`; the short
  /// form is that this check is exact for every overlap that does not turn on
  /// the bare-day reading, narrower than the device's for a same-day pair of
  /// bare days, and wider for a timed value that happens to land on UTC
  /// midnight. The rows already stored are not re-examined: this governs the
  /// row arriving, not the ones that arrived before it.
  ///
  /// **Scoped to `projectId` and to the two ends the candidate names**, so it
  /// reads only rows the caller can already pull in full — the same argument
  /// `_authorizeReferences` makes for its per-key checks. It is asked after
  /// the row has been authorized, so nothing here can answer a question the
  /// caller was not already entitled to ask.
  ///
  /// A row this build cannot parse as an interval is **not** refused here:
  /// `RowValidator` has already had it, and a second opinion from a weaker
  /// parse would be this project's oldest defect — a check that cannot tell
  /// its own failure from a pass.
  ///
  /// ## Checked against the store as this page leaves it, in page order
  ///
  /// [applyPush] decides every row before it writes any, so the store this
  /// reads is the store *before* the page. **A same-day swap is two rows in
  /// one page** — the old deployment closed at 14:32 and the new one opened
  /// at 14:32, written in one transaction on the device and pushed together
  /// — and against the store alone the new row meets the old one still open,
  /// an unbounded overlap, and is refused. That was the server's behaviour
  /// from the day it started enforcing the rule (task 11.243) until task
  /// 11.263 wrote the first test that pushed a swap: every synced swap left
  /// its new deployment held on the device.
  ///
  /// So [decidedSoFar] — the `Deployments` rows earlier in this page that
  /// this push has already decided to write — **replaces** the stored copy
  /// of any row it names (a tombstone among them frees its ends, as a stored
  /// tombstone would) and **adds** any row the store does not hold yet. The
  /// device wrote its page in `updated_at` order, which is the order it made
  /// each change true, and this reads it in that order: the same thing the
  /// device's own transaction saw when it ran the same rule row by row.
  /// **Order therefore matters**, and it is a property of the page rather
  /// than of the rule: a page that opened the new collar before closing the
  /// old one would be refused at the new collar, and no build of this app
  /// writes one. Asserted both ways in `deployment_interlock_test.dart`.
  Future<bool> _overlapsAStoredDeployment(
    String projectId,
    Map<String, Object?> row, {
    required Iterable<DeploymentInterval> decidedSoFar,
  }) async {
    final candidate = DeploymentInterlock.intervalFromRow(row);
    if (candidate == null) return false;
    final stored = await session.execute(
      'SELECT deployment_id, tag_id, individual_id, attached_date, '
      'removed_date, deleted_at, time_zone FROM ${quoted(Tables.deployments)} '
      r'WHERE project_id = $1 AND deleted_at IS NULL '
      r'AND (tag_id = $2 OR individual_id = $3)',
      parameters: [projectId, candidate.tagId, candidate.individualId],
    );
    final byId = <String, DeploymentInterval>{};
    for (final stored in stored) {
      final interval = DeploymentInterlock.intervalFromRow(
        stored.toColumnMap(),
      );
      if (interval != null) byId[interval.deploymentId] = interval;
    }
    for (final decided in decidedSoFar) {
      byId[decided.deploymentId] = decided;
    }
    return DeploymentInterlock.conflictFor(
          candidate,
          byId.values,
          // Task 11.331: a row that carries its zone is read in it, exactly
          // as the device reads it. Only a row with no zone (a build older
          // than v20) still has its ends read as instants, because this
          // process is never the zone that wrote it (task 11.266) — see
          // `DeploymentInterlock`'s class comment for what that gives up.
          zonelessEndsAreInstants: true,
        ) !=
        null;
  }

  Future<Map<String, Object?>?> _findRow(
    SyncTable table,
    Map<String, Object?> row,
  ) async {
    final predicate = [
      for (var i = 0; i < table.primaryKey.length; i++)
        '${table.primaryKey[i]} = \$${i + 1}',
    ].join(' AND ');
    final result = await session.execute(
      'SELECT * FROM ${quoted(table.name)} WHERE $predicate',
      parameters: [for (final column in table.primaryKey) row[column]],
    );
    return result.isEmpty ? null : result.first.toColumnMap();
  }

  Future<void> _insert(
    SyncTable table,
    Map<String, Object?> row,
    int serverSeq,
    MergeDecision decision,
  ) async {
    final spec = tableSpecsByName[table.name]!;
    final columns = [
      for (final column in spec.columns) column.name,
      'server_seq',
      'received_at',
      'clock_skew_flag',
    ];
    final values = <Object?>[
      for (final column in spec.columns) row[column.name],
      serverSeq,
      _now,
      decision.skewFlag?.db,
    ];
    final placeholders = [
      for (var i = 0; i < columns.length; i++) '\$${i + 1}',
    ].join(', ');
    await session.execute(
      'INSERT INTO ${quoted(table.name)} (${columns.join(', ')}) '
      'VALUES ($placeholders)',
      parameters: values,
    );
  }

  Future<void> _update(
    SyncTable table,
    Map<String, Object?> row,
    int serverSeq,
    MergeDecision decision,
  ) async {
    final spec = tableSpecsByName[table.name]!;
    final updatable = spec.columns
        .where((c) => !table.primaryKey.contains(c.name))
        .toList();
    final assignments = <String>[];
    final values = <Object?>[];
    var index = 1;
    for (final column in updatable) {
      assignments.add('${column.name} = \$${index++}');
      values.add(row[column.name]);
    }
    assignments.add('server_seq = \$${index++}');
    values.add(serverSeq);
    assignments.add('received_at = \$${index++}');
    values.add(_now);
    assignments.add('clock_skew_flag = \$${index++}');
    values.add(decision.skewFlag?.db);

    final predicate = [
      for (final column in table.primaryKey) '$column = \$${index++}',
    ].join(' AND ');
    values.addAll([for (final column in table.primaryKey) row[column]]);

    await session.execute(
      'UPDATE ${quoted(table.name)} SET ${assignments.join(', ')} '
      'WHERE $predicate',
      parameters: values,
    );
  }

  String? _rowKey(SyncTable table, Map<String, Object?> row) {
    final parts = <String>[];
    for (final column in table.primaryKey) {
      final value = row[column];
      if (value is! String || value.isEmpty) return null;
      parts.add(value);
    }
    return parts.join('/');
  }
}
