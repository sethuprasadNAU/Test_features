import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'project_exporter.dart';
import 'server_database_check.dart';
import 'sync_held_rows.dart';
import 'sync_row_receipts.dart';
import 'sync_state_store.dart';
import 'sync_transport.dart';

/// Result of a publish attempt.
class PublishReport {
  const PublishReport({
    required this.alreadyLinked,
    required this.rowsUploaded,
    this.refused = const [],
  });

  /// True if this project was already linked to the server — publish is
  /// idempotent, so this is a successful no-op, not an error.
  final bool alreadyLinked;

  /// Rows **offered** to the server, which is not the same as rows it kept —
  /// see [refused].
  final int rowsUploaded;

  /// Rows the server refused, now held locally by [SyncHeldRowStore]
  /// (task 10.28 / finding D-3).
  ///
  /// Publish had the same silent-loss shape the sync engine did, and slightly
  /// worse: it ignored per-row outcomes entirely, marked the project linked,
  /// set the push watermark to *now* — putting it past every refused row — and
  /// returned a count of rows "uploaded" that was really a count of rows sent.
  /// A refused observation was therefore dropped by the first action a user
  /// takes with a server, and the confirmation said "Published".
  final List<RefusedRow> refused;

  /// Whether every row of the project is accounted for on the server. False
  /// means the project is published but incomplete, and the difference must
  /// reach the user.
  bool get everythingReachedTheServer => refused.isEmpty;
}

/// Thrown when the project being published is not this signed-in user's to
/// put on the server, because its own `Projects` row names somebody else as
/// its owner.
///
/// **Why this is an exception and not a refused row.** Every other table in the
/// payload has a foreign key into `Projects`, so without that row nothing else
/// can land either; reporting it as one refusal among many would describe a
/// cascade as a detail. The server refuses the row for the same reason this
/// class declines to offer it — `Projects` is authorization state, and creating
/// one is a grant — so nothing is lost by saying so before anything is sent.
///
/// Reachable by restoring somebody else's `.zip` backup and then publishing it.
/// The publish confirmation already warns about exactly this (task 11.28); this
/// is the same statement made where it can be enforced rather than advised.
class PublishNotYoursToMake implements Exception {
  const PublishNotYoursToMake(this.projectId);

  final String projectId;

  @override
  String toString() =>
      'PublishNotYoursToMake: this project records somebody else as its '
      'owner, so it cannot be published from this account. Project: '
      '$projectId';
}

/// Turns a local, offline-created project into a server project (task 10.9).
///
/// ## What this reuses, and why nothing new was invented
///
/// The rows come from `ProjectExporter.collect` — the same generator a `.zip`
/// backup uses. There is no separate "publish payload" format: a project's
/// complete state is a project's complete state regardless of which transport
/// carries it, and inventing a second shape here would be a needless second
/// thing to keep in sync with the schema.
///
/// ## What publish sends, and the rule it is built from (task 11.43)
///
/// **A device offers the server every row of the project except the records
/// the server keeps for itself.** Who somebody is, and what they may do, are
/// the server's own records — it writes them from that person's authenticated
/// sign-in and from their own redemption of an invitation, and it will not
/// take another device's word for either.
///
/// The classification is `mayOfferRow` in the shared package, read off each
/// table's declared `MutationRule` and project scope rather than off a list of
/// table names, so a fourteenth table lands on one side or the other by
/// definition. See `offer_rules.dart` for the rule in full.
///
/// **Task 11.57 corrected its safety property**, which had read *"nothing
/// withheld here could ever have been accepted"* and was measured false: an
/// owner's write to a member's own membership row — a removal, or a role
/// change — names the member, was withheld by that flat rule, and is a write
/// the server accepts. The rule now waives the identity column when the caller
/// owns the project, which is why this method resolves ownership before
/// filtering.
///
/// **A backup is unaffected**, and that is why the filter lives here rather
/// than in the exporter. A `.zip` restored on a device that has never seen
/// these people must carry them or it cannot render who recorded what; a
/// server that authenticated them already knows.
///
/// **A colleague's bearing is still offered, refused and held.** Field records
/// are not what this withholds — see `offer_rules.dart`, and §4.17's accepted
/// cost, which is stated in terms of the user being told.
///
/// The wire calls are exactly `/sync/push` — the same route ordinary
/// incremental sync uses. **Project identity is the existing `project_id`
/// UUID; nothing server-side mints a new one.** Publishing is simply the
/// first push a project ever makes, and the server cannot tell "the first
/// push of a new project" apart from "an ordinary push" — which is precisely
/// what makes idempotency free rather than something to engineer: pushing the
/// same primary keys twice always upserts the same rows, never creates a
/// second project.
///
/// ## Chunking, and the one rule that makes it safe
///
/// `ProjectExporter.collect` returns the *entire* project in memory — for a
/// season of field data, too much for one HTTP request (10.7's chunking
/// rationale for pull applies identically here). This class slices it into
/// pushes of at most [batchSize] rows and sends them one request at a time.
///
/// **The slices must preserve `Tables.all`'s order, and for two reasons rather
/// than one.** Each push lands in its own Postgres transaction.
///
/// 1. **Foreign keys.** They are deferred *within* one transaction (task 10.5)
///    but not *across* separate ones, so a later table's rows reaching the
///    server before an earlier table's would fail against a dangling key.
/// 2. **Reachability (task 11.43, reopened).** The server refuses a row naming
///    a tag the project does not already reach, and across separate requests
///    the only thing that vouches for a tag is a **committed** `Project_Tags`
///    link — `RowAuthorizer._establishedThisPush` cannot reach into a request
///    that has already ended. This is the half that was missed: `Tables.all`
///    was FK-safe and offer-unsafe, so **every first publish of a project with
///    a tag had exactly one `Tag_Versions` row refused**, showed the person a
///    red banner saying this "is not a case the app expects", and cleared
///    itself minutes later on the next sync. `offer_order.dart` states the
///    constraint and `assertOfferOrderEstablishesReachBeforeItIsNeeded`
///    enforces it, so a fourteenth table cannot land in a bad position
///    silently.
///
/// Iterating `Tables.all` in order and only ever moving to the next table once
/// the current one is exhausted satisfies both: every batch's foreign keys and
/// every batch's tag references point at rows already committed in an earlier
/// batch (or the same one).
///
/// ## Failure and retry
///
/// An interrupted publish is safe to simply re-run from the beginning: nothing
/// is marked linked until every batch has succeeded, so a retry re-collects
/// and re-sends the whole project. Rows already on the server resolve to
/// `lost_to_server` (identical revision, so the incoming copy doesn't "win",
/// it just isn't re-applied) at no cost — the same tolerance every re-offer in
/// task 10.8 relies on. This does mean a retry
/// re-uploads from scratch rather than resuming a partial upload; see the
/// plan's Discovered Scope for why that is an accepted, not an unnoticed, cost.
class ProjectPublisher {
  const ProjectPublisher({
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

  /// The signed-in user this publish speaks for — `StoredSession.userId`, the
  /// server's own authoritative id, already adopted locally (task 10.75).
  ///
  /// **Required rather than defaulted**, on the discipline this codebase
  /// already applies to `SyncTable.insertIsAGrant` and `tableMutationRules`: a
  /// default is silence, and the silent value here would be "offer everything",
  /// which is the behaviour task 11.43 exists to end.
  ///
  /// It is the *session's* id and not the local profile's on purpose. The
  /// filter's whole job is to predict what the server will accept, so it has to
  /// compare against the id the server will compare against.
  final String userId;

  Future<PublishReport> publish(
    String projectId, {
    DateTime? now,
    int batchSize = defaultSyncBatchSize,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (await state.isProjectLinked(projectId)) {
      return const PublishReport(alreadyLinked: true, rowsUploaded: 0);
    }

    final at = now ?? DateTime.now().toUtc();
    final backup = await ProjectExporter.collect(db, projectId, now: at);
    await SyncHeldRowStore.ensureTable(db);
    await SyncRowReceiptStore.ensureTable(db);

    final payload = await _payloadFrom(backup, projectId);
    final total = payload.values.fold(0, (sum, rows) => sum + rows.length);
    var sent = 0;
    int? highestSeq;
    final refused = <RefusedRow>[];

    for (final table in Tables.all) {
      final rows = payload[table] ?? const <Map<String, Object?>>[];
      for (var offset = 0; offset < rows.length; offset += batchSize) {
        final slice = rows.sublist(
          offset,
          (offset + batchSize).clamp(0, rows.length),
        );
        final response = await transport.push(
          SyncPushRequest(
            projectId: projectId,
            deviceId: deviceId,
            rows: {table: slice},
          ),
        );
        // Task 11.58: the receipts this publish is about to write are
        // statements about the database that answered, so it becomes the
        // one this project records — and a project re-published after an
        // unlink onto a *different* database forgets the old one's receipts
        // and holds first, which would otherwise keep a row it refused here
        // off every later push. No notice: publishing is somebody's own act.
        await resetIfServerDatabaseChanged(
          db: db,
          state: state,
          projectId: projectId,
          reported: response.databaseId,
          noticeAt: null,
        );
        sent += slice.length;
        refused.addAll(
          await _accountForRows(
            projectId: projectId,
            table: table,
            offered: slice,
            response: response,
            at: at,
          ),
        );
        final seq = response.highestServerSeq;
        if (seq != null && (highestSeq == null || seq > highestSeq)) {
          highestSeq = seq;
        }
        onProgress?.call(sent, total);
      }
    }

    // Only now, after every batch has succeeded, is the project considered
    // linked. Marking it earlier would let a failure partway through leave
    // the project treated as published when the server doesn't yet have all
    // of it.
    //
    // **A refusal does not stop this.** The project *is* on the server, and
    // refusing to link it would leave the device unable to sync the rows that
    // were accepted, or to ever retry the ones that were not — strictly worse
    // for the held row than linking and reporting it.
    await state.markProjectLinked(projectId);
    if (highestSeq != null) {
      // This device already has every row it just uploaded, by definition —
      // there is nothing to pull below this point, so starting the cursor
      // here avoids immediately re-downloading the whole project it just
      // sent. (A row another device changed in the meantime still arrives
      // normally on the next ordinary sync, since the server would have
      // assigned it a higher sequence than anything published here.)
      await state.setCursor(projectId, highestSeq);
    }
    // Nothing to do about a push watermark: there isn't one any more
    // (task 10.33). Publish used to set it to the moment of the upload, which
    // put every refused row permanently behind the selection window, and task
    // 10.28 had to clamp it back to the earliest refusal to stop that. Per-row
    // receipts remove the whole problem — every row the server took got one in
    // `_accountForRows`, every row it refused deliberately did not, and the
    // refused row is therefore still in the pending set with no arithmetic
    // involved.
    await state.setLastSuccessAt(projectId, at);
    // Paired with the line above wherever it appears (task 11.116) — a first
    // publish that got through is a round that connected.
    await state.clearRememberedFailure(projectId);

    return PublishReport(
      alreadyLinked: false,
      rowsUploaded: sent,
      refused: refused,
    );
  }

  /// The rows this publish will offer, taken from the collected project by the
  /// one rule this class is built on: **a device offers the server every row of
  /// the project except the records the server keeps for itself.**
  ///
  /// Per-row rather than per-table, because the question is per-row: my own
  /// `Users` row goes up and my colleague's does not, and both are the same
  /// table. `mayOfferRow` answers it from the shared declarations — see
  /// `offer_rules.dart` — so a table added later is classified without anybody
  /// editing this method.
  ///
  /// A table with no [SyncTable] descriptor is passed through untouched: this
  /// build has nothing to say about it, and silence is not consent in the other
  /// direction either (task 10.46). The server will report on it, and
  /// [_accountForRows] already handles a table the server declines to report on.
  ///
  /// **The project's own `Projects` row is not optional.** If it is not this
  /// caller's to offer, publishing cannot succeed — every other row of the
  /// batch has a foreign key into it — so this throws by name rather than
  /// letting the upload fail partway with a constraint violation from the
  /// database. That is the case the publish confirmation already warns about
  /// (task 11.28): a project whose recorded creator is somebody else, which is
  /// what restoring another person's backup produces.
  Future<Map<String, List<Map<String, Object?>>>> _payloadFrom(
    ProjectBackup backup,
    String projectId,
  ) async {
    // **Whether this caller owns the project being published**, resolved from
    // the collected membership rows by the shared `resolveProjectOwners` —
    // never from a claim in the row being judged. It waives the identity-column
    // requirement on this project's own authorization rows, which is what lets
    // an owner's removal of a member leave the device at all; see
    // `namingRequirementsForOffering`. The creator fallback is the same one
    // that covers a first publish, where the batch's `Projects` row is not yet
    // stored anywhere.
    final projectRow = backup
        .rowsFor(Tables.projects)
        .where((row) => row['project_id'] == projectId)
        .firstOrNull;
    final owners = resolveProjectOwners(
      membershipRows: backup
          .rowsFor(Tables.projectMemberships)
          .where((row) => row['project_id'] == projectId),
      creatorUserId: projectRow?['owner_user_id'] as String?,
    );
    final callerOwnsTheProject = owners.contains(userId);
    // The waiver's other half: a row the server already holds. On a *first*
    // publish this set is empty, which is what keeps task 11.43's headline —
    // no refused record from a first publish — closed. See
    // `namingRequirementsForOffering`.
    final receipted = await SyncRowReceiptStore(db).rowKeysFor(projectId);

    final payload = <String, List<Map<String, Object?>>>{};
    for (final table in Tables.all) {
      final rows = backup.rowsFor(table);
      final syncTable = syncTablesByName[table];
      payload[table] = syncTable == null
          ? rows
          : [
              for (final row in rows)
                if (mayOfferRow(
                  syncTable,
                  row,
                  userId,
                  callerOwnsTheProject: callerOwnsTheProject,
                  serverAlreadyHoldsThisRow: receipted.contains(
                    '${syncTable.name}/${syncRowKey(syncTable, row)}',
                  ),
                ))
                  row,
            ];
    }

    final projects = payload[Tables.projects] ?? const [];
    if (!projects.any((row) => row['project_id'] == projectId)) {
      throw PublishNotYoursToMake(projectId);
    }
    return payload;
  }

  /// Accounts for every row one publish batch offered: a receipt for each row
  /// the server took, a durable hold for each row it would not.
  ///
  /// Deliberately the same rules as `SyncEngine._push`: an exhaustive
  /// classification of each outcome, silence about an offered row treated as a
  /// refusal rather than as success, the hold written before anything reports a
  /// result, and a receipt written **only** for a row the server accounted for.
  /// Publish and sync are two paths to the same wire call, so a guarantee that
  /// holds on only one of them is not a guarantee — and publish is the path a
  /// user reaches *first*, which is what made its version of this the more
  /// damaging one.
  Future<List<RefusedRow>> _accountForRows({
    required String projectId,
    required String table,
    required List<Map<String, Object?>> offered,
    required SyncPushResponse response,
    required DateTime at,
  }) async {
    final syncTable = syncTablesByName[table];
    // Not a sync table at all (a local-only table in `Tables.all`): the server
    // was never going to report on it and it is not part of the sync contract.
    if (syncTable == null) return const [];

    final store = SyncHeldRowStore(db);
    final receipts = SyncRowReceiptStore(db);
    final refused = <RefusedRow>[];

    for (final row in offered) {
      final rowKey = syncRowKey(syncTable, row);
      final outcome = response.outcomes['$table/$rowKey'];
      final reason = outcome == null
          ? HeldRowReason.unaccounted
          : HeldRowReason.forOutcome(outcome);
      // Task 11.124. Read straight off the response, which has already
      // dropped any detail that did not sit on an `invalid` outcome — so
      // nothing here has to remember that `unauthorized` stays opaque.
      final refusal = response.refusals['$table/$rowKey'];
      final interlockRule = response.interlockRefusals['$table/$rowKey'];
      final updatedAt = row['updated_at'];
      if (reason == null) {
        await receipts.record(
          projectId: projectId,
          tableName: table,
          rowKey: rowKey,
          ackedUpdatedAt: updatedAt is String ? updatedAt : null,
          at: at,
        );
        continue;
      }
      refused.add(
        RefusedRow(
          tableName: table,
          rowKey: rowKey,
          reason: reason,
          rowUpdatedAt: updatedAt is String ? updatedAt : null,
          issueCode: refusal?.code,
          issueField: refusal?.field,
          interlockRule: interlockRule,
        ),
      );
      await store.hold(
        projectId: projectId,
        tableName: table,
        rowKey: rowKey,
        reason: reason,
        rowUpdatedAt: updatedAt is String ? updatedAt : null,
        at: at,
        issueCode: refusal?.code,
        issueField: refusal?.field,
        interlockRule: interlockRule,
      );
    }
    return refused;
  }
}
