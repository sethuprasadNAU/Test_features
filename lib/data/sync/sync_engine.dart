import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../repositories/project_role_lookup.dart';
import 'pending_departure.dart';
import 'project_merger.dart';
import 'server_database_check.dart';
import 'sync_conflicts.dart';
import 'sync_dropped_rows.dart';
import 'sync_held_rows.dart';
import 'sync_row_receipts.dart';
import 'sync_state_store.dart';
import 'sync_transport.dart';
import 'unknown_columns.dart';

/// What one sync round did, for the status UI (task 10.12) and for tests.
class SyncRunReport {
  const SyncRunReport({
    required this.pushed,
    required this.applied,
    required this.pulled,
    required this.storedFromServer,
    required this.droppedOnArrival,
    required this.lostToServer,
    required this.refused,
    required this.heldCount,
    required this.droppedCount,
    required this.cursor,
    required this.pagesPulled,
    this.serverDatabaseChanged = false,
  });

  /// Rows offered to the server.
  final int pushed;

  /// Rows the server accepted (inserted or updated).
  final int applied;

  /// Rows the server delivered this round.
  ///
  /// **Delivered, not stored.** See [storedFromServer], and see
  /// [droppedOnArrival] for the difference between them — this number used to
  /// be the only one, and it was documented as "rows merged into the local
  /// database", which it never was.
  final int pulled;

  /// Rows the pull actually wrote — inserted or updated.
  final int storedFromServer;

  /// Rows the server delivered that this device **refused to store**, with the
  /// reason for each (task 11.41's second round of findings, 2026-08-27).
  ///
  /// A row is refused on arrival when this build's `RowValidator` does not
  /// recognise a value in it, or when it is scoped to a different project.
  /// Both are correct refusals. What was not correct is that the pull threw
  /// the merge report away, counted the row as pulled, receipted it, acked it,
  /// and reported a clean sync — so a colleague's bearing could vanish between
  /// the wire and the database with nothing said. That is finding D-3's asset
  /// reached from the inbound direction, and it had no instrument at all.
  ///
  /// The most likely way to reach it is a **build skew**: a phone on an older
  /// build sends an enum value the Mac's build has never heard of. Nothing is
  /// destroyed — the record is unharmed on the device that sent it — but this
  /// device does not have it and must not imply otherwise.
  ///
  /// **This round's tally only.** Every one of these is also durably recorded
  /// by [SyncDroppedRowStore] (task 11.44) — see [droppedCount] for the number
  /// that survives a restart.
  final List<RowIssue> droppedOnArrival;

  /// Rows whose local edit lost last-write-wins.
  ///
  /// Surfaced rather than swallowed because "my observation disappeared" is the
  /// bug that actually gets reported, and for a primary scientific record
  /// silent loss is the wrong default. Each one is also durably recorded by
  /// [SyncConflictStore] — this list is just this round's tally, for the
  /// status line; the reviewable list itself is read from the store, not from
  /// here.
  final List<String> lostToServer;

  /// Rows the server **refused** this round — offered, not applied, and not a
  /// last-write-wins loss either (task 10.28 / finding D-3).
  ///
  /// A separate list from [lostToServer] because the two are opposite
  /// situations that used to be handled by the same `continue`. A lost row *is
  /// on the server*, in a version this device now holds. A refused row is on
  /// **this device only**, and the server has said it will not take it — so it
  /// is irreplaceable field data that exists in exactly one place. Each one is
  /// also durably recorded by [SyncHeldRowStore]; this list is just this
  /// round's tally.
  final List<RefusedRow> refused;

  /// How many rows this device is holding for this project *in total* after
  /// this round — including refusals from earlier rounds that are still
  /// unresolved.
  ///
  /// [refused] alone is not enough for a status surface: a later round that
  /// refuses nothing new would show an empty list while the device is still
  /// holding a record the server never took. This is the number that decides
  /// whether the app is allowed to say everything is synced.
  final int heldCount;

  /// How many rows this device is missing for this project *in total* after
  /// this round — including drops from earlier rounds that have not since
  /// arrived. The inbound counterpart to [heldCount], for the same reason:
  /// [droppedOnArrival] alone would show empty on a later round that dropped
  /// nothing new, while the device is still missing a record from an earlier
  /// one (task 11.44).
  final int droppedCount;

  final int cursor;
  final int pagesPulled;

  /// **This round found the server's database had been replaced** — restored
  /// from a backup or rebuilt — and started this project's sync over from the
  /// beginning before completing (task 11.58). See
  /// `SyncEngine._confirmDatabase`.
  ///
  /// Everything else in this report describes the round that ran *after* the
  /// restart, which is the one whose numbers mean anything.
  final bool serverDatabaseChanged;

  /// This report, marked as having restarted over a replaced database.
  SyncRunReport _afterDatabaseChange() => SyncRunReport(
    pushed: pushed,
    applied: applied,
    pulled: pulled,
    storedFromServer: storedFromServer,
    droppedOnArrival: droppedOnArrival,
    lostToServer: lostToServer,
    refused: refused,
    heldCount: heldCount,
    droppedCount: droppedCount,
    cursor: cursor,
    pagesPulled: pagesPulled,
    serverDatabaseChanged: true,
  );

  bool get changedAnything => applied > 0 || storedFromServer > 0;

  /// Whether every local row is accounted for on the server.
  ///
  /// **The one thing a caller must consult before reporting success.** False
  /// means at least one record exists only on this device and the server has
  /// refused it.
  bool get everythingReachedTheServer => heldCount == 0;

  /// Whether everything the server has ever sent this device for this
  /// project is now on it.
  ///
  /// The inbound counterpart to [everythingReachedTheServer], reading the
  /// same kind of total: a round that drops nothing new must not read as
  /// clean while an earlier round's drop is still missing (task 11.44,
  /// mirroring how [heldCount] rather than this round's [refused] governs
  /// [everythingReachedTheServer]).
  bool get everythingArrived => droppedCount == 0;
}

/// Progress during a run, so a first sync shows movement rather than a spinner.
class SyncProgress {
  const SyncProgress({
    required this.pagesDone,
    required this.rowsRemaining,
    required this.phase,
  });

  final int pagesDone;
  final int rowsRemaining;
  final SyncPhase phase;
}

enum SyncPhase { pushing, pulling, done }

/// A local row this device offered that lost last-write-wins, carried from
/// [SyncEngine._push] to [SyncEngine._recordConflicts].
class _LostRow {
  const _LostRow({
    required this.table,
    required this.rowKey,
    required this.row,
  });

  final String table;
  final String rowKey;
  final Map<String, Object?> row;
}

/// One row a push put on the wire, indexed by the key the server will answer
/// with — so every outcome can be matched back to a row, and, just as
/// importantly, so **every offered row can be checked for an outcome**.
class _OfferedRow {
  const _OfferedRow({
    required this.table,
    required this.rowKey,
    required this.row,
    required this.updatedAt,
  });

  final String table;

  /// Primary key, `/`-joined for composite keys. `?` mirrors the server's own
  /// placeholder for a row it could not key.
  final String rowKey;

  final Map<String, Object?> row;
  final String? updatedAt;

  String get outcomeKey => '$table/$rowKey';
}

/// Everything one push produced, including the parts that are not good news.
class _PushOutcome {
  const _PushOutcome({
    required this.offered,
    required this.applied,
    required this.lost,
    required this.lostRows,
    required this.refused,
    required this.heldCount,
  });

  final int offered;
  final int applied;
  final List<String> lost;
  final List<_LostRow> lostRows;
  final List<RefusedRow> refused;
  final int heldCount;
}

/// Runs one sync round for one project.
///
/// ## What this deliberately does not do
///
/// **It does not touch `ProjectMerger`.** Inbound pages are handed to the
/// existing merger exactly as a restored backup is: same last-write-wins rule,
/// same user dedup, same validation, same all-or-nothing transaction. That
/// merger was already transport-agnostic — it takes an in-memory
/// `ProjectBackup`, not a file — so the server is just a third source of rows.
/// Reimplementing the inbound path here would create a second merge
/// implementation on the *client*, which is the same split-brain risk the
/// shared package exists to prevent, one layer down.
///
/// ## Failure behaviour
///
/// Every inbound page is applied inside the merger's own transaction, so a
/// failure mid-page rolls that page back completely. The local cursor advances
/// only *after* a page has committed, so a crash between receiving and
/// committing re-receives the page rather than skipping it. **A failed sync
/// leaves the local database exactly as it was**, which is the acceptance
/// criterion — and it is why the engine never writes anything of its own into
/// the synced tables.
class SyncEngine {
  const SyncEngine({
    required this.db,
    required this.transport,
    required this.state,
    required this.deviceId,
    required this.userId,
  });

  final Database db;
  final SyncTransport transport;
  final SyncStateStore state;
  final String deviceId;

  /// The signed-in user this device speaks for — `StoredSession.userId`, the
  /// server's own authoritative id, already adopted locally (task 10.75).
  ///
  /// Read by [_pendingClause] to answer the third of its questions: **is this
  /// row one this device may offer at all?** See `offer_rules.dart` for the
  /// rule, and [ProjectPublisher] for the other half of task 11.43.
  ///
  /// It is the session's id rather than the local profile's for the same reason
  /// the publisher's is: this filter predicts what the server will accept, so
  /// it must compare against the id the server compares against.
  final String userId;

  /// Runs push-then-pull for [projectId].
  ///
  /// Push first, deliberately: a field tech's own observations are the thing
  /// they care about getting off the device, so if only half a round completes
  /// it should be the outbound half. It also means the pull that follows
  /// already reflects this device's contribution.
  ///
  /// ## When the server's database has been replaced (task 11.58)
  ///
  /// The first response of a round that names a different database from the
  /// one this project last synced against has already reset what that
  /// database's numbering and contents made true — see [_confirmDatabase] —
  /// and the round is then **run once more from the top**, against a clean
  /// slate. That second round is the one reported, marked
  /// [SyncRunReport.serverDatabaseChanged].
  ///
  /// **Once more, not until it settles.** A database that changes again
  /// inside the restarted round is not a restore — a restore needs the server
  /// stopped, and a stopped server answers nothing — it is two databases
  /// answering at one address, which no number of retries fixes. That is
  /// reported as [SyncTransportException.serverDatabaseChanged], the failure
  /// task 11.54 left out of the classification because nothing could produce
  /// it.
  Future<SyncRunReport> run(
    String projectId, {
    void Function(SyncProgress)? onProgress,
    int batchSize = defaultSyncBatchSize,
  }) async {
    try {
      return await _round(
        projectId,
        onProgress: onProgress,
        batchSize: batchSize,
      );
    } on _ServerDatabaseChanged {
      try {
        final report = await _round(
          projectId,
          onProgress: onProgress,
          batchSize: batchSize,
        );
        return report._afterDatabaseChange();
      } on _ServerDatabaseChanged {
        throw const SyncTransportException(
          SyncTransportException.serverDatabaseChanged,
        );
      }
    }
  }

  /// One push-then-pull round — [run]'s body, split out so a round that meets
  /// a replaced database can be run again from the top.
  Future<SyncRunReport> _round(
    String projectId, {
    required void Function(SyncProgress)? onProgress,
    required int batchSize,
  }) async {
    // Both client-only stores this round reads and writes, ensured once here
    // rather than at each use: the push *selects* against them (a row is
    // pending unless a receipt matches it and no hold suppresses it), so they
    // have to exist before the first query, not merely before the first write.
    await SyncRowReceiptStore.ensureTable(db);
    await SyncHeldRowStore.ensureTable(db);
    await SyncDroppedRowStore.ensureTable(db);

    onProgress?.call(
      const SyncProgress(
        pagesDone: 0,
        rowsRemaining: 0,
        phase: SyncPhase.pushing,
      ),
    );

    final _PushOutcome pushOutcome;
    try {
      pushOutcome = await _push(projectId, batchSize: batchSize);
    } on SyncTransportException catch (error) {
      // **A project-level refusal on push is a question the pull can answer,
      // and until task 11.60 this threw the question away.**
      //
      // A `403` here means the server will not accept this device's rows for
      // this project. The commonest reason by far is that an owner removed
      // this person — and the *only* thing that can tell the device so is a
      // pull, which never ran because the push threw first. The device was
      // then left showing "the server is refusing access" forever, with a
      // delete control that did nothing, because the exemption that lets a
      // departed member delete their own copy reads the local membership rows
      // and locally they were still a member (task 11.57 measured it).
      //
      // So: ask. The server's closed-membership disclosure (§4.27) answers a
      // removed member with their own closed membership row and refuses
      // everything else, so this round ends with the device knowing what
      // happened. **The round still fails** — the push genuinely was refused,
      // and reporting otherwise would claim records reached a server they did
      // not. What changes is that `SyncController` classifies the refusal
      // against a database that now holds the truth, so it reads
      // `membershipEnded` rather than `accessRefused`.
      //
      // Narrow on purpose: only a `403`, only one extra request, and only a
      // read. A `401` is a dead session and is refused everywhere, so a pull
      // would add nothing.
      if (error.statusCode == 403) {
        try {
          await _pull(projectId, batchSize: batchSize, onProgress: onProgress);
        } catch (_) {
          // Deliberately catch-all. This pull is a question, not a result:
          // whatever it hit — another refusal, which is the ordinary case, or
          // a fault on this device — the honest report of *this round* is the
          // refusal the push already returned, and anything the pull did
          // manage to merge is committed before it threw. Letting a secondary
          // failure through here would replace a legible "access refused"
          // with "unexpected", which is the exact substitution task 11.54
          // existed to stop.
        }
      }
      rethrow;
    }

    onProgress?.call(
      SyncProgress(pagesDone: 0, rowsRemaining: 0, phase: SyncPhase.pulling),
    );

    final pullOutcome = await _pull(
      projectId,
      batchSize: batchSize,
      onProgress: onProgress,
    );

    // The winning row is guaranteed to be in this pull: a push can only lose
    // to a server write with a `server_seq` this device had not yet pulled
    // (otherwise it would already have been the local value, and would have
    // won on its own timestamp), so it necessarily arrives at or after this
    // device's own cursor. Reading it back from the *local* database, right
    // after the pull that must carry it, is simpler and more honest than
    // trying to correlate it against a specific page while pulling — a
    // completed sync round leaves it there or nowhere.
    if (pushOutcome.lostRows.isNotEmpty) {
      await _recordConflicts(projectId, pushOutcome.lostRows);
    }

    // After the pull, because the pull is one of the three things that can
    // settle a hold — and the only one this device could not otherwise notice.
    final heldCount = await _reconcileHolds(projectId);

    // Durable before anything reports a result, mirroring [_push]'s own rule
    // for holds: a row this device would not store must be remembered before
    // this round is allowed to say it succeeded (task 11.44).
    if (pullOutcome.droppedOnArrival.isNotEmpty) {
      await _recordDrops(projectId, pullOutcome.droppedOnArrival);
    }
    // Settles any drop from an earlier round whose record has since arrived —
    // the only way that happens is the record changing again wherever it was
    // written, which this pull would have just delivered.
    final droppedCount = await _reconcileDrops(projectId);

    // A round that moved data is still a round that connected, so this records
    // *connectivity*, not completeness. Whether everything actually reached the
    // server is [SyncRunReport.everythingReachedTheServer] / the held-row
    // count, which the status surfaces check ahead of this — a device holding a
    // refused row must never be presented as simply "Synced" (finding D-3).
    await state.setLastSuccessAt(projectId, DateTime.now().toUtc());
    // **Written down beside the success, in the same place, on purpose** (task
    // 11.116). A round that connected is the one piece of evidence that
    // outranks a remembered failure, and pairing the two writes here means
    // every caller of this engine — including a round for a project that is
    // not the open one — forgets the failure exactly when it stops being true.
    await state.clearRememberedFailure(projectId);
    onProgress?.call(
      SyncProgress(
        pagesDone: pullOutcome.pages,
        rowsRemaining: 0,
        phase: SyncPhase.done,
      ),
    );

    return SyncRunReport(
      pushed: pushOutcome.offered,
      applied: pushOutcome.applied,
      pulled: pullOutcome.merged,
      storedFromServer: pullOutcome.stored,
      droppedOnArrival: pullOutcome.droppedOnArrival,
      lostToServer: pushOutcome.lost,
      refused: pushOutcome.refused,
      heldCount: heldCount,
      droppedCount: droppedCount,
      cursor: pullOutcome.cursor,
      pagesPulled: pullOutcome.pages,
    );
  }

  /// Checks the database that just answered against the one this project
  /// last synced with (task 11.58) — [resetIfServerDatabaseChanged] says what
  /// that means and what it forgets — and abandons the round with
  /// [_ServerDatabaseChanged] when it had to forget anything, so [run] can
  /// start it again on a clean slate.
  Future<void> _confirmDatabase(String projectId, String? reported) async {
    final reset = await resetIfServerDatabaseChanged(
      db: db,
      state: state,
      projectId: projectId,
      reported: reported,
      noticeAt: DateTime.now().toUtc(),
    );
    if (reset) throw const _ServerDatabaseChanged();
  }

  /// Settles every hold that is no longer a true statement, and returns how
  /// many are left — task 11.41's answer to a red bar that never clears.
  ///
  /// ## The invariant
  ///
  /// **A hold says "this project is trying to send this row and the server
  /// will not take it."** It is therefore only meaningful while the row is
  /// still in this project's outbound set. Three ordinary things take a row
  /// out of that set, and until this method existed a hold survived all three:
  ///
  /// 1. **The server delivered the row on a pull.** This is the resolution
  ///    [HeldRowReason.notPermitted]'s own copy promises — *"it will arrive
  ///    from their device when they sync — you do not need to do anything"* —
  ///    and it did not happen. A hold was only ever cleared by a **successful
  ///    push**, while [_pendingClause]'s second join keeps a held row off
  ///    every subsequent push, so the one event that could clear it was the
  ///    one event that could no longer occur. The device ended up holding a
  ///    row it had *just pulled from the server*, reporting it as not on the
  ///    server, with no network traffic and no log line to explain either.
  ///    That is the observed symptom, and it is a false alarm rather than a
  ///    loss: the record is safe, and so is the server's copy.
  /// 2. **The row stopped being reachable from this project** — including
  ///    every hold created before [_globalReachClause] existed, which is
  ///    exactly the two rows this task was opened for. Those were never this
  ///    project's to send.
  /// 3. **The row was deleted from this device.** A hold on a row that is gone
  ///    can never be retried and can never be resolved; it is a warning about
  ///    nothing, and it warns forever.
  ///
  /// ## Why it is derived rather than three special cases
  ///
  /// It asks [_pendingClause] — *the push's own definition of what it will
  /// offer* — with the held-row join switched off, so the question is
  /// literally "would the next push offer this row, if it were not held?" A
  /// fourth reason a row leaves the outbound set is settled by this code
  /// without anybody adding a branch, which is the point.
  ///
  /// **A hold whose row key is [unkeyableRowKey] is left alone.** It names a
  /// row the *server* could not key, so it matches no local row and every
  /// query here would say "not offerable" — resolving it would be this
  /// method mistaking its own blindness for good news, which is the defect
  /// class this task exists to remove. It stays held and stays counted.
  Future<int> _reconcileHolds(String projectId) async {
    final store = SyncHeldRowStore(db);
    final open = await store.held(projectId);
    if (open.isEmpty) return 0;

    final byTable = <String, List<HeldRow>>{};
    for (final row in open) {
      if (row.rowKey == unkeyableRowKey) continue;
      byTable.putIfAbsent(row.tableName, () => []).add(row);
    }

    final now = DateTime.now().toUtc();
    for (final entry in byTable.entries) {
      final table = syncTablesByName[entry.key];
      // A table this build does not know about. Its holds are left standing:
      // this build cannot say whether the row is still outbound, and silence
      // is not consent (task 10.46).
      if (table == null) continue;
      final clause = _pendingClause(
        table,
        projectId,
        userId,
        suppressHeld: false,
      );
      final key = syncRowKeySql(table);
      final result = await db.rawQuery(
        'SELECT $key AS row_key FROM ${clause.from} WHERE ${clause.where}',
        clause.args,
      );
      final stillOutbound = {
        for (final row in result)
          if (row['row_key'] is String) row['row_key'] as String,
      };
      for (final held in entry.value) {
        if (stillOutbound.contains(held.rowKey)) continue;
        await store.resolve(
          projectId: projectId,
          tableName: held.tableName,
          rowKey: held.rowKey,
          at: now,
        );
      }
    }

    return store.heldCount(projectId);
  }

  /// Durably records every row this round's pull refused to store, before
  /// anything downstream reports a result (task 11.44, mirroring [_push]'s
  /// rule 3 for holds: write the refusal first, so a failure between writing
  /// it and finishing the round re-reports rather than forgets it).
  Future<void> _recordDrops(String projectId, List<RowIssue> issues) async {
    final store = SyncDroppedRowStore(db);
    final now = DateTime.now().toUtc();
    for (final issue in issues) {
      await store.record(projectId: projectId, issue: issue, at: now);
    }
  }

  /// Settles every drop whose row is now on this device, and returns how many
  /// are left — the inbound mirror of [_reconcileHolds].
  ///
  /// ## Why a dropped row needs its own reconciliation, differently shaped
  ///
  /// A held row is *this device's own data*: the next push automatically
  /// re-offers it, so [_reconcileHolds] can ask "would this still be
  /// offered?" A dropped row is the opposite — it was never written here, the
  /// pull that skipped it has already advanced the cursor past it, and this
  /// app has no "fetch everything again" action. **The only way this device
  /// ever ends up with it is the record changing again** wherever it was
  /// written, which arrives at a later `server_seq` the way any ordinary
  /// update does — and a pull that just delivered that update is exactly what
  /// runs before this method, every round.
  ///
  /// So the check here is simpler than [_reconcileHolds]'s: not "does the
  /// push's own predicate still select this row", but "does a row with this
  /// exact identity exist in the local table now". A dropped row's identity
  /// is a primary key, effectively unique by construction, so a match is
  /// overwhelmingly the record having arrived rather than coincidence.
  ///
  /// **A drop on a table this build does not recognise, or whose row key this
  /// build cannot parse back into a primary key, is left standing** — exactly
  /// [_reconcileHolds]'s own two exemptions, for the same reason: this build
  /// cannot ask the question, and silence is not consent (task 10.46).
  Future<int> _reconcileDrops(String projectId) async {
    final store = SyncDroppedRowStore(db);
    final open = await store.dropped(projectId);
    if (open.isEmpty) return 0;

    final now = DateTime.now().toUtc();
    for (final row in open) {
      final table = syncTablesByName[row.tableName];
      if (table == null) continue;
      final clause = syncRowKeyWhere(table, row.rowKey);
      if (clause == null) continue;
      final result = await db.query(
        table.name,
        where: clause.where,
        whereArgs: clause.args,
        limit: 1,
      );
      if (result.isEmpty) continue;
      await store.resolve(
        projectId: projectId,
        tableName: row.tableName,
        rowKey: row.rowKey,
        at: now,
      );
    }

    return store.droppedCount(projectId);
  }

  /// Offers this device's changed rows and accounts for **every one of them**.
  ///
  /// ## The refusal rule (task 10.28, finding D-3)
  ///
  /// The server answers a push with a per-row outcome. Three of those outcomes
  /// mean the row is on the server; two mean it is not, and before this method
  /// was rewritten those two were dropped on the floor by a `continue` while
  /// the watermark advanced past them — so the row was never re-offered, never
  /// counted as pending, and the app reported "Synced." For an irreplaceable
  /// field record that is silent data loss.
  ///
  /// The order of operations here is the fix, and it is load-bearing:
  ///
  /// 1. Every outcome is classified by [HeldRowReason.forOutcome], an
  ///    exhaustive switch, so no outcome can fall through as "fine".
  /// 2. Every *offered* row is checked for an outcome, and silence is treated
  ///    as a refusal ([HeldRowReason.unaccounted]) rather than as success.
  /// 3. Refusals are written to [SyncHeldRowStore] **before** anything records
  ///    progress. If that write throws, no receipt is written either and the
  ///    next push re-offers the row — the fail-safe direction.
  /// 4. A [SyncRowReceiptStore] receipt is written for each row the server
  ///    *did* account for, and only for those. A refused row gets none, so it
  ///    stays in the pending set by construction (task 10.33) — there is no
  ///    longer a watermark that could be advanced past it.
  ///
  /// ## Held, not retried forever
  ///
  /// The legitimate refusal is task 10.20's row-naming invariant declining a
  /// replica of a colleague's observation when that colleague is not on the
  /// project — a *permanent* refusal until somebody changes the project's
  /// membership. Re-offering it on every sync would be a pointless request
  /// every few minutes forever.
  ///
  /// So the row stays pending, and the *held-row record* is what keeps it off
  /// the wire in the meantime: it is counted, surfaced with an explanation, and
  /// excluded from selection only while it is unchanged. Edit the row and it
  /// goes back on the wire on the next sync; tap "Try again" and it goes back
  /// on the wire immediately; and until the server actually takes it, no
  /// surface in the app is allowed to claim it synced.
  ///
  /// Task 10.28 achieved that by clamping the push watermark to the earliest
  /// refusal for one round and relying on the held record from then on — the
  /// most that scheme could do, since a watermark pinned below a permanent
  /// refusal re-offers every row written after it forever. With per-row
  /// receipts the tension is simply gone: a refused row is pending until the
  /// server takes it, and nothing else is dragged back into the window with it.
  Future<_PushOutcome> _push(String projectId, {required int batchSize}) async {
    final heldStore = SyncHeldRowStore(db);
    final receipts = SyncRowReceiptStore(db);
    // Read once, and used for one thing: deciding whether an accepted row needs
    // its hold marked resolved. The *suppression* of held rows is done in SQL
    // by the selection itself (see [_pendingClause]), so this is not on the
    // path that keeps a refused row off the wire.
    final heldKeys = (await heldStore.heldSignatures(projectId)).keys.toSet();

    // **A project this device can see the signed-in person is not on offers
    // nothing** (task 11.237). Before the collection, not after: the refused-
    // row pile a non-member's push produces is the symptom, and not
    // generating it is the fix — a row the server was always going to refuse
    // must not be offered, held, counted and explained. Derived from the
    // membership rows on every round, so the round after their membership
    // arrives offers everything as usual. See [offersNothingFor] for the
    // exact question, which [pendingRowCount] asks too so "0 waiting" and
    // "nothing offered" cannot disagree.
    //
    // **One row is exempt, and it is the row that *causes* this standing**
    // (task 11.301). [offersNothingFor] reads this device's own membership
    // row, and a self-departure closes that row *before* trying to deliver
    // it — so by the time this push runs, the very row that needs to reach
    // the server has already made the gate above true. Left unexempted, a
    // self-departure could never be pushed by any means: not the ordinary
    // round `MembershipController.leaveProject` tries first, and not the
    // foreground flush `pending_departure.dart` exists to be the fallback
    // for. [_collectOwnDeparture] offers *only* the caller's own
    // not-yet-confirmed self-departure row — nothing else about a snapshot
    // project is offered, so task 11.237's guarantee holds for every other
    // row.
    if (await offersNothingFor(db, projectId, userId)) {
      final own = await _collectOwnDeparture(projectId, limit: batchSize);
      if (own.rowCount == 0) {
        return _PushOutcome(
          offered: 0,
          applied: 0,
          lost: const [],
          lostRows: const [],
          refused: const [],
          heldCount: await heldStore.heldCount(projectId),
        );
      }
      return _pushRows(
        projectId,
        rows: own.rows,
        offered: own.offered,
        heldKeys: heldKeys,
        heldStore: heldStore,
        receipts: receipts,
      );
    }

    final rows = await _collectChangedRows(projectId, limit: batchSize);
    if (rows.rowCount == 0) {
      return _PushOutcome(
        offered: 0,
        applied: 0,
        lost: const [],
        lostRows: const [],
        refused: const [],
        heldCount: await heldStore.heldCount(projectId),
      );
    }

    return _pushRows(
      projectId,
      rows: rows.rows,
      offered: rows.offered,
      heldKeys: heldKeys,
      heldStore: heldStore,
      receipts: receipts,
    );
  }

  /// Sends [rows] and processes the server's per-row outcomes — the shared
  /// second half of [_push], for both the ordinary collection and
  /// [_collectOwnDeparture]'s single-row exemption (task 11.301). [offered]
  /// must be exactly the rows [rows] carries, keyed the way
  /// [_collectChangedRows] keys them, so every outcome can be matched back.
  Future<_PushOutcome> _pushRows(
    String projectId, {
    required SyncRows rows,
    required Map<String, _OfferedRow> offered,
    required Set<String> heldKeys,
    required SyncHeldRowStore heldStore,
    required SyncRowReceiptStore receipts,
  }) async {
    final response = await transport.push(
      SyncPushRequest(projectId: projectId, deviceId: deviceId, rows: rows),
    );
    // Before a single outcome is read (task 11.58): every receipt and hold
    // written below is a statement about *this* database, so it must first be
    // the database this project's receipts already describe.
    await _confirmDatabase(projectId, response.databaseId);

    final lost = <String>[];
    final lostRows = <_LostRow>[];
    final refused = <RefusedRow>[];
    final accountedFor = <String>{};
    final refusedKeys = <String>{};

    for (final entry in response.outcomes.entries) {
      final offeredRow = offered[entry.key];
      final reason = HeldRowReason.forOutcome(entry.value);
      if (reason == null) {
        accountedFor.add(entry.key);
        if (entry.value == SyncRowOutcome.lostToServer) {
          lost.add(entry.key);
          if (offeredRow != null) {
            lostRows.add(
              _LostRow(
                table: offeredRow.table,
                rowKey: entry.key,
                row: offeredRow.row,
              ),
            );
          }
        }
        continue;
      }
      refusedKeys.add(entry.key);
      refused.add(
        RefusedRow(
          // An outcome key is `table/pk`. Splitting at the first `/` recovers
          // both halves for a key this device offered; for one it did not (the
          // server's `table/?` placeholder), it still yields a usable identity.
          tableName: offeredRow?.table ?? entry.key.split('/').first,
          rowKey:
              offeredRow?.rowKey ??
              entry.key.substring(entry.key.indexOf('/') + 1),
          reason: reason,
          rowUpdatedAt: offeredRow?.updatedAt,
          // Task 11.124. Taken from the response, which has already dropped
          // any detail that did not sit on an `invalid` outcome — so nothing
          // here has to remember that `unauthorized` stays opaque. A row the
          // server explained nothing about simply has no entry, and that
          // reaches task 11.122's honest default.
          issueCode: response.refusals[entry.key]?.code,
          issueField: response.refusals[entry.key]?.field,
          // Task 11.267's second channel — which shared rule about the
          // project's other rows refused this row, when one did.
          interlockRule: response.interlockRefusals[entry.key],
        ),
      );
    }

    // Silence is not consent. A row this device offered that the server said
    // nothing about is held, not assumed applied — reachable when the server
    // does not know a table this build pushes (version skew), which is exactly
    // the case where quietly dropping the row would be worst.
    for (final offeredRow in offered.values) {
      if (accountedFor.contains(offeredRow.outcomeKey)) continue;
      if (refusedKeys.contains(offeredRow.outcomeKey)) continue;
      refused.add(
        RefusedRow(
          tableName: offeredRow.table,
          rowKey: offeredRow.rowKey,
          reason: HeldRowReason.unaccounted,
          rowUpdatedAt: offeredRow.updatedAt,
        ),
      );
    }

    // Refusals first, and before anything reports a result or records progress.
    final now = DateTime.now().toUtc();
    for (final row in refused) {
      await heldStore.hold(
        projectId: projectId,
        tableName: row.tableName,
        rowKey: row.rowKey,
        reason: row.reason,
        rowUpdatedAt: row.rowUpdatedAt,
        at: now,
        issueCode: row.issueCode,
        issueField: row.issueField,
        interlockRule: row.interlockRule,
      );
    }

    // Only now, and only for rows the server accounted for. A receipt is the
    // *only* thing that takes a row out of the pending set, so a refused row —
    // or a row an interrupted round never got an answer about — is still
    // selected by the next push with no watermark arithmetic involved.
    for (final key in accountedFor) {
      final offeredRow = offered[key];
      if (offeredRow == null) continue;
      await receipts.record(
        projectId: projectId,
        tableName: offeredRow.table,
        rowKey: offeredRow.rowKey,
        ackedUpdatedAt: offeredRow.updatedAt,
        at: now,
      );
      // A row that was held and has now been accepted (or lost to a copy
      // already on the server) is no longer held — otherwise a resolved refusal
      // would warn forever, which trains people to ignore the warning.
      if (!heldKeys.contains(key)) continue;
      await heldStore.resolve(
        projectId: projectId,
        tableName: offeredRow.table,
        rowKey: offeredRow.rowKey,
        at: now,
      );
    }

    return _PushOutcome(
      offered: rows.values.fold(0, (sum, list) => sum + list.length),
      applied: response.applied,
      lost: lost,
      lostRows: lostRows,
      refused: refused,
      heldCount: await heldStore.heldCount(projectId),
    );
  }

  /// **The one row a "notAMember" snapshot is still entitled to push: this
  /// person's own already-closed membership row, when the server has not yet
  /// confirmed it** (task 11.301).
  ///
  /// [offersNothingFor] is right to silence a snapshot's — or a colleague's
  /// archive's — other rows (task 11.237). It was never meant to also silence
  /// the one row that *causes* that standing: a self-departure closes the
  /// caller's own membership row locally before it is ever offered, so by the
  /// time a push runs, [offersNothingFor] is already true of the very row that
  /// needs to reach the server. Restricted to `Project_Memberships`, and to
  /// exactly the rows [findUndeliveredDepartures] would itself select — the
  /// same definition [pending_departure.dart]'s foreground recovery uses — so
  /// this cannot offer anything beyond what a member in good standing would
  /// already have had offered.
  Future<({SyncRows rows, int rowCount, Map<String, _OfferedRow> offered})>
  _collectOwnDeparture(String projectId, {required int limit}) async {
    final pending = await findUndeliveredDepartures(
      db: db,
      state: state,
      userId: userId,
    );
    final mine = pending
        .where((departure) => departure.projectId == projectId)
        .take(limit)
        .toList();
    if (mine.isEmpty) {
      return (
        rows: const <String, List<Map<String, Object?>>>{},
        rowCount: 0,
        offered: const <String, _OfferedRow>{},
      );
    }

    final table = syncTablesByName[Tables.projectMemberships]!;
    final placeholders = mine.map((_) => '?').join(',');
    final result = await db.query(
      Tables.projectMemberships,
      where: 'project_id = ? AND membership_id IN ($placeholders)',
      whereArgs: [projectId, ...mine.map((departure) => departure.membershipId)],
    );
    final collected = [for (final row in result) Map<String, Object?>.of(row)];
    await UnknownColumnStore(db).attach(projectId, table, collected);

    final offered = <String, _OfferedRow>{};
    for (final row in collected) {
      final key = syncRowKey(table, row);
      final updatedAt = row['updated_at'];
      offered['${Tables.projectMemberships}/$key'] = _OfferedRow(
        table: Tables.projectMemberships,
        rowKey: key,
        row: row,
        updatedAt: updatedAt is String ? updatedAt : null,
      );
    }
    return (
      rows: {Tables.projectMemberships: collected},
      rowCount: collected.length,
      offered: offered,
    );
  }

  /// Reads back, for each row this device's push lost, what is now
  /// authoritative locally, and durably records the conflict.
  ///
  /// **A loss that changed nothing is not recorded.** The server answers
  /// `lost_to_server` whenever it did not apply an offered row, which includes
  /// the case where its stored copy is *identical* to the one offered — and
  /// re-offering an already-accepted row still happens: a round interrupted
  /// between the server's answer and the receipt, a re-publish, a device whose
  /// receipts were deliberately forgotten. Task 10.33 made those the exception
  /// rather than every round's routine, but not impossible. Recording them as
  /// "an edit you made was superseded" would fill the user's review list with
  /// entries where nothing was superseded, which is how a warning surface
  /// becomes noise and stops being read.
  Future<void> _recordConflicts(
    String projectId,
    List<_LostRow> lostRows,
  ) async {
    await SyncConflictStore.ensureTable(db);
    final store = SyncConflictStore(db);
    final now = DateTime.now().toUtc();
    for (final lost in lostRows) {
      final syncTable = syncTablesByName[lost.table];
      if (syncTable == null) continue;
      final where = syncTable.primaryKey.map((c) => '$c = ?').join(' AND ');
      final args = [for (final c in syncTable.primaryKey) lost.row[c]];
      final current = await db.query(
        lost.table,
        where: where,
        whereArgs: args,
        limit: 1,
      );
      final authoritative = current.isEmpty ? null : Map.of(current.first);
      if (_lostNothing(offered: lost.row, authoritative: authoritative)) {
        continue;
      }
      await store.record(
        projectId: projectId,
        tableName: lost.table,
        rowKey: lost.rowKey,
        localSnapshot: lost.row,
        incomingSnapshot: authoritative,
        detectedAtUtc: now,
      );
    }
  }

  /// Whether the row now authoritative locally is the same row this device
  /// offered — i.e. the "loss" discarded nothing.
  ///
  /// Compares on the *authoritative* row's columns only. The offered row can
  /// legitimately carry more of them: [_collectChangedRows] attaches values held
  /// for a newer schema minor (task 10.18), and those are not columns this build
  /// stores, so their presence is not a difference.
  bool _lostNothing({
    required Map<String, Object?> offered,
    required Map<String, Object?>? authoritative,
  }) {
    if (authoritative == null) return false;
    for (final entry in authoritative.entries) {
      if (offered[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<
    ({
      int merged,
      int stored,
      int cursor,
      int pages,
      List<RowIssue> droppedOnArrival,
    })
  >
  _pull(
    String projectId, {
    required int batchSize,
    void Function(SyncProgress)? onProgress,
  }) async {
    var cursor = await state.cursor(projectId);
    var merged = 0;
    var stored = 0;
    var pages = 0;
    final droppedOnArrival = <RowIssue>[];

    while (true) {
      final response = await transport.pull(
        SyncPullRequest(
          projectId: projectId,
          deviceId: deviceId,
          cursor: cursor,
          batchSize: batchSize,
        ),
      );
      // Before the page is merged or the cursor moves (task 11.58): the cursor
      // this page answers is a position in one database's numbering, and a
      // page answering it on behalf of a different database is an empty page
      // that means nothing.
      await _confirmDatabase(projectId, response.databaseId);
      // The cursor, not the row count, decides whether the stream is exhausted.
      //
      // `decodeRows` drops rows belonging to tables this build has never heard
      // of, so a page can legitimately arrive empty while the server is holding
      // plenty more behind it. Breaking on `rowCount == 0` would leave the
      // cursor parked forever at that page — sync wedged, no error, nothing to
      // notice. A genuinely exhausted stream is the case where the server hands
      // back the cursor it was given.
      if (response.nextCursor == cursor && response.rowCount == 0) break;

      if (response.rowCount > 0) {
        // Hand the page to the *unchanged* merger, wrapped in the same envelope
        // a restored backup uses. `preferIncoming` is deliberately NOT used:
        // last-write-wins is the rule, and a pulled row must not automatically
        // beat a newer local edit.
        //
        // `authenticatedServer` is what this path does differently from a file
        // import, and it is now one parameter rather than several that had to
        // agree. Task 10.55 is why the email dedup is off here: it is a rewrite
        // of `user_id` across the whole page, keyed on a string the server
        // assigned ids for anyway (see [IdentityTrust]). Task 10.73 folded the
        // rest of §4.19 in behind the same knob — a bounded clock, no authorship
        // from the payload, and the consent gate are all *off* on this path,
        // deliberately and for reasons [MergeOrigin] states, and the point of
        // one input is that a caller cannot get a different subset of them.
        final merged_ = await ProjectMerger(db).merge(
          ProjectBackup(
            manifest: BackupManifest(
              formatId: kBackupFormatId,
              formatVersion: kBackupFormatVersion,
              schemaVersion: response.envelope.schemaVersion,
              schemaMajor: response.envelope.schemaMajor,
              createdAtUtc: DateTime.now().toUtc(),
              projectId: projectId,
              projectName: '',
              rowCounts: rowCountsOf(response.rows),
            ),
            tables: response.rows,
          ),
          origin: MergeOrigin.authenticatedServer,
        );
        // **What the merge would not take.**
        //
        // Until 2026-08-27 this call discarded its own return value, and
        // `merged` below counted rows *the server sent* rather than rows this
        // device *stored*. A page whose rows the merger refused — a value this
        // build's `RowValidator` does not recognise, a row scoped to another
        // project — was dropped, counted as pulled, receipted and acked, and
        // the app reported a clean sync. For a colleague's bearing that is
        // silent loss of an irreplaceable field record arriving rather than
        // leaving, which is finding D-3's asset reached from the other
        // direction, and it had no instrument at all.
        //
        // Nothing is retried here and nothing is thrown: the row is refused
        // for a reason a retry cannot change, and wedging the cursor on it
        // would stop every later page too. What it must not do is go
        // unmentioned.
        droppedOnArrival.addAll(merged_.issues);
        stored += merged_.totalInserted + merged_.totalUpdated;
      }

      merged += response.rowCount;
      pages++;
      // Only now — the page is committed, so the cursor may move.
      final advanced = response.nextCursor != cursor;
      cursor = response.nextCursor;
      await _recordDeliveredReceipts(projectId, response.rows);
      await state.setCursor(projectId, cursor);
      // **Only acknowledge a cursor that moved** (task 11.60).
      //
      // An ack tells the server where this device has got to. Handing back a
      // position the server just handed *us* tells it nothing it does not
      // already hold, so the round trip was always pointless — and the loop
      // above already skips it for the empty-page case, by breaking before
      // this line.
      //
      // It stops being merely pointless on the one page where the server
      // returns rows *without* advancing the cursor: the closed-membership
      // disclosure (§4.27), which is how a removed member's device learns it
      // was removed. Ack is refused for a closed stint — correctly; it is a
      // write — so acking there would throw away a page this device had
      // already committed, and turn the one request that carries the news
      // into a failure.
      if (advanced) {
        await transport.ack(
          SyncAckRequest(
            projectId: projectId,
            deviceId: deviceId,
            cursor: cursor,
          ),
        );
      }

      onProgress?.call(
        SyncProgress(
          pagesDone: pages,
          rowsRemaining: response.remaining,
          phase: SyncPhase.pulling,
        ),
      );

      // A page that delivered rows without moving the cursor is terminal, and
      // is checked ahead of `hasMore` rather than trusting it. The delta
      // stream cannot produce one — every row in a page has `server_seq >
      // cursor`, so `nextCursor` is above it — but the disclosure page
      // deliberately does, and a page that both returned rows and left the
      // cursor where it was would otherwise be requested forever.
      if (!advanced || !response.hasMore) break;
    }
    return (
      merged: merged,
      stored: stored,
      cursor: cursor,
      pages: pages,
      droppedOnArrival: droppedOnArrival,
    );
  }

  /// Records a receipt for every row a committed page delivered.
  ///
  /// A row the server just handed this device *is* on the server, in exactly
  /// the version it sent, so there is nothing to push back. Without this, a
  /// device joining a project would pull a season of data and then immediately
  /// re-upload all of it — every pulled row would have no receipt, so the
  /// pending set would contain the entire project.
  ///
  /// **Recorded against the delivered `updated_at`, not against the row that
  /// ended up stored.** Last-write-wins can keep a newer local edit instead of
  /// the incoming copy, and in that case the local row's timestamp will not
  /// match this receipt — so it stays pending and goes up on the next push,
  /// which is exactly right. Writing a receipt for whatever the merger left
  /// behind would instead mark this device's own unsent edit as synced.
  Future<void> _recordDeliveredReceipts(
    String projectId,
    Map<String, List<Map<String, Object?>>> delivered,
  ) async {
    final receipts = SyncRowReceiptStore(db);
    final now = DateTime.now().toUtc();
    for (final entry in delivered.entries) {
      final table = syncTablesByName[entry.key];
      if (table == null) continue;
      for (final row in entry.value) {
        final updatedAt = row['updated_at'];
        await receipts.record(
          projectId: projectId,
          tableName: table.name,
          rowKey: syncRowKey(table, row),
          ackedUpdatedAt: updatedAt is String ? updatedAt : null,
          at: now,
        );
      }
    }
  }

  /// Selects local rows to push: the ones the server has not confirmed, in
  /// FK-safe table order, up to [limit].
  ///
  /// ## Why the selection is a join and not a timestamp comparison
  ///
  /// It used to be `updated_at >= watermark`, with one watermark per project
  /// set to the highest `updated_at` a push had *offered*. That is a per-table
  /// walk under a global comparison, and it strands rows two ways (see
  /// [SyncRowReceiptStore] for the full account): a row a batch limit never
  /// reached ends up below a watermark it was never offered against, and an
  /// imported replica carrying its sender's older clock (task 6.3) is below the
  /// watermark the moment it is written. Both silently drop a colleague's field
  /// record while the app reports "Synced" — finding D-3's asset, reached
  /// without any refusal being involved.
  ///
  /// So a row is offered when **no receipt matches its current `updated_at`**.
  /// That makes the pending set exact, and it makes the batch limit
  /// uninteresting: a row this round does not reach is unchanged in the pending
  /// set and is selected by the next round. Per-row progress, so a shared limit
  /// across tables cannot strand anything.
  ///
  /// **Over-pushing costs bandwidth; under-pushing loses an observation.** The
  /// join keeps that bias — anything unrecognised is pending — while removing
  /// the `>=` re-offer of the whole boundary timestamp, which was the old
  /// scheme's way of buying the same safety and which could, with enough rows
  /// sharing one timestamp, consume every batch forever and wedge the push.
  ///
  /// ## Held rows
  ///
  /// A row the server has already refused at *this exact* `updated_at` is left
  /// out (see [SyncHeldRowStore]): offering it again is a request guaranteed to
  /// fail. A held row whose timestamp has moved on — the user edited it — or
  /// whose hold has been released for a retry is offered normally. This is a
  /// second join rather than a post-filter so that held rows cannot consume the
  /// batch's slots; under the old post-filter a batch whose earliest rows were
  /// all held came back empty and stalled the push.
  ///
  /// ## Cost
  ///
  /// One full scan of each table's project rows per push, probing a unique
  /// index for each row's receipt, instead of a range scan from the watermark.
  /// For a season of field data that is milliseconds, and it buys a pending set
  /// that is correct rather than inferred — the trade the plan's own note asks
  /// for ("over-pushing is cheap, under-pushing loses an observation").
  Future<({SyncRows rows, int rowCount, Map<String, _OfferedRow> offered})>
  _collectChangedRows(String projectId, {required int limit}) async {
    final rows = <String, List<Map<String, Object?>>>{};
    final offered = <String, _OfferedRow>{};
    var count = 0;

    for (final table in syncTables) {
      if (count >= limit) break;
      final clause = _pendingClause(table, projectId, userId);
      final result = await db.rawQuery(
        'SELECT t.* FROM ${clause.from} WHERE ${clause.where} '
        'ORDER BY t.updated_at ASC LIMIT ?',
        [...clause.args, limit - count],
      );
      if (result.isEmpty) continue;

      final collected = [
        for (final row in result) Map<String, Object?>.of(row),
      ];
      final keys = [for (final row in collected) syncRowKey(table, row)];

      // Put back any values held for these rows by a newer schema minor, so a
      // row this build cannot fully read still leaves whole (task 10.18).
      await UnknownColumnStore(db).attach(projectId, table, collected);
      rows[table.name] = collected;
      count += collected.length;
      for (var i = 0; i < collected.length; i++) {
        final updatedAt = collected[i]['updated_at'];
        offered['${table.name}/${keys[i]}'] = _OfferedRow(
          table: table.name,
          rowKey: keys[i],
          row: collected[i],
          updatedAt: updatedAt is String ? updatedAt : null,
        );
      }
    }

    return (rows: rows, rowCount: count, offered: offered);
  }

  /// How many local rows the server has not confirmed — the "count of records
  /// pending upload" task 10.12's glanceable status wants, computed with
  /// [_pendingClause], the *same* predicate the push selects by, minus its
  /// batch limit (this is a count, not a page).
  ///
  /// **Held rows are excluded, not included.** "3 records waiting to sync" and
  /// "1 record the server refused" are different statements with different
  /// remedies — waiting means it will go on its own, refused means it will not
  /// — so counting a refused row in both would overstate the first and make the
  /// two numbers add up to more records than exist. A held row *released for a
  /// retry* counts as pending again, correctly: it is back on the wire.
  static Future<int> pendingRowCount(
    Database db,
    String projectId,
    String userId,
  ) async {
    await SyncRowReceiptStore.ensureTable(db);
    await SyncHeldRowStore.ensureTable(db);
    // Same gate as the push (task 11.237): a snapshot's rows are not waiting,
    // because nothing is going to offer them.
    if (await offersNothingFor(db, projectId, userId)) return 0;
    var total = 0;
    for (final table in syncTables) {
      final clause = _pendingClause(table, projectId, userId);
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${clause.from} WHERE ${clause.where}',
        clause.args,
      );
      total += (result.first['c'] as int?) ?? 0;
    }
    return total;
  }

  /// **Whether a push for [projectId] as [userId] offers nothing at all**
  /// (task 11.237): this device holds the project's own row and its
  /// membership rows, and none of them is [userId]'s — a read-only snapshot
  /// of a colleague's archive, or the copy of somebody who has since left.
  ///
  /// Read from the same rows, by the same rule, as every write gate in the
  /// app ([readProjectStanding]), so a project the Record screen refuses to
  /// write into is exactly the project the push declines to offer. Only
  /// [ProjectStanding.notAMember] withholds: a standing the device cannot
  /// resolve offers as before, because the server is the one to decide and a
  /// row withheld on a guess is a row nobody is told about.
  ///
  /// **Not stored, and it must not be**: the round after this person's
  /// membership row arrives by pull answers false and the push resumes with
  /// no re-import and nothing to clear.
  static Future<bool> offersNothingFor(
    Database db,
    String projectId,
    String userId,
  ) async =>
      (await readProjectStanding(
        db,
        projectId: projectId,
        userId: userId,
      )).isSnapshot;

  /// **Whether the next push for [projectId] would offer [row] of [table]**
  /// (task 11.289) — the push's own definition of "still needs to go to the
  /// server", asked about one row.
  ///
  /// This is the question `pending_project_change.dart` asks about a project's
  /// own row, and it is asked here rather than answered there so that there is
  /// exactly one definition of pending: [_pendingClause], with the held-row
  /// suppression on and the snapshot gate ([offersNothingFor]) applied, the
  /// same as [_collectChangedRows] and [pendingRowCount]. A copy of the rule
  /// written at the caller — `owner_user_id = ? AND last_modified_by = ?`, say
  /// — would be right today and silently wrong the next time
  /// `offer_rules.dart` changed, which is how task 11.57's ownership waiver
  /// went unoffered for a month.
  ///
  /// [row] needs only [table]'s primary-key columns.
  static Future<bool> wouldOffer(
    Database db, {
    required SyncTable table,
    required String projectId,
    required String userId,
    required Map<String, Object?> row,
  }) async {
    await SyncRowReceiptStore.ensureTable(db);
    await SyncHeldRowStore.ensureTable(db);
    if (await offersNothingFor(db, projectId, userId)) return false;
    final clause = _pendingClause(table, projectId, userId);
    final key = syncRowKeySql(table);
    final result = await db.rawQuery(
      'SELECT 1 FROM ${clause.from} WHERE ${clause.where} AND $key = ? LIMIT 1',
      [...clause.args, syncRowKey(table, row)],
    );
    return result.isNotEmpty;
  }

  /// How many rows this device is holding for [projectId] because the server
  /// refused them (task 10.28 / finding D-3) — the number that must stop any
  /// surface reporting a clean sync.
  ///
  /// Ensures the table first, so a device that has never had a row refused
  /// answers 0 rather than throwing on a missing table.
  static Future<int> heldRowCount(Database db, String projectId) async {
    await SyncHeldRowStore.ensureTable(db);
    return SyncHeldRowStore(db).heldCount(projectId);
  }

  /// How many rows this device is missing for [projectId] because it refused
  /// to store them when the server sent them (task 11.44) — the inbound
  /// mirror of [heldRowCount], read the same way and for the same reason:
  /// `SyncStatus` must be able to answer this the moment the app opens, not
  /// only right after a round that happened to drop something.
  static Future<int> droppedRowCount(Database db, String projectId) async {
    await SyncDroppedRowStore.ensureTable(db);
    return SyncDroppedRowStore(db).droppedCount(projectId);
  }

  /// Whether this device is holding any column values it cannot display for
  /// [projectId] (task 10.18) — a minor-version skew that produces no
  /// refusal and no error, so without this the only symptom is a field
  /// another device filled in silently not showing up. Project-scoped since
  /// task 10.76 gave [UnknownColumnStore] a `project_id` column: a value held
  /// through a different project no longer counts here, matching that it is
  /// no longer [attach]ed into this project's own pushes and exports either.
  static Future<bool> hasHeldUnknownColumns(
    Database db,
    String projectId,
  ) async {
    final rows = await db.rawQuery(
      'SELECT 1 FROM ${UnknownColumnStore.table} WHERE project_id = ? LIMIT 1',
      [projectId],
    );
    return rows.isNotEmpty;
  }
}

/// The definition of **"this row still needs to go to the server"**, as SQL
/// fragments over one table aliased `t`.
///
/// Written once and used by both the push selection and the pending count so
/// the two physically cannot drift. They were previously two separate
/// hand-written predicates that happened to agree, with a comment asking the
/// reader to keep them agreeing — and the number the status line shows must be
/// the number of rows the next push will actually offer, or "3 records waiting
/// to sync" becomes a figure nothing produces.
///
/// A row is pending when:
///
/// - **no receipt matches its current `updated_at`** — the server has never
///   confirmed this version of it. A null on *either* side counts as no match
///   rather than as two nulls agreeing: `updated_at` is `NOT NULL` in the
///   schema so this should be unreachable, and the point of spelling it out is
///   that if it ever becomes reachable the row is re-offered rather than
///   silently treated as synced (task 10.33); and
/// - **it is not currently held** — the server refused this exact version and
///   said so, so re-offering it would be a request guaranteed to fail. A hold
///   with a null `held_updated_at` is one the user released for a retry, and
///   does not suppress anything (task 10.28).
///
/// - **this project actually reaches it** — see [_globalReachClause]. A
///   project-scoped table answers this with its own scope column; a global one
///   (`Users`, `User_Emails`, `Tags`, `Tag_Versions`) answers it by
///   reachability, exactly as the server decides what to *deliver*.
///
/// - **this device may offer it at all** (task 11.43) — a record the *server*
///   keeps for itself, about who somebody is or what they may do, is not this
///   device's to send whoever it names. See `offer_rules.dart` for the rule and
///   for the property that makes withholding safe: nothing excluded by it could
///   ever have been accepted, so this can never suppress a row that would have
///   gone through.
///
/// ## Why the fourth condition had to be added (task 11.43)
///
/// Reachability answers *"is this global row part of this project?"* — the
/// question **pull** asks. It is the wrong question for a push, and the two had
/// been conflated: a teammate's `Users` row *is* reachable from a project they
/// are a member of, so this clause offered it, and the server refused it every
/// single time. `Users` is governed by [MutationRule.author], the clause that
/// vouches for a foreign name does not apply to it, and the refusal therefore
/// had no version of "later" in which it would clear. On the sync path it
/// looked survivable only because pulling the teammate's own copy eventually
/// wrote a receipt; on the **publish** path nothing pulls first, so a first
/// publish of a project two people had touched produced a stuck record every
/// time. That is what was found on real hardware.
///
/// **The two paths share this fix and had to.** Fixing only the publisher would
/// have left the very next sync re-offering the same rows and holding them
/// again. `ProjectPublisher` cannot use this clause — it re-collects the whole
/// project rather than selecting what is unconfirmed — so it applies the same
/// `mayOfferRow` to the rows it collected. One rule, two renderings, exactly as
/// [_globalReachClause] and `ProjectReachability` are.
///
/// **Existing holds clear themselves.** [_reconcileHolds] asks this very
/// predicate whether a held row would still be offered; narrowing it here means
/// every `Users`, `User_Emails` and `Project_Memberships` row already stuck on
/// somebody's device is resolved by the next sync, with no migration and no
/// button to press.
/// ## Why the third condition had to be added (task 11.41)
///
/// The sentence that used to be here said global tables *"are not filtered by
/// [a project]: pushing every unconfirmed row of them is correct, because they
/// are reachable from this project's data by design"* — and the premise is
/// false. Nothing made it true. A device holds one `Users` table and one
/// `Tags` table for **every** project it has ever had, including local
/// projects that were never published, so "reachable from this project's data"
/// described a subset and the code offered the whole thing.
///
/// Measured, not argued: a device with a second local project offered that
/// project's tag, and its owner's `Users` row, to the first project's server.
/// The server refuses what a project does not reach — that is the read filter
/// `ProjectReachability` applies and the write check `RowAuthorizer` applies —
/// so each of those rows came back refused, was recorded in
/// [SyncHeldRowStore], and was thereafter suppressed from every future push by
/// the second join above. The result on a real Mac was a permanent red bar
/// reading *"2 records aren't on the server"* naming two tables, no further
/// network traffic to explain it, and nothing anybody could do about it.
///
/// **The fix is about what may enter the queue, not about those two tables.**
/// The narrowing is derived from `reachColumnsFor` — the same declaration the
/// server narrows pull by — so a fifth global table inherits it rather than
/// needing somebody to remember. Receipts and holds stay keyed by project,
/// which is still right: the same `Users` row genuinely can be accepted by one
/// project and refused by another.
///
/// **What this does not do is drop anybody's data.** A row this project does
/// not reach is not a row this project was ever entitled to send; it belongs
/// to whichever project does reach it, and goes up when that project syncs. A
/// row that has no such project has nowhere on the server to be, which is true
/// of every row of an unpublished project and is not a change.
({String from, String where, List<Object?> args}) _pendingClause(
  SyncTable table,
  String projectId,
  String userId, {
  bool suppressHeld = true,
}) {
  final key = syncRowKeySql(table);
  // Argument order follows the order the `?`s appear in the assembled
  // statement — both joins before the WHERE clause.
  final args = <Object?>[projectId, table.name];
  var from =
      '${table.name} t '
      'LEFT JOIN ${SyncRowReceiptStore.table} r '
      'ON r.project_id = ? AND r.table_name = ? AND r.row_key = $key ';
  if (suppressHeld) {
    from +=
        'LEFT JOIN ${SyncHeldRowStore.table} h '
        'ON h.project_id = ? AND h.table_name = ? AND h.row_key = $key '
        'AND h.resolved_at_utc IS NULL';
    args.addAll([projectId, table.name]);
  }

  final where = <String>[
    '(r.row_key IS NULL OR r.acked_updated_at IS NULL '
        'OR t.updated_at IS NULL OR r.acked_updated_at <> t.updated_at)',
    if (suppressHeld)
      '(h.row_key IS NULL OR h.held_updated_at IS NULL '
          'OR h.held_updated_at IS NOT t.updated_at)',
  ];
  final scope = table.projectScopeColumn;
  if (scope != null) {
    where.add('t.$scope = ?');
    args.add(projectId);
  } else {
    final reach = _globalReachClause(table, projectId);
    where.add(reach.where);
    args.addAll(reach.args);
  }

  // Task 11.43, widened by task 11.57. Empty for every table whose rows are
  // this device's to send — which is most of them — so this adds nothing to the
  // common query. The columns come from the shared declarations, not from a
  // list here, so a fourteenth table is governed without anybody editing this
  // function.
  //
  // **The `EXISTS` is the ownership waiver**, and it is the reason an owner
  // ending a member's stint now leaves the device at all: before task 11.57
  // that row named the *member* in `user_id`, failed the flat clause, and was
  // withheld — silently, and not even counted as waiting, because this is the
  // predicate the pending count is computed from. See
  // `namingRequirementsForOffering` for the measurement and the three things
  // that bound the waiver; the sub-select is `isOpenOwnerMembership` written in
  // SQL, and `owner_membership_role` below is that predicate's `role` value.
  for (final requirement in namingRequirementsForOffering(table)) {
    final column = requirement.column;
    if (!requirement.waivedByOwnership) {
      where.add('(t.$column IS NULL OR t.$column = ?)');
      args.add(userId);
      continue;
    }
    // Only ever set for a project-scoped table; see the requirement's own doc.
    final scope = table.projectScopeColumn!;
    // `r.row_key IS NOT NULL` is the waiver's third bound written here: the
    // receipt join above is already in this query, and a receipt exists exactly
    // when the server has held this row — so the waiver applies to an *update*
    // and never to an insert, which the server refuses unconditionally.
    where.add(
      '(t.$column IS NULL OR t.$column = ? OR (r.row_key IS NOT NULL AND EXISTS ('
      'SELECT 1 FROM ${Tables.projectMemberships} m '
      'WHERE m.project_id = t.$scope AND m.user_id = ? AND m.role = ? '
      'AND m.end_date IS NULL AND m.deleted_at IS NULL)))',
    );
    args.addAll([userId, userId, ownerMembershipRole]);
  }

  return (from: from, where: where.join(' AND '), args: args);
}

/// "Does [projectId] reach this global row?", as a `WHERE` fragment over a
/// global table aliased `t` — the client's half of the rule
/// `ProjectReachability` applies on the server.
///
/// The id sets are not materialised in Dart. Each is a `UNION` of one
/// `SELECT <column> FROM <project-scoped table> WHERE <scope> = ?` per column
/// that `reachColumnsFor` says feeds this table's [GlobalScope.reach] — so the
/// question is asked of the same declarations on both sides of the wire, and a
/// column added to `userColumns` or `tagColumns` is picked up by both without
/// anybody editing a query.
///
/// **Fails closed.** A global table with no [SyncTable.globalScope], or a reach
/// set no column feeds, yields `0 = 1` — nothing offered — rather than the
/// permissive "no filter" that produced the finding. That direction is the
/// opposite of this file's usual bias (*"over-pushing is cheap, under-pushing
/// loses an observation"*), and it is right here for one reason: a global row
/// is never anybody's only copy of a field record. `Users` and `Tags` are
/// vocabulary that a project's own scoped rows point at; the observation
/// itself is project-scoped and unaffected by any of this.
/// `assertEveryGlobalTableDeclaresItsScope` makes the missing-declaration case
/// a failing test rather than something to discover in the field.
({String where, List<Object?> args}) _globalReachClause(
  SyncTable table,
  String projectId,
) {
  final scope = table.globalScope;
  if (scope == null) return (where: '0 = 1', args: const []);

  final selects = <String>[];
  final args = <Object?>[];
  for (final other in syncTables) {
    final otherScope = other.projectScopeColumn;
    if (otherScope == null) continue;
    for (final column in reachColumnsFor(other, scope.reach)) {
      selects.add(
        'SELECT $column FROM ${other.name} '
        'WHERE $otherScope = ? AND $column IS NOT NULL',
      );
      args.add(projectId);
    }
  }
  if (selects.isEmpty) return (where: '0 = 1', args: const []);

  return (
    where: 't.${scope.column} IN (${selects.join(' UNION ')})',
    args: args,
  );
}

/// Thrown by [SyncEngine._confirmDatabase] after it has reset a project for a
/// replaced server database, to abandon the round in progress so
/// [SyncEngine.run] can start it again. **Never escapes the engine** — `run`
/// either restarts or turns a second one into
/// [SyncTransportException.serverDatabaseChanged].
class _ServerDatabaseChanged implements Exception {
  const _ServerDatabaseChanged();
}
