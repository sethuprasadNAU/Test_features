/// HTTP surface for the project directory (task 10.9) and for project joining
/// (task 11.81, which replaced task 11.2's per-address invitations).
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../authz/project_authorizer.dart';
import '../security/error_responses.dart';
import '../security/rate_limiter.dart';
import '../security/request_identity.dart';
import '../sync/sync_routes.dart' show SyncContext, maxDeviceIdLength;
import '../schema/postgres_schema.dart' show quoted;
import '../security/audit_log.dart';
import 'join_service.dart';
import 'project_destruction_service.dart';
import 'project_directory_service.dart';

/// Largest body any route in this file accepts.
///
/// These carry a code, a role, a name and a couple of integers — never rows —
/// so the bound is the auth routes' 2 KB rather than sync's megabytes. Task 10.56 (findings I-5,
/// I-6) is the standing rule this follows: every field on every route is
/// bounded, and an unbounded read on any authenticated route is a
/// memory-exhaustion primitive available to anyone with a session.
const int _maxProjectBodyBytes = 2048;

/// Largest team-size limit an owner may set.
///
/// Bounded because it is a caller-supplied integer that ends up in a Postgres
/// `INTEGER` column and in a comparison — task 10.56's standing rule that every
/// field on every route is bounded. A thousand is far past any field crew and
/// far below anything that hurts.
const int _maxTeamSizeLimit = 1000;

/// Builds the project-directory and invitation routes.
///
/// [withSyncContext] is the **same** authenticated-session resolver
/// `createSyncRouter` uses — this isn't a new authentication mechanism, just
/// another consumer of the one that already exists, so there is exactly one
/// place a bearer token gets validated into a session. It runs its action
/// inside a transaction, which is what lets redemption consume a code and write
/// the membership it grants as one unit.
///
/// [rateLimiter] is the process-wide limiter the auth routes already use, so
/// join attempts count against counters that outlive one request.
///
/// [withAuditLog] is the same one the auth routes get, and **this router had no
/// audit log at all until task 11.81.** That was finding Q-1, and it was
/// *accepted* — reasonably — while this router only issued invitations. It is
/// now the place membership is **granted**, so the acceptance was superseded
/// rather than left standing (Michael's decision 4, 2026-08-31). It is optional
/// for the same reason it is optional everywhere else: a server started with no
/// database-backed audit connection still serves, and a logging failure must
/// never fail a request.
Router createProjectRouter({
  required Future<Response> Function(
    Request request,
    Future<Response> Function(SyncContext) action,
  )
  withSyncContext,
  RateLimiter? rateLimiter,
  Future<void> Function(Future<void> Function(AuthAuditLog) action)?
  withAuditLog,
  ProjectDeletionPolicy? deletionPolicy,
}) {
  final router = Router();
  final limiter = rateLimiter ?? RateLimiter();
  // Task 11.290. Read once, here, so the number a person is shown before
  // they commit and the number the server applies are the same value.
  final deletions = deletionPolicy ?? ProjectDeletionPolicy.fromEnvironment();
  ProjectDestructionService destruction(SyncContext context) =>
      ProjectDestructionService(context.sync.session, policy: deletions);

  /// Records one join event, best-effort.
  ///
  /// **`subjectUserId`/`subjectEmail` are the person the event is *about*, not
  /// the person who acted** — an approval is a fact about the account being
  /// admitted, and "was my account given access to something in March?" is a
  /// question asked of an account. The acting owner goes in [reason], and the
  /// project id in `outcome`, matching what `authorization_denied` already
  /// does. **The join code never appears in any of them.**
  Future<void> audit(
    AuthAuditEvent event, {
    String? subjectUserId,
    String? subjectEmail,
    String? deviceId,
    String? projectId,
    String? reason,
    String? requestId,
  }) async {
    final write = withAuditLog;
    if (write == null) return;
    await write(
      (log) => log.record(
        event,
        userId: subjectUserId,
        email: subjectEmail,
        deviceId: deviceId,
        outcome: projectId,
        reason: reason,
        requestId: requestId,
      ),
    );
  }

  /// The projects this caller has an open membership in.
  ///
  /// **Whose projects, and the only input.** The session's `user_id`. This
  /// route reads nothing from the body, the query string or the path — there
  /// is no field on it at all — which is §4.11 applied to a read: project
  /// scope comes from the session, never from the request.
  ///
  /// **What a row carries, and what it does not** — Security Model §4.28,
  /// which task 11.64 wrote because nothing said. Five fields:
  /// `project_id`, `project_name`, `owner_user_id`, `role`, and since task
  /// 11.290 `destroy_at`. No email, no device, no token, no membership
  /// dates, none of the server's own bookkeeping. `owner_user_id` is another
  /// person's identifier and is deliberately kept — §4.28 records why, and
  /// `project_directory_field_set_test.dart` fails if a sixth field appears
  /// without that record being updated. (This comment said "four fields"
  /// from 11.290 until 11.292 — the number lives in the derived table, not
  /// here.)
  ///
  /// **Bounded and limited like every other authenticated read** (task 11.64,
  /// finding P-1). Until then this route had neither, while `/auth/sessions`
  /// — the same shape of question, answered the same way — had both under task
  /// 10.56. The gap was not a judgement that this one was safer; it is that
  /// 10.56 swept for *fields to validate* and this route has none.
  router.get('/projects/mine', (Request request) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      // After the session is resolved, because the bucket is keyed on the
      // authenticated user — same ordering, and the same reason, as invite
      // redemption below and `GET /auth/sessions`. An unauthenticated caller
      // is refused by `withSyncContext` and never reaches a bucket.
      limiter.evictExpired();
      if (limiter.checkProjectList(userId: context.session.userId) !=
          RateLimitOutcome.allowed) {
        return errorResponse(429, 'rate_limited', traceId: traceId);
      }
      final projects = await ProjectDirectoryService(
        context.sync.session,
      ).listFor(context.session.userId);
      return Response.ok(
        jsonEncode(ProjectDirectoryResponse(projects: projects).toJson()),
        headers: const {
          'content-type': 'application/json',
          // A list of somebody's projects is not something to leave in a
          // shared cache, and the sessions listing already sends this. §4.7.
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// The projects this caller deleted from a device that the server still
  /// holds as tombstones (task 11.292) — the complement of the route above,
  /// which leaves a tombstoned project out for everybody.
  ///
  /// **Same shape as `/projects/mine`, on purpose.** No field on the route at
  /// all: the caller is the session's `user_id`, and the query is scoped to
  /// them three ways (an open owner membership, a tombstoned row, and a
  /// tombstone the server recorded *them* as sending). There is nothing to
  /// aim at another person's projects and nothing to probe an id with — a
  /// caller who wants to ask about a tombstoned or destroyed id they do not
  /// hold is answered by the `_requireOwner` routes below, identically to a
  /// fictional id. `ProjectDirectoryService.listDeletedFor` says why each
  /// clause is there; Security Model §4.28 says what a row may carry and
  /// refuses the general "show me deleted projects" listing this is not.
  ///
  /// Shares `/projects/mine`'s rate-limit bucket rather than adding one: it
  /// is the same question asked of the other half of the same table, by the
  /// same screen, and a second bucket would double the allowance for a read
  /// nobody needs more of.
  router.get('/projects/deleted/mine', (Request request) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      limiter.evictExpired();
      if (limiter.checkProjectList(userId: context.session.userId) !=
          RateLimitOutcome.allowed) {
        return errorResponse(429, 'rate_limited', traceId: traceId);
      }
      final projects = await ProjectDirectoryService(
        context.sync.session,
      ).listDeletedFor(context.session.userId);
      return Response.ok(
        jsonEncode(
          DeletedProjectDirectoryResponse(projects: projects).toJson(),
        ),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    });
  });

  // ---- The owner's side ----------------------------------------------------
  //
  // All seven refuse anything but an owner, through the existing
  // [_requireOwner], which answers the same 403 for "not yours" and "no such
  // project" — §4.13's rule that a forbidden project and a fabricated one must
  // be indistinguishable.

  /// Whether joining is on, the code, the limit, and the two counts.
  ///
  /// **Returns the join code in readable form**, which is Security Model
  /// §4.2.1 — the one written exception to §4.2's "never store a token in
  /// plaintext". Read that section before changing it; the short version is
  /// that a join code stopped being a credential when this task shipped, and
  /// an owner who cannot re-read the code has to rotate and re-broadcast to a
  /// whole field crew.
  router.get('/projects/<projectId>/join-settings', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;
      final settings = await _service(context).settingsFor(projectId);
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: const {
          'content-type': 'application/json',
          // It carries a live join code. Not something to leave in a shared
          // cache, for the same reason `/projects/mine` and `/auth/sessions`
          // say so. §4.7.
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// Switches joining on or off, and sets the team-size limit.
  ///
  /// Both fields are optional; a body naming neither is accepted and changes
  /// nothing, which is what makes the screen able to send one control's value
  /// without asserting the other's.
  router.post('/projects/<projectId>/join-settings', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;

      final json = await _readJsonBody(request);
      if (json == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final enabledRaw = json['joining_enabled'];
      if (enabledRaw != null && enabledRaw is! bool) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final limitRaw = json['team_size_limit'];
      if (limitRaw != null &&
          (limitRaw is! int || limitRaw < 1 || limitRaw > _maxTeamSizeLimit)) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }

      final settings = await _service(context).updateSettings(
        projectId: projectId,
        updatedBy: context.session.userId,
        joiningEnabled: enabledRaw as bool?,
        teamSizeLimit: limitRaw as int?,
      );
      if (enabledRaw is bool) {
        await audit(
          AuthAuditEvent.joiningSwitched,
          subjectUserId: context.session.userId,
          deviceId: context.session.deviceId,
          projectId: projectId,
          reason: enabledRaw ? 'on' : 'off',
          requestId: traceId,
        );
      }
      if (limitRaw is int) {
        await audit(
          AuthAuditEvent.teamSizeLimitChanged,
          subjectUserId: context.session.userId,
          deviceId: context.session.deviceId,
          projectId: projectId,
          reason: 'limit=$limitRaw',
          requestId: traceId,
        );
      }
      return Response.ok(
        jsonEncode(settings.toJson()),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// Mints a new code and returns it.
  ///
  /// **`clear_pending` defaults to false, and this is the only place in the
  /// whole design that offers a bulk operation.** Rotation is a deliberate
  /// sequence an owner goes looking for, so an option to also empty the queue
  /// is reachable there and nowhere else — it cannot be hit by mis-tapping a
  /// list. There is deliberately **no bulk reject**: an accidental "reject all"
  /// forces every legitimate requester to ask again and be contacted
  /// individually, and that accident is far likelier than the flood it would
  /// defend against.
  router.post('/projects/<projectId>/join-code/rotate', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;

      final json = await _readJsonBody(request);
      if (json == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final clearRaw = json['clear_pending'];
      if (clearRaw != null && clearRaw is! bool) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final clearPending = clearRaw as bool? ?? false;

      final rotated = await _service(context).rotateCode(
        projectId: projectId,
        rotatedBy: context.session.userId,
        clearPending: clearPending,
      );
      await audit(
        AuthAuditEvent.joinCodeRotated,
        subjectUserId: context.session.userId,
        deviceId: context.session.deviceId,
        projectId: projectId,
        // The code itself is never recorded. How many people it displaced is.
        reason: 'cleared=${rotated.clearedPending}',
        requestId: traceId,
      );
      if (rotated.clearedPending > 0) {
        await audit(
          AuthAuditEvent.joinCleared,
          subjectUserId: context.session.userId,
          deviceId: context.session.deviceId,
          projectId: projectId,
          reason: 'count=${rotated.clearedPending}',
          requestId: traceId,
        );
      }
      return Response.ok(
        jsonEncode(rotated.toJson()),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// The project's join requests, pending first.
  router.get('/projects/<projectId>/join-requests', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;
      final requests = await _service(context).listRequests(projectId);
      return Response.ok(
        jsonEncode(JoinRequestListResponse(requests: requests).toJson()),
        headers: const {
          'content-type': 'application/json',
          // Carries other people's email addresses. §4.7.
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// Approves one request, and writes the membership it grants.
  ///
  /// **One at a time.** The role is chosen here and nowhere else — it is not in
  /// the code and not in the request — which is what makes a leaked code
  /// uninteresting: there is no such thing as a leaked *owner* code.
  router.post('/projects/<projectId>/join-requests/<requestId>/approve', (
    Request request,
    String projectId,
    String requestId,
  ) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;
      if (!_isUsableId(requestId)) {
        return errorResponse(403, joinRefusalRequestNotOpen, traceId: traceId);
      }
      final json = await _readJsonBody(request);
      if (json == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final role = _roleOf(json['role']);
      if (role == null) {
        return errorResponse(400, 'invalid_role', traceId: traceId);
      }

      final result = await _service(context).approve(
        projectId: projectId,
        requestId: requestId,
        role: role,
        decidedBy: context.session.userId,
        deviceId: context.session.deviceId,
      );
      switch (result) {
        case JoinDecisionRefused():
          return errorResponse(
            409,
            joinRefusalRequestNotOpen,
            traceId: traceId,
          );
        case JoinDecisionApplied(:final userId, :final email):
          await audit(
            AuthAuditEvent.joinApproved,
            subjectUserId: userId,
            subjectEmail: email,
            deviceId: context.session.deviceId,
            projectId: projectId,
            reason: 'role=${role.db} by=${context.session.userId}',
            requestId: traceId,
          );
          return Response.ok(
            jsonEncode(const <String, Object?>{}),
            headers: const {'content-type': 'application/json'},
          );
      }
    });
  });

  /// Rejects one request. **There is deliberately no bulk reject** — see the
  /// rotation route above for the reasoning, which is Michael's.
  router.post('/projects/<projectId>/join-requests/<requestId>/reject', (
    Request request,
    String projectId,
    String requestId,
  ) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;
      if (!_isUsableId(requestId)) {
        return errorResponse(403, joinRefusalRequestNotOpen, traceId: traceId);
      }
      final result = await _service(context).reject(
        projectId: projectId,
        requestId: requestId,
        decidedBy: context.session.userId,
      );
      switch (result) {
        case JoinDecisionRefused():
          return errorResponse(
            409,
            joinRefusalRequestNotOpen,
            traceId: traceId,
          );
        case JoinDecisionApplied(:final userId, :final email):
          await audit(
            AuthAuditEvent.joinRejected,
            subjectUserId: userId,
            subjectEmail: email,
            deviceId: context.session.deviceId,
            projectId: projectId,
            reason: 'by=${context.session.userId}',
            requestId: traceId,
          );
          return Response.ok(
            jsonEncode(const <String, Object?>{}),
            headers: const {'content-type': 'application/json'},
          );
      }
    });
  });

  /// Puts a **past member** back on the project directly (design §1.5).
  ///
  /// This is what "re-invite a past member" became, and it is better than what
  /// it replaces: today an owner re-admitting somebody they already trust makes
  /// that person go and redeem a code. **It cannot add a stranger** — the named
  /// person must already hold a closed membership row here and no open one — so
  /// it discloses nothing and grants nothing the owner had not already granted
  /// once.
  router.post('/projects/<projectId>/members/readmit', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;

      final json = await _readJsonBody(request);
      if (json == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final userId = json['user_id'];
      if (userId is! String || !_isUsableId(userId)) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final role = _roleOf(json['role']);
      if (role == null) {
        return errorResponse(400, 'invalid_role', traceId: traceId);
      }

      final result = await _service(context).readmit(
        projectId: projectId,
        userId: userId,
        role: role,
        decidedBy: context.session.userId,
        deviceId: context.session.deviceId,
      );
      if (result case JoinDecisionApplied(:final email)) {
        await audit(
          AuthAuditEvent.memberReadmitted,
          subjectUserId: userId,
          subjectEmail: email,
          deviceId: context.session.deviceId,
          projectId: projectId,
          reason: 'role=${role.db} by=${context.session.userId}',
          requestId: traceId,
        );
      }
      return switch (result) {
        JoinDecisionRefused(:final failure) => errorResponse(
          409,
          switch (failure) {
            JoinDecisionFailure.teamFull => joinRefusalTeamFull,
            _ => joinRefusalNotAPastMember,
          },
          traceId: traceId,
        ),
        JoinDecisionApplied() => Response.ok(
          jsonEncode(const <String, Object?>{}),
          headers: const {'content-type': 'application/json'},
        ),
      };
    });
  });

  // ---- Destroying the project (task 11.290) ---------------------------------
  //
  // Owner only, through the same [_requireOwner] as everything above it: this
  // destroys contributors' records and not only the owner's, which is exactly
  // why nobody below owner may do it. Both routes answer with the deletion's
  // standing so the screen draws what the server holds, never what it
  // assumed.

  /// Where this project's deletion stands, and the grace period the server
  /// would apply. Read before the owner is shown the dialog, so the sentence
  /// *"in 30 days"* is the server's number and not the app's guess.
  router.get('/projects/<projectId>/deletion', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;
      final standing = await destruction(context).standingFor(projectId);
      return Response.ok(
        jsonEncode(standing.toJson()),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// Schedules, carries out, or cancels this project's destruction — or,
  /// since task 11.302, **restores** a project its owner deleted in the app —
  /// by [ProjectDeletionAction].
  ///
  /// **Restore is here rather than on a route of its own** because it is the
  /// same owner acting on the same project's deletion, it answers with the
  /// same standing, and a new route would be a new surface to inventory and
  /// attack for one verb. It is the one action gated more narrowly than
  /// `_requireOwner`: see [_restore].
  ///
  /// **The server sets the date.** The body carries an action and nothing
  /// else — no date, no number of days — so a device with a wrong clock, or a
  /// hostile one, cannot shorten or extend anybody's grace period. The
  /// *immediate* action runs the destruction inside this request's
  /// transaction; after it commits the project has no members and this route
  /// refuses the same caller as it would a stranger, which is the same
  /// answer every other route gives for a project that is not there.
  router.post('/projects/<projectId>/deletion', (
    Request request,
    String projectId,
  ) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      final refusal = await _requireOwner(context, projectId, request);
      if (refusal != null) return refusal;

      final json = await _readJsonBody(request);
      if (json == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final action = ProjectDeletionAction.fromWire(json['action']);
      if (action == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }

      final service = destruction(context);
      final userId = context.session.userId;
      final ProjectDeletionStanding standing;
      switch (action) {
        case ProjectDeletionAction.schedule:
          standing = await service.schedule(
            projectId: projectId,
            scheduledBy: userId,
          );
          await audit(
            AuthAuditEvent.projectDeletionScheduled,
            subjectUserId: userId,
            deviceId: context.session.deviceId,
            projectId: projectId,
            reason: 'destroy_at=${standing.destroyAt?.toIso8601String()}',
            requestId: traceId,
          );
        case ProjectDeletionAction.cancel:
          standing = await service.cancel(projectId);
          await audit(
            AuthAuditEvent.projectDeletionCanceled,
            subjectUserId: userId,
            deviceId: context.session.deviceId,
            projectId: projectId,
            requestId: traceId,
          );
        case ProjectDeletionAction.immediate:
          final rows = await service.destroy(
            projectId: projectId,
            scheduledBy: userId,
          );
          standing = await service.standingFor(projectId);
          await audit(
            AuthAuditEvent.projectDestroyed,
            subjectUserId: userId,
            deviceId: context.session.deviceId,
            projectId: projectId,
            reason: 'immediate rows=$rows',
            requestId: traceId,
          );
        case ProjectDeletionAction.restore:
          final withdrawn = (await service.standingFor(projectId)).destroyAt;
          final restored = await _restore(context, service, projectId);
          if (restored == null) {
            return errorResponse(403, 'forbidden', traceId: traceId);
          }
          standing = await service.standingFor(projectId);
          if (restored) {
            await audit(
              AuthAuditEvent.projectRestored,
              subjectUserId: userId,
              deviceId: context.session.deviceId,
              projectId: projectId,
              reason: withdrawn == null
                  ? null
                  : 'withdrew destroy_at=${withdrawn.toIso8601String()}',
              requestId: traceId,
            );
          }
      }
      return Response.ok(
        jsonEncode(standing.toJson()),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    });
  });

  // ---- The requester's side --------------------------------------------------

  /// The caller's own join requests.
  ///
  /// **Keyed on the session and nothing else.** There is no field on this route
  /// by which a caller could name somebody else. It exists so that a rejected
  /// person is *told* rather than left waiting forever — the defect task 11.60
  /// exists to have fixed for removed members, answered here before it could
  /// happen again. Inventory entry 29.
  ///
  /// Registered before the owner's `/projects/<projectId>/join-requests` for
  /// clarity, though the two cannot collide: this one's third segment must
  /// literally be `mine`, and that one's must literally be `join-requests`.
  router.get('/projects/join-requests/mine', (Request request) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);
      limiter.evictExpired();
      if (limiter.checkJoinRequestList(userId: context.session.userId) !=
          RateLimitOutcome.allowed) {
        return errorResponse(429, 'rate_limited', traceId: traceId);
      }
      final requests = await _service(
        context,
      ).myRequests(context.session.userId);
      return Response.ok(
        jsonEncode(MyJoinRequestsResponse(requests: requests).toJson()),
        headers: const {
          'content-type': 'application/json',
          'cache-control': 'no-store',
        },
      );
    });
  });

  /// Asks to join whichever project the code names.
  ///
  /// **No `project_id` in the path**, for exactly the reason the old redeem
  /// route had none: a route that took one would let a caller ask "does this
  /// code work for project X" and read the answer off the difference, which is
  /// §4.13's existence oracle in a new costume.
  ///
  /// **This grants nothing.** It creates a row an owner will look at. The one
  /// thing it accepts beyond the code is the requester's **claimed name**,
  /// which is caller-supplied text bounded by the same rule `Users.first_name`
  /// carries — see [JoinService.request] and Michael's decision 1.
  router.post('/projects/join-requests', (Request request) {
    return withSyncContext(request, (context) async {
      final traceId = traceIdOf(request);

      limiter.evictExpired();
      if (limiter.checkJoinRequest(userId: context.session.userId) !=
          RateLimitOutcome.allowed) {
        return errorResponse(429, 'rate_limited', traceId: traceId);
      }

      final json = await _readJsonBody(request);
      if (json == null) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }
      final code = json['code'];
      // Bounded before it reaches `canonicalizeJoinCode`, which walks every
      // rune. The code is 8 characters — 64 is room for hyphens, spaces and a
      // fat-fingered paste.
      if (code is! String || code.isEmpty || code.length > 64) {
        return _codeNotValid(traceId);
      }
      final nameRaw = json['claimed_name'];
      if (nameRaw != null && nameRaw is! String) {
        return errorResponse(400, 'malformed_body', traceId: traceId);
      }

      final service = _service(context);
      final email = await service.authenticatedEmailOf(context.session.userId);
      if (email == null) {
        // A live session whose account row is gone. Nothing the caller can act
        // on, and it must not read differently from a bad code.
        return _codeNotValid(traceId);
      }

      final result = await service.request(
        rawCode: code,
        userId: context.session.userId,
        authenticatedEmail: email,
        claimedName: nameRaw as String?,
        deviceId: context.session.deviceId,
      );

      switch (result) {
        case JoinRequestAccepted(:final requestId, :final projectName):
          await audit(
            AuthAuditEvent.joinRequested,
            subjectUserId: context.session.userId,
            subjectEmail: email,
            deviceId: context.session.deviceId,
            reason: 'accepted',
            requestId: traceId,
          );
          return Response.ok(
            jsonEncode(
              JoinRequestCreatedResponse(
                requestId: requestId,
                projectName: projectName,
              ).toJson(),
            ),
            headers: const {
              'content-type': 'application/json',
              'cache-control': 'no-store',
            },
          );
        case JoinRequestRefused(:final failure):
          // **The refused attempt is logged too**, and it is the more useful
          // of the two when reading this log later: a sweep of guessed codes
          // is a run of these. `outcome` is deliberately left null — naming
          // the project a wrong code failed to reach would record an answer
          // the caller was refused.
          await audit(
            AuthAuditEvent.joinRequested,
            subjectUserId: context.session.userId,
            subjectEmail: email,
            deviceId: context.session.deviceId,
            reason: 'refused=${failure.name}',
            requestId: traceId,
          );
          return switch (failure) {
            // These three are facts about the caller themselves, so saying
            // them discloses nothing and saves a pointless trip to the owner.
            JoinRequestFailure.alreadyMember => errorResponse(
              409,
              joinRefusalAlreadyMember,
              traceId: traceId,
            ),
            JoinRequestFailure.alreadyRequested => errorResponse(
              409,
              joinRefusalAlreadyRequested,
              traceId: traceId,
            ),
            JoinRequestFailure.teamFull => errorResponse(
              409,
              joinRefusalTeamFull,
              traceId: traceId,
            ),
            JoinRequestFailure.invalidName => errorResponse(
              400,
              joinRefusalInvalidName,
              traceId: traceId,
            ),
            JoinRequestFailure.codeNotValid => _codeNotValid(traceId),
          };
      }
    });
  });

  return router;
}

JoinService _service(SyncContext context) =>
    JoinService(session: context.sync.session, sync: context.sync);

/// The owner's *restore* (task 11.302): true when a tombstone was cleared,
/// false when there was nothing to clear, and **null when this caller may
/// not** — which the route answers with the same `403 forbidden` as
/// everything else here.
///
/// **Who may is the listing's population, asked of the listing's own
/// query** — `ProjectDirectoryService.isDeletedBy`, built from the same text
/// as `GET /projects/deleted/mine`, so the join screen never offers a
/// restore the server refuses and the server never permits one the screen
/// cannot show. `_requireOwner` has already run and admits any open owner;
/// this narrows it to the owner who deleted it (§4.28.1 says why, and what
/// would reopen it).
///
/// **A project that is not deleted is not a refusal.** The caller is an
/// owner of it, so saying so discloses nothing, and a restore whose answer
/// was lost on a field link is retried by the app: the retry must read as
/// done, not as refused. It changes nothing and writes no audit row.
///
/// **One act, one transaction.** Any destruction scheduled for it is
/// withdrawn first — a restored project still counting down to destruction
/// would be restored in name only — and the tombstone cleared second. The
/// withdrawal takes the `project_destruction` row's lock, which is what the
/// sweep's own re-check waits on (`destroyIfStillDue`); if the sweep got
/// there first, the `Projects` row is gone by the time it is read here, this
/// returns false, and the standing the route answers with says the project
/// was destroyed.
Future<bool?> _restore(
  SyncContext context,
  ProjectDestructionService destruction,
  String projectId,
) async {
  final session = context.sync.session;
  final userId = context.session.userId;
  if (!await ProjectDirectoryService(session).isDeletedBy(userId, projectId)) {
    final live = await session.execute(
      'SELECT 1 FROM ${quoted(Tables.projects)} '
      r'WHERE project_id = $1 AND deleted_at IS NULL',
      parameters: [projectId],
    );
    return live.isEmpty ? null : false;
  }
  await destruction.cancel(projectId);
  return context.sync.restoreTombstonedProject(
    projectId: projectId,
    restoredBy: userId,
    deviceId: context.session.deviceId,
  );
}

/// Refuses unless the session owns [projectId], identically for "not yours"
/// and "no such project".
///
/// §4.11: project scope comes from the session, never from the request. The
/// `project_id` in the path is a filter within what the session already
/// reaches, never the grant — and §4.13 requires that a forbidden project and a
/// fabricated one answer the same, so both land on the same 403.
Future<Response?> _requireOwner(
  SyncContext context,
  String projectId,
  Request request,
) async {
  if (projectId.isEmpty ||
      projectId.length > maxDeviceIdLength ||
      _hasControlCharacter(projectId)) {
    return errorResponse(403, 'forbidden', traceId: traceIdOf(request));
  }
  final access = await ProjectAuthorizer.resolve(
    context.sync.session,
    projectId: projectId,
    userId: context.session.userId,
  );
  if (access != ProjectAccess.owner) {
    return errorResponse(403, 'forbidden', traceId: traceIdOf(request));
  }
  return null;
}

/// The single refusal every unusable join code draws.
///
/// Malformed, unknown, belonging to a project whose owner has switched joining
/// off, and belonging to a project that has been deleted are **one answer**.
/// See [joinRefusalCodeNotValid] for why: splitting them would let somebody
/// sweeping codes learn which guesses named a real project.
Response _codeNotValid(String? traceId) =>
    errorResponse(403, joinRefusalCodeNotValid, traceId: traceId);

/// Whether a path or body identifier is one this server will carry to a query.
///
/// The same triple `_requireOwner` applies to a project id, hoisted because
/// three routes now take a second identifier (a request id, a user id) and
/// three copies of a bound is how they come to disagree.
bool _isUsableId(String value) =>
    value.isNotEmpty &&
    value.length <= maxDeviceIdLength &&
    !_hasControlCharacter(value);

ProjectRole? _roleOf(Object? value) {
  if (value is! String) return null;
  for (final role in ProjectRole.values) {
    if (role.db == value) return role;
  }
  return null;
}

/// C0/C7 controls, NUL included.
///
/// NUL matters most (task 10.64, finding J-4's class): every value checked here
/// reaches a Postgres `TEXT` column or a `WHERE` clause unhashed, and Postgres
/// rejects a NUL byte in `TEXT` mid-statement rather than returning a typed
/// refusal — which is a bare 500 seen from outside. The rest go because an
/// address or an id containing a CR is a header-injection question nobody
/// should have to re-answer per sink.
bool _hasControlCharacter(String value) =>
    RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

/// Reads a request body, refusing anything oversized or not a JSON object.
Future<Map<String, Object?>?> _readJsonBody(Request request) async {
  final declared = request.contentLength;
  if (declared != null && declared > _maxProjectBodyBytes) return null;
  final buffer = <int>[];
  await for (final chunk in request.read()) {
    buffer.addAll(chunk);
    // Checked while streaming too: Content-Length is caller-supplied, and a
    // chunked request need not declare one at all.
    if (buffer.length > _maxProjectBodyBytes) return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(buffer));
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}
