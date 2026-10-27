/// HTTP surface for sync (task 10.7).
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../auth/auth_service.dart';
import '../authz/closed_membership_disclosure.dart';
import '../authz/project_authorizer.dart';
import '../authz/row_authorizer.dart';
import '../diagnostics/sync_traffic_log.dart';
import '../projects/project_destruction_service.dart';
import '../schema/postgres_schema.dart';
import '../security/audit_log.dart';
import '../security/request_identity.dart';
import 'cursor_store.dart';
import 'database_identity.dart';
import 'sync_service.dart';
import 'tombstone_retention_service.dart';

/// Everything a sync request needs, resolved per call inside a transaction.
class SyncContext {
  const SyncContext({
    required this.sync,
    required this.cursors,
    required this.session,
    required this.trafficLog,
  });

  final SyncService sync;
  final CursorStore cursors;

  /// **The authenticated session decides who is calling.** The `device_id` in
  /// the payload is a label for bookkeeping, never an authorization input — it
  /// is a forgeable client-side value (Security Model §3.7).
  final ActiveSession session;

  /// Records this request for the diagnostics console (task 10.13). Writes
  /// through the same open transaction as the sync work itself, so a logged
  /// entry and the write it describes commit or roll back together.
  final SyncTrafficLogStore trafficLog;
}

/// Largest sync body accepted.
///
/// Bigger than the auth routes' 2 KB because a push legitimately carries a
/// batch of rows, but still bounded: `defaultSyncBatchSize` rows of
/// observation-shaped JSON is a few hundred kilobytes, and an unbounded read is
/// a memory-exhaustion primitive on a route that, while authenticated, is
/// reachable by anyone with a session.
const int maxSyncBodyBytes = 8 * 1024 * 1024;

/// Longest accepted `device_id` or `project_id`.
///
/// Matches the cap `/auth/redeem` already applies to `device_id`. Generalized
/// here to `project_id` too (task 10.56, finding I-5's class): both values are
/// caller-supplied TEXT that lands in a Postgres btree index —
/// `sync_cursors`' primary key `(user_id, device_id, project_id)`,
/// `sync_traffic_log`'s `idx_sync_traffic_log_device`, and every
/// project-scoped table's `(project_id, server_seq)` index
/// (`postgres_schema.dart`). Btree tuples top out at roughly a third of an
/// 8 KB page; past that, an INSERT does not produce a typed refusal, it
/// throws mid-statement — I-5 was that throw seen from outside as a bare
/// `500` on `/sync/push`, with nothing durable and nothing in the traffic
/// log to explain it. `/sync/ack` already bounded `device_id`; push, pull,
/// and `project_id` on all three routes did not.
const int maxDeviceIdLength = 200;

/// Savepoint name for the first-publish attempt (task 10.21). A constant
/// identifier, never interpolated from a request.
const String _publishSavepoint = 'tritrack_publish';

/// A refusal, as a stable machine-readable `error` code plus optional detail.
///
/// [detail] carries the version numbers a skew refusal needs to be *actionable*
/// (task 10.11). They go in named fields rather than baked into the code string
/// so the client can tell which side is behind without parsing English, and so
/// the code itself stays a fixed vocabulary the client can switch on.
Response _error(int status, String code, {Map<String, Object?>? detail}) =>
    Response(
      status,
      body: jsonEncode({'error': code, ...?detail}),
      headers: const {'content-type': 'application/json'},
    );

/// Same shape as every other denial in this file — no detail about *why*, so
/// a caller probing project ids learns nothing beyond "no".
Response _forbidden() => _error(403, 'forbidden');

/// The one denial in this file that says why (task 11.290): the project
/// named was destroyed on this server. See [syncRefusalProjectDestroyed] in
/// the shared package for the argument — the refusal has to exist or a
/// publish-shaped push would re-create the project, and a refusal that must
/// exist is honest about itself so the device can tell its owner the right
/// cause rather than "an owner may have removed you".
Response _projectDestroyed() => _error(403, syncRefusalProjectDestroyed);

/// Whether [push] carries any row belonging to the project it names.
///
/// A push of nothing but *global* rows (`Users`, `User_Emails` — the tables
/// with no `project_id`) is not a request about that project at all: the id in
/// the envelope selects nothing, authorizes nothing, and vouches for nothing.
/// The publisher's first two requests are exactly this shape — it uploads a
/// project's people before the project row that would make them reachable
/// exists — so it has to work against an id the server has never seen. Which
/// means, for §4.13, it must work identically against one the server *has*. It
/// does, because [RowAuthorizer] no longer lets a project the caller has no
/// relationship to contribute anything to a row's authorization.
///
/// **`Tags` used to be on that list and is not (task 11.219, corrected here by
/// task 11.220).** It is project-scoped now, so a tag-only push *does* touch
/// the project it names and is refused at this route when the caller has no
/// relationship to it — rather than being let through and then refused row by
/// row. **§4.13 is unaffected and the answer is still uniform**: a real project
/// the caller cannot reach and a fabricated one both answer `403 forbidden`
/// with no detail, which `publish_and_join_test.dart`'s *"nor does a tag push"*
/// measures directly. **And a first publish still works**, because
/// `Tables.all` offers `Projects` before `Tags`, so the establishing row has
/// committed by the time the tag arrives —
/// `publish_request_sequence_test.dart` replays exactly that sequence.
bool _touchesProject(SyncPushRequest push) => syncTables.any(
  (table) =>
      table.projectScopeColumn != null &&
      (push.rows[table.name]?.isNotEmpty ?? false),
);

/// Whether [push] carries the `Projects` row that would establish the project
/// it names, with [userId] as its owner.
///
/// This is publish (task 10.9), and it is the one request that legitimately
/// concerns a project the server does not hold. The row is validated here
/// rather than left to `applyPush` so that a *malformed* establishing row is
/// refused identically to a forbidden one: were it allowed through, a
/// deliberately broken row would fail at insert and answer `500` for a free id
/// while a taken id answered `403` — the same oracle in a different costume.
bool _establishesProject(SyncPushRequest push, String userId) {
  final rows = push.rows[Tables.projects] ?? const [];
  return rows.any(
    (row) =>
        row['project_id'] == push.projectId &&
        row['owner_user_id'] == userId &&
        RowValidator.validate(Tables.projects, row).isEmpty,
  );
}

/// Per-table `invalid` outcomes for every key of `body['rows']` this build
/// does not recognize (task 10.46, finding H-5).
///
/// [SyncPushRequest.fromJson] → `decodeRows` already drops unknown table
/// names silently — deliberately: task 10.11 owns the version-refusal
/// policy, and a newer peer's not-yet-recognized table should not turn a
/// whole push into a parse error the way an unknown *column* does not
/// (task 10.18's preservation, for the same reason). But "silently" left the
/// `outcomes` map with nothing to say about the rows that vanished, where the
/// protocol already has an outcome for exactly this — `invalid`, the same one
/// `RowValidator` uses — and never produced it on this path. This reads the
/// **raw** body, before `decodeRows` filters it, because by the time a
/// [SyncPushRequest] exists the unknown keys are already gone.
///
/// Reported once per unknown *table*, not per row: an unrecognized table's
/// shape is unknown to this build, so there is no primary key to key a
/// per-row outcome by — the `/?` placeholder already used for a row this
/// build DOES recognize but cannot key (`sync_service.dart`'s `_rowKey`
/// returning null) is reused here for the same reason.
Map<String, SyncRowOutcome> _unknownTableOutcomes(Map<String, Object?> body) {
  final rawRows = body['rows'];
  if (rawRows is! Map) return const {};
  return {
    for (final key in rawRows.keys)
      if (key is String && !Tables.all.contains(key))
        '$key/?': SyncRowOutcome.invalid,
  };
}

/// Per-table `invalid` outcomes for a **known** table whose row list is
/// itself malformed: not a JSON array at all, or an array containing an
/// entry that is not a JSON object (task 10.64, finding J-5; task 10.78,
/// finding K-6's per-table half).
///
/// `decodeRows` (`sync_protocol.dart`) keeps only entries that are `List`s of
/// `Map`s — deliberately, the same forward-compatible spirit as
/// [_unknownTableOutcomes] above — so both `{"rows": {"Observations":
/// ["hello", 1, null]}}` (J-5) and `{"rows": {"Observations": "not a
/// list"}}` (K-6) answered `200 applied:0 outcomes:{}` with no trace of what
/// vanished. Task 10.46 produced `invalid` for an unrecognized table *name*;
/// this is the same silence one level in, for a row-list *shape* this build
/// cannot use inside a table name it does recognize — J-5 fixed the case
/// where the list itself was well-shaped but one entry inside it was not;
/// K-6 is the same fix for the list itself being the wrong shape. Reads the
/// **raw** body for the same reason [_unknownTableOutcomes] does — a
/// [SyncPushRequest] never sees the dropped entries.
///
/// Keyed like [_unknownTableOutcomes]: once per table, not per row — neither
/// a non-`List` value nor a non-`Map` entry inside one carries a primary key
/// to key a per-row outcome by, so this reuses the same `table/?`
/// placeholder `sync_service.dart`'s `_rowKey` returns for a row it cannot
/// key for a different reason. Safe to merge with `result.outcomes` even if
/// that map already used `table/?` for an unkeyable-but-well-shaped row in
/// the same table — both mean `invalid`.
Map<String, SyncRowOutcome> _malformedRowOutcomes(Map<String, Object?> body) {
  final rawRows = body['rows'];
  if (rawRows is! Map) return const {};
  return {
    for (final entry in rawRows.entries)
      if (entry.key is String &&
          Tables.all.contains(entry.key) &&
          (entry.value is! List ||
              (entry.value as List).any((row) => row is! Map)))
        '${entry.key}/?': SyncRowOutcome.invalid,
  };
}

/// One `invalid` outcome, keyed `rows/?`, when `body['rows']` itself is not
/// a JSON object — a string, a number, a JSON array, or absent/explicit
/// `null` (task 10.78, finding K-6's container half).
///
/// `decodeRows` treats all of these identically to an honest empty push: it
/// returns `{}` without complaint, by the same deliberate design as
/// [_unknownTableOutcomes] and [_malformedRowOutcomes] tolerate what is
/// *inside* a well-shaped `rows` object. But the container not being an
/// object at all is not a forward-compatibility question the way an unknown
/// table name is — there is no future version this could be a valid shape
/// for. [_unknownTableOutcomes] and [_malformedRowOutcomes] both already
/// require `rawRows is Map` before they look inside it, which is exactly why
/// neither one ever sees this case: task 10.64's enumeration covered every
/// *field* of the envelope and every entry *inside* `rows`, but not the
/// shape of `rows` itself. There is no table name here to key a per-table
/// outcome by, so this reports one fixed `rows/?` entry instead — enough to
/// stop the response being indistinguishable from a genuinely empty push,
/// which was the whole of the finding.
Map<String, SyncRowOutcome> _malformedContainerOutcome(
  Map<String, Object?> body,
) {
  if (body['rows'] is Map) return const {};
  return const {'rows/?': SyncRowOutcome.invalid};
}

/// `value` if it is already a [String], else `null` — never throws.
///
/// Task 10.46 (F10, H-4): the difference between this and `value as String?`
/// is the whole fix. `as String?` accepts `null` but throws on anything else
/// wrongly typed, which is exactly what a hostile or buggy caller sends.
String? _asString(Object? value) => value is String ? value : null;

/// `value` if it is already an [int], else `null` — never throws. See
/// [_asString].
int? _asInt(Object? value) => value is int ? value : null;

/// Whether [value] contains a NUL byte (task 10.64, finding J-4).
///
/// A NUL byte survives `jsonDecode` — JSON strings may carry one, escaped
/// as `\u0000` — and Postgres `TEXT` cannot: a NUL byte in a bound parameter
/// throws an `invalid_byte_sequence` error the driver raises directly, not
/// through any typed refusal this file writes. `project_id`/`device_id`
/// reach an index lookup before either per-row protection in
/// `sync_service.dart` would ever see them, which is what made this the
/// fifth field beside the four task 10.46 already typed — same class,
/// different failure mode than a wrong JSON type.
bool _hasNulByte(String value) => value.contains('\u0000');

Response _json(Map<String, Object?> body) => Response.ok(
  jsonEncode(body),
  headers: const {'content-type': 'application/json'},
);

Future<Map<String, Object?>?> _readBody(Request request) async {
  final declared = request.contentLength;
  if (declared != null && declared > maxSyncBodyBytes) return null;
  final buffer = <int>[];
  await for (final chunk in request.read()) {
    buffer.addAll(chunk);
    if (buffer.length > maxSyncBodyBytes) return null;
  }
  try {
    final decoded = jsonDecode(utf8.decode(buffer));
    return decoded is Map<String, Object?> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Builds the sync routes.
///
/// [withSyncContext] must run the action inside a **transaction**: the
/// `server_seq` allocator's correctness depends on holding its row lock until
/// that transaction commits, and a partially applied push would let a cursor
/// advance past rows that were never merged.
/// [withAuditLog] records §4.7's `authorization_denied` events. The *data
/// access* half of the audit split already lives in `SyncContext.trafficLog`
/// (task 10.13); this is the authentication half, and a denial belongs to it
/// because "who was refused access to what, and when" is an account-security
/// question retained for a year, not a where-did-my-row-go question retained
/// for a season.
Router createSyncRouter({
  required Future<Response> Function(
    Request request,
    Future<Response> Function(SyncContext) action,
  )
  withSyncContext,
  Future<void> Function(Future<void> Function(AuthAuditLog) action)?
  withAuditLog,
  SourceIdentity? sourceIdentity,
}) {
  final router = Router();
  // Task 10.52 / §4.4: the same resolver the auth routes use, so a denial
  // recorded here names the caller rather than the reverse proxy. This is
  // attribution only — nothing on these routes authorizes on an address.
  final sources = sourceIdentity ?? SourceIdentity();

  Future<void> auditDenial(
    Request request, {
    required String userId,
    required String projectId,
    required String kind,
  }) async {
    final write = withAuditLog;
    if (write == null) return;
    await write(
      (log) => log.record(
        AuthAuditEvent.authorizationDenied,
        userId: userId,
        sourceAddress: sources.of(request).auditValue,
        // The project id is the *subject* of the denial, not a secret: the
        // caller already named it, and an operator reading this log needs to
        // know which project was refused. No row content, no coordinates.
        outcome: projectId,
        reason: kind,
        requestId: traceIdOf(request),
      ),
    );
  }

  /// Logs, audits, and returns the one refusal every project-level denial on
  /// this route shares. Factored out so a forbidden project and a fictional
  /// one cannot drift apart by being written twice.
  Future<Response> refusePush(
    Request request,
    SyncContext context,
    SyncPushRequest push,
  ) async {
    await context.trafficLog.record(
      kind: 'push',
      userId: context.session.userId,
      deviceId: push.deviceId,
      projectId: push.projectId,
      clientSchemaMajor: push.envelope.schemaMajor,
      clientSchemaVersion: push.envelope.schemaVersion,
      statusCode: 403,
      errorCode: 'forbidden',
    );
    await auditDenial(
      request,
      userId: context.session.userId,
      projectId: push.projectId,
      kind: 'push',
    );
    return _forbidden();
  }

  /// Whether [projectId] was destroyed here (task 11.290). **Asked on every
  /// push, pull and ack, unconditionally**, so the work done for a live
  /// project, a fictional one and a destroyed one is one indexed probe each
  /// — the same equal-work discipline §4.13 asks of `ProjectAuthorizer`.
  Future<bool> wasDestroyed(SyncContext context, String projectId) =>
      ProjectDestructionService(
        context.sync.session,
        policy: const ProjectDeletionPolicy(grace: Duration.zero),
      ).wasDestroyed(projectId);

  /// Logs and audits the destroyed-project refusal, for whichever route met
  /// it. The audit reason names the route, as [auditDenial] does for a
  /// forbidden project, so an operator can tell the two apart.
  Future<Response> refuseDestroyed(
    Request request,
    SyncContext context, {
    required String kind,
    required String projectId,
    required String deviceId,
    required SyncEnvelope envelope,
  }) async {
    await context.trafficLog.record(
      kind: kind,
      userId: context.session.userId,
      deviceId: deviceId,
      projectId: projectId,
      clientSchemaMajor: envelope.schemaMajor,
      clientSchemaVersion: envelope.schemaVersion,
      statusCode: 403,
      errorCode: syncRefusalProjectDestroyed,
    );
    await auditDenial(
      request,
      userId: context.session.userId,
      projectId: projectId,
      kind: '${kind}_project_destroyed',
    );
    return _projectDestroyed();
  }

  /// Applies a first publish inside a savepoint, returning null if it did not
  /// cleanly establish the project.
  ///
  /// The savepoint is what lets a failed publish become a refusal rather than
  /// a `500`: without it the caller could tell a free project id from a taken
  /// one by pushing a deliberately broken batch — a `500` for the id that let
  /// the write begin, a `403` for the one that never did.
  ///
  /// `SET CONSTRAINTS ALL IMMEDIATE` is the load-bearing line. Foreign keys are
  /// `DEFERRABLE INITIALLY DEFERRED` (task 10.5), so a dangling reference would
  /// otherwise not raise until COMMIT — long after the savepoint could still
  /// catch it, and back to a `500`. Forcing the check here brings that failure
  /// inside the savepoint, where it can be turned into the same "no" as
  /// everything else. Both the constraint mode and the rows roll back together.
  Future<PushResult?> attemptPublish(
    SyncContext context,
    SyncPushRequest push,
    RowAuthorizer authorizer,
  ) async {
    final session = context.sync.session;
    await session.execute('SAVEPOINT $_publishSavepoint');
    try {
      final result = await context.sync.applyPush(
        projectId: push.projectId,
        rows: push.rows,
        authorizer: authorizer,
        deviceId: push.deviceId,
      );
      await session.execute('SET CONSTRAINTS ALL IMMEDIATE');
      // A publish that did not leave this caller owning this project was not a
      // publish, whatever else it managed to do. Checked rather than assumed,
      // because "the batch contained a row that would establish it" and "the
      // project is established" are not the same statement — the row could
      // have lost a merge, or been refused by [RowAuthorizer].
      final owner = await session.execute(
        'SELECT owner_user_id FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: [push.projectId],
      );
      if (owner.isEmpty || owner.first.first != context.session.userId) {
        await session.execute('ROLLBACK TO SAVEPOINT $_publishSavepoint');
        return null;
      }
      await session.execute('RELEASE SAVEPOINT $_publishSavepoint');
      return result;
    } catch (_) {
      // Deliberately catch-all. Every failure of a first publish has to leave
      // the same trace on the wire, or the exception type becomes the oracle.
      await session.execute('ROLLBACK TO SAVEPOINT $_publishSavepoint');
      return null;
    }
  }

  /// Wraps a handler with envelope decoding, uniform error mapping, and
  /// traffic logging (task 10.13) — every request logged exactly once, at
  /// exactly one call site, regardless of which of push/pull/ack it was or
  /// whether it succeeded.
  Future<Response> handle(
    Request request,
    String kind,
    Future<Response> Function(SyncContext, Map<String, Object?>) action,
  ) async {
    final body = await _readBody(request);
    if (body == null) return _error(400, 'malformed_body');
    // Best-effort, for logging only — a body that fails full envelope
    // parsing may still carry a readable project/device id, and a refusal is
    // exactly the case a developer most wants attributed to a project.
    //
    // **Task 10.46, findings F10 and H-4.** These four used to be `as
    // String?`/`as int?` — an unchecked cast that only tolerates `null`, not
    // a *wrongly typed* value. `{"project_id": 42}` or
    // `{"schema_major": "2"}` threw here, before authentication runs and
    // before `withSyncContext` below has even resolved a session — an
    // unauthenticated caller drew a `500` where every other malformed shape
    // correctly draws a typed `4xx`, and steered the error path from outside
    // any session at all. `_asString`/`_asInt` return `null` on a wrong type
    // instead of throwing; the *real* validation (which must reject a
    // wrongly-typed field, not silently log `null` and move on) still
    // happens below, in `SyncEnvelope.fromJson`, which throws
    // [SyncProtocolException] for exactly this shape and is caught into a
    // proper `400 malformed_envelope`.
    final loggedProjectId = _asString(body['project_id']);
    final loggedDeviceId = _asString(body['device_id']);
    final loggedSchemaMajor = _asInt(body['schema_major']);
    final loggedSchemaVersion = _asInt(body['schema_version']);

    // Task 10.56, I-5's class: bounded before any query touches an index on
    // either value, on all three routes — not just the one the finding
    // probed. A malformed-envelope 400 here is indistinguishable from any
    // other oversized-field refusal, and is cheaper than the transaction
    // `withSyncContext` is about to open.
    //
    // Task 10.64, finding J-4's other half: the same index reject a NUL byte
    // the same way, but as a raw driver exception rather than a typed
    // refusal — see [_hasNulByte]. Checked in the same condition as the
    // length bound because both are "this value can never reach the index
    // safely," and a malformed-envelope 400 is the correct answer to both.
    if ((loggedProjectId != null &&
            (loggedProjectId.length > maxDeviceIdLength ||
                _hasNulByte(loggedProjectId))) ||
        (loggedDeviceId != null &&
            (loggedDeviceId.length > maxDeviceIdLength ||
                _hasNulByte(loggedDeviceId)))) {
      return _error(400, 'malformed_envelope');
    }

    return withSyncContext(request, (context) async {
      Future<Response> logged(Response response, {String? errorCode}) async {
        await context.trafficLog.record(
          kind: kind,
          userId: context.session.userId,
          deviceId: loggedDeviceId,
          projectId: loggedProjectId,
          clientSchemaMajor: loggedSchemaMajor,
          clientSchemaVersion: loggedSchemaVersion,
          statusCode: response.statusCode,
          errorCode: errorCode,
        );
        return response;
      }

      try {
        return await action(context, body);
      } on SyncProtocolVersionException catch (error) {
        // Explicit and actionable, per task 10.11's requirement — a client told
        // "update to sync" can act on it, while a silent partial sync is data
        // loss. This deliberately reports the version numbers: they are not
        // sensitive, and withholding them would make the message unactionable.
        return logged(
          _error(
            409,
            'protocol_version_mismatch',
            detail: {
              'client_protocol_version': error.received,
              'server_protocol_version': error.supported,
            },
          ),
          errorCode: 'protocol_version_mismatch',
        );
      } on SyncSchemaVersionException catch (error) {
        // Task 10.18's version-skew refusal (10.11's, with the boundary moved
        // from the minor to the major). `received` is the caller's and
        // `supported` is this server's, so the client can work out which side is
        // behind and tell the right party to update — sending a field tech to
        // update an app that is already current, while the *server* is the stale
        // one, is exactly the unactionable message the task rules out. Only a
        // major mismatch reaches here; a minor difference is compatible.
        return logged(
          _error(
            409,
            'schema_version_mismatch',
            detail: {
              'client_schema_version': error.received,
              'server_schema_version': error.supported,
              'client_schema_major': error.receivedMajor,
              'server_schema_major': error.supportedMajor,
            },
          ),
          errorCode: 'schema_version_mismatch',
        );
      } on StaleCursorException catch (error) {
        // Task 10.11's retention refusal. 409 rather than 403 because this is
        // not an authorization failure — the caller is entitled to this
        // project, its *position* is unusable — and because the client already
        // treats 409 as terminal, which is correct here: retrying changes
        // nothing until the device is reconciled deliberately.
        return logged(
          _error(
            409,
            'cursor_too_old',
            detail: {
              'device_cursor': error.cursor,
              'purged_through_seq': error.purgedThroughSeq,
            },
          ),
          errorCode: 'cursor_too_old',
        );
      } on SyncProtocolException {
        return logged(
          _error(400, 'malformed_envelope'),
          errorCode: 'malformed_envelope',
        );
      }
    });
  }

  router.post('/sync/push', (Request request) {
    return handle(request, 'push', (context, body) async {
      final push = SyncPushRequest.fromJson(body);
      final resolved = await ProjectAuthorizer.resolve(
        context.sync.session,
        projectId: push.projectId,
        userId: context.session.userId,
      );
      // **Task 11.290.** A destroyed project reads as *absent* to the
      // resolver, and an absent project is exactly the one a publish may
      // establish — so without this, an owner's device that was offline
      // across the deletion and holds a pending change to the `Projects` row
      // would re-create the project on its next round. A push that names the
      // project's rows is refused; a push of nothing but global rows is left
      // alone, because it says nothing about the project (see
      // [_touchesProject]).
      final destroyed = await wasDestroyed(context, push.projectId);
      if (destroyed && _touchesProject(push)) {
        return refuseDestroyed(
          request,
          context,
          kind: 'push',
          projectId: push.projectId,
          deviceId: push.deviceId,
          envelope: push.envelope,
        );
      }
      // **Task 10.21.** A caller with no relationship to this project may
      // still be making one of two requests that say nothing about whether it
      // exists: a push of global rows only (see [_touchesProject]), or the
      // publish that establishes it (see [_establishesProject]). Everything
      // else is refused, and refused the same way whether the project is
      // forbidden or fictional — which is §4.13's whole requirement.
      final publishing =
          resolved == ProjectAccess.absent &&
          _establishesProject(push, context.session.userId);
      final permitted =
          resolved.permitsSync || publishing || !_touchesProject(push);
      if (!permitted) {
        return refusePush(request, context, push);
      }
      // Only a device that actually syncs this project can be behind its purge
      // floor, and asking on behalf of one that does not is itself a tell: a
      // stranger's global-only push would draw a `409` for a real project with
      // a floor and a `200` for a fictional one.
      if (resolved.permitsSync) {
        // Task 10.11: before accepting any row, confirm this device is not
        // pushing from behind a tombstone purge. Checked here rather than
        // inside `applyPush` so the refusal is a transport-level "your position
        // is too old", not a per-row outcome the client would treat as partial
        // success.
        await TombstoneRetentionService(
          context.sync.session,
        ).assertDeviceMayPush(
          userId: context.session.userId,
          deviceId: push.deviceId,
          projectId: push.projectId,
        );
      }
      final PushResult result;
      final authorizer = RowAuthorizer(
        session: context.sync.session,
        projectId: push.projectId,
        userId: context.session.userId,
        // Project access alone is not authorization: it says the caller may
        // touch this project, not that they may write each row they sent.
        // A publish is authorized as the owner it is in the act of becoming —
        // the `Projects` row naming this caller is landing in this very
        // transaction, so by the time anything is visible, it is true.
        access: publishing ? ProjectAccess.owner : resolved,
      );
      if (publishing) {
        // A publish is the only request on this route that *writes* to a
        // project the caller has no relationship to, and writes can fail —
        // a dangling foreign key, a missing NOT NULL column. Left alone, those
        // failures answer `500` where a forbidden project answers `403`, and
        // the difference is the oracle again, now reachable without even
        // creating anything. So the whole attempt runs in a savepoint and any
        // failure becomes the same refusal: a first publish either works, or
        // it is indistinguishable from being turned away. The real cause is
        // still in the server log against this request's trace id.
        final attempt = await attemptPublish(context, push, authorizer);
        if (attempt == null) {
          return refusePush(request, context, push);
        }
        result = attempt;
      } else {
        result = await context.sync.applyPush(
          projectId: push.projectId,
          rows: push.rows,
          authorizer: authorizer,
          deviceId: push.deviceId,
        );
      }
      // H-5: a table name in the raw body this build does not recognize.
      // J-5 (task 10.64) / K-6 (task 10.78): a table's row list that isn't
      // shaped right, or isn't there at all. All three are `decodeRows`
      // filtering the raw body before `result` was computed, so all three
      // are folded in here from the raw body rather than from `push.rows`.
      final outcomes = {
        ...result.outcomes,
        ..._unknownTableOutcomes(body),
        ..._malformedRowOutcomes(body),
        ..._malformedContainerOutcome(body),
      };
      final rowsRejected = outcomes.values
          .where(
            (o) =>
                o == SyncRowOutcome.invalid || o == SyncRowOutcome.unauthorized,
          )
          .length;
      await context.trafficLog.record(
        kind: 'push',
        userId: context.session.userId,
        deviceId: push.deviceId,
        projectId: push.projectId,
        cursorOut: result.highestServerSeq,
        rowsPushed: push.rowCount,
        rowsApplied: result.applied,
        rowsRejected: rowsRejected,
        // Table + primary key only, per [LoggedLostRow] — this is a debugging
        // aid, not a second copy of project data.
        lost: [
          for (final row in result.lost)
            LoggedLostRow(table: row.table, primaryKey: row.primaryKey),
        ],
        clientSchemaMajor: push.envelope.schemaMajor,
        clientSchemaVersion: push.envelope.schemaVersion,
        statusCode: 200,
      );
      return _json(
        SyncPushResponse(
          applied: result.applied,
          outcomes: outcomes,
          // The three folded-in outcome sets above are all "this build cannot
          // read what you sent", which names no column and carries no detail.
          // `SyncPushResponse` drops any detail that does not sit on an
          // `invalid` outcome, so this cannot widen what a refusal discloses.
          refusals: result.refusals,
          interlockRefusals: result.interlockRefusals,
          highestServerSeq: result.highestServerSeq,
          // Task 11.58 — see `database_identity.dart`.
          databaseId: await readDatabaseIdentity(context.sync.session),
        ).toJson(),
      );
    });
  });

  router.post('/sync/pull', (Request request) {
    return handle(request, 'pull', (context, body) async {
      final pull = SyncPullRequest.fromJson(body);
      final access = await ProjectAuthorizer.resolve(
        context.sync.session,
        projectId: pull.projectId,
        userId: context.session.userId,
      );
      // Task 11.290 — see the push route. A pull cannot resurrect anything,
      // but a device that never saw the countdown learns the cause here on
      // its first round back, instead of reading a bare refusal as removal.
      if (await wasDestroyed(context, pull.projectId)) {
        return refuseDestroyed(
          request,
          context,
          kind: 'pull',
          projectId: pull.projectId,
          deviceId: pull.deviceId,
          envelope: pull.envelope,
        );
      }
      if (!access.permitsSync) {
        // **The closed-membership disclosure exemption** (task 11.60, §4.27,
        // inventory entry 28). The one thing this server tells a caller it is
        // otherwise refusing: their own membership rows, on this project,
        // whose stint is over — so a person an owner removed learns they were
        // removed, instead of being shown "the server is refusing access" and
        // a delete control that does nothing.
        //
        // **Run unconditionally, before the answer is chosen.** Not inside an
        // `if` that only a member-ish caller reaches: a lookup that ran only
        // where it could succeed would make the refusal branch shorter than
        // the disclosure branch, and the amount of work done is as observable
        // from outside as the status code is (§4.13, and task 10.29's D-1,
        // which was this same question answered one level down). For every
        // caller who is not the person this exemption exists for, it returns
        // empty and the refusal below is byte-for-byte what it was before.
        final closed = await ClosedMembershipDisclosure.rowsFor(
          context.sync.session,
          projectId: pull.projectId,
          userId: context.session.userId,
        );
        if (closed.isEmpty) {
          await context.trafficLog.record(
            kind: 'pull',
            userId: context.session.userId,
            deviceId: pull.deviceId,
            projectId: pull.projectId,
            cursorIn: pull.cursor,
            clientSchemaMajor: pull.envelope.schemaMajor,
            clientSchemaVersion: pull.envelope.schemaVersion,
            statusCode: 403,
            errorCode: 'forbidden',
          );
          await auditDenial(
            request,
            userId: context.session.userId,
            projectId: pull.projectId,
            kind: 'pull',
          );
          return _forbidden();
        }
        // Still a denial, and audited as one — the request asked for the
        // project and got one table's worth of the caller's own rows. §4.7's
        // "who was refused access to what, and when" is the right question
        // for this, and recording it under a distinct reason is what lets an
        // operator tell it from the flat refusal above. Volume does not rise:
        // a device that learns this stops syncing the project, where before
        // it went on being refused every interval forever.
        await auditDenial(
          request,
          userId: context.session.userId,
          projectId: pull.projectId,
          kind: 'pull_membership_closed',
        );
        await context.trafficLog.record(
          kind: 'pull',
          userId: context.session.userId,
          deviceId: pull.deviceId,
          projectId: pull.projectId,
          cursorIn: pull.cursor,
          // **The cursor is handed straight back, and that is load-bearing.**
          // It makes this a page the client never acknowledges — ack is still
          // refused for a closed stint, and a client that acked here would
          // throw away a page it had already committed. It also makes the
          // disclosure independent of where the device's cursor happens to
          // sit, so a row already below it is still delivered.
          cursorOut: pull.cursor,
          rowsPulled: closed.length,
          clientSchemaMajor: pull.envelope.schemaMajor,
          clientSchemaVersion: pull.envelope.schemaVersion,
          statusCode: 200,
          errorCode: 'membership_closed',
        );
        return _json(
          SyncPullResponse(
            rows: {Tables.projectMemberships: closed},
            nextCursor: pull.cursor,
            // Nothing follows this page, ever. `remaining` is what the
            // client's pull loop reads as `hasMore`, so a non-zero value here
            // would spin a removed device against a route that will only ever
            // hand back the same rows.
            remaining: 0,
            // Task 11.58. On the disclosure page too: a removed member's
            // device reading this page is still reading *this* database.
            databaseId: await readDatabaseIdentity(context.sync.session),
          ).toJson(),
        );
      }
      // Task 10.11: an *incremental* pull from below the purge floor would
      // hand back a page implying the device is now current, when in fact it
      // is missing deletes the server can no longer describe. A cursor of zero
      // is exempt — that is a full re-pull, which is the safe request.
      await TombstoneRetentionService(
        context.sync.session,
      ).assertCursorIsFresh(projectId: pull.projectId, cursor: pull.cursor);
      // Task 11.291: a pull says where this device is, and the server keeps
      // that. Until this line the only writer of `sync_cursors` was
      // `/sync/ack`, which the app sends only after a page that *moved* — so
      // a project's publisher (a push, then pulls that return nothing) and
      // any device on a quiet project had no row here at all, and the
      // tombstone sweep's active-device holdback, which reads this table,
      // could not see them. A device that synced every week then read as
      // one that had never been here, and the guard above would refuse it
      // the first time anything in its project was purged. The cursor in a
      // pull is the position the client has committed — the same number an
      // ack carries, from the same device, earlier — and `acknowledge` is
      // monotonic, so a low or replayed cursor never lowers a recorded
      // position. Recorded after the guard, so a refused pull records
      // nothing; and not on the closed-membership page above, because that
      // is a disclosure to a removed device, not a sync.
      await context.cursors.acknowledge(
        SyncCursorKey(
          userId: context.session.userId,
          deviceId: pull.deviceId,
          projectId: pull.projectId,
        ),
        cursor: pull.cursor,
        at: DateTime.now().toUtc(),
      );
      final page = await context.sync.pull(
        projectId: pull.projectId,
        // The client's cursor, not the stored one — the client is the only
        // party that knows what it actually committed.
        cursor: pull.cursor,
        batchSize: pull.batchSize,
      );
      await context.trafficLog.record(
        kind: 'pull',
        userId: context.session.userId,
        deviceId: pull.deviceId,
        projectId: pull.projectId,
        cursorIn: pull.cursor,
        cursorOut: page.nextCursor,
        rowsPulled: page.rows.values.fold(0, (sum, rows) => sum + rows.length),
        clientSchemaMajor: pull.envelope.schemaMajor,
        clientSchemaVersion: pull.envelope.schemaVersion,
        statusCode: 200,
      );
      return _json(
        SyncPullResponse(
          rows: page.rows,
          nextCursor: page.nextCursor,
          remaining: page.remaining,
          // Task 11.58: which database this page's numbering belongs to, so a
          // device holding a bookmark into a different one can tell.
          databaseId: await readDatabaseIdentity(context.sync.session),
        ).toJson(),
      );
    });
  });

  router.post('/sync/ack', (Request request) {
    return handle(request, 'ack', (context, body) async {
      final ack = SyncAckRequest.fromJson(body);
      final access = await ProjectAuthorizer.resolve(
        context.sync.session,
        projectId: ack.projectId,
        userId: context.session.userId,
      );
      // Task 11.290 — the same answer on all three routes, so the device
      // never meets two causes for one fact.
      if (await wasDestroyed(context, ack.projectId)) {
        return refuseDestroyed(
          request,
          context,
          kind: 'ack',
          projectId: ack.projectId,
          deviceId: ack.deviceId,
          envelope: ack.envelope,
        );
      }
      if (!access.permitsSync) {
        await context.trafficLog.record(
          kind: 'ack',
          userId: context.session.userId,
          deviceId: ack.deviceId,
          projectId: ack.projectId,
          cursorOut: ack.cursor,
          clientSchemaMajor: ack.envelope.schemaMajor,
          clientSchemaVersion: ack.envelope.schemaVersion,
          statusCode: 403,
          errorCode: 'forbidden',
        );
        await auditDenial(
          request,
          userId: context.session.userId,
          projectId: ack.projectId,
          kind: 'ack',
        );
        return _forbidden();
      }
      // `device_id` and `project_id` are both already bounded in `handle()`,
      // above the point this transaction opened.
      await context.cursors.acknowledge(
        SyncCursorKey(
          userId: context.session.userId,
          deviceId: ack.deviceId,
          projectId: ack.projectId,
        ),
        cursor: ack.cursor,
        at: DateTime.now().toUtc(),
      );
      await context.trafficLog.record(
        kind: 'ack',
        userId: context.session.userId,
        deviceId: ack.deviceId,
        projectId: ack.projectId,
        cursorOut: ack.cursor,
        clientSchemaMajor: ack.envelope.schemaMajor,
        clientSchemaVersion: ack.envelope.schemaVersion,
        statusCode: 200,
      );
      return _json({
        ...const SyncEnvelope().toJson(),
        'status': 'acknowledged',
      });
    });
  });

  return router;
}
