import 'dart:convert';

import 'package:http/http.dart' as http;

/// Outcome of asking the server for a sign-in link.
class MagicLinkRequest {
  const MagicLinkRequest({required this.requestId});

  /// Poll `linkStatus` with this so the requesting device can stop waiting
  /// when its link is opened somewhere else.
  final String requestId;
}

/// What the server says happened to a requested link.
enum LinkStatus {
  pending,

  /// Used — possibly on another device. This device gets no session from it.
  consumed,
  expired,
}

/// A session as handed back by the server, before it is adopted locally.
class RedeemedSession {
  const RedeemedSession({
    required this.token,
    required this.userId,
    required this.email,
    required this.expiresAt,
  });

  final String token;

  /// The server's authoritative `user_id`. This device adopts it.
  final String userId;
  final String email;
  final DateTime expiresAt;
}

/// Thrown when the server rejects a redemption. Carries no detail about *why*
/// — the server deliberately does not distinguish unknown, consumed, and
/// expired tokens, and inventing a distinction here would misreport it.
class RedemptionRejected implements Exception {
  const RedemptionRejected();
  @override
  String toString() => 'RedemptionRejected';
}

/// Thrown when a `2xx` auth response's body isn't the shape this client
/// expects.
///
/// Task 10.67: every field read out of a decoded auth response here used a
/// naked `json['key']! as String` — a malformed or unexpected response body
/// (a server on a mismatched build, a misbehaving proxy) threw an uncaught
/// `TypeError` rather than something a caller could recognize. Not a
/// permissive-fallback case: the old cast already failed closed (sign-in
/// simply crashed rather than succeeding with garbage data), but per task
/// 10.66's "fix the class" rule this gets the same typed-rejection
/// treatment already applied to the sync wire's equivalent fields.
class AuthProtocolException implements Exception {
  const AuthProtocolException(this.message);
  final String message;
  @override
  String toString() => 'AuthProtocolException: $message';
}

String _requireAuthString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw AuthProtocolException('Missing or malformed "$key" in auth response.');
  }
  return value;
}

/// Whether a `400` body is the server's own "that token is no good" answer.
///
/// Matched by the error code the route documents (`_redemptionFailed` in
/// `server/lib/src/auth/auth_routes.dart`) rather than by the status alone,
/// because `400` is also what a malformed body or a missing `device_id`
/// returns, and neither of those is a statement about the code the person
/// pasted. An unparseable body is not a rejection — it becomes an
/// [AuthServerError], which reports honestly that the server answered with
/// something this build did not understand.
/// The `error` code of a uniform server error body, or null when the body is
/// not that shape — a proxy's HTML, an empty body, a non-string code. Never
/// throws: the status is the fact, and a body that cannot be read subtracts
/// nothing from it.
String? _errorCodeOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final code = decoded['error'];
    return code is String ? code : null;
  } catch (_) {
    return null;
  }
}

bool _isRejectedToken(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map && decoded['error'] == 'invalid_or_expired_link';
  } catch (_) {
    return false;
  }
}

Map<String, Object?> _decodeAuthBody(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw AuthProtocolException('Auth response body is not valid JSON: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw AuthProtocolException(
      'Auth response body is not a JSON object (got ${decoded.runtimeType}).',
    );
  }
  return decoded;
}

/// Thrown when the server **was reached and answered**, with a status the
/// route cannot act on.
///
/// **Task 11.37, item 1.** This type exists to keep two failures apart that
/// the app used to report as one. A sign-in address saved with a trailing
/// slash produced `//auth/magic-link`, the server answered `404`, and the
/// screen said "Could not reach the server. Try again." Every visible signal
/// pointed at the network, and the network was fine — that conflation cost
/// the first hour of the two-device walkthrough on 2026-08-26, and in the
/// field, where there is no terminal to check, it costs a day.
///
/// The distinction is not a nicety: "nothing answered" and "something
/// answered and said no" have disjoint fixes. The first is Wi-Fi, the server
/// process, the address. The second is the address's *shape*, the route, or
/// the server's own state — and only the second can be told apart by anything
/// other than a person with a terminal.
///
/// Applied to every route rather than to `requestMagicLink` alone, because
/// each one had its own version of the same defect (task 10.66's "fix the
/// class" rule): `linkStatus` reported any non-200 as `pending`, so a wrong
/// address polled forever; `redeem` reported any non-200 as a bad code, so a
/// 404 read as "your sign-in code did not work" and sent people to request
/// another one that would fail identically; `signOut` ignored the status
/// outright and reported success.
class AuthServerError implements Exception {
  const AuthServerError({
    required this.statusCode,
    required this.path,
    this.code,
  });

  final int statusCode;

  /// The server's machine-readable error code — the `error` field of its
  /// uniform error body — when the body was JSON and carried one, else null.
  ///
  /// Added by task 11.298 so that one `400` can be told from another. The
  /// server answers `400 invalid_email` to an address its mail path will not
  /// carry (accented or non-Latin characters, a quoted or bracketed form),
  /// and until then the screen rendered every `400` as *"the address, or the
  /// server's own state, is what to check"* — where "the address" means the
  /// server URL, which was fine. Carried as data, never shown: a code is a
  /// server-chosen string and nothing here echoes one to a person (§4.20).
  final String? code;

  /// The request path, **not** the full URL: this string travels toward the
  /// UI, and the base URL is the one part of it a screen must not echo back
  /// (the same reason `SyncTransportException` carries no exception text).
  final String path;

  /// The server has no such route. In practice this is nearly always the
  /// saved address, not a broken server.
  bool get isNotFound => statusCode == 404;

  /// The server is refusing this caller for now. Honest and caller-scoped —
  /// see `RateLimitPolicy`; the *per-address* limit is deliberately invisible
  /// and never produces this.
  bool get isRateLimited => statusCode == 429;

  /// The server itself failed, rather than refusing the request.
  bool get isServerFault => statusCode >= 500;

  /// The server will not send a sign-in link to the address as typed. A fact
  /// about the string the person supplied — never about whether anybody is
  /// registered under it, which the server does not disclose (§4.5).
  bool get isInvalidEmail => statusCode == 400 && code == 'invalid_email';

  @override
  String toString() => 'AuthServerError($statusCode on $path)';
}


/// One of your own signed-in devices, as the server reports it.
///
/// **No label, and that is a decision rather than an omission** (task 11.36).
/// A device name would have to be free text the phone chooses and this app
/// then displays — a schema change plus length bounds, control characters and
/// every other question this project has already paid for once on imported
/// text. What the server already records and the phone cannot choose turns out
/// to identify a device to its owner well enough: *"signed in 3 August, last
/// used 12 August"*. If that proves genuinely insufficient in use, a label
/// becomes a considered follow-up rather than the first thing reached for.
///
/// **One row per device, not per session**, and it carries no token, no token
/// hash and no source address — see `ListedSession` on the server for each of
/// those decisions.
class DeviceSession {
  const DeviceSession({
    required this.deviceId,
    required this.firstSignedInAt,
    required this.lastSeenAt,
    required this.expiresAt,
    required this.isCurrentDevice,
  });

  final String deviceId;

  /// When the **oldest** live session on this device started.
  final DateTime firstSignedInAt;

  /// When the device most recently made a request. Leads the row on screen:
  /// it is what actually distinguishes one of your devices from another.
  final DateTime lastSeenAt;

  /// When the **longest-lived** session on this device runs out.
  final DateTime expiresAt;

  /// Whether this is the device asking. Marked plainly on screen so nobody
  /// signs themselves out while trying to sign out something else.
  final bool isCurrentDevice;

  static DeviceSession fromJson(Map<String, Object?> json) => DeviceSession(
    deviceId: _requireAuthString(json, 'device_id'),
    firstSignedInAt: _requireAuthTime(json, 'first_signed_in_at'),
    lastSeenAt: _requireAuthTime(json, 'last_seen_at'),
    expiresAt: _requireAuthTime(json, 'expires_at'),
    // Absent or wrong-typed reads as false, which is the fail-safe direction:
    // a device wrongly *not* marked "this device" gets a confirmation dialog
    // it did not need, while one wrongly marked as such would hide the
    // revoke control for a device somebody may be trying to cut off.
    isCurrentDevice: json['is_current_device'] == true,
  );
}

DateTime _requireAuthTime(Map<String, Object?> json, String key) {
  final raw = _requireAuthString(json, key);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw AuthProtocolException('"$key" is not a parseable timestamp: $raw');
  }
  return parsed.toUtc();
}

/// HTTP client for the auth endpoints.
///
/// Takes an `http.Client` rather than making one, so it can only exist where
/// `serverHttpClientProvider` produced one — which is only when a server is
/// configured (task 10.2's invariant).
class AuthClient {
  const AuthClient({required this.httpClient, required this.baseUrl});

  final http.Client httpClient;
  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Rejects any status but the documented one.
  ///
  /// Every route funnels through here so that "the server answered something
  /// unexpected" is one typed outcome with one shape, rather than four
  /// route-local guesses at what the status meant. A transport failure — no
  /// connection, DNS, a dropped socket — never reaches this method: `http`
  /// throws before a response exists, and that exception travels on
  /// unwrapped, which is what lets a caller tell the two apart.
  void _requireStatus(http.Response response, int expected, String path) {
    if (response.statusCode == expected) return;
    throw AuthServerError(
      statusCode: response.statusCode,
      path: path,
      code: _errorCodeOf(response.body),
    );
  }

  Future<MagicLinkRequest> requestMagicLink(String email) async {
    const path = '/auth/magic-link';
    final response = await httpClient.post(
      _uri(path),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    // Note what is *not* special-cased: the per-address rate limit returns the
    // same `202` as a sent link and writes no email (§4.4/§4.5), so there is
    // nothing here to distinguish and deliberately no way to add one — telling
    // this caller would disclose that somebody recently requested a link for
    // an address they may not own. A `429` is the *per-source* limit, which is
    // a fact about this caller and honest to report.
    _requireStatus(response, 202, path);
    final json = _decodeAuthBody(response.body);
    return MagicLinkRequest(requestId: _requireAuthString(json, 'request_id'));
  }

  /// Polls what happened to a requested link.
  ///
  /// A `429` is reported as [LinkStatus.pending] rather than thrown: this is a
  /// poll against a route with a deliberately tight per-source limit
  /// (`RateLimitPolicy.linkStatusPerSource`), being refused for a moment is an
  /// expected part of polling, and "not yet" is the honest reading of it.
  /// **Every other non-200 throws**, which it did not before task 11.37: a
  /// mistyped or slash-suffixed address answered `404` and this method
  /// reported `pending`, so a poll against a route that does not exist waited
  /// forever and never said why.
  Future<LinkStatus> linkStatus(String requestId) async {
    final path = '/auth/link-status/$requestId';
    final response = await httpClient.get(_uri(path));
    if (response.statusCode == 429) return LinkStatus.pending;
    _requireStatus(response, 200, path);
    final status = _decodeAuthBody(response.body)['status'];
    return switch (status) {
      'consumed' => LinkStatus.consumed,
      'expired' => LinkStatus.expired,
      _ => LinkStatus.pending,
    };
  }

  /// Exchanges [token] for a session bound to **this** device.
  ///
  /// The device that calls this is the device that gets signed in — there is
  /// no path by which one device's redemption mints a session on another.
  Future<RedeemedSession> redeem({
    required String token,
    required String deviceId,
  }) async {
    const path = '/auth/redeem';
    final response = await httpClient.post(
      _uri(path),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'token': token, 'device_id': deviceId}),
    );
    // A rejected token is a `400` carrying `invalid_or_expired_link` — the
    // one non-200 that means *the code*. Anything else means the request
    // never reached a working redemption route, and saying "that sign-in
    // code did not work" would send somebody to burn a second code on the
    // same broken address (task 11.37).
    if (response.statusCode == 400 && _isRejectedToken(response.body)) {
      throw const RedemptionRejected();
    }
    _requireStatus(response, 200, path);
    final json = _decodeAuthBody(response.body);
    final expiresAtRaw = _requireAuthString(json, 'expires_at');
    final expiresAt = DateTime.tryParse(expiresAtRaw);
    if (expiresAt == null) {
      throw AuthProtocolException(
        '"expires_at" is not a parseable timestamp: $expiresAtRaw',
      );
    }
    return RedeemedSession(
      token: _requireAuthString(json, 'session_token'),
      userId: _requireAuthString(json, 'user_id'),
      email: _requireAuthString(json, 'email'),
      expiresAt: expiresAt.toUtc(),
    );
  }

  /// Ends this device's session on the server.
  ///
  /// `401` counts as success and always has: the route is deliberately
  /// idempotent, and a session that is already gone is the state being asked
  /// for. Any *other* non-200 now throws (task 11.37) — this method used to
  /// discard the status entirely, so a `404` from a mistyped address left the
  /// session live on the server while the screen said "Signed out".
  Future<void> signOut(String sessionToken) async {
    const path = '/auth/sign-out';
    final response = await httpClient.post(
      _uri(path),
      headers: {'authorization': 'Bearer $sessionToken'},
    );
    if (response.statusCode == 401) return;
    _requireStatus(response, 200, path);
  }

  /// **"Sign out everywhere" (task 11.28 part 2).** Revokes every session this
  /// person holds, on every device, and returns how many there were.
  ///
  /// The route has existed and been correct since task 10.14 — the person
  /// revoked is always the authenticated caller, taken from the session and
  /// never from the request, because §4.11 forbids an authorization input
  /// coming from a client-supplied value and this one destroys credentials.
  /// **No screen called it**, so the security model's stated answer to "I
  /// think somebody has my token" was, in practice, that the person could do
  /// nothing. This method is the missing half.
  ///
  /// It is also the answer to "I lost my phone" (part 3), and the reason is
  /// worth writing down rather than leaving to be rediscovered: the server's
  /// per-device route (`/auth/sessions/revoke-device`) needs the lost device's
  /// id, and nothing tells this device what its owner's *other* device ids
  /// are — there is no route that lists your own sessions. Signing every
  /// device out and signing back in on the ones you still hold reaches the
  /// same end state; it costs one sign-in per surviving device.
  ///
  /// Throws [AuthServerError] on any non-200, including the `401` a session
  /// that is already gone produces — unlike [signOut], which is deliberately
  /// idempotent, this one must not report success when nothing was revoked.
  Future<int> revokeAllSessions(String sessionToken) async {
    const path = '/auth/sessions/revoke-all';
    final response = await httpClient.post(
      _uri(path),
      headers: {'authorization': 'Bearer $sessionToken'},
    );
    _requireStatus(response, 200, path);
    final count = _decodeAuthBody(response.body)['sessions_revoked'];
    // A missing or wrong-typed count is a protocol fault, not a zero: zero is
    // a real answer ("nothing was revoked") and must not be what a malformed
    // response looks like. Same typed-rejection rule as
    // [_requireAuthString], applied to the one numeric field in this file.
    if (count is! int) {
      throw const AuthProtocolException(
        'Missing or malformed "sessions_revoked" in revoke-all response.',
      );
    }
    return count;
  }

  /// **Your own signed-in devices, most recently used first** (task 11.36,
  /// over the route task 11.35 built).
  ///
  /// There is no way to ask for anybody else's: the server takes the `user_id`
  /// from the validated session and reads nothing from the request. This
  /// method sends no identifier at all, which is what makes that true on this
  /// side too rather than merely respected.
  ///
  /// Sorted here rather than trusted from the wire — the order is what the
  /// screen's "most recent first" promise rests on, and a server that returned
  /// them in any order would silently make that promise false.
  Future<List<DeviceSession>> listSessions(String sessionToken) async {
    const path = '/auth/sessions';
    final response = await httpClient.get(
      _uri(path),
      headers: {'authorization': 'Bearer $sessionToken'},
    );
    _requireStatus(response, 200, path);
    final raw = _decodeAuthBody(response.body)['sessions'];
    if (raw is! List) {
      throw const AuthProtocolException(
        'Missing or malformed "sessions" in the session-list response.',
      );
    }
    final sessions = [
      for (final entry in raw)
        if (entry is Map<String, Object?>)
          DeviceSession.fromJson(entry)
        else
          throw AuthProtocolException(
            'A session in the list is not a JSON object (got '
            '${entry.runtimeType}).',
          ),
    ];
    sessions.sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return sessions;
  }

  /// **Ends every session on one of your own devices** — the lost-phone case,
  /// without signing out the laptop you are holding.
  ///
  /// [deviceId] names *which of the caller's own devices*, and it is a
  /// selector inside an already-authorized scope rather than an authorization
  /// input: the server keys the delete on `(user_id, device_id)` with the
  /// `user_id` taken from the session, so a forged value can only ever revoke
  /// one of the caller's own devices. §4.11 is satisfied by that keying, not
  /// by this client being careful.
  ///
  /// Returns how many sessions were ended. Throws [AuthServerError] on any
  /// non-200 — including the `401` from a session that is already gone. Like
  /// [revokeAllSessions] and unlike [signOut], reporting success when nothing
  /// was revoked is the worst answer available: somebody using this believes a
  /// device is in the wrong hands.
  Future<int> revokeDevice({
    required String sessionToken,
    required String deviceId,
  }) async {
    const path = '/auth/sessions/revoke-device';
    final response = await httpClient.post(
      _uri(path),
      headers: {
        'authorization': 'Bearer $sessionToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({'device_id': deviceId}),
    );
    _requireStatus(response, 200, path);
    final count = _decodeAuthBody(response.body)['sessions_revoked'];
    if (count is! int) {
      throw const AuthProtocolException(
        'Missing or malformed "sessions_revoked" in revoke-device response.',
      );
    }
    return count;
  }
}

/// Pulls the token out of whatever the user pasted.
///
/// Accepts either the whole sign-in URL or the bare code, because both are
/// things a person will reasonably paste: the browser landing page offers the
/// code, but someone may copy the link out of the email instead. Rejecting one
/// of those would look like a broken sign-in.
String? extractSignInToken(String pasted) {
  final trimmed = pasted.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  final fromQuery = uri?.queryParameters['token'];
  if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
  // Bare token: base64url, no padding. Anything else is not a sign-in code.
  if (RegExp(r'^[A-Za-z0-9_-]{20,}$').hasMatch(trimmed)) return trimmed;
  return null;
}
