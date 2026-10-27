/// HTTP surface for the read-only diagnostics console (task 10.13).
library;

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../auth/auth_routes.dart' show bearerToken;
import '../auth/tokens.dart';
import '../security/audit_log.dart';
import 'diagnostics_config.dart';
import 'diagnostics_repository.dart';
import 'sync_traffic_log.dart';

/// What one diagnostics request needs, resolved per call.
///
/// No transaction, unlike [SyncContext] (`sync_routes.dart`) — every method
/// on [DiagnosticsRepository] and [SyncTrafficLogStore]'s readers is a bare
/// `SELECT`, so there is no write to hold a lock for and no multi-statement
/// atomicity to preserve.
class DiagnosticsContext {
  const DiagnosticsContext({
    required this.repo,
    required this.trafficLog,
    required this.auditLog,
  });

  final DiagnosticsRepository repo;
  final SyncTrafficLogStore trafficLog;

  /// §4.7's authentication audit log (task 10.14). "Both logs are the same
  /// store the diagnostics console reads. One recording mechanism, two
  /// consumers" — this is the second consumer.
  final AuthAuditLog auditLog;
}

Response _json(Object? body) => Response.ok(
  jsonEncode(body),
  headers: const {'content-type': 'application/json'},
);

Response _notFound(String message) => Response.notFound(
  jsonEncode({'error': message}),
  headers: const {'content-type': 'application/json'},
);

int _limitFrom(Request request, {int fallback = 50, int max = 500}) {
  final raw = request.url.queryParameters['limit'];
  final parsed = raw == null ? null : int.tryParse(raw);
  if (parsed == null || parsed < 1) return fallback;
  return parsed > max ? max : parsed;
}

/// Refuses anything that isn't a real loopback connection, unless
/// [DiagnosticsConfig.allowRemote] opted in.
///
/// Reads the *actual TCP peer address* shelf_io attaches to the request
/// (`request.context['shelf.io.connection_info']`), not a header — a header
/// is whatever the caller claims, and `X-Forwarded-For` is exactly the kind
/// of thing a caller on the LAN could set to impersonate localhost. A request
/// built in-process for a test (no real socket) carries no connection info at
/// all; that is treated as local, since the only way to construct one is to
/// already be running inside this process.
Middleware _requireLocalUnlessAllowed(bool allowRemote) {
  return (Handler innerHandler) {
    return (Request request) async {
      if (allowRemote) return innerHandler(request);
      final info = request.context['shelf.io.connection_info'];
      InternetAddress? remote;
      if (info is HttpConnectionInfo) remote = info.remoteAddress;
      if (remote != null && !remote.isLoopback) {
        return Response.forbidden(
          jsonEncode({'error': 'diagnostics_console_local_only'}),
          headers: const {'content-type': 'application/json'},
        );
      }
      return innerHandler(request);
    };
  };
}

/// Requires the shared token in [DiagnosticsConfig.token], compared in
/// constant time (`Tokens.constantTimeEquals`) — the console has no
/// per-user session, so this bearer token is the entire authentication
/// mechanism (see [DiagnosticsConfig]'s doc comment).
Middleware _requireToken(String token) {
  return (Handler innerHandler) {
    return (Request request) async {
      final presented = bearerToken(request);
      if (presented == null || !Tokens.constantTimeEquals(presented, token)) {
        return Response(
          401,
          body: jsonEncode({'error': 'diagnostics_console_unauthorized'}),
          headers: const {'content-type': 'application/json'},
        );
      }
      return innerHandler(request);
    };
  };
}

/// Builds the diagnostics routes.
///
/// **Every handler below issues reads only** — see [DiagnosticsRepository]'s
/// own doc comment for why that is enforced at the repository layer too, not
/// just by convention here. Mounted only when [config.enabled] is true; see
/// `router.dart` for why disabling this removes the routes rather than
/// hiding them behind a gate that still answers "no."
Router createDiagnosticsRouter({
  required DiagnosticsConfig config,
  required Future<Response> Function(
    Request request,
    Future<Response> Function(DiagnosticsContext) action,
  )
  withDiagnostics,
  required DateTime startedAt,
  DateTime Function()? now,
}) {
  assert(
    config.enabled && config.token != null,
    'createDiagnosticsRouter must only be called when the console is enabled',
  );
  final clock = now ?? DateTime.now;
  final router = Router();

  Future<Response> handle(
    Request request,
    Future<Response> Function(DiagnosticsContext) action,
  ) => withDiagnostics(request, action);

  // **The two gates, applied per declared route rather than to everything
  // this router is mounted over (finding F9, task 10.80).**
  //
  // Until 10.80 the whole thing was `Router()..mount('/', pipeline)`, and
  // `router.dart` mounts *that* at `/` as well — so with the console on, the
  // gates ran for every path this server does not otherwise handle. `/nope`,
  // `/admin` and `/wp-login.php` all answered a branded
  // `403 diagnostics_console_local_only`, which tells an unauthenticated
  // scanner in one request that the console exists, and it replaced the
  // ordinary 404 for the entire API for as long as the console was enabled.
  //
  // Registering the gates one route at a time means an unmatched path returns
  // shelf_router's not-found sentinel and the outer router carries on to its
  // own 404 — indistinguishable from a server with no console at all, which
  // is what §4.10's "disabling it removes the routes" is protecting.
  //
  // **Every route below is registered through [get] and never through
  // `router.get` directly**, so a new route cannot be added ungated by
  // forgetting a wrapper. `diagnostics_gating_test.dart` derives the route
  // list from this file and refuses to pass if any of them answers without a
  // token, which is the check that survives somebody bypassing this helper.
  final gates = Pipeline()
      .addMiddleware(_requireLocalUnlessAllowed(config.allowRemote))
      .addMiddleware(_requireToken(config.token!));

  // Path parameters are read from `request.params` rather than from extra
  // positional arguments, because a [Handler] is what a [Middleware] can
  // wrap — the arity of a shelf_router callback is not.
  void get(String route, Handler handler) =>
      router.get(route, gates.addHandler(handler));

  get('/diagnostics/health', (Request request) {
    return _json({
      'status': 'ok',
      'schema_major': schemaMajorVersion,
      'schema_version': latestSchemaVersion,
      'protocol_version': syncProtocolVersion,
      'uptime_seconds': clock().difference(startedAt).inSeconds,
    });
  });

  get('/diagnostics/projects', (Request request) {
    return handle(request, (context) async {
      return _json({'projects': await context.repo.projects()});
    });
  });

  get('/diagnostics/projects/<projectId>', (Request request) {
    final projectId = request.params['projectId']!;
    return handle(request, (context) async {
      final counts = await context.repo.rowCounts(projectId);
      final memberships = await context.repo.membershipsFor(projectId);
      return _json({
        'project_id': projectId,
        'row_counts': counts,
        'memberships': memberships,
      });
    });
  });

  get('/diagnostics/projects/<projectId>/rows/<table>', (Request request) {
    final projectId = request.params['projectId']!;
    final table = request.params['table']!;
    return handle(request, (context) async {
      final rows = await context.repo.recentRows(
        table,
        projectId: projectId,
        limit: _limitFrom(request),
      );
      if (rows == null) return _notFound('unknown_table');
      return _json({'table': table, 'rows': rows});
    });
  });

  get('/diagnostics/identities', (Request request) {
    return handle(request, (context) async {
      return _json({'identities': await context.repo.identities()});
    });
  });

  get('/diagnostics/devices', (Request request) {
    return handle(request, (context) async {
      final userId = request.url.queryParameters['user_id'];
      return _json({'devices': await context.repo.devices(userId: userId)});
    });
  });

  /// §4.7's authentication audit log (task 10.14) — the account-security half
  /// of the console, answering "was my account compromised in March?"
  ///
  /// **There is no token column to leak here**, by construction: the audit
  /// table has nowhere to store one (see [AuthAuditLog]), so unlike the
  /// identity and device views this route needs no explicit column list to stay
  /// within §4.10's no-token-values rule.
  get('/diagnostics/auth-events', (Request request) {
    return handle(request, (context) async {
      final limit = _limitFrom(request, fallback: 100);
      final email = request.url.queryParameters['email'];
      final entries = email == null
          ? await context.auditLog.recent(limit: limit)
          : await context.auditLog.forEmail(email, limit: limit);
      return _json({
        'events': [for (final e in entries) e.toJson()],
      });
    });
  });

  // Task 11.159. Separate from `/diagnostics/traffic` because a pinned row is
  // a standing condition rather than an event: the traffic log says what
  // happened during one request, this says which records are currently
  // unovertakable.
  get('/diagnostics/revision-anomalies', (Request request) {
    return handle(request, (context) async {
      final limit = _limitFrom(request, fallback: 100);
      final entries = await context.repo.revisionAnomalies(limit: limit);
      return _json({
        'anomalies': [for (final e in entries) e.toJson()],
      });
    });
  });

  get('/diagnostics/traffic', (Request request) {
    return handle(request, (context) async {
      final limit = _limitFrom(request, fallback: 100);
      final lostOnly = request.url.queryParameters['lost_only'] == 'true';
      final entries = lostOnly
          ? await context.trafficLog.recentLost(limit: limit)
          : await context.trafficLog.recent(limit: limit);
      return _json({
        'entries': [for (final e in entries) _entryJson(e)],
      });
    });
  });

  return router;
}

Map<String, Object?> _entryJson(SyncTrafficLogEntry e) => {
  'id': e.id,
  'occurred_at': e.occurredAt.toIso8601String(),
  'kind': e.kind,
  'user_id': e.userId,
  'device_id': e.deviceId,
  'project_id': e.projectId,
  'cursor_in': e.cursorIn,
  'cursor_out': e.cursorOut,
  'rows_pushed': e.rowsPushed,
  'rows_applied': e.rowsApplied,
  'rows_pulled': e.rowsPulled,
  'rows_lost': e.rowsLost,
  'rows_rejected': e.rowsRejected,
  'lost_detail': [for (final l in e.lostDetail) l.toJson()],
  'client_schema_major': e.clientSchemaMajor,
  'client_schema_version': e.clientSchemaVersion,
  'status_code': e.statusCode,
  'error_code': e.errorCode,
};
