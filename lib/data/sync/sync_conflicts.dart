import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One local edit that last-write-wins discarded during sync — task 10.12's
/// "an edit you made was superseded" record.
///
/// Last-write-wins has always been able to discard a local edit silently
/// (`ProjectMerger`'s `stats.skipped`, `SyncEngine`'s `lostToServer` list);
/// this is the first place either result is durably recorded rather than just
/// counted, so a user can review what was overwritten instead of only
/// noticing that an observation looks different than they remember.
///
/// **Client-only table**, following the same pattern as [UnknownColumnStore]
/// (`unknown_columns.dart`) and for the same reason: this is this device's own
/// history, not project data, so it stays outside [Tables] / `tableSpecs` /
/// [latestSchemaVersion] and is created with `IF NOT EXISTS` on every open
/// rather than by a migration.
class SyncConflictStore {
  const SyncConflictStore(this.db);

  final DatabaseExecutor db;

  static const String table = 'Sync_Conflicts';

  static const String _createTable = '''
CREATE TABLE IF NOT EXISTS $table (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  detected_at_utc TEXT NOT NULL,
  local_snapshot_json TEXT NOT NULL,
  incoming_snapshot_json TEXT,
  reviewed_at_utc TEXT
)''';

  static Future<void> ensureTable(DatabaseExecutor db) =>
      db.execute(_createTable);

  /// Records that [localSnapshot] (this device's own edit) lost last-write-wins
  /// to [incomingSnapshot] (the row now authoritative, read back from the local
  /// database immediately after the pull that must carry it — see
  /// `SyncEngine._recordConflicts`). Null only if that row could not be found,
  /// which should not happen in practice but must not crash the sync round if
  /// it somehow does.
  Future<void> record({
    required String projectId,
    required String tableName,
    required String rowKey,
    required Map<String, Object?> localSnapshot,
    required Map<String, Object?>? incomingSnapshot,
    required DateTime detectedAtUtc,
  }) => db.insert(table, {
    'project_id': projectId,
    'table_name': tableName,
    'row_key': rowKey,
    'detected_at_utc': detectedAtUtc.toUtc().toIso8601String(),
    'local_snapshot_json': jsonEncode(localSnapshot),
    'incoming_snapshot_json':
        incomingSnapshot == null ? null : jsonEncode(incomingSnapshot),
  });

  /// Conflicts the user has not yet acknowledged, newest first.
  Future<List<SyncConflict>> unreviewed(String projectId) async {
    final rows = await db.query(
      table,
      where: 'project_id = ? AND reviewed_at_utc IS NULL',
      whereArgs: [projectId],
      orderBy: 'detected_at_utc DESC',
    );
    return [for (final row in rows) SyncConflict._fromRow(row)];
  }

  /// Marks one conflict acknowledged. Never deletes the row — the record
  /// stays for anyone who later wants to know what happened, it just stops
  /// counting toward the reviewable list.
  Future<void> markReviewed(int id, {DateTime? now}) =>
      markReviewedMany([id], now: now);

  /// [markReviewed] for a whole [SyncConflictEvent] at once — task 10.87's
  /// "one reviewable event" for an import or a sync round. Same rule: nothing
  /// is deleted.
  Future<void> markReviewedMany(Iterable<int> ids, {DateTime? now}) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final stamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    // SQLite's default variable limit is 999; an import can overwrite more
    // rows than that, so the update goes out in slices.
    const slice = 500;
    for (var i = 0; i < list.length; i += slice) {
      final part = list.sublist(i, i + slice > list.length ? list.length : i + slice);
      await db.update(
        table,
        {'reviewed_at_utc': stamp},
        where: 'id IN (${List.filled(part.length, '?').join(', ')})',
        whereArgs: part,
      );
    }
  }
}

/// **Task 10.87 — every overwrite one import or one sync round produced,
/// grouped as one reviewable thing.**
///
/// Task 10.12 built the "Overwritten edits" list for the occasional sync
/// overwrite: one card per record, expand it, read the two versions, tap
/// *Got it*. An honest whole-project restore writes one `Sync_Conflicts` row
/// per updated row — §4.19 clause 4's recoverability half working exactly as
/// specified — and after a large merge that is several thousand cards nobody
/// will open. **A review queue nobody will read is the same failure as a
/// consent dialog nobody can read, one screen over.**
///
/// The grouping key is `detected_at_utc`: both writers stamp every row of one
/// pass with a single clock reading (`ProjectMerger._apply` takes one `now`
/// per merge, `SyncEngine._recordConflicts` one per round), so rows sharing
/// the stamp are rows one act produced. **The stamp is this device's clock,
/// never the file's**, so a file cannot split or merge events. No schema
/// change: the grouping is derived at read time from a column the table has
/// always had.
///
/// What a person sees per event is bounded the way [ConsentSummary] is: how
/// many records, per kind of record, and a short sample in an order the file
/// did not choose — with the total stated beside the sample. Every underlying
/// row is still in the table, and *Got it* on the event marks all of them.
class SyncConflictEvent {
  const SyncConflictEvent({required this.detectedAtUtc, required this.conflicts});

  final DateTime detectedAtUtc;

  /// Every conflict in this event, in a fixed order: the table's position in
  /// the declared display order, then the row key — never the order the rows
  /// were written in, which is the order the file's rows came in.
  final List<SyncConflict> conflicts;

  int get count => conflicts.length;

  List<int> get ids => [for (final c in conflicts) c.id];

  /// Records per table, in the same declared order as [conflicts].
  Map<String, int> get countByTable {
    final out = <String, int>{};
    for (final c in conflicts) {
      out[c.tableName] = (out[c.tableName] ?? 0) + 1;
    }
    return out;
  }

  /// Groups [conflicts] into events, newest event first, each event's rows in
  /// [tableOrder] then by row key. A table [tableOrder] does not name sorts
  /// after every one it does — nothing is dropped.
  static List<SyncConflictEvent> group(
    List<SyncConflict> conflicts, {
    required List<String> tableOrder,
  }) {
    final byStamp = <DateTime, List<SyncConflict>>{};
    for (final c in conflicts) {
      byStamp.putIfAbsent(c.detectedAtUtc, () => []).add(c);
    }
    int rank(String table) {
      final i = tableOrder.indexOf(table);
      return i < 0 ? tableOrder.length : i;
    }
    final stamps = byStamp.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final stamp in stamps)
        SyncConflictEvent(
          detectedAtUtc: stamp,
          conflicts: byStamp[stamp]!
            ..sort((a, b) {
              final byTable = rank(a.tableName).compareTo(rank(b.tableName));
              return byTable != 0 ? byTable : a.rowKey.compareTo(b.rowKey);
            }),
        ),
    ];
  }
}

/// One row read back from [SyncConflictStore].
class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.tableName,
    required this.rowKey,
    required this.detectedAtUtc,
    required this.localSnapshot,
    required this.incomingSnapshot,
  });

  final int id;
  final String tableName;
  final String rowKey;
  final DateTime detectedAtUtc;

  /// This device's edit, as it was when the push offering it was rejected.
  final Map<String, Object?> localSnapshot;

  /// The row that replaced it, as read back from the local database right
  /// after the pull that applied it. Null in the rare case that row could not
  /// be found (e.g. it was itself deleted by a later sync before review).
  final Map<String, Object?>? incomingSnapshot;

  static SyncConflict _fromRow(Map<String, Object?> row) => SyncConflict(
    id: row['id'] as int,
    tableName: row['table_name'] as String,
    rowKey: row['row_key'] as String,
    detectedAtUtc: DateTime.parse(row['detected_at_utc'] as String),
    localSnapshot: Map<String, Object?>.from(
      jsonDecode(row['local_snapshot_json'] as String) as Map,
    ),
    incomingSnapshot: row['incoming_snapshot_json'] == null
        ? null
        : Map<String, Object?>.from(
            jsonDecode(row['incoming_snapshot_json'] as String) as Map,
          ),
  );

  /// Field-level differences between what this device had and what replaced
  /// it — the generic, per-table-agnostic answer to "what was it, and what
  /// replaced it." Only fields present in either snapshot and unequal are
  /// included; identical fields (most of a row, usually) are not noise.
  List<({String field, Object? was, Object? replacedBy})> get changedFields {
    final incoming = incomingSnapshot;
    if (incoming == null) return const [];
    final keys = {...localSnapshot.keys, ...incoming.keys};
    final out = <({String field, Object? was, Object? replacedBy})>[];
    for (final key in keys) {
      final was = localSnapshot[key];
      final replacedBy = incoming[key];
      if (was != replacedBy) {
        out.add((field: key, was: was, replacedBy: replacedBy));
      }
    }
    return out;
  }
}
