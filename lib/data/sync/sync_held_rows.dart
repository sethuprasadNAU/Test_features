import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The key the sync protocol identifies one row by: its primary key, `/`-joined
/// for composite keys.
///
/// Mirrors the server's `_rowKey` (`server/lib/src/sync/sync_service.dart`)
/// deliberately rather than sharing it: only the client needs to correlate
/// outcomes back to rows, and the shared package is kept to the things both
/// sides must agree on to merge correctly. Where the server returns null for a
/// row it cannot key, this returns [unkeyableRowKey] — the same `?` the server
/// then reports the outcome under, so the two still line up.
String syncRowKey(SyncTable table, Map<String, Object?> row) {
  final parts = <String>[];
  for (final column in table.primaryKey) {
    final value = row[column];
    if (value is! String || value.isEmpty) return unkeyableRowKey;
    parts.add(value);
  }
  return parts.join('/');
}

/// What [syncRowKey] returns for a row with no usable primary key.
const String unkeyableRowKey = '?';

/// [syncRowKey] as a SQL expression over [alias]'s columns, so a query can join
/// a table against the client-only stores that key rows the protocol's way
/// (`Sync_Row_Receipts`, `Sync_Held_Rows`) without reading every candidate row
/// into Dart first.
///
/// **Must produce the same string [syncRowKey] does**, which is why it lives
/// beside it rather than inline at the two call sites: the three functions in
/// this group are one format written three ways, and a disagreement between
/// them would silently stop a join from matching — which, for the receipt join,
/// means re-offering rows forever, and for the held join means offering a row
/// the server has already refused.
String syncRowKeySql(SyncTable table, {String alias = 't'}) =>
    table.primaryKey.map((column) => '$alias.$column').join(" || '/' || ");

/// The inverse of [syncRowKey]: a `WHERE` clause selecting the one row
/// [rowKey] names, or null if it cannot name a row in [table] (an unkeyable
/// placeholder, or the wrong number of key parts for this build's schema).
({String where, List<Object?> args})? syncRowKeyWhere(
  SyncTable table,
  String rowKey,
) {
  if (rowKey == unkeyableRowKey) return null;
  final parts = rowKey.split('/');
  if (parts.length != table.primaryKey.length) return null;
  return (
    where: table.primaryKey.map((c) => '$c = ?').join(' AND '),
    args: List<Object?>.of(parts),
  );
}

/// Why the server would not take a row this device offered.
///
/// **A category, not a sentence.** Each value used to carry an `explanation`
/// string that the sync status screen rendered verbatim, and task 11.41
/// removed it. The reason is worth recording, because the field was reworded
/// twice trying to make it work and neither rewording could:
///
/// - The server answers **one opaque `unauthorized`** for every reason it
///   refuses a row (§4.13), deliberately, so a refusal cannot be used to probe
///   what the server holds. So [notPermitted]'s sentence had to cover every
///   cause at once — a record naming somebody else, a tag the project has not
///   added — and a sentence covering three unrelated causes tells a person
///   nothing about the one in front of them. Task 10.34 reworded it, task
///   11.24 reworded it again after half of it became advice that could not
///   work, and it was still one paragraph for three situations.
/// - It could not name the record either, because an enum value does not know
///   which row it was attached to. The screen therefore showed the words
///   "Users" and "Tags" and that paragraph, which is the state task 11.41 was
///   opened for: a banner promising a reason, pointing at a screen with none.
///
/// What replaced it reads the **record** — who it names, whether that is the
/// signed-in person, which tags it uses that the project has not added — and
/// writes a sentence about that record. See `HeldRowDetails`. This enum stays
/// as what it always genuinely was: the stored classification of the server's
/// outcome, and the thing `HeldRowDetails` switches on.
enum HeldRowReason {
  /// Refused by authorization (task 10.10 / 10.20 / 10.29 / 11.24).
  ///
  /// The legitimate cases, and there is more than one, which is the whole
  /// reason this value cannot carry its own user-facing sentence:
  ///
  /// - a record whose author is somebody other than the signed-in person —
  ///   refused whether or not that person is on the project, because otherwise
  ///   anyone on the team could file a record under a colleague's name (task
  ///   11.24, finding N-1). It resolves when that person's own device syncs.
  /// - a record referring to a tag this project has not added (task 10.29). It
  ///   resolves when an owner adds the tag.
  ///
  /// The server will not say which, so the client distinguishes them by
  /// reading the record. See `HeldRowDetails`.
  notPermitted('not_permitted'),

  /// Rejected by the server's row validator as malformed.
  rejected('rejected'),

  /// The server answered without saying what it did with the row.
  ///
  /// Reachable under version skew: a table this build knows about and the
  /// server does not is dropped server-side, so no outcome comes back for it.
  /// **Silence is treated as a refusal, not as success** — that is the whole
  /// lesson of this finding.
  unaccounted('unaccounted');

  const HeldRowReason(this.db);

  /// Stored value. Kept stable — it is written to a local table.
  final String db;

  static HeldRowReason fromDb(String value) =>
      values.firstWhere((r) => r.db == value, orElse: () => unaccounted);

  /// Classifies one server outcome: null when the row is accounted for, a
  /// reason to hold it otherwise.
  ///
  /// **Deliberately an exhaustive switch with no `default`.** Adding a value
  /// to [SyncRowOutcome] is then a compile error here rather than a row that
  /// silently falls through the accepted branch — which is precisely how a
  /// refusal became invisible in the first place (`unauthorized` and `invalid`
  /// hit a `continue` that only `lostToServer` was ever meant to pass).
  static HeldRowReason? forOutcome(SyncRowOutcome outcome) => switch (outcome) {
    // Accounted for: the server stored it, or it lost last-write-wins to a
    // copy the server already holds (recorded by `SyncConflictStore`, and the
    // row is *on the server* either way — nothing is being held).
    SyncRowOutcome.inserted ||
    SyncRowOutcome.updated ||
    SyncRowOutcome.lostToServer => null,
    SyncRowOutcome.unauthorized => HeldRowReason.notPermitted,
    SyncRowOutcome.invalid => HeldRowReason.rejected,
  };
}

/// Rows this device offered to the server, the server would not take, and this
/// device is therefore still holding — task 10.28's answer to D-3.
///
/// ## Why this table exists
///
/// Before it, a refused row was discarded from the push response, the push
/// watermark advanced past it, and the app reported "Synced." For a primary
/// scientific record that is silent loss of irreplaceable field data, which is
/// the one failure mode this project ranks above everything else. The row
/// itself was never deleted — it stayed in SQLite — but nothing remembered that
/// the server had refused it, so nothing could re-offer it and nothing could
/// tell the user.
///
/// This is the memory that was missing. It answers three questions the sync
/// engine cannot otherwise answer:
///
/// 1. **Is anything not on the server?** (`heldCount`) — so no surface can
///    report success while a row was dropped.
/// 2. **Which rows, and why?** (`held`) — so the user gets an explanation
///    rather than a mystery.
/// 3. **Should this row be offered again right now?** (`heldUpdatedAt`) — so a
///    permanent refusal is *held and explained* rather than retried forever,
///    while a row the user has since edited, or explicitly retried, goes back
///    on the wire automatically.
///
/// ## Shape
///
/// **Client-only table**, following [SyncConflictStore] and `UnknownColumnStore`
/// for the same reason: this is this device's own bookkeeping, not project
/// data, so it stays out of `tableSpecs` / `latestSchemaVersion` and is created
/// with `IF NOT EXISTS` on every use rather than by a migration.
///
/// **One row per refused row, not one per refusal.** The unique key is
/// `(project, table, row)` and a repeat refusal updates it in place. A refusal
/// is triggered by a remote decision an attacker or a broken server could
/// repeat without limit, and an append-only log of it would be an unbounded
/// local write — the same mistake task 10.30 had to undo server-side.
///
/// **No copy of the row's data.** Only its identity (`table_name`, `row_key`)
/// and the `updated_at` it carried when it was refused. The record itself is
/// already in SQLite, unharmed; duplicating a coordinate or a note here would
/// mean a second copy to keep current and a second place for field data to
/// leak from, for no gain — the UI reads the live row when it needs detail.
class SyncHeldRowStore {
  const SyncHeldRowStore(this.db);

  final DatabaseExecutor db;

  static const String table = 'Sync_Held_Rows';

  static const String _createTable =
      '''
CREATE TABLE IF NOT EXISTS $table (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  reason TEXT NOT NULL,
  issue_code TEXT,
  issue_field TEXT,
  interlock_rule TEXT,
  held_updated_at TEXT,
  first_held_at_utc TEXT NOT NULL,
  last_refused_at_utc TEXT NOT NULL,
  refusal_count INTEGER NOT NULL DEFAULT 1,
  resolved_at_utc TEXT
)''';

  static const String _createIndex =
      '''
CREATE UNIQUE INDEX IF NOT EXISTS ${table}_identity
  ON $table (project_id, table_name, row_key)''';

  /// Creates the table, and adds [issueCodeColumn] and [issueFieldColumn] to
  /// one that predates them (task 11.124).
  ///
  /// **Why this is not a `latestSchemaVersion` migration, which is what task
  /// 11.124's own brief expected.** That constant is the *shared* schema
  /// version, negotiated with the server on every request: bumping it
  /// announces a change to the synced tables, and this table is not one of
  /// them. It is this device's own bookkeeping, created here rather than by a
  /// migration for exactly that reason (see the class note), and a bump would
  /// tell every server and every other device that something about the data
  /// contract had moved when nothing had. `UnknownColumnStore.ensureTable`
  /// already evolves a client-only table this way, for task 10.76; this
  /// follows it.
  ///
  /// **Additive, and it keeps the rows** — where 10.76 had to drop, because a
  /// row from before its column could not say which project taught it a value
  /// and nothing could recover that. Here the missing value is a refusal
  /// detail, null reads as "not recorded", and null is exactly what the code
  /// means anyway: this device does not know why, so the screen says so. A
  /// held row is a record of field data that has not reached the server, so
  /// dropping one to add an explanatory column would be the wrong trade by a
  /// wide margin.
  static Future<void> ensureTable(DatabaseExecutor db) async {
    await db.execute(_createTable);
    final existing = {
      for (final column in await db.rawQuery('PRAGMA table_info($table)'))
        column['name'],
    };
    for (final column in addedColumns) {
      if (existing.contains(column)) continue;
      await db.execute('ALTER TABLE $table ADD COLUMN $column TEXT');
    }
    await db.execute(_createIndex);
  }

  /// What the server said was wrong with the row, as
  /// [RowIssueCode.wire]. Named once so the DDL above, the in-place upgrade,
  /// the read and the test that pins the upgrade cannot disagree about it.
  static const String issueCodeColumn = 'issue_code';

  /// Which column of the row [issueCodeColumn] is about, as the server named
  /// it. **Untrusted on the way back out** — checked against this build's own
  /// declared columns before it is put in a sentence; see `HeldRowDetails`.
  static const String issueFieldColumn = 'issue_field';

  /// Which shared rule about the project's other rows refused this row, as
  /// [DeploymentInterlock.ruleId] or another rule's own identity — the
  /// second channel task 11.267 added beside [issueCodeColumn], for a
  /// refusal a `RowRefusal` cannot answer. Null is the ordinary case: no
  /// interlock fired, or this row predates the column.
  static const String interlockRuleColumn = 'interlock_rule';

  /// The columns [ensureTable] adds to a table that predates them, in order.
  ///
  /// A list rather than a check per column so that the next one added is a
  /// one-line edit here rather than a fourth near-identical `if` — and so a
  /// test can assert that a database built by an older build ends up with
  /// every one of them.
  static const List<String> addedColumns = [
    issueCodeColumn,
    issueFieldColumn,
    interlockRuleColumn,
  ];

  /// Records that the server refused this row, or that it refused it again.
  ///
  /// [rowUpdatedAt] is the row's `updated_at` as offered. It is what makes
  /// "held" different from "retried forever": while the stored row still
  /// carries that timestamp there is no point offering it again, and the moment
  /// it changes there is.
  /// [issueCode] is what the server said was wrong with the row, when it said
  /// anything (task 11.124). Null is the ordinary case and means this device
  /// does not know — it is stored as null and read back as null, so the screen
  /// falls through to the honest default rather than to a stale answer.
  ///
  /// **Overwritten on a repeat refusal, including with null.** A row refused
  /// today for a reason the server can name and refused again tomorrow for one
  /// it cannot must not keep yesterday's answer: the newest refusal is the one
  /// the person is looking at.
  Future<void> hold({
    required String projectId,
    required String tableName,
    required String rowKey,
    required HeldRowReason reason,
    required String? rowUpdatedAt,
    required DateTime at,
    RowIssueCode? issueCode,
    String? issueField,
    String? interlockRule,
  }) async {
    final stamp = at.toUtc().toIso8601String();
    await db.rawInsert(
      '''
INSERT INTO $table (
  project_id, table_name, row_key, reason, $issueCodeColumn,
  $issueFieldColumn, $interlockRuleColumn, held_updated_at,
  first_held_at_utc, last_refused_at_utc, refusal_count, resolved_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)
ON CONFLICT (project_id, table_name, row_key) DO UPDATE SET
  reason = excluded.reason,
  $issueCodeColumn = excluded.$issueCodeColumn,
  $issueFieldColumn = excluded.$issueFieldColumn,
  $interlockRuleColumn = excluded.$interlockRuleColumn,
  held_updated_at = excluded.held_updated_at,
  last_refused_at_utc = excluded.last_refused_at_utc,
  refusal_count = $table.refusal_count + 1,
  resolved_at_utc = NULL''',
      [
        projectId,
        tableName,
        rowKey,
        reason.db,
        issueCode?.wire,
        issueField,
        interlockRule,
        rowUpdatedAt,
        stamp,
        stamp,
      ],
    );
  }

  /// Records that a previously-held row is now accounted for on the server.
  ///
  /// Never deletes: the history of "this did not sync for a while" is worth
  /// keeping, exactly as [SyncConflictStore.markReviewed] keeps a reviewed
  /// conflict. It just stops counting as held.
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

  /// Lifts the "no point re-offering this" suppression for one held row, so the
  /// next push offers it again.
  ///
  /// The user-initiated half of "held, not retried forever": the fix for the
  /// common refusal is a change on the *server* (a colleague is added to the
  /// project), which this device cannot observe. Nulling the held timestamp
  /// rather than deleting the record keeps the row counted as not-synced until
  /// the server actually takes it — a retry is not a resolution.
  Future<void> release({
    required String projectId,
    required String tableName,
    required String rowKey,
  }) => db.update(
    table,
    {'held_updated_at': null},
    where: 'project_id = ? AND table_name = ? AND row_key = ?',
    whereArgs: [projectId, tableName, rowKey],
  );

  /// [release] for every row still held in [projectId] — used when the
  /// server's database has been replaced underneath this project (task
  /// 11.58).
  ///
  /// A hold is the answer of one particular database: *that* database would
  /// not take this row. A restored or rebuilt one has never been asked, and
  /// until it is, a hold keeps the row off the push exactly as a stale
  /// receipt would. Released rather than resolved, for [release]'s reason: the
  /// rows stay counted as not synced until the new database actually takes
  /// them, and one it refuses too is simply held again with its answer.
  Future<int> releaseProject(String projectId) => db.update(
    table,
    {'held_updated_at': null},
    where: 'project_id = ? AND resolved_at_utc IS NULL',
    whereArgs: [projectId],
  );

  /// Rows still being held for [projectId], most recently refused first.
  Future<List<HeldRow>> held(String projectId) async {
    final rows = await db.query(
      table,
      where: 'project_id = ? AND resolved_at_utc IS NULL',
      whereArgs: [projectId],
      orderBy: 'last_refused_at_utc DESC, id DESC',
    );
    return [for (final row in rows) HeldRow._fromRow(row)];
  }

  /// How many rows this device is holding for [projectId] — the number no
  /// status surface may round down to "everything is synced."
  Future<int> heldCount(String projectId) async {
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table '
      'WHERE project_id = ? AND resolved_at_utc IS NULL',
      [projectId],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// `table/rowKey` → the `updated_at` the row carried when it was refused,
  /// for every row currently held. A null value means "offer it again": either
  /// the timestamp was never known, or the user asked for a retry.
  ///
  /// Read once per push and used to filter the selection, rather than queried
  /// per candidate row.
  Future<Map<String, String?>> heldSignatures(String projectId) async {
    final rows = await db.query(
      table,
      columns: ['table_name', 'row_key', 'held_updated_at'],
      where: 'project_id = ? AND resolved_at_utc IS NULL',
      whereArgs: [projectId],
    );
    return {
      for (final row in rows)
        '${row['table_name']}/${row['row_key']}':
            row['held_updated_at'] as String?,
    };
  }
}

/// One row the server refused during a single push — what a push *reports*,
/// as distinct from [HeldRow], which is what the device *remembers*.
///
/// Carried out of the push rather than left inside it so that a caller
/// (`SyncEngine.run`, `ProjectPublisher.publish`) physically cannot hand back a
/// success report without also handing back the refusals: they arrive in the
/// same record.
class RefusedRow {
  const RefusedRow({
    required this.tableName,
    required this.rowKey,
    required this.reason,
    required this.rowUpdatedAt,
    this.issueCode,
    this.issueField,
    this.interlockRule,
  });

  final String tableName;
  final String rowKey;
  final HeldRowReason reason;

  /// What the server said was wrong, when it said anything (task 11.124), or
  /// null — the ordinary case, and the one that reads as "this device does
  /// not know why".
  final RowIssueCode? issueCode;

  /// Which column [issueCode] is about, as the server named it, or null.
  final String? issueField;

  /// Which shared rule about the project's other rows refused this row (task
  /// 11.267), or null — the ordinary case. See
  /// [SyncHeldRowStore.interlockRuleColumn].
  final String? interlockRule;

  /// The `updated_at` the refused row carried, or null when the refusal could
  /// not be matched to a row this device offered (a row the server could not
  /// even key, or a table it does not have).
  final String? rowUpdatedAt;

  String get outcomeKey => '$tableName/$rowKey';
}

/// One row read back from [SyncHeldRowStore].
class HeldRow {
  const HeldRow({
    required this.id,
    required this.tableName,
    required this.rowKey,
    required this.reason,
    required this.heldUpdatedAt,
    required this.firstHeldAtUtc,
    required this.lastRefusedAtUtc,
    required this.refusalCount,
    this.issueCode,
    this.issueField,
    this.interlockRule,
  });

  final int id;
  final String tableName;

  /// The row's primary key, `/`-joined for composite keys. `?` when the server
  /// refused a row it could not even key.
  final String rowKey;

  final HeldRowReason reason;

  /// What the server said was wrong with this row, when it said anything
  /// (task 11.124).
  ///
  /// **Null on a row held before this column existed, on a refusal the server
  /// could not explain, and on a code this build does not recognise** — three
  /// different situations that all mean the same thing to a reader, which is
  /// why they share one value rather than being told apart. All three reach
  /// task 11.122's honest default.
  final RowIssueCode? issueCode;

  /// Which column [issueCode] is about, **as the server named it** — so it is
  /// a string this device did not choose, and nothing renders it as-is. The
  /// screen matches it against the columns this build declares for this table
  /// and falls back to the honest default when it does not match.
  final String? issueField;

  /// Which shared rule about the project's other rows refused this row
  /// (task 11.267), or null on the ordinary case — no interlock fired, or
  /// this row predates the column. See
  /// [SyncHeldRowStore.interlockRuleColumn].
  final String? interlockRule;

  /// The `updated_at` this row carried when it was refused, or null if it is
  /// due to be offered again (unknown, or released by the user).
  final String? heldUpdatedAt;

  final DateTime firstHeldAtUtc;
  final DateTime lastRefusedAtUtc;
  final int refusalCount;

  /// The key the sync protocol uses for this row, `table/pk`.
  String get outcomeKey => '$tableName/$rowKey';

  static HeldRow _fromRow(Map<String, Object?> row) => HeldRow(
    id: row['id'] as int,
    tableName: row['table_name'] as String,
    rowKey: row['row_key'] as String,
    reason: HeldRowReason.fromDb(row['reason'] as String),
    // `fromWire` returns null for anything unrecognised rather than throwing:
    // a code written by a newer build, read back by an older one, must land on
    // the honest default and not on a crash. See [RowIssueCode.fromWire].
    issueCode: RowIssueCode.fromWire(row[SyncHeldRowStore.issueCodeColumn]),
    issueField: row[SyncHeldRowStore.issueFieldColumn] as String?,
    interlockRule: row[SyncHeldRowStore.interlockRuleColumn] as String?,
    heldUpdatedAt: row['held_updated_at'] as String?,
    firstHeldAtUtc: DateTime.parse(row['first_held_at_utc'] as String),
    lastRefusedAtUtc: DateTime.parse(row['last_refused_at_utc'] as String),
    refusalCount: (row['refusal_count'] as int?) ?? 1,
  );
}
