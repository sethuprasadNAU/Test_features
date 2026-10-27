/// Read-only queries behind the diagnostics console (task 10.13).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';
import '../sync/revision_anomaly_log.dart';

/// **Every method here issues `SELECT` only.** No route built on top of this
/// class may call anything else — a console that can write becomes a second,
/// untested, unauthorized mutation path straight past task 10.10's
/// authorization work. If a table needs an explicit column list rather than
/// `SELECT *`, it is because that table can carry a secret — see [identities]
/// and [devices], neither of which ever selects `token_hash`.
class DiagnosticsRepository {
  const DiagnosticsRepository(this.session);

  final Session session;

  /// Every project on the server, newest first.
  Future<List<Map<String, Object?>>> projects() async {
    final result = await session.execute(
      'SELECT project_id, project_name, owner_user_id, created_at, '
      'updated_at, server_seq FROM ${quoted(Tables.projects)} '
      'WHERE deleted_at IS NULL ORDER BY created_at DESC',
    );
    return [for (final row in result) row.toColumnMap()];
  }

  /// Row counts per sync table, scoped to [projectId] where a table has a
  /// project column and reported server-wide otherwise (`Users`/`Tags` have
  /// no project of their own to scope by).
  Future<Map<String, int>> rowCounts(String projectId) async {
    final counts = <String, int>{};
    for (final table in syncTables) {
      final scope = table.projectScopeColumn;
      final result = scope == null
          ? await session.execute('SELECT count(*) FROM ${quoted(table.name)}')
          : await session.execute(
              'SELECT count(*) FROM ${quoted(table.name)} WHERE $scope = \$1',
              parameters: [projectId],
            );
      counts[table.name] = result.first.first! as int;
    }
    return counts;
  }

  /// The most recent [limit] rows of [tableName], with their sync columns.
  ///
  /// [tableName] is validated against [syncTablesByName] — the only tables
  /// this can ever read are the ones the sync protocol itself already
  /// exposes to any authorized client, so this route reveals nothing sync
  /// doesn't. Returns null for an unrecognized table rather than querying, so
  /// this can never become a way to probe for `auth_*`/`sync_*` server-only
  /// tables by name.
  Future<List<Map<String, Object?>>?> recentRows(
    String tableName, {
    String? projectId,
    int limit = 50,
  }) async {
    final table = syncTablesByName[tableName];
    if (table == null) return null;
    final scope = table.projectScopeColumn;
    final result = scope == null || projectId == null
        ? await session.execute(
            'SELECT * FROM ${quoted(tableName)} '
            'ORDER BY server_seq DESC NULLS LAST LIMIT \$1',
            parameters: [limit],
          )
        : await session.execute(
            'SELECT * FROM ${quoted(tableName)} WHERE $scope = \$1 '
            'ORDER BY server_seq DESC NULLS LAST LIMIT \$2',
            parameters: [projectId, limit],
          );
    return [for (final row in result) row.toColumnMap()];
  }

  /// Rows carrying a `revision` no honest edit can overtake (task 11.159).
  ///
  /// **The console's answer to "is anybody's correction being silently
  /// discarded forever."** `revision` decides last-write-wins first, so a row
  /// stored at an unexplainably high one wins every future merge and every
  /// teammate's later edit is reported to them as *"Unchanged (local was
  /// newer)"*. Nothing refuses such a row — see `RevisionPlausibility` for why
  /// a refusal cannot be both safe and effective — so this register is the only
  /// place the fact exists.
  ///
  /// An empty list means the server has looked and found none, which
  /// `observed_as = 'blocking'` is what makes true of rows pinned before the
  /// detection shipped as well as after.
  Future<List<RevisionAnomalyEntry>> revisionAnomalies({int limit = 100}) =>
      RevisionAnomalyLog(session).recent(limit: limit);

  /// The membership rows for one project — in Phase 10, exactly one
  /// never-ended owner; Phase 11's task 11.2 is what makes ended stints and
  /// non-owner members possible.
  Future<List<Map<String, Object?>>> membershipsFor(String projectId) async {
    final result = await session.execute(
      'SELECT membership_id, user_id, role, join_date, end_date '
      'FROM ${quoted(Tables.projectMemberships)} WHERE project_id = \$1 '
      'ORDER BY join_date',
      parameters: [projectId],
    );
    return [for (final row in result) row.toColumnMap()];
  }

  /// Every account, its synced display name, and the deduplication trail —
  /// "who deduped onto whom" (Phase 6/7's remap), otherwise invisible.
  ///
  /// Explicit column list: `auth_accounts` carries no secret, but this joins
  /// it against nothing that does either, and staying explicit here means a
  /// future column added to `auth_accounts` doesn't silently start appearing
  /// in a console response without a decision being made about it.
  Future<List<Map<String, Object?>>> identities() async {
    final result = await session.execute(
      'SELECT a.user_id, a.email AS account_email, a.created_at AS '
      'account_created_at, u.first_name, u.last_name, u.email AS '
      'current_email FROM auth_accounts a LEFT JOIN '
      '${quoted(Tables.users)} u ON u.user_id = a.user_id ORDER BY '
      'a.created_at',
    );
    final accounts = [for (final row in result) row.toColumnMap()];

    final history = await session.execute(
      'SELECT user_id, email, recorded_at FROM ${quoted(Tables.userEmails)} '
      'ORDER BY user_id, recorded_at',
    );
    final emailsByUser = <String, List<Map<String, Object?>>>{};
    for (final row in history) {
      final map = row.toColumnMap();
      emailsByUser.putIfAbsent(map['user_id']! as String, () => []).add({
        'email': map['email'],
        'recorded_at': map['recorded_at'],
      });
    }

    return [
      for (final account in accounts)
        {
          ...account,
          'prior_emails': emailsByUser[account['user_id']] ?? const [],
        },
    ];
  }

  /// Every device known for [userId] (or every device on the server, if
  /// null), joining the cursor position, the schema version it last synced
  /// with (task 10.18's minor-skew gap, named again by this task's own spec),
  /// and its session's liveness — this is "why is my phone behind."
  ///
  /// **Never selects `token_hash`** — `auth_sessions` carries a credential-
  /// equivalent secret, and this is the one query in this file that touches
  /// that table.
  Future<List<Map<String, Object?>>> devices({String? userId}) async {
    final cursorRows = userId == null
        ? await session.execute(
            'SELECT user_id, device_id, project_id, acknowledged_seq, '
            'last_synced_at FROM sync_cursors ORDER BY user_id, device_id',
          )
        : await session.execute(
            'SELECT user_id, device_id, project_id, acknowledged_seq, '
            'last_synced_at FROM sync_cursors WHERE user_id = \$1 '
            'ORDER BY device_id',
            parameters: [userId],
          );

    final sessionRows = userId == null
        ? await session.execute(
            'SELECT user_id, device_id, created_at, last_seen_at, '
            'expires_at, revoked_at, revoked_reason FROM auth_sessions '
            'ORDER BY user_id, device_id, last_seen_at DESC',
          )
        : await session.execute(
            'SELECT user_id, device_id, created_at, last_seen_at, '
            'expires_at, revoked_at, revoked_reason FROM auth_sessions '
            'WHERE user_id = \$1 ORDER BY device_id, last_seen_at DESC',
            parameters: [userId],
          );
    // Most-recent session per (user, device) — a device can hold more than
    // one historical session row, and only the latest describes it now.
    final latestSession = <String, Map<String, Object?>>{};
    for (final row in sessionRows) {
      final map = row.toColumnMap();
      final key = '${map['user_id']}/${map['device_id']}';
      latestSession.putIfAbsent(key, () => map);
    }

    return [
      for (final row in cursorRows)
        () {
          final map = row.toColumnMap();
          final key = '${map['user_id']}/${map['device_id']}';
          final deviceSession = latestSession[key];
          return {
            ...map,
            'session_last_seen_at': deviceSession?['last_seen_at'],
            'session_expires_at': deviceSession?['expires_at'],
            'session_revoked_at': deviceSession?['revoked_at'],
            'session_revoked_reason': deviceSession?['revoked_reason'],
          };
        }(),
    ];
  }
}
