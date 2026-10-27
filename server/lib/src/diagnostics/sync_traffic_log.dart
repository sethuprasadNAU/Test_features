/// Durable record of every sync request, for the diagnostics console
/// (task 10.13).
library;

import 'dart:convert';

import 'package:postgres/postgres.dart';

/// DDL for the traffic log.
///
/// **Server-only, like `sync_cursors`/`auth_*` — not part of `tableSpecs` or
/// `latestSchemaVersion`.** Nothing here is synced data; it is the server's own
/// record of what happened, kept only so a developer can answer "why did my
/// observation disappear" without reconstructing it from `server_seq` and
/// timestamps by hand.
///
/// `rows_lost`/`lost_detail` is the single most important field in this table
/// — see `sync_routes.dart`'s call sites and the task's own framing: a row
/// that lost last-write-wins is the bug that actually gets reported.
///
/// **No retention policy yet.** Unlike every other server-only table (a
/// cursor per device, an account per user), this one grows without bound —
/// one row per sync request, forever. Fine at Phase 10's scale; flagged as
/// Discovered Scope rather than guessed at, since the right answer (age-based
/// purge? row cap? ship it to an external log sink instead?) is a product
/// decision, not an implementation detail.
const String createSyncTrafficLog = '''
CREATE TABLE IF NOT EXISTS sync_traffic_log (
  id BIGSERIAL PRIMARY KEY,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind TEXT NOT NULL,
  user_id TEXT,
  device_id TEXT,
  project_id TEXT,
  cursor_in BIGINT,
  cursor_out BIGINT,
  rows_pushed INT NOT NULL DEFAULT 0,
  rows_applied INT NOT NULL DEFAULT 0,
  rows_pulled INT NOT NULL DEFAULT 0,
  rows_lost INT NOT NULL DEFAULT 0,
  rows_rejected INT NOT NULL DEFAULT 0,
  lost_detail TEXT,
  client_schema_major INT,
  client_schema_version INT,
  status_code INT NOT NULL,
  error_code TEXT
)''';

const List<String> createSyncTrafficLogIndexes = [
  // The console's default view: most recent traffic first.
  'CREATE INDEX IF NOT EXISTS idx_sync_traffic_log_occurred '
      'ON sync_traffic_log (occurred_at DESC)',
  // The task's headline query: "rows that lost last-write-wins," cheaply.
  'CREATE INDEX IF NOT EXISTS idx_sync_traffic_log_lost '
      'ON sync_traffic_log (occurred_at DESC) WHERE rows_lost > 0',
  // "Which schema version is each of my devices on" (task 10.18's minor-skew
  // visibility gap, named again in this task's own spec): the most recent row
  // per (user, device) carries the answer.
  'CREATE INDEX IF NOT EXISTS idx_sync_traffic_log_device '
      'ON sync_traffic_log (user_id, device_id, occurred_at DESC)',
];

List<String> syncTrafficLogStatements() => [
  createSyncTrafficLog,
  ...createSyncTrafficLogIndexes,
];

/// One row a push offered that lost last-write-wins, for [SyncTrafficLogStore]
/// entries' `lost_detail`. Deliberately just enough to identify the row — not
/// its content — since this is a debugging aid, not a second copy of project
/// data.
class LoggedLostRow {
  const LoggedLostRow({required this.table, required this.primaryKey});

  final String table;
  final String primaryKey;

  Map<String, Object?> toJson() => {'table': table, 'primary_key': primaryKey};

  static LoggedLostRow fromJson(Map<String, Object?> json) => LoggedLostRow(
    table: json['table'] as String,
    primaryKey: json['primary_key'] as String,
  );
}

/// One request as recorded for the diagnostics console.
class SyncTrafficLogEntry {
  const SyncTrafficLogEntry({
    required this.id,
    required this.occurredAt,
    required this.kind,
    required this.userId,
    required this.deviceId,
    required this.projectId,
    required this.cursorIn,
    required this.cursorOut,
    required this.rowsPushed,
    required this.rowsApplied,
    required this.rowsPulled,
    required this.rowsLost,
    required this.rowsRejected,
    required this.lostDetail,
    required this.clientSchemaMajor,
    required this.clientSchemaVersion,
    required this.statusCode,
    required this.errorCode,
  });

  final int id;
  final DateTime occurredAt;
  final String kind;
  final String? userId;
  final String? deviceId;
  final String? projectId;
  final int? cursorIn;
  final int? cursorOut;
  final int rowsPushed;
  final int rowsApplied;
  final int rowsPulled;
  final int rowsLost;
  final int rowsRejected;
  final List<LoggedLostRow> lostDetail;
  final int? clientSchemaMajor;
  final int? clientSchemaVersion;
  final int statusCode;
  final String? errorCode;

  static SyncTrafficLogEntry fromRow(Map<String, Object?> row) {
    final rawLostDetail = row['lost_detail'] as String?;
    final decoded = rawLostDetail == null
        ? const <Object?>[]
        : jsonDecode(rawLostDetail) as List<Object?>;
    return SyncTrafficLogEntry(
      id: row['id']! as int,
      occurredAt: row['occurred_at']! as DateTime,
      kind: row['kind']! as String,
      userId: row['user_id'] as String?,
      deviceId: row['device_id'] as String?,
      projectId: row['project_id'] as String?,
      cursorIn: row['cursor_in'] as int?,
      cursorOut: row['cursor_out'] as int?,
      rowsPushed: row['rows_pushed']! as int,
      rowsApplied: row['rows_applied']! as int,
      rowsPulled: row['rows_pulled']! as int,
      rowsLost: row['rows_lost']! as int,
      rowsRejected: row['rows_rejected']! as int,
      lostDetail: [
        for (final entry in decoded)
          LoggedLostRow.fromJson(entry as Map<String, Object?>),
      ],
      clientSchemaMajor: row['client_schema_major'] as int?,
      clientSchemaVersion: row['client_schema_version'] as int?,
      statusCode: row['status_code']! as int,
      errorCode: row['error_code'] as String?,
    );
  }
}

/// Writes and reads [sync_traffic_log].
///
/// Writes happen inside the same transaction as the sync request they
/// describe (see `sync_routes.dart`), so a log entry and the write it
/// describes commit or roll back together — there is never a logged success
/// for a push that didn't actually land, or vice versa.
class SyncTrafficLogStore {
  const SyncTrafficLogStore(this.session);

  final Session session;

  Future<void> record({
    required String kind,
    String? userId,
    String? deviceId,
    String? projectId,
    int? cursorIn,
    int? cursorOut,
    int rowsPushed = 0,
    int rowsApplied = 0,
    int rowsPulled = 0,
    List<LoggedLostRow> lost = const [],
    int rowsRejected = 0,
    int? clientSchemaMajor,
    int? clientSchemaVersion,
    required int statusCode,
    String? errorCode,
  }) => session.execute(
    'INSERT INTO sync_traffic_log '
    '(kind, user_id, device_id, project_id, cursor_in, cursor_out, '
    'rows_pushed, rows_applied, rows_pulled, rows_lost, rows_rejected, '
    'lost_detail, client_schema_major, client_schema_version, status_code, '
    'error_code) '
    r'VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)',
    parameters: [
      kind,
      userId,
      deviceId,
      projectId,
      cursorIn,
      cursorOut,
      rowsPushed,
      rowsApplied,
      rowsPulled,
      lost.length,
      rowsRejected,
      lost.isEmpty ? null : jsonEncode([for (final l in lost) l.toJson()]),
      clientSchemaMajor,
      clientSchemaVersion,
      statusCode,
      errorCode,
    ],
  );

  /// Most recent requests, newest first — the console's default view.
  Future<List<SyncTrafficLogEntry>> recent({int limit = 100}) async {
    final result = await session.execute(
      'SELECT * FROM sync_traffic_log ORDER BY occurred_at DESC LIMIT \$1',
      parameters: [limit],
    );
    return [for (final row in result) SyncTrafficLogEntry.fromRow(row.toColumnMap())];
  }

  /// Requests where at least one row lost last-write-wins — the task's
  /// headline view, and the answer to "my observation disappeared."
  Future<List<SyncTrafficLogEntry>> recentLost({int limit = 100}) async {
    final result = await session.execute(
      'SELECT * FROM sync_traffic_log WHERE rows_lost > 0 '
      'ORDER BY occurred_at DESC LIMIT \$1',
      parameters: [limit],
    );
    return [for (final row in result) SyncTrafficLogEntry.fromRow(row.toColumnMap())];
  }

  /// The most recent request from each (user, device) pair that carried a
  /// schema version — the device-registry's "who is behind and by how much"
  /// (task 10.18's minor-skew gap, named again by this task's own spec).
  Future<List<SyncTrafficLogEntry>> latestPerDevice() async {
    final result = await session.execute(
      'SELECT DISTINCT ON (user_id, device_id) * FROM sync_traffic_log '
      'WHERE user_id IS NOT NULL AND device_id IS NOT NULL '
      'ORDER BY user_id, device_id, occurred_at DESC',
    );
    return [for (final row in result) SyncTrafficLogEntry.fromRow(row.toColumnMap())];
  }
}
