/// Magic-link authentication (task 10.6).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'email_sender.dart';
import 'tokens.dart';

/// How long a magic link stays usable.
///
/// Fifteen minutes, reasoned against the actual use case: long enough for email
/// delivery plus walking to a laptop, short enough that a mailbox skimmed
/// tomorrow yields nothing.
const Duration magicLinkLifetime = Duration(minutes: 15);

/// Absolute session lifetime.
///
/// Ninety days is a long time for a bearer token and is accepted **only
/// because revocation is immediate and server-side** (§4.3). The two decisions
/// are a package: field devices go offline for weeks, and a session that
/// expires mid-season forces a sign-in exactly when there is no connectivity
/// to receive the email — the app would appear broken at the worst possible
/// moment. Do not shorten the revocation guarantee while keeping this.
const Duration sessionAbsoluteLifetime = Duration(days: 90);

/// Idle timeout — a session unused for this long stops working even if its
/// absolute lifetime has not run out.
const Duration sessionIdleLifetime = Duration(days: 30);

/// Most rows `GET /auth/sessions` will return (task 11.35).
///
/// A person's own live sessions across their real devices is a single-digit
/// number; this is a bound on the caller-influenced case, where one device
/// signs in over and over and accumulates rows. See
/// [AuthService.listSessionsForUser].
const int maxListedSessions = 100;

/// What happened to a magic link, from the *requesting* device's point of view.
enum LinkRequestOutcome {
  /// Consumed — but possibly on a different device. The requester gets this,
  /// never a session: the session belongs to whoever redeemed the link.
  consumed('consumed'),

  /// Expired without being used.
  expired('expired');

  const LinkRequestOutcome(this.db);
  final String db;

  static LinkRequestOutcome? fromDb(String? value) =>
      value == null ? null : values.firstWhere((o) => o.db == value);
}

/// One of the caller's own signed-in devices, as `GET /auth/sessions` reports
/// it (task 11.35).
///
/// **One row per device, not per session, and that is deliberate.** Signing in
/// twice on the same phone leaves two `auth_sessions` rows, and
/// `/auth/sessions/revoke-device` ends both of them together — it is keyed on
/// `(user_id, device_id)`. A list that showed two rows for one phone would
/// offer a revoke control that silently also closed the row next to it. So the
/// list is aggregated to the same granularity the revocation has, and a person
/// reading it sees devices, which is what they were trying to count.
///
/// **What is absent is the point of this class.** There is no token, no token
/// hash, and — the one that took a decision rather than an omission — **no
/// source address.** The route exists so a person can pick their lost phone
/// out of a list and revoke it; a device id and a last-used time do that. An
/// address would add nothing to that job and would put a record of where each
/// of a person's devices last was onto a new read surface, which §4.7 keeps
/// out of everything else a caller can fetch. If a future task needs "where
/// was this signed in from", it is a diagnostics question with its own
/// authorization, not a field on this row.
///
/// **There is also no device *label*, because the server does not store one.**
/// `auth_sessions.device_id` is the client's install id and the only thing
/// naming a device anywhere in the schema. Inventing a friendly name here —
/// from a user agent, say — would be a guess presented as a fact, so the row
/// carries the id and [isCurrentDevice], and a screen can say "this device"
/// for the one the caller is holding.
class ListedSession {
  const ListedSession({
    required this.deviceId,
    required this.firstSignedInAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.isCurrentDevice,
  });

  final String deviceId;

  /// When the **oldest** live session on this device started.
  final DateTime firstSignedInAt;

  /// When the device most recently made a request.
  final DateTime lastSeenAt;

  /// When the **longest-lived** session on this device runs out — the honest
  /// answer to "when does this device stop working if I do nothing", since the
  /// device keeps access until its last session expires.
  final DateTime expiresAt;

  /// Whether this is the device the request arrived on — so a screen can warn
  /// before someone revokes the device they are holding.
  final bool isCurrentDevice;
}

/// A minted session, returned only to the device that redeemed the link.
class IssuedSession {
  const IssuedSession({
    required this.token,
    required this.sessionId,
    required this.userId,
    required this.email,
    required this.expiresAt,
  });

  /// The plaintext bearer token. Exists in memory here and in the HTTP response
  /// exactly once, and is never stored anywhere server-side except as a hash.
  final String token;

  final String sessionId;

  /// **The server's authoritative `user_id` for this email.** The client adopts
  /// this and remaps its local rows onto it; it does not keep its own locally
  /// minted id and does not negotiate.
  final String userId;

  /// Normalized email, echoed so the client can confirm which identity it just
  /// adopted without having to re-derive it.
  final String email;

  final DateTime expiresAt;
}

/// A validated session, as resolved from a bearer token on each request.
class ActiveSession {
  const ActiveSession({
    required this.sessionId,
    required this.userId,
    required this.deviceId,
  });

  final String sessionId;
  final String userId;
  final String deviceId;
}

class AuthService {
  AuthService({
    required this.session,
    required this.emailSender,
    required this.linkBaseUrl,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Session session;
  final EmailSender emailSender;

  /// Base URL the emailed link points at, e.g. `http://192.168.1.42:8080`.
  final String linkBaseUrl;

  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  /// Starts a sign-in. Returns the request id the caller can poll.
  ///
  /// **This deliberately reveals nothing about whether [rawEmail] is
  /// registered** (§4.5). Concretely:
  ///
  /// - No account row is created here. Creating one would make an
  ///   unauthenticated endpoint a database-writer *and* a second enumeration
  ///   oracle (row exists ⇒ address was requested). Accounts are created on
  ///   redemption, behind proof of mailbox control.
  /// - A link is sent to *any* syntactically plausible address, registered or
  ///   not, so the registered and unregistered paths do identical work.
  /// - The email body carries no caller-supplied content, so this cannot be
  ///   used as a message-delivery channel. The residual risk — TriTrack can be
  ///   induced to send a small number of emails to an arbitrary address — is
  ///   accepted and bounded by the rate limits task 10.14 adds here.
  ///
  /// The caller is responsible for returning an identical HTTP response
  /// regardless of what this does, including on failure.
  Future<String> requestMagicLink({
    required String rawEmail,
    required String requestId,
    // Task 11.293. Forwarded verbatim to `emailSender.sendMagicLink` — see
    // that method and `EmailSender.sendMagicLink` for why this cannot be an
    // `await` here without re-opening the timing oracle task 11.287 closed.
    void Function(bool delivered)? onDeliveryOutcome,
  }) async {
    final email = normalizeEmail(rawEmail);
    final token = Tokens.generate();
    final tokenHash = Tokens.hash(token);
    final now = _now;
    final expiresAt = now.add(magicLinkLifetime);

    await session.execute(
      // One live link per address: tapping "resend" three times leaves one
      // usable token, not three.
      r'UPDATE auth_magic_links SET consumed_at = $1 '
      r'WHERE email = $2 AND consumed_at IS NULL',
      parameters: [now, email],
    );
    await session.execute(
      r'INSERT INTO auth_magic_links (token_hash, email, created_at, expires_at) '
      r'VALUES ($1, $2, $3, $4)',
      parameters: [tokenHash, email, now, expiresAt],
    );
    await session.execute(
      r'INSERT INTO auth_link_requests (request_id, token_hash, created_at, expires_at) '
      r'VALUES ($1, $2, $3, $4)',
      parameters: [requestId, tokenHash, now, expiresAt],
    );

    // Fire-and-forget on purpose: the HTTP response must not vary in latency
    // with whether delivery succeeded, or timing becomes the enumeration
    // oracle the identical response body was meant to close.
    emailSender.sendMagicLink(
      email: email,
      url: '$linkBaseUrl/auth/redeem?token=$token',
      expiresAt: expiresAt,
      onOutcome: onDeliveryOutcome,
    );

    return requestId;
  }

  /// Consumes [token] and mints a session for [deviceId].
  ///
  /// Returns null if the token is unknown, already consumed, or expired — the
  /// caller must render all three identically.
  ///
  /// **The session belongs to the device that redeemed the link**, never to the
  /// device that requested it. A link requested on a laptop and opened on a
  /// phone signs in the phone.
  Future<IssuedSession?> redeem({
    required String token,
    required String deviceId,
    required String sessionId,
    required String newUserId,
  }) async {
    final tokenHash = Tokens.hash(token);
    final now = _now;

    // Single-use, done as ONE atomic statement. A SELECT-then-UPDATE here is a
    // race in which two concurrent redemptions both succeed; the conditional
    // UPDATE makes the loser return zero rows.
    final consumed = await session.execute(
      r'UPDATE auth_magic_links SET consumed_at = $1 '
      r'WHERE token_hash = $2 AND consumed_at IS NULL AND expires_at > $1 '
      r'RETURNING email',
      parameters: [now, tokenHash],
    );
    if (consumed.isEmpty) return null;
    final email = consumed.first.first! as String;

    // Account created here, on proof of mailbox control — not at request time.
    // ON CONFLICT makes this idempotent for the normal case of an existing
    // account, and the RETURNING/SELECT pair resolves the id either way.
    final inserted = await session.execute(
      r'INSERT INTO auth_accounts (user_id, email, created_at) '
      r'VALUES ($1, $2, $3) '
      r'ON CONFLICT (email) DO NOTHING RETURNING user_id',
      parameters: [newUserId, email, now],
    );
    final String userId;
    if (inserted.isNotEmpty) {
      userId = inserted.first.first! as String;
    } else {
      // The address already had an account. This is the path that makes the
      // server authoritative: a second device signing in to the same email
      // gets the *same* user_id, which is what stops the two devices renaming
      // each other forever under continuous sync.
      final existing = await session.execute(
        r'SELECT user_id FROM auth_accounts WHERE email = $1',
        parameters: [email],
      );
      userId = existing.first.first! as String;
    }

    final sessionToken = Tokens.generate();
    final expiresAt = now.add(sessionAbsoluteLifetime);
    await session.execute(
      r'INSERT INTO auth_sessions '
      r'(session_id, token_hash, user_id, device_id, created_at, last_seen_at, expires_at) '
      r'VALUES ($1, $2, $3, $4, $5, $5, $6)',
      parameters: [
        sessionId,
        Tokens.hash(sessionToken),
        userId,
        deviceId,
        now,
        expiresAt,
      ],
    );

    // Let the requesting device stop waiting. It learns only that its link was
    // used — not by whom, and it gets no session out of it.
    await session.execute(
      r'UPDATE auth_link_requests SET outcome = $1 WHERE token_hash = $2',
      parameters: [LinkRequestOutcome.consumed.db, tokenHash],
    );

    return IssuedSession(
      token: sessionToken,
      sessionId: sessionId,
      userId: userId,
      email: email,
      expiresAt: expiresAt,
    );
  }

  /// State of a magic-link request, for the requesting device to poll.
  ///
  /// Returns null for an unknown request id. Deliberately carries no email and
  /// no user id, so guessing a request id reveals nothing about whose it was.
  Future<LinkRequestOutcome?> linkRequestOutcome(String requestId) async {
    final result = await session.execute(
      r'SELECT outcome, expires_at FROM auth_link_requests WHERE request_id = $1',
      parameters: [requestId],
    );
    if (result.isEmpty) return null;
    final recorded = LinkRequestOutcome.fromDb(result.first[0] as String?);
    if (recorded != null) return recorded;
    final expiresAt = result.first[1] as DateTime;
    // Expiry is derived rather than swept, so a link nobody ever opens still
    // resolves to a definite answer instead of leaving the requester spinning.
    if (!_now.isBefore(expiresAt)) return LinkRequestOutcome.expired;
    return null;
  }

  /// Resolves a bearer token to a live session, or null.
  ///
  /// Checked on **every** request, which is what makes revocation immediate:
  /// there is no cached decision to go stale, and no in-flight operation gets
  /// grandfathered. A chunked sync that is 80% done and gets revoked stops.
  Future<ActiveSession?> validateSession(String token) async {
    final now = _now;
    final idleFloor = now.subtract(sessionIdleLifetime);
    // The freshness conditions live in the UPDATE so validation and the
    // last_seen_at bump cannot disagree, and so a revoked or expired session
    // can never have its clock refreshed as a side effect of being rejected.
    final result = await session.execute(
      r'UPDATE auth_sessions SET last_seen_at = $1 '
      r'WHERE token_hash = $2 AND revoked_at IS NULL '
      r'AND expires_at > $1 AND last_seen_at > $3 '
      r'RETURNING session_id, user_id, device_id',
      parameters: [now, Tokens.hash(token), idleFloor],
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return ActiveSession(
      sessionId: row[0]! as String,
      userId: row[1]! as String,
      deviceId: row[2]! as String,
    );
  }

  /// Signs out one session — the ordinary "sign out" button.
  ///
  /// Signing out must leave the app **fully functional locally**, not degraded:
  /// nothing about local recording, mapping, or estimation depends on a server.
  /// That is a client-side guarantee; here it just means we revoke the row and
  /// take nothing else away.
  Future<void> signOut(String token) async {
    await session.execute(
      r'UPDATE auth_sessions SET revoked_at = $1, revoked_reason = $2 '
      r'WHERE token_hash = $3 AND revoked_at IS NULL',
      parameters: [_now, 'signed_out', Tokens.hash(token)],
    );
  }

  /// Revokes **every** session a user holds, on every device.
  ///
  /// The mechanism task 10.14 hardens and task 11.2 calls on member removal.
  /// It exists here because sessions are per-device by design, which makes
  /// "revoke the one that happened to make the last request" the natural-looking
  /// and completely inadequate implementation — a removed member's other phone
  /// would keep syncing, which is the same as not revoking at all.
  Future<int> revokeAllSessionsForUser(
    String userId, {
    String reason = 'revoked',
  }) async {
    final result = await session.execute(
      r'UPDATE auth_sessions SET revoked_at = $1, revoked_reason = $2 '
      r'WHERE user_id = $3 AND revoked_at IS NULL RETURNING session_id',
      parameters: [_now, reason, userId],
    );
    return result.length;
  }

  /// The caller's own signed-in devices, most recently used first (task
  /// 11.35).
  ///
  /// **[userId] is the caller's, resolved from the validated session by the
  /// route, and it is the only thing this query is keyed on.** There is no
  /// argument by which somebody else's rows could be named — the same shape as
  /// the two revocation methods above, and the reason those were found
  /// correctly built.
  ///
  /// Revoked, expired and idled-out sessions are excluded by the same three
  /// conditions [validateSession] enforces, so the list contains exactly the
  /// devices that would still work if used right now. Aggregated per device
  /// for the reason [ListedSession] gives.
  ///
  /// [limit] bounds the result because the row count is caller-influenced: a
  /// caller can mint device ids freely, and an unbounded `SELECT` on a route
  /// anyone signed in can call is task 10.56's finding in a new place. Real
  /// devices will not approach it.
  Future<List<ListedSession>> listSessionsForUser(
    String userId, {
    required String currentDeviceId,
    int limit = maxListedSessions,
  }) async {
    final now = _now;
    final idleFloor = now.subtract(sessionIdleLifetime);
    final result = await session.execute(
      r'SELECT device_id, min(created_at), max(last_seen_at), max(expires_at) '
      r'FROM auth_sessions '
      r'WHERE user_id = $1 AND revoked_at IS NULL '
      r'AND expires_at > $2 AND last_seen_at > $3 '
      r'GROUP BY device_id '
      r'ORDER BY max(last_seen_at) DESC, device_id '
      r'LIMIT $4',
      parameters: [userId, now, idleFloor, limit],
    );
    return [
      for (final row in result)
        ListedSession(
          deviceId: row[0]! as String,
          firstSignedInAt: row[1]! as DateTime,
          lastSeenAt: row[2]! as DateTime,
          expiresAt: row[3]! as DateTime,
          isCurrentDevice: row[0] == currentDeviceId,
        ),
    ];
  }

  /// Revokes one device's sessions without signing the user out everywhere —
  /// the practical mitigation for a lost or stolen field device (§4.8).
  Future<int> revokeDeviceSessions(
    String userId,
    String deviceId, {
    String reason = 'device_revoked',
  }) async {
    final result = await session.execute(
      r'UPDATE auth_sessions SET revoked_at = $1, revoked_reason = $2 '
      r'WHERE user_id = $3 AND device_id = $4 AND revoked_at IS NULL '
      r'RETURNING session_id',
      parameters: [_now, reason, userId, deviceId],
    );
    return result.length;
  }
}
