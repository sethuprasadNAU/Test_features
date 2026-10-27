import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../sync/sync_row_receipts.dart';

/// Schema v15 (task 11.225): re-points a "no signal" entry's tag ids after
/// schema v14's fork (task 11.224) split a collar two projects held.
///
/// ## What v14's fork deliberately left broken, and why this reads it anyway
///
/// `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md` §3.3(3) told the fork to leave
/// `Non_Detections.tag_ids_listened_for` alone: it is one of
/// [unvalidatedIdListColumns], sealed by
/// [assertSealedColumnsFeedNoReachability] so that nothing decides which rows
/// a pull, an export or an authorization check reaches on the strength of an
/// id stored there. Re-pointing it inside the fork would have been the first
/// code in this repository to treat the list as a relationship — exactly the
/// day that assertion exists to notice.
///
/// **This migration is that code, on purpose, for a narrower reason than
/// reachability.** In a project that received a *copy* of a forked collar, a
/// "no signal" entry that named the original id now names a row that belongs
/// to a *different* project — the Log renders it as "no tags recorded", the
/// map's no-signal marker has no colour for it, the CSV export writes the
/// bare id where the frequency and name belong, and the per-collar filter
/// misses it. Security Model §5.9(b) recorded this as an accepted
/// consequence of the fork; Michael decided on 2026-09-10 to fix it instead,
/// which is what this migration does.
///
/// ## The obligation this reader owes, and how it is discharged
///
/// [assertSealedColumnsFeedNoReachability] cannot see this reader: it checks
/// `SyncTable.userColumns` / `tagColumns` / `emailColumns`, the three
/// declared sets `ProjectReachability`, `ProjectExporter` and
/// `RowAuthorizer` walk, and this file declares none of them —
/// `test/data/non_detection_relink_migration_test.dart` asserts that the
/// assertion still returns normally with this migration in the tree, so a
/// later change that tries to fold the column into one of those sets is
/// still caught exactly as before.
///
/// What makes it safe to read the column as a relationship here anyway is
/// structural, not a promise: **every lookup below is filtered to the row's
/// own `project_id`.** Checking whether a listened-for id still resolves
/// asks "does *this* project hold a `Tags` row with this id" — never any
/// other project's. Finding a replacement asks "does *this* project hold a
/// `Tags` row with the same `lineage_id`" — never "which projects hold a tag
/// with this lineage", which is the query that would actually leak. Nothing
/// here can answer a question about what another project holds, which is the
/// whole of what a reachability computation would need it to do. The same
/// test asserts both queries stay scoped this way by reading this file's own
/// source.
///
/// ## Why a separate migration rather than folded into v14's
///
/// Michael's phone has already run v14's fork — this is a repair applied
/// afterwards, on a device that already made its choice about which project
/// keeps which tag id. A fresh install runs v14 and this in the same launch
/// instead, and the two devices have to reach the same answer despite
/// arriving by different paths, which is exactly what deriving from
/// `lineage_id` rather than from the fork's own bookkeeping buys.
///
/// ## Derived from lineage, not from what the fork did
///
/// So this does not repair "what the fork just changed", which is knowable
/// on one path and not the other. Instead, for
/// every `Non_Detections` row and every id it lists: if the id no longer
/// names a `Tags` row in that row's own project, and that project holds a
/// `Tags` row with the same `lineage_id`, the id is rewritten to that row's.
/// An id with no same-lineage row in that project is left exactly as it is,
/// and counted — it should not happen, and if it does, the count is the
/// finding.
///
/// This is **idempotent** by construction: after one pass every listened-for
/// id already resolves inside its own project, so a second pass finds
/// nothing left to rewrite.
///
/// ## `updated_at`, measured rather than assumed
///
/// Task 11.224 left re-pointed bearings' `updated_at` alone, reasoning that
/// the server has refused a second project's claim on a tag since task 11.3,
/// so a bearing this fork re-points was never accepted under the shared id
/// and has no receipt to leave stale.
///
/// **That argument does not carry here.** `Non_Detections.tag_ids_listened_for`
/// is unvalidated and feeds nothing — that is why it is sealed — so nothing
/// ever stopped one project's push of it from being accepted while the same
/// collar's *bearings* were refused. `SyncEngine`'s pending selection
/// (`_pendingClause` in `lib/data/sync/sync_engine.dart`) says exactly what
/// that means for a row this migration edits in place: a row counts as
/// pending only when [SyncRowReceiptStore]'s `acked_updated_at` does **not**
/// match the row's current `updated_at` — `r.acked_updated_at <> t.updated_at`,
/// read directly off that clause. A row the server has already accepted
/// keeps a receipt whose `acked_updated_at` equals its `updated_at`, and
/// rewriting the data without moving `updated_at` would leave that match
/// intact — the correction would satisfy "already synced" and never be
/// offered again. So this measures it, per row, rather than assuming an
/// answer: it checks whether [SyncRowReceiptStore]'s table holds a receipt
/// for the exact row being rewritten, and bumps `updated_at` (and
/// `revision`, the pair every ordinary edit in this codebase moves together —
/// see `BaseRepository.updateById`) exactly when one is found. A row with no
/// receipt is already pending regardless of what its `updated_at` says, so
/// leaving it alone costs nothing.
abstract final class NonDetectionRelinkMigration {
  // ignore: avoid_print
  static void _print(String line) => print(line);

  /// Applies schema v15. Called from the migration list; not for direct use.
  ///
  /// [log] follows [TagScopeMigration.apply]'s reasoning exactly: `print` by
  /// default so a census is visible in a device log, in CI, and to a `Zone` a
  /// test installs. [fromVersion] is the schema the database is coming from —
  /// a fresh create (`0`) prints nothing, since there is nothing to repair;
  /// an upgrade always prints, including one that finds nothing to rewrite,
  /// because "nothing to do" is a result and an absent line is not.
  static Future<void> apply(
    DatabaseExecutor db,
    int fromVersion, {
    void Function(String line) log = _print,
  }) async {
    final report = await relink(db);
    if (fromVersion > 0) {
      for (final line in report.report()) {
        log(line);
      }
    }
  }

  /// Re-points every `Non_Detections` row's listened-for ids that no longer
  /// resolve in their own project, to that project's same-lineage `Tags`
  /// row where one exists. Public and separately callable, the way
  /// [TagScopeMigration.fork] is: a number a migration reports only into a
  /// log is a number no test can assert.
  static Future<NonDetectionRelinkReport> relink(DatabaseExecutor db) async {
    final column = unvalidatedIdListColumns[Tables.nonDetections];
    if (column == null) {
      throw StateError(
        'unvalidatedIdListColumns no longer names ${Tables.nonDetections}. '
        'This migration exists to repair exactly that column by exactly '
        'this name; if the registration moved, update this reader rather '
        'than let it silently repair nothing.',
      );
    }

    final receiptTableExists = (await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [SyncRowReceiptStore.table],
    )).isNotEmpty;

    var rowsExamined = 0;
    var idsRewritten = 0;
    var idsLeftAlone = 0;
    var rowsUpdatedAtBumped = 0;

    final rows = await db.query(
      Tables.nonDetections,
      columns: [
        'non_detection_id',
        'project_id',
        column,
        'updated_at',
        'revision',
      ],
    );

    for (final row in rows) {
      rowsExamined++;
      final nonDetectionId = row['non_detection_id']! as String;
      final projectId = row['project_id']! as String;
      final ids = DbCodec.decodeStringList(row[column]);
      if (ids.isEmpty) continue;

      var changed = false;
      final rewritten = <String>[];
      for (final id in ids) {
        // Does this id still name a `Tags` row in *this* project? Scoped to
        // `project_id` on purpose — see the class comment.
        final local = await db.query(
          Tables.tags,
          columns: ['tag_id'],
          where: 'tag_id = ? AND project_id = ?',
          whereArgs: [id, projectId],
          limit: 1,
        );
        if (local.isNotEmpty) {
          rewritten.add(id);
          continue;
        }

        // It does not. Find the lineage the id names (wherever the row
        // actually is), then this project's own copy of that lineage, if it
        // has one. Neither query asks "which projects hold this lineage" —
        // only "does *this* project" — see the class comment.
        final named = await db.query(
          Tables.tags,
          columns: ['lineage_id'],
          where: 'tag_id = ?',
          whereArgs: [id],
          limit: 1,
        );
        String? replacement;
        if (named.isNotEmpty) {
          final lineageId = named.single['lineage_id']! as String;
          final ownCopy = await db.query(
            Tables.tags,
            columns: ['tag_id'],
            where: 'project_id = ? AND lineage_id = ?',
            whereArgs: [projectId, lineageId],
            limit: 1,
          );
          if (ownCopy.isNotEmpty) {
            replacement = ownCopy.single['tag_id']! as String;
          }
        }

        if (replacement != null) {
          rewritten.add(replacement);
          changed = true;
          idsRewritten++;
        } else {
          rewritten.add(id);
          idsLeftAlone++;
        }
      }

      if (!changed) continue;

      final rowKey = '$nonDetectionId/$projectId';
      final hasReceipt =
          receiptTableExists &&
          (await db.query(
            SyncRowReceiptStore.table,
            columns: const ['row_key'],
            where: 'project_id = ? AND table_name = ? AND row_key = ?',
            whereArgs: [projectId, Tables.nonDetections, rowKey],
            limit: 1,
          )).isNotEmpty;

      final values = <String, Object?>{
        column: DbCodec.encodeStringList(rewritten),
      };
      if (hasReceipt) {
        values['updated_at'] = DbCodec.encodeUtc(DateTime.now());
        values['revision'] = (row['revision']! as int) + 1;
        rowsUpdatedAtBumped++;
      }
      await db.update(
        Tables.nonDetections,
        values,
        where: 'non_detection_id = ? AND project_id = ?',
        whereArgs: [nonDetectionId, projectId],
      );
    }

    return NonDetectionRelinkReport(
      rowsExamined: rowsExamined,
      idsRewritten: idsRewritten,
      idsLeftAlone: idsLeftAlone,
      rowsUpdatedAtBumped: rowsUpdatedAtBumped,
    );
  }
}

/// What [NonDetectionRelinkMigration.relink] found and did.
class NonDetectionRelinkReport {
  const NonDetectionRelinkReport({
    required this.rowsExamined,
    required this.idsRewritten,
    required this.idsLeftAlone,
    required this.rowsUpdatedAtBumped,
  });

  /// `Non_Detections` rows looked at, whatever they held.
  final int rowsExamined;

  /// Listened-for ids re-pointed to this project's own same-lineage `Tags`
  /// row.
  final int idsRewritten;

  /// Listened-for ids that named no `Tags` row in this project and no
  /// same-lineage row to redirect to either — left exactly as found. Should
  /// be zero; if it is not, that is the finding.
  final int idsLeftAlone;

  /// Rows whose `updated_at` (and `revision`) were bumped because
  /// `Sync_Row_Receipts` already held a receipt for them — see the class
  /// comment for why a rewrite with no receipt does not need one.
  final int rowsUpdatedAtBumped;

  /// The lines the migration prints, in order — a five-line tail has to be
  /// able to tell a clean run from a run that did nothing, so every number
  /// prints, including the zeroes.
  List<String> report() => [
    'Schema v15 (task 11.225) — re-pointing "no signal" entries left dangling '
        'by schema v14\'s fork:',
    '  Non_Detections rows examined: $rowsExamined',
    '  listened-for ids rewritten to this project\'s own copy: $idsRewritten',
    '  listened-for ids left alone (no same-lineage row in this project): '
        '$idsLeftAlone',
    '  rows whose updated_at was bumped (already held a sync receipt): '
        '$rowsUpdatedAtBumped',
  ];
}
