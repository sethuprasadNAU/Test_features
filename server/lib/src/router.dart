import 'dart:convert';
import 'dart:math';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/auth_routes.dart';
import 'auth/auth_service.dart';
import 'diagnostics/diagnostics_config.dart';
import 'diagnostics/diagnostics_routes.dart';
import 'projects/project_destruction_service.dart';
import 'projects/project_routes.dart';
import 'readiness.dart';
import 'security/audit_log.dart';
import 'security/error_responses.dart';
import 'security/rate_limiter.dart';
import 'security/request_identity.dart';
import 'security/security_headers.dart';
import 'sync/sync_routes.dart';

/// The server's route table.
///
/// **Two unauthenticated routes reveal anything at all, and between them they
/// reveal exactly two bits: this process is running, and its database is or is
/// not reachable.** No schema version, no dependency versions, no build info.
/// `TriTrack_Security_Model.md` §2.2 is explicit that a chattier health check
/// is free reconnaissance for an opportunistic scanner; that information
/// belongs on the authenticated diagnostics console instead.
///
/// `/ready` is the second of those two and is new in task 11.128 — §2.2's
/// bullet said "no unauthenticated endpoint except `/health`" until then, and
/// the amendment is recorded there with the measurement behind it. See
/// `readiness.dart` for why readiness is a separate route rather than a status
/// code or a body on `/health`, and for the disclosure decision.
///
/// The auth routes (task 10.6) are necessarily unauthenticated — they are how
/// you become authenticated — and carry their own anti-enumeration and
/// single-use guarantees; see `auth_routes.dart`.
///
/// The diagnostics console (10.13) is off by default and localhost-only per
/// the security model — see [DiagnosticsConfig] and `diagnostics_routes.dart`.
///
/// **Every response passes through the same three middlewares (task 10.14),
/// applied here rather than per-router so a new route cannot forget them:**
/// security headers and the no-CORS policy (§4.16), a correlation id, and the
/// catch-all that turns any unhandled exception into an opaque 500 instead of
/// shelf's default stack-trace body (§4.13). `/health` and 404s are included —
/// a header policy with holes is a header policy someone will find the hole in.
Handler createHandler({
  Future<T> Function<T>(Future<T> Function(AuthService) action)?
  withAuthService,
  IdGenerator? newId,
  Future<Response> Function(
    Request request,
    Future<Response> Function(SyncContext) action,
  )?
  withSyncContext,
  DiagnosticsConfig? diagnosticsConfig,
  Future<Response> Function(
    Request request,
    Future<Response> Function(DiagnosticsContext) action,
  )?
  withDiagnostics,
  DateTime? diagnosticsStartedAt,
  ReadinessProbe? readiness,
  RateLimiter? rateLimiter,
  Future<void> Function(Future<void> Function(AuthAuditLog) action)?
  withAuditLog,
  SourceIdentity? sourceIdentity,
  bool tlsEnabled = false,
  void Function(String)? logLine,
  ProjectDeletionPolicy? deletionPolicy,
}) {
  final router = Router();
  // One resolver for the whole server (task 10.52, §4.4): the rate limiter and
  // the audit log must agree on what "the caller's address" means, and the
  // degenerate-source warning is throttled per instance, so two of these would
  // both halve the throttle and let the two consumers disagree.
  //
  // **Deliberately not given to the diagnostics router.** Its loopback gate
  // reads the raw TCP peer and must keep doing so — see
  // `diagnostics_routes.dart` and `peerInternetAddressOf`.
  final sources = sourceIdentity ?? SourceIdentity(log: logLine);

  // **`/health` means LIVENESS: this process is running and answering HTTP.**
  // It means nothing else, and in particular it does not mean the server can
  // sign anybody in — a server started with no database answers `200` here,
  // deliberately (the server-optional seam, task 10.2, and `bin/server.dart`'s
  // degraded start). Task 11.125 measured exactly that on a real stack and
  // reported it as a defect; it is not one, but until task 11.128 nothing
  // anywhere said which of liveness and readiness this route was, which is the
  // defect it actually found. **The remedy for a failing liveness probe is a
  // restart, and a restart cannot reach a database that is down** — so this
  // route must keep answering `200` whenever the process is up. Readiness is
  // `/ready`, immediately below.
  router.get('/health', (Request request) {
    return Response.ok(
      jsonEncode({'status': 'ok'}),
      headers: {'content-type': 'application/json'},
    );
  });

  // **`/ready` means READINESS: this server can do its job.** `200` with
  // `{"status":"ready"}`, or `503` with `{"status":"not_ready","degraded":
  // ["database"]}` naming the subsystems that are out. `503` is the answer an
  // uptime monitor or a load balancer should act on; `/health`'s `200` is not.
  //
  // Unauthenticated, and the vocabulary of `degraded` is closed by the
  // [Subsystem] enum — see `readiness.dart` for both decisions, including the
  // measurement showing this discloses nothing a caller cannot already get
  // from `POST /auth/magic-link` answering `404` on a database-less server.
  //
  // **The default probe, when the caller supplies none, is derived from what
  // was actually mounted rather than declared separately.** If the auth or
  // sync routers are absent then this server has no database — that is the
  // same condition `bin/server.dart` mounts them on — so a test or an embedder
  // that builds a handler cannot get a `/ready` that disagrees with the routes
  // beside it. `bin/server.dart` passes a probe that additionally notices a
  // connection lost after startup.
  final probe =
      readiness ??
      () => {
        if (withAuthService == null || withSyncContext == null)
          Subsystem.database,
      };
  router.get('/ready', (Request request) {
    final degraded = probe().map((s) => s.wireName).toList()..sort();
    if (degraded.isEmpty) {
      return Response.ok(
        jsonEncode({'status': 'ready'}),
        headers: {'content-type': 'application/json'},
      );
    }
    return Response(
      503,
      body: jsonEncode({'status': 'not_ready', 'degraded': degraded}),
      headers: {'content-type': 'application/json'},
    );
  });

  // Auth is mounted only when a database-backed service is available. A server
  // started without one still answers /health — useful for container
  // orchestration — but offers no sign-in surface at all rather than one that
  // fails confusingly at the first query. **That absence is what `/ready`
  // above reports**, and it is also directly observable: this route answering
  // `404` instead of `202` is how a caller learns the same fact without
  // `/ready`, which is the measurement the disclosure decision rests on.
  if (withAuthService != null) {
    router.mount(
      '/',
      createAuthRouter(
        withAuthService: withAuthService,
        newId: newId ?? _uuidV4,
        rateLimiter: rateLimiter,
        withAuditLog: withAuditLog,
        sourceIdentity: sources,
      ).call,
    );
  }

  // Sync (10.7) and the project directory (10.9) share one authenticated
  // session resolver — see bin/server.dart's implementation of
  // [withSyncContext] for where a bearer token actually becomes a session.
  if (withSyncContext != null) {
    router.mount(
      '/',
      createSyncRouter(
        withSyncContext: withSyncContext,
        withAuditLog: withAuditLog,
        sourceIdentity: sources,
      ).call,
    );
    router.mount(
      '/',
      createProjectRouter(
        withSyncContext: withSyncContext,
        // The same limiter the auth routes get: the join-request rule is per
        // authenticated user, and per-user counters are only a limit if they
        // outlive the request that incremented them.
        rateLimiter: rateLimiter,
        // **New in task 11.81, and the closure of finding Q-1's acceptance.**
        // This router writes no audit rows at all before this line — which was
        // accepted while it only issued invitations, and is not acceptable now
        // that approving a join request is how somebody is granted access to a
        // project full of collar locations.
        withAuditLog: withAuditLog,
        // Task 11.290: how long a scheduled project deletion waits. Null
        // reads the environment; tests pass one so a day can be minutes.
        deletionPolicy: deletionPolicy,
      ).call,
    );
  }

  // Mounted only when explicitly enabled — see [DiagnosticsConfig]. This is
  // the acceptance criterion that disabling the console removes its routes
  // entirely rather than mounting them behind a gate that still answers
  // "no": with `diagnosticsConfig == null` or `.enabled == false`, nothing
  // below this point is ever reached, so an unmounted route 404s exactly
  // like any other nonexistent path — indistinguishable from a server built
  // without this feature at all.
  if (diagnosticsConfig != null &&
      diagnosticsConfig.enabled &&
      withDiagnostics != null) {
    router.mount(
      '/',
      createDiagnosticsRouter(
        config: diagnosticsConfig,
        withDiagnostics: withDiagnostics,
        startedAt: diagnosticsStartedAt ?? DateTime.now(),
      ).call,
    );
  }

  // Order matters, outermost first:
  //
  // 1. Security headers, so they are attached even to a response produced by
  //    the error handler below — a 500 with no `nosniff` is still a 500 a
  //    browser can be talked into misinterpreting.
  // 2. The correlation id, so the error handler has one to report and to log.
  // 3. The catch-all, innermost, so it sees exceptions from every route and
  //    from the other middlewares' inner handlers.
  return Pipeline()
      .addMiddleware(securityHeadersMiddleware(tlsEnabled: tlsEnabled))
      .addMiddleware(traceIdMiddleware())
      .addMiddleware(errorHandlerMiddleware(log: logLine))
      .addHandler(router.call);
}

/// A v4 UUID from the platform CSPRNG.
///
/// Session ids and account ids are not secrets — the bearer token is the
/// secret, and it is generated by `Tokens.generate()` — but they are still
/// generated from `Random.secure()` so that nothing downstream can come to
/// depend on them being predictable, and so an id appearing in a log leaks
/// nothing about any other id.
String _uuidV4() {
  final bytes = List<int>.generate(16, (_) => _secureByte());
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

int _secureByte() => _random.nextInt(256);
final Random _random = Random.secure();
