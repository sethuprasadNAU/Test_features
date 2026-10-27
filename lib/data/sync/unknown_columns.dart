import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

import '../db/data_arrival.dart';

/// Holds column values this build does not recognize, so it can hand them back
/// untouched (task 10.18).
///
/// ## The problem this exists to remove
///
/// Row-level last-write-wins plus a build that drops what it cannot store is
/// silent data destruction: an app at schema minor 5 pulls a row written at
/// minor 6, discards the column it has no place for, the user edits the notes,
/// and the push writes the whole row back with that column now empty. A value
/// another device contributed is gone, and nothing anywhere logged an error.
///
/// Task 10.11 read that as proof that any version skew must be refused. The step
/// it missed is that the drop is a choice. **If the older build never drops what
/// it doesn't recognize — holds it verbatim and returns it on the next push —
/// the destruction cannot happen, and the merge engine does not change at all.**
/// The row that goes back out is still whole; it was simply carried through a
/// build that could not read part of it.
///
/// ## Why this is a compatibility floor, not a feature
///
/// The protection lives on the *older* side. A build released without it cannot
/// be protected retroactively — bumping the schema still strands it. Whatever
/// version first ships this is the permanent floor, which is why it had to exist
/// before the first deployment rather than after.
///
/// ## Storage
///
/// A **client-only** table, deliberately outside [Tables] / `tableSpecs` /
/// [syncTables] and therefore outside [latestSchemaVersion]. It is created with
/// `IF NOT EXISTS` on every open rather than by a migration — the same pattern
/// the server uses for its own bookkeeping tables (task 10.11), and for the same
/// reason: adding a table only one side needs must not force a schema bump that
/// every device in the field has to chase.
///
/// Values are stored as their JSON encoding, which is the form they arrived in
/// and the form they leave in, so a round trip is byte-identical rather than
/// merely equal-ish after a coercion.
///
/// ## Project scoping (task 10.76, finding K-5)
///
/// Every entry is keyed against the project it arrived through. Project-scoped
/// tables already carry `project_id` inside their own primary key, so this adds
/// nothing new for them — but `Users`, `User_Emails` and `Tags` are globally
/// keyed and, without this, a value learned via one project's sync would be
/// [attach]ed onto that same shared row when a completely different project is
/// exported or pushed. That is a live A→B channel: a value never authorized for
/// project B rides out in project B's own payload because it happens to sit on
/// a row project B also references. Scoping the store closes it — [attach] only
/// returns what was learned through the project asking for it.
///
/// ## Bounds and failure handling (task 10.76, finding K-5)
///
/// `promote` used to run unconditionally from `onOpen`, on every launch, with
/// no bound on how many entries could accumulate, how long a stashed column
/// name could be, how large a stashed value could be, or what happened when a
/// value could not be written. An unwritable value threw *inside* `onOpen`, and
/// the entry was only deleted *after* a successful update — so the failure
/// repeated on every single launch and the database never opened again. [hold]
/// now refuses entries past [maxEntries], [maxColumnNameLength] or
/// [maxValueJsonLength] outright, so nothing unbounded can even be stashed, and
/// [promote] never lets a single bad entry take the rest of the pass down with
/// it: a failure is caught, the entry is moved to [quarantineTable] rather than
/// retried, and the next entry still gets a chance. A guard that turns a bad
/// value into a permanent brick is worse than no guard.
class UnknownColumnStore {
  const UnknownColumnStore(this.db);

  final DatabaseExecutor db;

  static const String table = 'Unknown_Columns';

  /// Entries [promote] could not apply, kept (not silently dropped) so the
  /// value is still inspectable later rather than simply gone. Bounded the
  /// same way [table] is — see [_quarantine].
  static const String quarantineTable = 'Unknown_Columns_Quarantine';

  /// Upper bound on how many rows [table] may hold at once. Reached only by a
  /// pathological or hostile peer — a real schema skew holds a handful of
  /// columns on a handful of rows — so refusing past it costs nothing a normal
  /// field season would ever notice.
  static const int maxEntries = 2000;

  /// Longest accepted `column_name`. SQLite identifiers this app ever mints
  /// are short snake_case names; this is generous headroom, not a real limit.
  static const int maxColumnNameLength = 128;

  /// Longest accepted `value_json`, in characters. Bounds a single held value
  /// to a size no real column on this schema approaches, so a value this large
  /// is refused rather than stored on the strength of "arrived over sync".
  static const int maxValueJsonLength = 8000;

  static const String _createTable = '''
CREATE TABLE IF NOT EXISTS $table (
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  column_name TEXT NOT NULL,
  project_id TEXT NOT NULL,
  value_json TEXT NOT NULL,
  PRIMARY KEY (table_name, row_key, column_name, project_id)
)''';

  static const String _createQuarantineTable = '''
CREATE TABLE IF NOT EXISTS $quarantineTable (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  column_name TEXT NOT NULL,
  project_id TEXT NOT NULL,
  value_json TEXT,
  reason TEXT NOT NULL,
  quarantined_at_utc TEXT NOT NULL
)''';

  /// Creates both tables, upgrading an older [table] in place if it predates
  /// `project_id` (task 10.76).
  ///
  /// An entry from before that column existed carries no record of which
  /// project taught this device the value, and — exactly as
  /// `RowKeyMigration._purgeStaleUnknownColumns` already reasons for the same
  /// table's `row_key` shape — there is nothing to recover it from. Purging is
  /// the answer already established for this table, not a new compromise: the
  /// value comes back on the next pull from whichever project still has it.
  static Future<void> ensureTable(DatabaseExecutor db) async {
    if (await _existsWithoutProjectScope(db)) {
      await db.execute('DROP TABLE $table');
    }
    await db.execute(_createTable);
    await db.execute(_createQuarantineTable);
  }

  static Future<bool> _existsWithoutProjectScope(DatabaseExecutor db) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.isEmpty) return false; // table does not exist yet.
    return columns.every((c) => c['name'] != 'project_id');
  }

  /// Splits [row] into the columns this build declares and the rest.
  ///
  /// A table this build has never heard of has no declaration to check against,
  /// so everything counts as known — the caller (which iterates [syncTables])
  /// never reaches that case, and treating it as all-unknown would invent
  /// holding entries for rows that have nowhere to go back to.
  static ({Map<String, Object?> known, Map<String, Object?> unknown}) split(
    String tableName,
    Map<String, Object?> row,
  ) {
    final spec = tableSpecsByName[tableName];
    if (spec == null) return (known: row, unknown: const {});
    final declared = spec.columnNames.toSet();
    final known = <String, Object?>{};
    final unknown = <String, Object?>{};
    row.forEach((column, value) {
      (declared.contains(column) ? known : unknown)[column] = value;
    });
    return (known: known, unknown: unknown);
  }

  /// The holding-table key for [row] — its primary key, JSON-encoded so a
  /// composite key cannot collide with a single one that happens to contain the
  /// separator.
  static String rowKeyFor(SyncTable table, Map<String, Object?> row) =>
      jsonEncode([for (final column in table.primaryKey) row[column]]);

  /// Records [unknown] as held against [row]'s identity, scoped to
  /// [projectId] — the project this value arrived through.
  ///
  /// **Upserts, never deletes.** A column absent from an incoming row leaves any
  /// held value alone, which is exactly what a build that *did* know the column
  /// would do: `UPDATE` writes only the columns the row carried. Matching that
  /// is the point — an old build must behave like a new one, not more cautiously
  /// and not less.
  ///
  /// Silently drops (rather than throws on) any entry whose column name or
  /// value exceeds [maxColumnNameLength]/[maxValueJsonLength], or that would
  /// push [table] past [maxEntries] — see the class doc. A dropped value is no
  /// worse than what every build before this task did with every unrecognized
  /// column: it does not come back on this device until the next pull.
  Future<void> hold(
    String projectId,
    SyncTable table,
    Map<String, Object?> row,
    Map<String, Object?> unknown,
  ) async {
    if (unknown.isEmpty) return;
    final rowKey = rowKeyFor(table, row);
    for (final entry in unknown.entries) {
      final columnName = entry.key;
      if (columnName.length > maxColumnNameLength) continue;
      final valueJson = jsonEncode(entry.value);
      if (valueJson.length > maxValueJsonLength) continue;
      if (await _wouldExceedCapacity(
        tableName: table.name,
        rowKey: rowKey,
        columnName: columnName,
        projectId: projectId,
      )) {
        continue;
      }
      await db.insert(UnknownColumnStore.table, {
        'table_name': table.name,
        'row_key': rowKey,
        'column_name': columnName,
        'project_id': projectId,
        'value_json': valueJson,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Whether inserting this exact key would grow [table] past [maxEntries].
  /// An update to an already-held key never grows the table, so only a brand
  /// new key is checked against the cap.
  Future<bool> _wouldExceedCapacity({
    required String tableName,
    required String rowKey,
    required String columnName,
    required String projectId,
  }) async {
    final existing = await db.query(
      table,
      columns: const ['table_name'],
      where: 'table_name = ? AND row_key = ? AND column_name = ? '
          'AND project_id = ?',
      whereArgs: [tableName, rowKey, columnName, projectId],
      limit: 1,
    );
    if (existing.isNotEmpty) return false;
    final count = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return (count.first['c'] as int) >= maxEntries;
  }

  /// Puts held values back onto [rows] in place, before they go out over the
  /// wire or into a backup — but only the values held through [projectId]
  /// itself, never a value this device learned via a different project (task
  /// 10.76). Rows without held values for this project are untouched.
  Future<void> attach(
    String projectId,
    SyncTable table,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    final byKey = {for (final row in rows) rowKeyFor(table, row): row};
    final keys = byKey.keys.toList();
    const chunkSize = 500; // under SQLite's 999-variable limit.
    for (var i = 0; i < keys.length; i += chunkSize) {
      final chunk = keys.sublist(
        i,
        i + chunkSize > keys.length ? keys.length : i + chunkSize,
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final held = await db.query(
        UnknownColumnStore.table,
        where: 'table_name = ? AND project_id = ? AND row_key IN '
            '($placeholders)',
        whereArgs: [table.name, projectId, ...chunk],
      );
      for (final entry in held) {
        final row = byKey[entry['row_key'] as String];
        if (row == null) continue;
        row[entry['column_name'] as String] = jsonDecode(
          entry['value_json'] as String,
        );
      }
    }
  }

  /// Moves held values into real columns that now exist, and forgets them.
  ///
  /// Written once and generically against `tableSpecs` rather than per column,
  /// so every future addition is covered without anyone remembering to write a
  /// promotion step for it. Each held value is an independent entry, so a value
  /// carried across two minor bumps promotes on whichever upgrade first declares
  /// its column.
  ///
  /// Never overwrites a column that already holds a non-null value: a held
  /// value racing a migration's own backfill (schema v4's `Tags.color_hex`
  /// `UPDATE` is the shape task 10.76 named) loses, silently and safely, rather
  /// than clobbering what the migration computed. Every per-entry failure —
  /// a malformed key, a value that will not fit the column, anything the update
  /// itself throws — is caught and the entry is quarantined rather than left to
  /// throw again on the next launch; see the class doc.
  ///
  /// Returns how many values were promoted.
  Future<int> promote() async {
    final held = await db.query(table);
    if (held.isEmpty) return 0;
    var promoted = 0;
    for (final entry in held) {
      try {
        if (await _promoteOne(entry)) promoted++;
      } catch (error) {
        await _quarantine(entry, reason: error.toString());
      }
    }
    // A promoted value lands in a real data table — a column on an observation
    // or a tag this build has only just learned to read — so the screens have
    // to be told (task 11.45). Once for the pass, not once per value.
    if (promoted > 0) DataArrival.announce();
    return promoted;
  }

  Future<bool> _promoteOne(Map<String, Object?> entry) async {
    final tableName = entry['table_name'] as String;
    final columnName = entry['column_name'] as String;

    if (columnName.length > maxColumnNameLength) {
      await _quarantine(entry, reason: 'column name exceeds bound');
      return false;
    }
    final valueJson = entry['value_json'] as String;
    if (valueJson.length > maxValueJsonLength) {
      await _quarantine(entry, reason: 'value exceeds bound');
      return false;
    }

    final spec = tableSpecsByName[tableName];
    final syncTable = syncTablesByName[tableName];
    if (spec == null ||
        syncTable == null ||
        !spec.columnNames.contains(columnName)) {
      // Still unknown to this build — leave it exactly where it is.
      return false;
    }

    final rowKey = entry['row_key'] as String;
    final decoded = jsonDecode(rowKey);
    if (decoded is! List || decoded.length != syncTable.primaryKey.length) {
      await _quarantine(entry, reason: 'row key does not match primary key');
      return false;
    }
    final keyValues = decoded;
    final where = syncTable.primaryKey.map((c) => '$c = ?').join(' AND ');

    final existingRows = await db.query(
      tableName,
      columns: [columnName],
      where: where,
      whereArgs: keyValues,
      limit: 1,
    );
    if (existingRows.isEmpty) {
      // The row this value was held for is gone (deleted since it was held).
      await _delete(entry);
      return false;
    }
    if (existingRows.first[columnName] != null) {
      // Something already wrote this column — a migration's own backfill, or
      // sync catching up by the normal path. Never clobber it with a stale
      // held value.
      await _delete(entry);
      return false;
    }

    await db.update(
      tableName,
      {columnName: jsonDecode(valueJson)},
      where: where,
      whereArgs: keyValues,
    );
    await _delete(entry);
    return true;
  }

  Future<void> _delete(Map<String, Object?> entry) => db.delete(
    table,
    where: 'table_name = ? AND row_key = ? AND column_name = ? '
        'AND project_id = ?',
    whereArgs: [
      entry['table_name'],
      entry['row_key'],
      entry['column_name'],
      entry['project_id'],
    ],
  );

  /// Moves a held entry that [promote] could not apply into
  /// [quarantineTable] instead of retrying it on the next launch, and bounds
  /// that table the same way [table] is bounded — trimming the oldest entry
  /// once [maxEntries] is reached, so a device that keeps hitting the same
  /// failure cannot grow this table without limit either.
  Future<void> _quarantine(
    Map<String, Object?> entry, {
    required String reason,
  }) async {
    final count = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $quarantineTable',
    );
    if ((count.first['c'] as int) >= maxEntries) {
      final oldest = await db.query(
        quarantineTable,
        columns: const ['id'],
        orderBy: 'id ASC',
        limit: 1,
      );
      if (oldest.isNotEmpty) {
        await db.delete(
          quarantineTable,
          where: 'id = ?',
          whereArgs: [oldest.single['id']],
        );
      }
    }
    await db.insert(quarantineTable, {
      'table_name': entry['table_name'],
      'row_key': entry['row_key'],
      'column_name': entry['column_name'],
      'project_id': entry['project_id'],
      'value_json': entry['value_json'],
      'reason': reason,
      'quarantined_at_utc': DateTime.now().toUtc().toIso8601String(),
    });
    await _delete(entry);
  }
}
