/// HTTP surface for magic-link authentication (task 10.6).
library;

import 'dart:async' show Completer, unawaited;
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart' show normalizeEmail;

import '../security/audit_log.dart';
import '../security/error_responses.dart';
import '../security/rate_limiter.dart';
import '../security/request_identity.dart';
import '../security/security_headers.dart';
import 'auth_service.dart';
import 'smtp_email_sender.dart' show isDeliverableAddress;

/// Generates the ids the auth flow needs (request ids, session ids, account
/// ids). Injectable so tests are deterministic.
typedef IdGenerator = String Function();

/// The uniform response for a sign-in request.
///
/// **Byte-identical for a registered address, an unregistered one, a
/// rate-limited one, and a delivery failure** — that identity is the whole
/// anti-enumeration control (§4.5), and it is easy to break by adding a
/// helpful detail later. There is deliberately nothing here to vary.
Response _acceptedSignIn(String requestId) => Response(
  202,
  body: jsonEncode({'status': 'sent', 'request_id': requestId}),
  headers: const {'content-type': 'application/json'},
);

/// The uniform failure for redemption.
///
/// Unknown token, already-consumed token, and expired token all land here. A
/// caller must not be able to tell which — "already used" would confirm a
/// guessed token was once real.
Response _redemptionFailed() => Response(
  400,
  body: jsonEncode({'error': 'invalid_or_expired_link'}),
  headers: const {'content-type': 'application/json'},
);

/// Largest body either auth route will read.
///
/// Both are unauthenticated, and `readAsString()` is otherwise unbounded — a
/// single multi-gigabyte POST is a memory-exhaustion primitive that costs the
/// attacker nothing (§3.1 names request body size limits as a control). Two
/// kilobytes is generous for `{"email": "...", "token": "...",
/// "device_id": "..."}`: the longest legal address is 320 bytes and a token is
/// 43.
const int _maxAuthBodyBytes = 2048;

/// Reads a request body, refusing anything oversized.
///
/// Returns null when the body is too large or not a JSON object; the caller
/// turns that into a uniform 400.
Future<Map<String, Object?>?> _readJsonBody(Request request) async {
  final declared = request.contentLength;
  if (declared != null && declared > _maxAuthBodyBytes) return null;
  final buffer = <int>[];
  await for (final chunk in request.read()) {
    buffer.addAll(chunk);
    // Checked while streaming too, because Content-Length is caller-supplied
    // and a chunked request need not declare one at all.
    if (buffer.length > _maxAuthBodyBytes) return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(buffer));
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Whether [value] is an address this server will actually send a sign-in
/// link to — **the sender's own rule, applied at the boundary to the exact
/// string the sender will be handed.**
///
/// **Task 11.298.** Until then this was a deliberately loose shape check —
/// 3–320 characters, one `@` not at either end, no spaces, no control
/// characters, commas or semicolons — whose comment said *"rejecting unusual
/// but valid addresses would lock real collaborators out."* The sender it fed
/// ([isDeliverableAddress], the header-injection control) is strict ASCII, so
/// `üser@example.com`, `josé@universidad.mx` and `user@[192.168.1.1]` passed
/// here and were refused there (the plan also named `"odd name"@example.com`;
/// that one the old check already refused, for its space). Reproduced on
/// 2026-09-21 against a live relay: a `202`, no message, and an
/// `outcome=undelivered` audit row nobody outside the container can see. **The
/// permissive check did not keep those people in; it kept them from being
/// told.** They now get `400 invalid_email`, which the app renders as a
/// sentence about the address they typed.
///
/// **Why this is not a §4.5 disclosure.** §4.5 forbids the response varying
/// between a registered and an unregistered address — a fact about server
/// state. This answer varies with the *syntax of the string the caller just
/// supplied*, a fact the caller already holds, computed by a fixed rule that is
/// the same on every deployment and readable in this repository; a caller can
/// get the same verdict without asking the server. The boundary has answered
/// `400` to a malformed address on exactly that footing since it was written;
/// this only makes the rule it applies the true one. The argument is written
/// out in Security Model §4.5, with the reopen trigger — the day this rule
/// becomes a runtime property of the relay rather than a constant, a `400`
/// starts to fingerprint the deployment and that paragraph has to be re-read.
///
/// **Why [normalizeEmail] first.** `AuthService.requestMagicLink` normalizes
/// (trims, lowercases) before handing the address to the sender, so the string
/// the sender judges is the normalized one, and this check judges that same
/// string rather than the raw input. The difference is real at the edges:
/// Dart's `toLowerCase` folds the Kelvin sign `K` (U+212A) to an ASCII `k`, so
/// a raw-string check here would refuse an address the sender would carry.
///
/// **The injection control is unchanged and lives in one place.** The old
/// boundary check's real job — refusing CR, LF and the other C0 controls
/// before an address could reach a `To:` header or a `RCPT TO` line, and
/// commas and semicolons because several mail APIs read them as recipient
/// separators — is a strict subset of what [isDeliverableAddress] refuses, and
/// the sender still applies that rule itself on every path, independently of
/// anything a route did (see its doc comment). Sharing the predicate does not
/// make the sender trust this boundary; it makes this boundary stop lying
/// about the sender.
///
/// **Kept equal to the sender by a test, not by good intentions:**
/// `server/test/auth/sign_in_address_rule_test.dart` asserts, over a corpus of
/// tens of thousands of generated strings, that this function and
/// `isDeliverableAddress(normalizeEmail(s))` agree on every one of them, in
/// both directions. A boundary looser than the sender is this task's silent
/// trapdoor; a boundary stricter than it refuses somebody the mail path could
/// have served. Either divergence goes red.
bool isAcceptableSignInAddress(String value) =>
    isDeliverableAddress(normalizeEmail(value));

/// Whether [value] contains a NUL byte (task 10.64, finding J-4's class).
///
/// A NUL byte survives `jsonDecode` and URL percent-decoding alike — a JSON
/// string may carry one escaped as `\\u0000`, and a path segment may carry
/// one as `%00` — and Postgres `TEXT` cannot: a NUL byte in a bound
/// parameter throws an `invalid_byte_sequence` error the driver raises
/// directly, not through any typed refusal this file writes. Two
/// caller-supplied values on these routes reach `TEXT` columns unhashed and
/// unfiltered — `device_id` (see [_isUsableDeviceId]) and the `request_id`
/// path segment on `/auth/link-status/<requestId>` below. `token` is always
/// hashed first (`Tokens.hash`), and `email` is already excluded by
/// [isAcceptableSignInAddress], whose rule admits no control character.
bool _hasNulByte(String value) => value.contains('\u0000');

/// Whether [value] is usable as a `device_id`: right shape, and no NUL byte
/// (task 10.64, finding J-4's class, checked here too rather than only on the
/// sync routes it was found on). `device_id` reaches `auth_sessions.device_id`
/// as raw, unhashed caller input — see [_hasNulByte].
bool _isUsableDeviceId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 200 &&
    !_hasNulByte(value);

/// Builds the auth routes.
///
/// [withAuthService] supplies a per-call database session. It is expected to
/// wrap the action in a **transaction** — `redeem` issues several statements
/// (consume the token, upsert the account, create the session, record the
/// outcome) and a failure partway through would otherwise burn a single-use
/// token without minting a session, leaving the user with a dead link and no
/// way to tell why. `bin/server.dart` supplies `Connection.runTx`.
///
/// [rateLimiter] enforces §4.4's per-email and per-source limits. Supplied
/// rather than constructed so its counters outlive a single request — they are
/// in-process state, which §4.4 flags as a prototype-only shortcut that must
/// move to Postgres or Redis before any multi-instance deployment.
///
/// [withAuditLog] records §4.7's authentication events. Separate from
/// [withAuthService] because an audit write must not join the auth
/// transaction: a rate-limit trip or a redemption failure has no transaction
/// to join, and rolling back the record of a failed attempt alongside the
/// failure would erase exactly the evidence the log exists for.
///
/// [sourceIdentity] decides what "the caller's address" means for [rateLimiter]
/// and for the audit log (task 10.52, §4.4). It defaults to no trusted proxy at
/// all, which reads the TCP peer and never a header — the behaviour that
/// shipped before this task, and still the right one for a directly-bound
/// server.
Router createAuthRouter({
  required Future<T> Function<T>(Future<T> Function(AuthService) action)
  withAuthService,
  required IdGenerator newId,
  RateLimiter? rateLimiter,
  Future<void> Function(Future<void> Function(AuthAuditLog) action)?
  withAuditLog,
  SourceIdentity? sourceIdentity,
}) {
  final router = Router();
  final limiter = rateLimiter ?? RateLimiter();
  final sources = sourceIdentity ?? SourceIdentity();

  Future<void> audit(
    AuthAuditEvent event, {
    String? userId,
    String? email,
    String? deviceId,
    RequestSource? source,
    String? outcome,
    String? reason,
    String? requestId,
  }) async {
    final write = withAuditLog;
    if (write == null) return;
    // `auditValue`, not the raw address: behind a trusted proxy this is the
    // client rather than the proxy, and a proxy that named nobody records an
    // honest marker instead of a machine that did not send the request
    // (task 10.52, §4.7). §11.3's "158 events, one distinct source_address" is
    // what the old behaviour produced.
    final sourceAddress = source?.auditValue;
    await write(
      (log) => log.record(
        event,
        userId: userId,
        email: email,
        deviceId: deviceId,
        sourceAddress: sourceAddress,
        outcome: outcome,
        reason: reason,
        requestId: requestId,
      ),
    );
  }

  // ---- Request a link -------------------------------------------------------

  router.post('/auth/magic-link', (Request request) async {
    final correlationId = traceIdOf(request);
    final json = await _readJsonBody(request);
    if (json == null) {
      return errorResponse(400, 'malformed_body', traceId: correlationId);
    }
    final email = json['email'];
    // A malformed *request* is a caller error and can be reported as one —
    // it says nothing about whether any address is registered.
    if (email is! String || !isAcceptableSignInAddress(email)) {
      return errorResponse(400, 'invalid_email', traceId: correlationId);
    }

    final source = sources.of(request);
    final normalized = normalizeEmail(email);
    final requestId = newId();

    limiter.evictExpired();
    final verdict = limiter.checkMagicLink(email: normalized, source: source);

    if (verdict == RateLimitOutcome.sourceLimited) {
      // Honest 429: this fact is about the caller, not about any third party
      // (§4.4). The audit row is how an operator sees a flood at all, since the
      // caller is told but nobody else would be.
      await audit(
        AuthAuditEvent.rateLimitTripped,
        email: normalized,
        source: source,
        outcome: 'source_limited',
        reason: 'magic_link',
        requestId: correlationId,
      );
      return errorResponse(429, 'rate_limited', traceId: correlationId);
    }

    if (verdict == RateLimitOutcome.emailLimited) {
      // **Silently the same 202, and deliberately no email.** A 429 keyed on an
      // address would tell this caller that somebody recently requested links
      // for it — a real oracle about a third party, and the one thing §4.5's
      // byte-identical response exists to prevent. The trip is recorded where
      // only an operator can see it.
      await audit(
        AuthAuditEvent.rateLimitTripped,
        email: normalized,
        source: source,
        outcome: 'email_limited',
        reason: 'magic_link',
        requestId: correlationId,
      );
      return _acceptedSignIn(requestId);
    }

    var outcome = 'sent';
    // Completed once this request's own audit row is written, below. The
    // detached delivery's failure row waits on it — see `onDeliveryOutcome`.
    final requestRowWritten = Completer<void>();
    try {
      await withAuthService(
        (auth) => auth.requestMagicLink(
          rawEmail: email,
          requestId: requestId,
          // Task 11.293. Delivery is detached (§4.5, §7.6): the sender
          // reports from its own future, after `sendMagicLink` has returned
          // (that much `EmailSender` promises). So it cannot change
          // `outcome` below; it writes its own row instead, which is the
          // whole reason there are two rows rather than one edited in place:
          // the row below stays an honest record of what this request knew
          // when it answered.
          //
          // **Task 11.298: "after `sendMagicLink` returned" is not "after
          // this request's row is written".** 11.293's comment here claimed
          // the latter, and it was only ever true because a relay round trip
          // is slower than a Postgres commit. A sender that refuses at once —
          // an address it will not put on the wire, a relay with its port
          // closed — reported before this handler reached its own audit
          // write, and the `undelivered` row landed *ahead* of the `sent`
          // row: measured on 2026-09-21, 2 ms apart, on a live server. So the
          // order is now held by construction rather than by timing: the
          // failure row is written only after [requestRowWritten] completes,
          // and nothing on this path is awaited by the request, so it cannot
          // lengthen the response either — which is the §4.5 property, and
          // the one that matters more than the order.
          onDeliveryOutcome: (delivered) {
            if (delivered) return;
            unawaited(
              requestRowWritten.future.then(
                (_) => audit(
                  AuthAuditEvent.linkRequested,
                  email: normalized,
                  source: source,
                  outcome: 'undelivered',
                  requestId: correlationId,
                ),
              ),
            );
          },
        ),
      );
    } catch (_) {
      // Swallowed on purpose. An internal failure must not produce a different
      // response for some addresses than others; the caller always gets the
      // same 202. Operational visibility comes from the audit log below, which
      // records the failure without echoing anything to the caller.
      outcome = 'internal_error';
    }
    try {
      await audit(
        AuthAuditEvent.linkRequested,
        email: normalized,
        source: source,
        outcome: outcome,
        requestId: correlationId,
      );
    } finally {
      // Completed even if the write above threw: a delivery report that is
      // already waiting must not wait forever, and a second row after a
      // failed first one is harmless where a stranded future is a leak.
      requestRowWritten.complete();
    }
    return _acceptedSignIn(requestId);
  });

  // ---- Poll a request's outcome --------------------------------------------

  // Lets the *requesting* device stop waiting when its link was opened
  // somewhere else. Returns only 'pending' | 'consumed' | 'expired' — never a
  // session, and never anything identifying. See `createAuthLinkRequests`.
  //
  // Unauthenticated, like `/auth/magic-link` and `/auth/redeem` above it — and
  // until task 10.56 (finding I-6), the one unauthenticated route with no
  // bound and no rate limit at all: 60 requests all answered `200`, none
  // refused, none audited, contradicting §3.1's "rate limits on the
  // unauthenticated routes". Both gaps are closed the same way the other two
  // routes already were, rather than left as the exception.
  router.get('/auth/link-status/<requestId>', (
    Request request,
    String requestId,
  ) async {
    final correlationId = traceIdOf(request);
    // `request_id` is a server-generated UUID (`newId()` in `router.dart`),
    // always 36 characters. Bounded before it reaches a query for the same
    // reason `device_id` is bounded elsewhere in this file: an unauthenticated
    // caller must not be able to hand the server an arbitrarily large string
    // to hold and compare.
    //
    // NUL-checked too (task 10.64, finding J-4's class) — a third instance
    // found by asking [_hasNulByte]'s question of every route that binds a
    // caller-supplied value into `TEXT` unhashed: this path segment reaches
    // `linkRequestOutcome`'s `WHERE request_id = $1` the same raw way
    // `device_id` reaches `auth_sessions`, and it is reachable with **no
    // authentication at all**, unlike either `device_id` site.
    if (requestId.isEmpty || requestId.length > 200 || _hasNulByte(requestId)) {
      return errorResponse(400, 'invalid_request_id', traceId: correlationId);
    }

    final source = sources.of(request);
    limiter.evictExpired();
    if (limiter.checkLinkStatus(source: source) ==
        RateLimitOutcome.sourceLimited) {
      await audit(
        AuthAuditEvent.rateLimitTripped,
        source: source,
        outcome: 'source_limited',
        reason: 'link_status',
        requestId: correlationId,
      );
      return errorResponse(429, 'rate_limited', traceId: correlationId);
    }

    final outcome = await withAuthService(
      (auth) => auth.linkRequestOutcome(requestId),
    );
    // An unknown request id and a pending one answer identically, so a guessed
    // id cannot be confirmed as real.
    return Response.ok(
      jsonEncode({'status': outcome?.db ?? 'pending'}),
      headers: const {'content-type': 'application/json'},
    );
  });

  // ---- Redemption landing page (GET — does NOT consume) --------------------

  // **This route must never consume the token.** Corporate mail scanners and
  // messaging-app link previewers prefetch URLs; a GET-consumes design lets a
  // scanner silently burn the single-use token so the user's link is dead on
  // arrival. That reads as a broken sign-in and invites someone to "fix" it by
  // making tokens reusable. It also means any intermediary that logs URLs has
  // logged a working credential.
  router.get('/auth/redeem', (Request request) {
    final token = request.url.queryParameters['token'];
    // A nonce, not `'unsafe-inline'`: this is the only HTML the server serves
    // and it renders a live magic-link token, which is precisely the value an
    // injected script would want. A nonce permits exactly this response's own
    // style and script block and nothing else.
    final nonce = cspNonce();
    final policy =
        "default-src 'none'; style-src 'nonce-$nonce'; "
        "script-src 'nonce-$nonce'; frame-ancestors 'none'; base-uri 'none'; "
        "form-action 'none'";
    final headers = {
      'content-type': 'text/html; charset=utf-8',
      // Keep the token out of caches and out of any referrer sent to a third
      // party if the page ever grows an outbound link.
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
      contentSecurityPolicyHeader: policy,
    };
    if (token == null || token.isEmpty) {
      // HTML, not the JSON error shape: this route is reached by a person's
      // browser clicking a mail link, and a raw JSON blob is a worse answer to
      // "your link is malformed" than a sentence is. It still discloses
      // nothing — there is no detail here beyond what the caller already sent.
      return Response(400, body: _redeemErrorPage(nonce), headers: headers);
    }
    return Response.ok(_redeemLandingPage(token, nonce), headers: headers);
  });

  // ---- Redemption (POST — consumes) ---------------------------------------

  router.post('/auth/redeem', (Request request) async {
    final correlationId = traceIdOf(request);
    final source = sources.of(request);

    limiter.evictExpired();
    if (limiter.checkRedemption(source: source) ==
        RateLimitOutcome.sourceLimited) {
      // Bounds token-guessing volume from one source. Honest 429 — a
      // redemption attempt carries no third party's address, so there is
      // nothing here that telling the caller could disclose about anyone else.
      await audit(
        AuthAuditEvent.rateLimitTripped,
        source: source,
        outcome: 'source_limited',
        reason: 'redemption',
        requestId: correlationId,
      );
      return errorResponse(429, 'rate_limited', traceId: correlationId);
    }

    final json = await _readJsonBody(request);
    if (json == null) {
      return errorResponse(400, 'malformed_body', traceId: correlationId);
    }
    final token = json['token'];
    final deviceId = json['device_id'];
    if (token is! String || token.isEmpty) return _redemptionFailed();
    // Bounded and NUL-free because it is stored verbatim in a TEXT column —
    // see [_isUsableDeviceId].
    if (!_isUsableDeviceId(deviceId)) {
      return errorResponse(400, 'missing_device_id', traceId: correlationId);
    }
    // Safe now that [_isUsableDeviceId] has confirmed the type.
    final safeDeviceId = deviceId as String;

    final issued = await withAuthService(
      (auth) => auth.redeem(
        token: token,
        deviceId: safeDeviceId,
        sessionId: newId(),
        newUserId: newId(),
      ),
    );
    if (issued == null) {
      // No email is recorded: a failed redemption means the token matched
      // nothing, so the server does not know whose address was involved and
      // must not guess.
      await audit(
        AuthAuditEvent.redemptionFailed,
        deviceId: safeDeviceId,
        source: source,
        outcome: 'invalid_or_expired',
        requestId: correlationId,
      );
      return _redemptionFailed();
    }

    await audit(
      AuthAuditEvent.linkRedeemed,
      userId: issued.userId,
      email: issued.email,
      deviceId: safeDeviceId,
      source: source,
      outcome: 'redeemed',
      requestId: correlationId,
    );
    // A distinct event from the redemption, because §4.7 lists both and they
    // are not the same fact: a redemption is a claim about a token, a session
    // creation is a new credential existing. `session_id` is safe to record;
    // the token is not, and there is nowhere in the audit table to put one.
    await audit(
      AuthAuditEvent.sessionCreated,
      userId: issued.userId,
      email: issued.email,
      deviceId: deviceId,
      source: source,
      outcome: issued.sessionId,
      requestId: correlationId,
    );

    return Response.ok(
      jsonEncode({
        // The one and only time this value leaves the server.
        'session_token': issued.token,
        // The authoritative identity the client must adopt.
        'user_id': issued.userId,
        'email': issued.email,
        'expires_at': issued.expiresAt.toIso8601String(),
      }),
      headers: const {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );
  });

  // ---- Sign out ------------------------------------------------------------

  router.post('/auth/sign-out', (Request request) async {
    final token = bearerToken(request);
    // Idempotent and uninformative: signing out with a token that was never
    // valid succeeds. There is nothing useful to tell the caller, and a
    // difference here would confirm whether a token existed.
    if (token != null) {
      final session = await withAuthService((auth) async {
        // Resolved before revoking so the audit row can name who it was.
        // Validation also refreshes `last_seen_at`, which is harmless on a
        // session about to be revoked in the same transaction.
        final active = await auth.validateSession(token);
        await auth.signOut(token);
        return active;
      });
      await audit(
        AuthAuditEvent.sessionRevoked,
        userId: session?.userId,
        deviceId: session?.deviceId,
        source: sources.of(request),
        outcome: session?.sessionId,
        reason: 'signed_out',
        requestId: traceIdOf(request),
      );
    }
    return Response.ok(
      jsonEncode({'status': 'signed_out'}),
      headers: const {'content-type': 'application/json'},
    );
  });

  // ---- Revocation, the two granularities §4.3 requires ---------------------

  // **Both routes are self-service only: the user revoked is always the
  // authenticated caller.** The `user_id` is taken from the validated session,
  // never from the request body — the §4.11 rule that authorization inputs
  // never come from client-supplied values, applied to a route whose whole
  // purpose is destroying credentials.
  //
  // There is deliberately **no cross-user revocation route.** Member removal
  // does **not** call `AuthService.revokeAllSessionsForUser` — this comment
  // used to claim it did, and task 11.27 corrected it (2026-08-22). Sessions
  // belong to a person, not a project: revoking them on removal from one
  // project would sign that person out of every other project they hold,
  // which is the assumption Phase 11 exists to break. The mechanism that
  // actually makes removal immediate is `ProjectAuthorizer.resolve` running
  // fresh on every request with no cached decision (§4.3) — a removed
  // member's session stays valid, and their next request to *that* project is
  // refused anyway, measured in
  // `server/test/integration/membership_and_joining_test.dart`. Exposing an
  // HTTP endpoint that revokes someone else's sessions would mean building an
  // authorization model for it now, with no roles to build it on, and
  // shipping an attack surface for a capability nothing calls.

  /// Revokes every session the caller holds, on every device (§4.3).
  ///
  /// The user-facing "sign out everywhere" — the answer to "I think someone has
  /// my token" that does not require knowing which device leaked it.
  router.post('/auth/sessions/revoke-all', (Request request) async {
    return _revoke(
      request,
      withAuthService: withAuthService,
      audit: audit,
      sources: sources,
      reason: 'revoked_all_devices',
      revoke: (auth, session) => auth.revokeAllSessionsForUser(
        session.userId,
        reason: 'revoked_all_devices',
      ),
    );
  });

  /// Revokes the caller's sessions on one named device (§4.3, §4.8).
  ///
  /// The lost-or-stolen-phone case: cut that device off without signing the
  /// person out of the laptop they are holding. `device_id` comes from the body
  /// because it names *which of the caller's own devices* to revoke — it is a
  /// selector within an already-authorized scope, not an authorization input,
  /// and the SQL is keyed on `(user_id, device_id)` with the `user_id` from the
  /// session, so a forged value can only ever revoke the caller's own rows.
  router.post('/auth/sessions/revoke-device', (Request request) async {
    final correlationId = traceIdOf(request);
    final json = await _readJsonBody(request);
    if (json == null) {
      return errorResponse(400, 'malformed_body', traceId: correlationId);
    }
    final deviceId = json['device_id'];
    if (!_isUsableDeviceId(deviceId)) {
      return errorResponse(400, 'missing_device_id', traceId: correlationId);
    }
    // Safe now that [_isUsableDeviceId] has confirmed the type.
    final safeDeviceId = deviceId as String;
    return _revoke(
      request,
      withAuthService: withAuthService,
      audit: audit,
      sources: sources,
      reason: 'device_revoked',
      revokedDeviceId: safeDeviceId,
      revoke: (auth, session) => auth.revokeDeviceSessions(
        session.userId,
        safeDeviceId,
        reason: 'device_revoked',
      ),
    );
  });

  // ---- The list the per-device revocation needs (task 11.35) ---------------

  /// The caller's own live sessions.
  ///
  /// **Why it exists.** `/auth/sessions/revoke-device` above is correct and was
  /// unusable: it needs the lost device's `device_id`, and a device knows only
  /// its own. So the app could offer "sign me out everywhere" and could not
  /// offer "sign out the phone I lost and leave my laptop alone" — task 11.28
  /// shipped the first and said so on the screen rather than implying the
  /// second existed.
  ///
  /// **Whose sessions.** The caller's, and there is no way to ask for anyone
  /// else's: the `user_id` comes from the validated session and the route
  /// reads nothing from the body or the query string. Same rule as the two
  /// revocation routes — §4.11, authorization inputs never come from
  /// client-supplied values.
  ///
  /// **What a row carries, and what it does not.** A `device_id`, when the
  /// oldest live session on it started, when it was last used, when it runs
  /// out, and whether it is this device. One row per device, not per session —
  /// see [ListedSession]. **No source address** — see [ListedSession] for that
  /// decision. No token and no token hash, which is the one thing that would
  /// turn a convenience into a credential leak.
  ///
  /// **401, not a uniform success**, for an absent or invalid token, for the
  /// same reason [_revoke] gives: there is no third-party fact being disclosed
  /// and the caller already knows whether they sent a token.
  router.get('/auth/sessions', (Request request) async {
    final correlationId = traceIdOf(request);
    final token = bearerToken(request);
    if (token == null) {
      return errorResponse(401, 'unauthorized', traceId: correlationId);
    }

    final result = await withAuthService((auth) async {
      final session = await auth.validateSession(token);
      if (session == null) return null;
      // The limit is checked after authentication because it is keyed on the
      // authenticated user (task 11.35, and the same ordering question task
      // 11.2 answered for invite redemption). An unauthenticated caller is
      // refused by the 401 above and never reaches a bucket.
      limiter.evictExpired();
      if (limiter.checkSessionList(userId: session.userId) !=
          RateLimitOutcome.allowed) {
        return (session: session, sessions: null);
      }
      final sessions = await auth.listSessionsForUser(
        session.userId,
        currentDeviceId: session.deviceId,
      );
      return (session: session, sessions: sessions);
    });

    if (result == null) {
      return errorResponse(401, 'unauthorized', traceId: correlationId);
    }

    final sessions = result.sessions;
    if (sessions == null) {
      await audit(
        AuthAuditEvent.rateLimitTripped,
        userId: result.session.userId,
        deviceId: result.session.deviceId,
        source: sources.of(request),
        reason: 'session_list_per_user',
        requestId: correlationId,
      );
      return errorResponse(429, 'rate_limited', traceId: correlationId);
    }

    return Response.ok(
      jsonEncode({
        'sessions': [
          for (final s in sessions)
            {
              'device_id': s.deviceId,
              'first_signed_in_at': s.firstSignedInAt.toIso8601String(),
              'last_seen_at': s.lastSeenAt.toIso8601String(),
              'expires_at': s.expiresAt.toIso8601String(),
              'is_current_device': s.isCurrentDevice,
            },
        ],
      }),
      headers: const {
        'content-type': 'application/json',
        // A list of somebody's devices is not something to leave in a shared
        // cache, and §4.7 keeps it out of one the same way the sign-in response
        // above does.
        'cache-control': 'no-store',
      },
    );
  });

  return router;
}

/// Shared body of the two revocation routes.
///
/// Returns 401 for an absent or invalid token — the one place in this file
/// where an unauthenticated caller is told "no" rather than given a uniform
/// success, because unlike sign-out there is no revocation to perform
/// idempotently and no third-party fact being disclosed: the caller already
/// knows whether they sent a token.
Future<Response> _revoke(
  Request request, {
  required Future<T> Function<T>(Future<T> Function(AuthService) action)
  withAuthService,
  required Future<void> Function(
    AuthAuditEvent event, {
    String? userId,
    String? email,
    String? deviceId,
    RequestSource? source,
    String? outcome,
    String? reason,
    String? requestId,
  })
  audit,
  required SourceIdentity sources,
  required String reason,
  required Future<int> Function(AuthService, ActiveSession) revoke,
  String? revokedDeviceId,
}) async {
  final correlationId = traceIdOf(request);
  final token = bearerToken(request);
  if (token == null) {
    return errorResponse(401, 'unauthorized', traceId: correlationId);
  }

  final result = await withAuthService((auth) async {
    final session = await auth.validateSession(token);
    if (session == null) return null;
    final revoked = await revoke(auth, session);
    return (session: session, revoked: revoked);
  });

  if (result == null) {
    return errorResponse(401, 'unauthorized', traceId: correlationId);
  }

  await audit(
    AuthAuditEvent.sessionRevoked,
    userId: result.session.userId,
    deviceId: revokedDeviceId ?? result.session.deviceId,
    source: sources.of(request),
    outcome: '${result.revoked}',
    reason: reason,
    requestId: correlationId,
  );

  return Response.ok(
    // The count is the caller's own session total, which they are entitled to.
    jsonEncode({'status': 'revoked', 'sessions_revoked': result.revoked}),
    headers: const {'content-type': 'application/json'},
  );
}

/// Extracts a bearer token from the `Authorization` header.
///
/// Note for any request-logging middleware added later: this header must be
/// redacted (§4.7's never-log list).
String? bearerToken(Request request) {
  final header = request.headers['authorization'];
  if (header == null) return null;
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return null;
  final token = header.substring(prefix.length).trim();
  return token.isEmpty ? null : token;
}

/// The page shown when the emailed link is opened in a browser.
///
/// **It deliberately does not sign anything in, and consumes nothing.** Two
/// reasons, and both are load-bearing:
///
/// 1. *A browser is not the app.* A session minted here would belong to a web
///    browser, which has no way to hand it to TriTrack — and inventing a
///    hand-off (a short pairing code, say) would mean a second, lower-entropy
///    credential to design, rate-limit, and get wrong. The app redeems
///    directly instead: the user pastes the link into TriTrack, the app POSTs
///    the token with its own `device_id`, and **the device that completes the
///    exchange is the device that gets signed in** — the security model's
///    constraint (§4.2) satisfied literally rather than approximately.
/// 2. *Nothing here can be prefetched into a consumed token.* Mail scanners
///    and link previewers issue GETs; since GET does nothing, a scanner cannot
///    burn the single-use token and leave the user with a dead link.
///
/// So this page's whole job is to tell the person what to do and let them copy
/// the link. A deep link would be nicer and is recorded as follow-up scope —
/// it changes only how the token reaches the app, not who redeems it.
String _redeemLandingPage(String token, String nonce) {
  // Escaped even though the token is base64url (no HTML-significant
  // characters) — the escape is what makes that a property of the code rather
  // than of the token format, which a later change could quietly alter.
  final escapedText = const HtmlEscape().convert(token);
  return '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <title>Sign in to TriTrack</title>
  <style nonce="$nonce">
    body { font-family: system-ui, sans-serif; margin: 0; padding: 2rem;
           display: flex; min-height: 100vh; align-items: center;
           justify-content: center; background: #f6f6f4; color: #1d1b20; }
    main { max-width: 24rem; }
    h1 { font-size: 1.25rem; margin: 0 0 0.75rem; }
    p { font-size: 0.9rem; line-height: 1.55; color: #48454e; }
    code { display: block; margin-top: 1rem; padding: 0.75rem;
           background: #fff; border: 1px solid #d8d5dd; border-radius: 8px;
           font-size: 0.8rem; word-break: break-all; }
    button { margin-top: 0.75rem; width: 100%; min-height: 44px;
             font-size: 1rem; font-weight: 700; color: #fff;
             background: #3E7A4C; border: 0; border-radius: 8px; }
  </style>
</head>
<body>
  <main>
    <h1>Finish signing in</h1>
    <p>Open <strong>TriTrack</strong> on the device you want to sign in, go to
       <strong>More &rsaquo; Server Connection</strong>, and paste this code.
       Whichever device you paste it into is the one that gets signed in.</p>
    <p>This code works once, and expires shortly.</p>
    <code id="token">$escapedText</code>
    <button type="button" id="copy">Copy code</button>
    <script nonce="$nonce">
      document.getElementById('copy').addEventListener('click', function () {
        navigator.clipboard.writeText(
          document.getElementById('token').textContent.trim()
        );
        this.textContent = 'Copied';
      });
    </script>
  </main>
</body>
</html>
''';
}

/// The page shown when the mail link arrived without a usable token.
///
/// Says what to do and nothing else — no detail about what was wrong with the
/// request, because there is nothing a caller could learn here that they did
/// not already send, and inventing a diagnostic would be the start of one.
String _redeemErrorPage(String nonce) =>
    '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <title>Sign-in link incomplete</title>
  <style nonce="$nonce">
    body { font-family: system-ui, sans-serif; margin: 0; padding: 2rem;
           display: flex; min-height: 100vh; align-items: center;
           justify-content: center; background: #f6f6f4; color: #1d1b20; }
    main { max-width: 24rem; }
    h1 { font-size: 1.25rem; margin: 0 0 0.75rem; }
    p { font-size: 0.9rem; line-height: 1.55; color: #48454e; }
  </style>
</head>
<body>
  <main>
    <h1>This sign-in link is incomplete</h1>
    <p>Open the most recent sign-in email and use the whole link, or request a
       new one from <strong>TriTrack &rsaquo; More &rsaquo; Server
       Connection</strong>. Links expire shortly and work once.</p>
  </main>
</body>
</html>
''';
