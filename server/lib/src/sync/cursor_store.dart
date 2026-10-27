/// Per-`(user, device, project)` cursor storage (task 10.7).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// DDL for the cursor table.
///
/// **The primary key is `(user_id, device_id, project_id)`. It must never be
/// narrowed to `(user_id, project_id)`.** With a per-user cursor, one device's
/// sync advances the shared position past rows another device never received,
/// and that device is never offered them again — it asks for `server_seq > n`
/// forever while the rows below `n` it never saw simply do not come. No error,
/// no retry, just an observation missing on one device, discovered months later
/// if at all. A test asserts the two devices' rows are independent; if you are
/// tempted to "simplify" this key, read that test first.
const String createSyncCursors = '''
CREATE TABLE IF NOT EXISTS sync_cursors (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  project_id TEXT NOT NULL,
  acknowledged_seq BIGINT NOT NULL DEFAULT 0,
  last_synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id, project_id)
)''';

const List<String> createSyncCursorIndexes = [
  // The device registry view (10.13): "which devices does this user have and
  // how far behind is each".
  'CREATE INDEX IF NOT EXISTS idx_sync_cursors_user ON sync_cursors (user_id)',
];

List<String> syncCursorStatements() => [
  createSyncCursors,
  ...createSyncCursorIndexes,
];

/// A device's recorded position, as the server understands it.
class StoredCursor {
  const StoredCursor({
    required this.acknowledgedSeq,
    required this.lastSyncedAt,
  });

  final int acknowledgedSeq;
  final DateTime lastSyncedAt;
}

/// Reads and advances cursors.
///
/// **This record is bookkeeping, not the delivery decision.** What a device is
/// sent is decided by the cursor it puts in its *request* — the client knows
/// what it actually committed, and the server only knows what it sent. This
/// table exists so the diagnostics console can answer "why is my phone behind"
/// (10.13) and so task 10.11 can tell whether a device's last sync predates the
/// tombstone retention window. Treating it as authoritative for delivery would
/// reintroduce the silent-loss bug from the other direction: a client that
/// crashed after the server advanced the cursor but before committing locally
/// would never see those rows again.
///
/// **Two writers since task 11.291: `/sync/ack`, and `/sync/pull`.** The app
/// acknowledges only a page that moved its cursor, so a device on a quiet
/// project — or a project's publisher, whose cursor comes from its own push —
/// could go months without an ack and had no row here at all. The pull route
/// now records the cursor a device pulls from, which is the same committed
/// position an ack would carry. Both go through [acknowledge], so both are
/// monotonic.
class CursorStore {
  const CursorStore(this.session);

  final Session session;

  Future<StoredCursor?> read(SyncCursorKey key) async {
    final result = await session.execute(
      r'SELECT acknowledged_seq, last_synced_at FROM sync_cursors '
      r'WHERE user_id = $1 AND device_id = $2 AND project_id = $3',
      parameters: [key.userId, key.deviceId, key.projectId],
    );
    if (result.isEmpty) return null;
    return StoredCursor(
      acknowledgedSeq: result.first[0]! as int,
      lastSyncedAt: result.first[1]! as DateTime,
    );
  }

  /// Records that [key]'s device has committed everything up to [cursor].
  ///
  /// **Monotonic: never moves backward.** `GREATEST` rather than assignment,
  /// because acknowledgements can arrive out of order on a flaky link (a
  /// retried older ack landing after a newer one), and letting the recorded
  /// position regress would make the retention check in 10.11 wrong in the
  /// dangerous direction — it would think a device is further behind than it
  /// is and force needless full re-pulls, or worse, be used to justify serving
  /// rows that were already purged.
  Future<void> acknowledge(
    SyncCursorKey key, {
    required int cursor,
    required DateTime at,
  }) async {
    await session.execute(
      r'INSERT INTO sync_cursors '
      r'(user_id, device_id, project_id, acknowledged_seq, last_synced_at) '
      r'VALUES ($1, $2, $3, $4, $5) '
      r'ON CONFLICT (user_id, device_id, project_id) DO UPDATE SET '
      r'acknowledged_seq = GREATEST(sync_cursors.acknowledged_seq, EXCLUDED.acknowledged_seq), '
      r'last_synced_at = EXCLUDED.last_synced_at',
      parameters: [key.userId, key.deviceId, key.projectId, cursor, at],
    );
  }

  /// Every device a user has synced this project from, for the 10.13 registry.
  Future<List<({String deviceId, StoredCursor cursor})>> devicesFor({
    required String userId,
    required String projectId,
  }) async {
    final result = await session.execute(
      r'SELECT device_id, acknowledged_seq, last_synced_at FROM sync_cursors '
      r'WHERE user_id = $1 AND project_id = $2 ORDER BY device_id',
      parameters: [userId, projectId],
    );
    return [
      for (final row in result)
        (
          deviceId: row[0]! as String,
          cursor: StoredCursor(
            acknowledgedSeq: row[1]! as int,
            lastSyncedAt: row[2]! as DateTime,
          ),
        ),
    ];
  }
}
