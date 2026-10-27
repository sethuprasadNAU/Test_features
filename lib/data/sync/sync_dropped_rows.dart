import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Records this device refused to store when the server sent them — task
/// 11.44's answer to the inbound half of finding D-3, built to task 10.28's
/// own shape rather than a second one.
///
/// ## Why this exists
///
/// `SyncEngine._pull` hands every incoming page to `ProjectMerger`, and the
/// merger refuses a row whose values this build's `RowValidator` does not
/// recognise, or one scoped to a different project. Both are correct
/// refusals — but until this task, the only record of one was
/// `SyncRunReport.droppedOnArrival`, a plain list rebuilt from nothing every
/// round and read once by `SyncController`. Close the app and reopen it, or
/// let one ordinary offline failure rebuild `SyncStatus` from scratch, and
/// the list was gone: a teammate's record could be dropped by this device and
/// nothing anywhere would say so a minute later.
///
/// This is the memory that was missing, mirroring [SyncHeldRowStore] exactly
/// where the two situations agree, and departing from it only where they
/// genuinely differ:
///
/// - **Same shape.** A client-only table, one row per refused identity (not
///   one per refusal), created with `IF NOT EXISTS` rather than migrated,
///   holding no copy of the row's data.
/// - **Different content.** A held row's data is still in SQLite, so
///   `HeldRowDetails` can read the live row to say who it names. A dropped
///   row was never written anywhere on this device — there is nothing local
///   to read — so what is kept instead is the one thing that *is* known: the
///   validator's own `field`/`message` explanation, the same pair already
///   shown on the restore-preview screen (`data_export_screen.dart`).
/// - **Different resolution.** A held row is *this* device's own data, and
///   the next push automatically re-offers it, so [SyncHeldRowStore] can ask
///   "would this still be offered?" to tell when a hold has cleared itself.
///   A dropped row is the opposite: nothing on this device asks the server
///   for it again on its own — the pull cursor has already moved past it, and
///   there is no "re-fetch everything" action once a project is joined. It
///   only comes back if the record changes again wherever it was written,
///   which delivers it at a later `server_seq` the way any update does. So
///   [resolve] fires only when that happens — checked by [SyncEngine] against
///   the live database, exactly as [SyncHeldRowStore]'s own resolution is.
class SyncDroppedRowStore {
  const SyncDroppedRowStore(this.db);

  final DatabaseExecutor db;

  static const String table = 'Sync_Dropped_Rows';

  static const String _createTable =
      '''
CREATE TABLE IF NOT EXISTS $table (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  field TEXT NOT NULL,
  message TEXT NOT NULL,
  first_dropped_at_utc TEXT NOT NULL,
  last_dropped_at_utc TEXT NOT NULL,
  drop_count INTEGER NOT NULL DEFAULT 1,
  resolved_at_utc TEXT
)''';

  static const String _createIndex =
      '''
CREATE UNIQUE INDEX IF NOT EXISTS ${table}_identity
  ON $table (project_id, table_name, row_key)''';

  static Future<void> ensureTable(DatabaseExecutor db) async {
    await db.execute(_createTable);
    await db.execute(_createIndex);
  }

  /// Records that this device would not store this row, or that it would not
  /// again — [issue] carries which field and why, straight from the merge
  /// that refused it.
  Future<void> record({
    required String projectId,
    required RowIssue issue,
    required DateTime at,
  }) async {
    final stamp = at.toUtc().toIso8601String();
    await db.rawInsert(
      '''
INSERT INTO $table (
  project_id, table_name, row_key, field, message,
  first_dropped_at_utc, last_dropped_at_utc, drop_count, resolved_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, 1, NULL)
ON CONFLICT (project_id, table_name, row_key) DO UPDATE SET
  field = excluded.field,
  message = excluded.message,
  last_dropped_at_utc = excluded.last_dropped_at_utc,
  drop_count = $table.drop_count + 1,
  resolved_at_utc = NULL''',
      [
        projectId,
        issue.table,
        issue.primaryKeyValue,
        issue.field,
        issue.message,
        stamp,
        stamp,
      ],
    );
  }

  /// Records that a previously-dropped row is now on this device — never
  /// deletes, for the same reason [SyncHeldRowStore.resolve] does not.
  Future<void> resolve({
    required String projectId,
    required String tableName,
    required String rowKey,
    required DateTime at,
  }) => db.update(
    table,
    {'resolved_at_utc': at.toUtc().toIso8601String()},
    where:
        'project_id = ? AND table_name = ? AND row_key = ? '
        'AND resolved_at_utc IS NULL',
    whereArgs: [projectId, tableName, rowKey],
  );

  /// Rows this device is still missing for [projectId], most recently dropped
  /// first.
  Future<List<DroppedRow>> dropped(String projectId) async {
    final rows = await db.query(
      table,
      where: 'project_id = ? AND resolved_at_utc IS NULL',
      whereArgs: [projectId],
      orderBy: 'last_dropped_at_utc DESC, id DESC',
    );
    return [for (final row in rows) DroppedRow._fromRow(row)];
  }

  /// How many rows this device is missing for [projectId] — the durable
  /// count `SyncStatus.droppedOnArrivalCount` reads, so it survives a restart
  /// exactly as `SyncStatus.heldCount` already does.
  Future<int> droppedCount(String projectId) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table '
      'WHERE project_id = ? AND resolved_at_utc IS NULL',
      [projectId],
    );
    return (result.first['c'] as int?) ?? 0;
  }
}

/// One row read back from [SyncDroppedRowStore].
class DroppedRow {
  const DroppedRow({
    required this.id,
    required this.tableName,
    required this.rowKey,
    required this.field,
    required this.message,
    required this.firstDroppedAtUtc,
    required this.lastDroppedAtUtc,
    required this.dropCount,
  });

  final int id;
  final String tableName;

  /// The row's primary key, `/`-joined for composite keys — the same format
  /// [syncRowKey] produces, so it can be looked up against the live table.
  final String rowKey;

  /// The column [RowValidator] or the scope check refused, and why. Never
  /// server-supplied text: both come from this device's own read of the row
  /// as it arrived on the wire.
  final String field;
  final String message;

  final DateTime firstDroppedAtUtc;
  final DateTime lastDroppedAtUtc;
  final int dropCount;

  static DroppedRow _fromRow(Map<String, Object?> row) => DroppedRow(
    id: row['id'] as int,
    tableName: row['table_name'] as String,
    rowKey: row['row_key'] as String,
    field: row['field'] as String,
    message: row['message'] as String,
    firstDroppedAtUtc: DateTime.parse(row['first_dropped_at_utc'] as String),
    lastDroppedAtUtc: DateTime.parse(row['last_dropped_at_utc'] as String),
    dropCount: (row['drop_count'] as int?) ?? 1,
  );
}
