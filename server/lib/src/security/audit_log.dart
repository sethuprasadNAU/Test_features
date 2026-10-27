/// The authentication audit log (task 10.14, Security Model §4.7).
library;

import 'package:postgres/postgres.dart';

/// DDL for the authentication audit log.
///
/// **Server-only bookkeeping**, like `auth_*`/`sync_cursors`/`sync_traffic_log`
/// — created idempotently on every start rather than by a shared-schema
/// migration, so adding it does not force every device in the field to chase a
/// `latestSchemaVersion` bump for a table no client has any concept of.
///
/// §4.7 splits logging in two because retention and sensitivity differ. This is
/// the **authentication** half, retained one year, because "was my account
/// compromised in March?" is a question that gets asked in September. The
/// **data-access** half is `sync_traffic_log` (task 10.13) at 180 days. One
/// recording mechanism per concern, both read by the diagnostics console.
///
/// **What is structurally impossible to store here:** there is no token
/// column, and no coordinate column. §4.7's never-log list is enforced by the
/// shape of the table, not by remembering — a caller cannot record a token
/// through this API because there is nowhere to put one. [AuthAuditEvent] is a
/// closed enum for the same reason: a free-form event string invites someone to
/// interpolate a value into it.
const String createAuthAuditLog = '''
CREATE TABLE IF NOT EXISTS auth_audit_log (
  id BIGSERIAL PRIMARY KEY,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  event TEXT NOT NULL,
  user_id TEXT,
  email TEXT,
  device_id TEXT,
  source_address TEXT,
  outcome TEXT,
  reason TEXT,
  request_id TEXT
)''';

const List<String> createAuthAuditLogIndexes = [
  // The console's default view, and the retention sweep's predicate.
  'CREATE INDEX IF NOT EXISTS idx_auth_audit_log_occurred '
      'ON auth_audit_log (occurred_at DESC)',
  // "Was my account compromised in March?" — the question this log exists to
  // answer is always scoped to one identity.
  'CREATE INDEX IF NOT EXISTS idx_auth_audit_log_email '
      'ON auth_audit_log (email, occurred_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_auth_audit_log_user '
      'ON auth_audit_log (user_id, occurred_at DESC)',
];

List<String> authAuditLogStatements() => [
  createAuthAuditLog,
  ...createAuthAuditLogIndexes,
];

/// The closed set of events §4.7 requires be recorded.
enum AuthAuditEvent {
  linkRequested('link_requested'),
  linkRedeemed('link_redeemed'),
  redemptionFailed('redemption_failed'),
  sessionCreated('session_created'),
  sessionRevoked('session_revoked'),
  rateLimitTripped('rate_limit_tripped'),
  authorizationDenied('authorization_denied'),

  // ---- Project joining (task 11.81) ---------------------------------------
  //
  // **These exist because finding Q-1's acceptance was superseded, not
  // forgotten.** Q-1 recorded that the project router writes no audit rows at
  // all, and that was accepted while the router only *issued invitations*.
  // Task 11.81 made it the place membership is **granted** — an owner's tap
  // now creates somebody else's access to a project holding collar locations —
  // and an unlogged grant is not something to accept. Michael settled this on
  // 2026-08-31 (decision 4).
  //
  // **What a row here may carry, so nobody has to re-derive it:** `user_id`
  // and `email` are the *subject* — the person joining or being decided about
  // — because "was my account compromised in March?" is asked of an account.
  // `outcome` carries the `project_id`, matching `authorization_denied`.
  // `reason` carries the *actor* and the role. **Never the join code**: this
  // table has no token column by construction (§4.7), and §4.2.1's exception
  // covers storing the code in `project_join_settings`, nothing else.

  /// Somebody asked to join a project. Written whether or not it succeeded —
  /// a refused request is the interesting one when reading this log later.
  joinRequested('join_requested'),

  /// An owner approved a request. **This is the grant**, and it is the row
  /// this whole group exists for.
  joinApproved('join_approved'),

  joinRejected('join_rejected'),

  /// A request was removed by a code rotation rather than decided on its
  /// merits.
  joinCleared('join_cleared'),

  joinCodeRotated('join_code_rotated'),

  /// Joining was switched on or off. `reason` says which.
  joiningSwitched('joining_switched'),

  teamSizeLimitChanged('team_size_limit_changed'),

  /// An owner put a past member back on a project directly, with no code and
  /// no request. The **second** way a membership row is granted, so it is
  /// logged as carefully as the first.
  memberReadmitted('member_readmitted'),

  // ---- Project destruction (task 11.290) ---------------------------------
  //
  // `outcome` carries the project id, matching `authorization_denied`;
  // `user_id` is the owner who acted. `reason` carries the date the server
  // set, or `immediate`. **These rows outlive the project on purpose** —
  // Michael, 2026-09-20: the audit log is out of scope of "gone" — so an
  // operator asked "what happened to project X" a month later can answer.

  /// An owner scheduled a project's destruction. `reason` is the destroy
  /// date the server chose.
  projectDeletionScheduled('project_deletion_scheduled'),

  /// An owner withdrew a scheduled destruction before it ran.
  projectDeletionCanceled('project_deletion_canceled'),

  /// The owner who deleted a project in the app brought it back on the
  /// server (task 11.302): its tombstone cleared, for every member. `reason`
  /// names the destroy date it also withdrew, when one was scheduled.
  projectRestored('project_restored'),

  /// The project and every row in it were deleted — by the sweep on its
  /// date (`user_id` is the owner who scheduled it) or by an owner's
  /// *immediate* request (`reason` says which).
  projectDestroyed('project_destroyed');

  const AuthAuditEvent(this.db);
  final String db;

  static AuthAuditEvent? fromDb(String? value) =>
      value == null ? null : values.firstWhere((e) => e.db == value);
}

/// One recorded authentication event.
class AuthAuditEntry {
  const AuthAuditEntry({
    required this.id,
    required this.occurredAt,
    required this.event,
    required this.userId,
    required this.email,
    required this.deviceId,
    required this.sourceAddress,
    required this.outcome,
    required this.reason,
    required this.requestId,
  });

  final int id;
  final DateTime occurredAt;
  final String event;
  final String? userId;
  final String? email;
  final String? deviceId;
  final String? sourceAddress;
  final String? outcome;
  final String? reason;
  final String? requestId;

  static AuthAuditEntry fromRow(Map<String, Object?> row) => AuthAuditEntry(
    id: row['id']! as int,
    occurredAt: row['occurred_at']! as DateTime,
    event: row['event']! as String,
    userId: row['user_id'] as String?,
    email: row['email'] as String?,
    deviceId: row['device_id'] as String?,
    sourceAddress: row['source_address'] as String?,
    outcome: row['outcome'] as String?,
    reason: row['reason'] as String?,
    requestId: row['request_id'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'occurred_at': occurredAt.toIso8601String(),
    'event': event,
    'user_id': userId,
    'email': email,
    'device_id': deviceId,
    'source_address': sourceAddress,
    'outcome': outcome,
    'reason': reason,
    'request_id': requestId,
  };
}

/// Longest value [AuthAuditLog.record] will store in any single free-text
/// column.
///
/// Task 10.30 (Security Model §7 D-2): the `outcome` column carries the
/// caller's `project_id` for an `authorization_denied` row
/// (`sync_routes.dart`), and `project_id` is entirely caller-controlled with
/// no length bound of its own — ten denied `/sync/pull` requests with a 1 MB
/// `project_id` each wrote 10 MB to `auth_audit_log` in under a second. Every
/// legitimate id, email, device id and trace id in this system is well under
/// this limit, so truncating costs nothing on the genuine-denial path C-5
/// exists to preserve; it only caps what an attacker can make one row cost.
/// Applied uniformly to every free-text field passed to [record] rather than
/// only `outcome`, so the next caller that puts caller-controlled text in a
/// different field does not reopen the same hole.
const int maxAuditFieldLength = 500;

String? _bounded(String? value) =>
    value == null || value.length <= maxAuditFieldLength
        ? value
        : value.substring(0, maxAuditFieldLength);

/// Writes and reads [createAuthAuditLog].
///
/// [session] must be a connection of its own, never one on loan from a
/// request's own transaction. `postgres` refuses a second statement on a
/// connection while that connection's own `runTx` is open (Security Model
/// §7.3 B5: `auditDenial` shared the sync handler's connection this way and
/// silently lost every `authorization_denied` row). A dedicated connection —
/// `bin/server.dart`'s `auditDb` — has no transaction of its own to collide
/// with, no matter what the calling request is in the middle of.
///
/// Recording is **best-effort and must never fail a request**: an audit write
/// that throws and propagates would turn a logging problem into an
/// availability problem on the sign-in path, and §1 ranks server availability
/// last but does not rank it at zero. [record] catches its own failures for
/// that reason — the alternative is that a full disk stops anyone signing in.
/// But "must not fail the request" is not "must not be noticed": [onError] is
/// required, not optional, so nothing can construct this class without
/// deciding what happens when a write is lost. The B5 bug above shipped with
/// an `onError` already wired to a `print` and still went undetected for a
/// whole gate — the fix is the dedicated connection, not a louder log line —
/// but a required callback at least makes "nobody is told" a compile error
/// rather than a default.
///
/// Note the asymmetry with the data-access log: `sync_traffic_log` writes
/// inside the sync transaction on purpose (a logged success for a push that
/// rolled back would be a lie about data). Auth events are observations about
/// requests, not claims about committed rows, so the same coupling would buy
/// nothing and cost the availability above.
class AuthAuditLog {
  const AuthAuditLog(this.session, {required this.onError});

  final Session session;

  /// Called with the failure's runtime type when a write fails. Never receives
  /// the exception itself — see `error_responses.dart` on why a Postgres
  /// message is not safe to log.
  final void Function(String) onError;

  Future<void> record(
    AuthAuditEvent event, {
    String? userId,
    String? email,
    String? deviceId,
    String? sourceAddress,
    String? outcome,
    String? reason,
    String? requestId,
  }) async {
    try {
      await session.execute(
        'INSERT INTO auth_audit_log '
        '(event, user_id, email, device_id, source_address, outcome, reason, '
        'request_id) '
        r'VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
        parameters: [
          event.db,
          _bounded(userId),
          _bounded(email),
          _bounded(deviceId),
          _bounded(sourceAddress),
          _bounded(outcome),
          _bounded(reason),
          _bounded(requestId),
        ],
      );
    } catch (error) {
      onError(error.runtimeType.toString());
    }
  }

  /// Most recent events, newest first, for the diagnostics console.
  Future<List<AuthAuditEntry>> recent({int limit = 100}) async {
    final result = await session.execute(
      'SELECT * FROM auth_audit_log ORDER BY occurred_at DESC LIMIT \$1',
      parameters: [limit],
    );
    return [for (final row in result) AuthAuditEntry.fromRow(row.toColumnMap())];
  }

  /// Events for one normalized email, newest first — the account-history
  /// question §4.7's one-year retention exists to answer.
  Future<List<AuthAuditEntry>> forEmail(String email, {int limit = 100}) async {
    final result = await session.execute(
      'SELECT * FROM auth_audit_log WHERE email = \$1 '
      'ORDER BY occurred_at DESC LIMIT \$2',
      parameters: [email, limit],
    );
    return [for (final row in result) AuthAuditEntry.fromRow(row.toColumnMap())];
  }
}
