import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_held_rows.dart';
import 'sync_row_receipts.dart';
import 'sync_conflicts.dart';
import 'unknown_columns.dart';

/// Brings the client-only sync stores' stored `row_key` values across schema
/// major 2's re-keying (task 10.35).
///
/// `Sync_Held_Rows`, `Sync_Row_Receipts`, `Sync_Conflicts` and
/// `Unknown_Columns` are deliberately *outside* the versioned schema — they are
/// this device's own bookkeeping, created `IF NOT EXISTS` on open rather than
/// by a migration, so no `Migration` entry can reach them. But three of them
/// store a `row_key` in `syncRowKey`'s format, which is built from
/// `SyncTable.primaryKey` and therefore changed shape when the six
/// project-scoped tables gained `project_id` in their keys.
///
/// Left alone, a key written before the upgrade has one part where the current
/// schema expects two. `syncRowKeyWhere` already handles that gracefully — it
/// returns null for "the wrong number of key parts for this build's schema" —
/// so nothing corrupts. The problem is subtler: a **held row** whose key no
/// longer resolves is a record of data waiting to sync that can never be
/// matched to its row again, so it can never be retried and never cleared. It
/// would sit in "Waiting to sync" forever. That is precisely the stuck-record
/// shape tasks 10.28 and 10.34 exist to prevent, arriving by a different route.
///
/// **Idempotent by construction, which is why it needs no version flag.** Only
/// keys with exactly one part fewer than the current primary key are rewritten;
/// after one pass there are none, so a second pass is a no-op. That is cheaper
/// and more robust than recording "did I run this yet", which is another piece
/// of state that can be wrong.
abstract final class RowKeyMigration {
  /// The tables re-keyed by schema v6, with the scope column appended to their
  /// keys.
  ///
  /// Read from [syncTables] rather than hardcoded: unlike a schema migration —
  /// which must describe the change as it was made, and so is hardcoded (see
  /// `schemaV6Statements`) — this repairs *derived* state to match whatever the
  /// current key shape is. Deriving it is what keeps it correct if a later
  /// change re-keys another table.
  static Iterable<SyncTable> get _rekeyed => syncTables.where(
        (t) => t.primaryKey.length > 1 && t.primaryKey.last == 'project_id',
      );

  /// Rewrites stale keys in every client-only store that holds them.
  ///
  /// Safe to call on a database where these tables do not exist yet (a fresh
  /// install, or before the sync engine has ever run): each is checked for
  /// first, because they are created lazily by their own `ensureTable`.
  static Future<void> run(DatabaseExecutor db) async {
    for (final table in _rekeyed) {
      // Every store below keys rows the protocol's way and carries the
      // project the row belongs to, so the missing key part is recoverable
      // exactly — this is a rename, not a reconstruction.
      for (final store in const [
        SyncHeldRowStore.table,
        SyncRowReceiptStore.table,
        SyncConflictStore.table,
      ]) {
        if (!await _exists(db, store)) continue;
        await db.rawUpdate(
          'UPDATE $store SET row_key = row_key || ? || project_id '
          "WHERE table_name = ? AND row_key != ? "
          'AND length(row_key) - length(replace(row_key, ?, ?)) = ?',
          [
            _separator,
            table.name,
            unkeyableRowKey,
            _separator,
            '',
            table.primaryKey.length - 2,
          ],
        );
      }
    }
    await _purgeStaleUnknownColumns(db);
  }

  /// `Unknown_Columns` is the one store that cannot be migrated, only cleared.
  ///
  /// It keys held values by `jsonEncode(primaryKey values)`, so a `row_key`
  /// from before schema v6's rekeying is one part short and not recoverable
  /// from the row alone. Purging is nonetheless the right answer rather than a
  /// compromise: this table holds columns a *newer minor* peer sent that this
  /// build does not understand, and two builds only ever exchange rows when
  /// their majors match. A value held here from before the major bump came
  /// from a peer this build can no longer talk to at all, so there is nothing
  /// the held value could be promoted into.
  ///
  /// In practice this is now a no-op on any device that has reached task
  /// 10.76's build at least once: [UnknownColumnStore.ensureTable] itself
  /// clears the whole table the first time it finds one without a
  /// `project_id` column, since a pre-10.76 entry also carries no record of
  /// which project taught this device the value. This purge stays as the
  /// belt to that suspenders — the row-key shape it checks for is a different
  /// property than the column's presence, and it costs nothing to keep
  /// correct for both orders a device could apply these builds in.
  ///
  /// Entries whose key has the current number of parts are left untouched,
  /// which is what makes this safe to run on every open.
  static Future<void> _purgeStaleUnknownColumns(DatabaseExecutor db) async {
    if (!await _exists(db, UnknownColumnStore.table)) return;
    for (final table in _rekeyed) {
      final rows = await db.query(
        UnknownColumnStore.table,
        columns: ['row_key'],
        where: 'table_name = ?',
        whereArgs: [table.name],
        distinct: true,
      );
      final stale = <String>[];
      for (final row in rows) {
        final key = row['row_key'];
        if (key is! String) continue;
        final decoded = _tryDecodeList(key);
        if (decoded != null && decoded.length != table.primaryKey.length) {
          stale.add(key);
        }
      }
      if (stale.isEmpty) continue;
      await db.delete(
        UnknownColumnStore.table,
        where: 'table_name = ? AND row_key IN '
            '(${List.filled(stale.length, '?').join(', ')})',
        whereArgs: [table.name, ...stale],
      );
    }
  }

  static List<Object?>? _tryDecodeList(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// The separator [syncRowKey] joins key parts with.
  static const String _separator = '/';

  static Future<bool> _exists(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      [table],
    );
    return rows.isNotEmpty;
  }
}
