import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What the server has confirmed it holds, one row per synced row — task
/// 10.33's answer to the second silent-loss path.
///
/// ## Why this replaced the push watermark
///
/// Selection used to be `updated_at >= watermark`, where the watermark was a
/// single per-project timestamp set to the highest `updated_at` a push had
/// *offered*. Two properties of that scheme lose data, and they compound:
///
/// 1. **The walk is per-table; the watermark is global.** `_collectChangedRows`
///    takes rows from `syncTables` in FK order under one shared batch limit, so
///    when the limit is reached in an early table the later tables are never
///    queried — and their rows can be *older* than what was offered. The
///    watermark then advances above them and `updated_at >= watermark` never
///    selects them again.
/// 2. **A row can be written below the watermark at any time.** Task 6.3 copies
///    the sender's sync clock verbatim onto an imported replica, so a
///    colleague's observation shared today carries *last week's* `updated_at`.
///    On any device that has already pushed anything newer — which is every
///    device that has ever synced — it lands below the watermark and is never
///    selected. No batch limit is needed to reach this; it is the ordinary
///    outcome of importing a shared observation.
///
/// Both strand exactly the asset finding D-3 was about: a colleague's field
/// record, present only on this device, while the app reports "Synced."
///
/// ## What this stores instead
///
/// A receipt says: *for this project, the server has this row at this
/// `updated_at`.* A local row is **pending** when no receipt matches its
/// current `updated_at` — which makes the pending set exact rather than
/// inferred from a clock comparison, and closes both paths above at once:
///
/// - a row the batch limit never reached has no receipt, so the next push
///   selects it (per-row progress, so a shared batch limit is no longer able to
///   strand anything);
/// - an imported older-clock replica has no receipt, so it is selected
///   regardless of how far the device's own clock has moved on;
/// - a row already accepted has a matching receipt, so it is *not* re-offered —
///   which is what guarantees forward progress and is why no project size can
///   wedge the push. The old `>=` bias re-offered every row sharing the
///   boundary timestamp, and with enough rows on that boundary those re-offers
///   consumed the whole batch forever.
///
/// **The failure direction is deliberate.** Anything this table does not know
/// about is pending, so a write path nobody thought of, a clock that jumps
/// backwards, a restore from backup, and a schema this build has never seen all
/// fail toward *offering the row again*. Over-pushing costs bandwidth;
/// under-pushing loses an observation. That asymmetry is the whole argument.
///
/// ## Shape
///
/// **Client-only table**, following [SyncHeldRowStore], [SyncConflictStore] and
/// `UnknownColumnStore`: this is this device's own bookkeeping about one
/// server, it is not project data, and it never syncs — so it stays out of
/// `tableSpecs` / `latestSchemaVersion` and is created with `IF NOT EXISTS` on
/// use rather than by a migration.
///
/// **One row per (project, table, row).** A receipt is replaced in place when
/// the server confirms a newer version, so the table is bounded by the number
/// of rows the device actually holds — not by the number of syncs it has run.
///
/// **Keyed per project, including for the global tables.** `Users` and `Tags`
/// have no project column and are pushed to every project this device is
/// linked to; the same user row genuinely can be accepted by one project's
/// server state and refused by another's (task 10.20's row-naming invariant),
/// so "accepted" is not a property of the row alone.
///
/// **No copy of the row.** Only its identity and the `updated_at` that was
/// accepted. The record itself is in SQLite already, and a second copy would be
/// a second thing to keep current — the same rule [SyncHeldRowStore] follows.
class SyncRowReceiptStore {
  const SyncRowReceiptStore(this.db);

  final DatabaseExecutor db;

  static const String table = 'Sync_Row_Receipts';

  static const String _createTable =
      '''
CREATE TABLE IF NOT EXISTS $table (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  acked_updated_at TEXT,
  acked_at_utc TEXT NOT NULL
)''';

  static const String _createIndex =
      '''
CREATE UNIQUE INDEX IF NOT EXISTS ${table}_identity
  ON $table (project_id, table_name, row_key)''';

  static Future<void> ensureTable(DatabaseExecutor db) async {
    await db.execute(_createTable);
    await db.execute(_createIndex);
  }

  /// Records that the server is now holding this row at [ackedUpdatedAt].
  ///
  /// Written only for an outcome that means **the row is on the server** —
  /// `inserted`, `updated`, or `lost_to_server` (which is the server declining
  /// to overwrite its own copy with an older one, so the row is there in a
  /// version this device will pull). A refusal writes a [SyncHeldRowStore]
  /// entry instead and deliberately leaves no receipt, which is what keeps the
  /// row in the pending set.
  ///
  /// [ackedUpdatedAt] is null only for a row with no readable `updated_at`,
  /// which the schema's `NOT NULL` should make unreachable. The selection
  /// treats a null on either side as *no match* rather than as two nulls
  /// agreeing, so if it ever does happen the row stays pending and is offered
  /// again — noisy, but the fail-safe direction.
  Future<void> record({
    required String projectId,
    required String tableName,
    required String rowKey,
    required String? ackedUpdatedAt,
    required DateTime at,
  }) => db.rawInsert(
    '''
INSERT INTO $table (
  project_id, table_name, row_key, acked_updated_at, acked_at_utc
) VALUES (?, ?, ?, ?, ?)
ON CONFLICT (project_id, table_name, row_key) DO UPDATE SET
  acked_updated_at = excluded.acked_updated_at,
  acked_at_utc = excluded.acked_at_utc''',
    [
      projectId,
      tableName,
      rowKey,
      ackedUpdatedAt,
      at.toUtc().toIso8601String(),
    ],
  );

  /// Forgets every receipt for [projectId], so the next push re-offers the
  /// whole project.
  ///
  /// The escape hatch that `SyncStateStore.resetPushWatermark` used to be. It
  /// is needed far less often now — the receipt scheme already covers the
  /// clock-jumped-backwards case that was its original reason to exist — but it
  /// remains the honest answer to "this device and the server disagree and I
  /// cannot tell why": re-offering everything is cheap, and the server resolves
  /// each already-known row to `lost_to_server` without storing anything.
  Future<int> forgetProject(String projectId) =>
      db.delete(table, where: 'project_id = ?', whereArgs: [projectId]);

  /// How many rows the server has confirmed for [projectId]. Diagnostics and
  /// tests; nothing in the app's behaviour depends on it.
  Future<int> count(String projectId) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table WHERE project_id = ?',
      [projectId],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// Every row of [projectId] the server has ever held, as
  /// `table/rowKey` strings.
  ///
  /// **"Held", not "accepted".** A receipt is written both when the server
  /// takes a pushed row and when it *delivers* one on a pull
  /// (`SyncEngine._recordDeliveredReceipts`), so this answers the question
  /// `mayOfferRow` needs — *would writing this row be an update rather than an
  /// insert?* — which is what bounds task 11.57's ownership waiver to the
  /// writes the server actually accepts. `ProjectPublisher` reads it once per
  /// publish; the sync engine asks the same question through the join in
  /// `_pendingClause` rather than through this method.
  Future<Set<String>> rowKeysFor(String projectId) async {
    final rows = await db.query(
      table,
      columns: ['table_name', 'row_key'],
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    return {
      for (final row in rows) '${row['table_name']}/${row['row_key']}',
    };
  }

  /// The `updated_at` the server has confirmed for one row, or null if it has
  /// confirmed none. Diagnostics and tests.
  Future<String?> ackedUpdatedAt({
    required String projectId,
    required String tableName,
    required String rowKey,
  }) async {
    final rows = await db.query(
      table,
      columns: ['acked_updated_at'],
      where: 'project_id = ? AND table_name = ? AND row_key = ?',
      whereArgs: [projectId, tableName, rowKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['acked_updated_at'] as String?;
  }
}
