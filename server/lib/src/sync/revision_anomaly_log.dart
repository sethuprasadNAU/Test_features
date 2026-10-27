/// The durable register of rows carrying a `revision` nobody can overtake
/// (task 11.159).
library;

import 'package:postgres/postgres.dart';

import 'revision_plausibility.dart';

/// DDL for the revision-anomaly register.
///
/// **Server-only bookkeeping**, like `auth_audit_log`/`sync_traffic_log` —
/// created idempotently on every start rather than by a shared-schema
/// migration, so adding it does not force every device in the field to chase a
/// `latestSchemaVersion` bump for a table no client has any concept of. The
/// alternative considered and rejected was a `revision_anomaly` column beside
/// `clock_skew_flag` on every synced table, which would have been a
/// server-only observation paid for with a shared version bump and a migration
/// on every one of them.
///
/// ## A register, not an event stream
///
/// The primary key is the row this is *about* — `(project_id, table_name,
/// row_key)` — and a repeat sighting updates that row rather than appending a
/// second one. Two consequences, both deliberate:
///
/// - **The table answers the question an operator actually has**, which is
///   *"which rows on this server are pinned"* and not *"how many times did the
///   server notice"*. `SELECT count(*)` is the answer, directly.
/// - **It cannot grow without bound.** `sync_traffic_log`'s own header records
///   that it grows forever with no retention policy, flagged rather than
///   solved. One row per affected record has a ceiling: the number of records
///   on the server.
///
/// `first_seen_at`, `last_seen_at` and `sightings` keep what an event stream
/// would have given for this purpose, in three columns instead of a table that
/// needs purging.
///
/// ## What is structurally impossible to store here
///
/// No column holds row *content* — not a coordinate, not a note, not a name.
/// The row is identified by its primary key and nothing else, the same bound
/// `sync_traffic_log`'s `lost_detail` keeps and for the same reason (§4.7 rule
/// 6): this is a debugging aid, not a second copy of the field record.
const String createRevisionAnomalyLog = '''
CREATE TABLE IF NOT EXISTS revision_anomalies (
  project_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  anomaly TEXT NOT NULL,
  observed_as TEXT NOT NULL,
  stored_revision BIGINT,
  incoming_revision BIGINT NOT NULL,
  claimed_edits BIGINT NOT NULL,
  allowed_edits BIGINT NOT NULL,
  span_seconds BIGINT NOT NULL,
  reporting_user_id TEXT,
  reporting_device_id TEXT,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sightings INT NOT NULL DEFAULT 1,
  PRIMARY KEY (project_id, table_name, row_key)
)''';

const List<String> createRevisionAnomalyLogIndexes = [
  // The console's view and the operator report's count: most recent first.
  'CREATE INDEX IF NOT EXISTS idx_revision_anomalies_seen '
      'ON revision_anomalies (last_seen_at DESC)',
];

List<String> revisionAnomalyLogStatements() => [
  createRevisionAnomalyLog,
  ...createRevisionAnomalyLogIndexes,
];

/// **How the server came to notice this row**, which decides what the
/// attribution columns mean.
///
/// Two sightings, because a pin has two moments and only one of them is the
/// moment it arrives.
enum RevisionSighting {
  /// The pinned row was **stored by this push**. `reporting_user_id` /
  /// `reporting_device_id` are the caller who pushed it — the one to ask about
  /// a broken client.
  arriving('arriving'),

  /// A push **lost last-write-wins to a row already on the server** whose own
  /// `revision` is unexplainable. `reporting_user_id` /
  /// `reporting_device_id` are the person whose correction was just discarded,
  /// **not** whoever pinned the row.
  ///
  /// **This is what makes a pin that predates this code visible at all.** The
  /// register would otherwise only ever hold pins pushed since the upgrade, and
  /// a count of zero would mean "nothing arrived since Tuesday" while reading
  /// as "there are none" — a check that cannot tell success from its own
  /// silence. Catching it here also catches it at the exact moment it starts
  /// costing somebody something.
  blocking('blocking');

  const RevisionSighting(this.db);

  /// Stored value for the `observed_as` column.
  final String db;
}

/// One recorded anomaly, for the diagnostics console.
class RevisionAnomalyEntry {
  const RevisionAnomalyEntry({
    required this.projectId,
    required this.tableName,
    required this.rowKey,
    required this.anomaly,
    required this.observedAs,
    required this.storedRevision,
    required this.incomingRevision,
    required this.claimedEdits,
    required this.allowedEdits,
    required this.spanSeconds,
    required this.reportingUserId,
    required this.reportingDeviceId,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.sightings,
  });

  final String projectId;
  final String tableName;
  final String rowKey;
  final String anomaly;
  final String observedAs;
  final int? storedRevision;
  final int incomingRevision;
  final int claimedEdits;
  final int allowedEdits;
  final int spanSeconds;
  final String? reportingUserId;
  final String? reportingDeviceId;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final int sightings;

  static RevisionAnomalyEntry fromRow(Map<String, Object?> row) =>
      RevisionAnomalyEntry(
        projectId: row['project_id']! as String,
        tableName: row['table_name']! as String,
        rowKey: row['row_key']! as String,
        anomaly: row['anomaly']! as String,
        observedAs: row['observed_as']! as String,
        storedRevision: row['stored_revision'] as int?,
        incomingRevision: row['incoming_revision']! as int,
        claimedEdits: row['claimed_edits']! as int,
        allowedEdits: row['allowed_edits']! as int,
        spanSeconds: row['span_seconds']! as int,
        reportingUserId: row['reporting_user_id'] as String?,
        reportingDeviceId: row['reporting_device_id'] as String?,
        firstSeenAt: row['first_seen_at']! as DateTime,
        lastSeenAt: row['last_seen_at']! as DateTime,
        sightings: row['sightings']! as int,
      );

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'table_name': tableName,
    'row_key': rowKey,
    'anomaly': anomaly,
    'observed_as': observedAs,
    'stored_revision': storedRevision,
    'incoming_revision': incomingRevision,
    'claimed_edits': claimedEdits,
    'allowed_edits': allowedEdits,
    'span_seconds': spanSeconds,
    'reporting_user_id': reportingUserId,
    'reporting_device_id': reportingDeviceId,
    'first_seen_at': firstSeenAt.toIso8601String(),
    'last_seen_at': lastSeenAt.toIso8601String(),
    'sightings': sightings,
  };
}

/// Longest value [RevisionAnomalyLog.record] stores in any free-text column.
///
/// The same bound and the same reason as `maxAuditFieldLength`: `project_id`
/// and the row key are caller-controlled with no length of their own, and a
/// push of rows with megabyte-long ids must not be a way to make one write
/// cost megabytes. Every legitimate id here is well under this.
const int maxRevisionAnomalyFieldLength = 500;

String _bounded(String value) => value.length <= maxRevisionAnomalyFieldLength
    ? value
    : value.substring(0, maxRevisionAnomalyFieldLength);

String? _boundedOrNull(String? value) => value == null ? null : _bounded(value);

/// Writes and reads [createRevisionAnomalyLog].
///
/// Unlike `AuthAuditLog`, this takes the **caller's own session** and is meant
/// to be called from inside the push transaction. That is the point: an
/// anomaly recorded outside the transaction that stored the row could survive
/// a rollback and name a row that was never written, and a row written while
/// its anomaly's write failed would be pinned with nothing saying so. The two
/// facts are one fact and they commit together.
class RevisionAnomalyLog {
  const RevisionAnomalyLog(this.session);

  /// Must be the session inside the push's open transaction.
  final Session session;

  /// Records [verdict] against one row. Idempotent per row: a second sighting
  /// updates the existing entry and bumps `sightings` rather than appending.
  Future<void> record({
    required String projectId,
    required String tableName,
    required String rowKey,
    required RevisionVerdict verdict,
    required RevisionSighting observedAs,
    String? userId,
    String? deviceId,
  }) async {
    await session.execute(
      'INSERT INTO revision_anomalies ('
      'project_id, table_name, row_key, anomaly, observed_as, '
      'stored_revision, incoming_revision, claimed_edits, allowed_edits, '
      'span_seconds, reporting_user_id, reporting_device_id) '
      r'VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) '
      'ON CONFLICT (project_id, table_name, row_key) DO UPDATE SET '
      'anomaly = EXCLUDED.anomaly, '
      'observed_as = EXCLUDED.observed_as, '
      'stored_revision = EXCLUDED.stored_revision, '
      'incoming_revision = EXCLUDED.incoming_revision, '
      'claimed_edits = EXCLUDED.claimed_edits, '
      'allowed_edits = EXCLUDED.allowed_edits, '
      'span_seconds = EXCLUDED.span_seconds, '
      'reporting_user_id = EXCLUDED.reporting_user_id, '
      'reporting_device_id = EXCLUDED.reporting_device_id, '
      'last_seen_at = now(), '
      'sightings = revision_anomalies.sightings + 1',
      parameters: [
        _bounded(projectId),
        _bounded(tableName),
        _bounded(rowKey),
        verdict.anomaly.db,
        observedAs.db,
        verdict.storedRevision,
        verdict.incomingRevision,
        verdict.claimedEdits,
        verdict.allowedEdits,
        verdict.spanSeconds,
        _boundedOrNull(userId),
        _boundedOrNull(deviceId),
      ],
    );
  }

  /// Every recorded anomaly, most recently seen first.
  Future<List<RevisionAnomalyEntry>> recent({int limit = 100}) async {
    final result = await session.execute(
      'SELECT * FROM revision_anomalies ORDER BY last_seen_at DESC LIMIT \$1',
      parameters: [limit],
    );
    return [
      for (final row in result) RevisionAnomalyEntry.fromRow(row.toColumnMap()),
    ];
  }

  /// How many rows on this server are carrying an unexplainable `revision`.
  ///
  /// **The number `operator_status.sh` prints.** Zero is the answer that means
  /// something here: it says the server has looked and found nothing, which is
  /// different from nobody having looked.
  Future<int> count() async {
    final result = await session.execute(
      'SELECT count(*) FROM revision_anomalies',
    );
    return result.first.first! as int;
  }
}
