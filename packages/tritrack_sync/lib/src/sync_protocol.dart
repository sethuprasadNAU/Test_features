/// The client/server sync wire contract (task 10.7).
///
/// Lives in the shared package because a client and server that disagree about
/// any of this produce either a hard failure or — worse — a silent one. It is
/// deliberately plain DTOs plus encode/decode: no HTTP, no database, so both
/// sides and every test can use it directly.
library;

import 'row_refusal.dart';
import 'schema_constants.dart';

/// Envelope marker, following task 6.2's `TT1:` precedent that the *envelope*
/// and the *payload version* are separate concerns.
///
/// This identifies "a TriTrack sync envelope" and is expected never to change.
/// [syncProtocolVersion] is what moves when the shape inside it does — so an
/// old client gets a comprehensible "wrong protocol version" rather than a
/// parse error on something it cannot even identify.
const String kSyncEnvelopeId = 'tritrack_sync';

/// The wire shape's version.
///
/// **Separate from `latestSchemaVersion`, on purpose.** The schema version says
/// what columns a row has; this says what the request/response *envelope* looks
/// like. They move for different reasons — adding a column bumps the former
/// and leaves this alone — and conflating them would force a protocol break on
/// every schema change. Task 10.11 owns what the server does about a mismatch
/// in either; this task only makes both legible in every message.
const int syncProtocolVersion = 1;

/// How many rows travel in one batch, in either direction.
///
/// **Sized for the first sync, not the steady state.** A phone joining a
/// project with a season of data behind a marginal connection is the case that
/// matters: a single unbounded response times out, exhausts memory, or dies
/// mid-transfer, and a retry that restarts from zero never completes. 500 rows
/// of observation-shaped JSON is a few hundred kilobytes — small enough to
/// survive a bad link and cheap to re-send if it fails, large enough that a
/// season of data is tens of round trips rather than thousands.
///
/// The steady state pushes a handful of rows and never notices this number.
const int defaultSyncBatchSize = 500;

/// Upper bound the server enforces on a client-requested batch size.
///
/// A client may ask for less (a phone on a bad link reasonably might) but not
/// more: an unbounded request is a memory-exhaustion primitive, and the server
/// has to be able to bound its own response regardless of what a caller asks
/// for.
const int maxSyncBatchSize = 2000;

/// Thrown when a payload is not a well-formed sync envelope.
class SyncProtocolException implements Exception {
  const SyncProtocolException(this.message);
  final String message;
  @override
  String toString() => 'SyncProtocolException: $message';
}

/// Thrown when the envelope is well-formed but its protocol version is not one
/// this build speaks. Distinct from [SyncProtocolException] so task 10.11 can
/// give the actionable "update to sync" answer the plan requires, rather than a
/// generic parse failure.
class SyncProtocolVersionException implements Exception {
  const SyncProtocolVersionException({
    required this.received,
    required this.supported,
  });
  final int received;
  final int supported;
  @override
  String toString() =>
      'SyncProtocolVersionException: envelope protocol v$received, '
      'this build speaks v$supported';
}

/// Thrown when the envelope is well-formed and speaks this protocol, but the
/// two sides' schema **majors** differ (tasks 10.11, revised by 10.18).
///
/// ## Why a major/minor split rather than exact equality
///
/// 10.11 required exact equality and was right about the danger it was avoiding.
/// The tempting relaxation — "let an older client sync the columns it knows
/// about" — is data loss, not compatibility: server at minor 6 with a new
/// `Observations` column, client at minor 5 that has never heard of it. The
/// client pulls the row *dropping the column it cannot store*, the user edits
/// the notes, the client pushes the row back, and last-write-wins writes the
/// whole row with the new column now empty. A value another device contributed,
/// destroyed silently by a client behaving exactly as designed.
///
/// The step 10.11 missed is that the drop is not forced. **An older build can
/// hold what it does not recognize verbatim and hand it back untouched** (the
/// app's `UnknownColumnStore`), which removes the destruction without changing
/// the merge model at all — row-level last-write-wins still, just over a row
/// that stayed whole. Protocol Buffers have worked this way for twenty years.
///
/// So the boundary moved: additive changes bump [latestSchemaVersion] (the
/// minor) and stay compatible; changes preservation cannot save — deleting or
/// renaming a column, retyping one, reusing a name for a new meaning, deleting a
/// table, tightening a validation rule — bump [schemaMajorVersion] and are
/// refused here.
///
/// **The protection only ever covers builds that shipped with it**, which is why
/// it had to exist before the first release: an app released without unknown-
/// value preservation cannot be made compatible retroactively.
///
/// Both halves of both sides' versions are recorded rather than a single
/// "mismatch" so the refusal can name *which side is behind* — the client is
/// told to update the app, the operator is told to update the server, and nobody
/// is sent chasing the wrong one.
class SyncSchemaVersionException implements Exception {
  const SyncSchemaVersionException({
    required this.received,
    required this.supported,
    required this.receivedMajor,
    required this.supportedMajor,
  });

  /// The schema minor version the message carried (the other party's).
  final int received;

  /// The schema minor version this build implements.
  final int supported;

  /// The schema major version the message carried.
  final int receivedMajor;

  /// The schema major version this build implements.
  final int supportedMajor;

  /// True when the sender is behind this build. Major decides; the minor only
  /// breaks a tie that cannot occur while majors are the refusal criterion, but
  /// is consulted anyway so the answer stays right if that ever changes.
  bool get senderIsOlder => receivedMajor != supportedMajor
      ? receivedMajor < supportedMajor
      : received < supported;

  @override
  String toString() =>
      'SyncSchemaVersionException: peer schema v$receivedMajor.$received, '
      'this build implements v$supportedMajor.$supported';
}

/// Fields every request and response carries.
///
/// The schema version rides along in both directions so a mismatch is detectable
/// on the *first* message rather than after a payload has been half-applied. It
/// travels as two fields — `schema_major` decides compatibility, `schema_version`
/// is the minor and is carried for reporting only.
class SyncEnvelope {
  const SyncEnvelope({
    this.envelopeId = kSyncEnvelopeId,
    this.protocolVersion = syncProtocolVersion,
    this.schemaVersion = latestSchemaVersion,
    this.schemaMajor = schemaMajorVersion,
  });

  final String envelopeId;
  final int protocolVersion;

  /// The minor half — informational across the wire. A peer one minor behind is
  /// accepted, not refused.
  final int schemaVersion;

  /// The major half — the compatibility boundary.
  final int schemaMajor;

  Map<String, Object?> toJson() => {
    'envelope': envelopeId,
    'protocol_version': protocolVersion,
    'schema_version': schemaVersion,
    'schema_major': schemaMajor,
  };

  /// Validates the envelope fields of [json].
  ///
  /// Checks identity before version so an unrelated payload is reported as
  /// "not a sync envelope" rather than as a version problem, which would send
  /// whoever is debugging it down the wrong path.
  static SyncEnvelope fromJson(Map<String, Object?> json) {
    if (json['envelope'] != kSyncEnvelopeId) {
      throw SyncProtocolException(
        'Not a TriTrack sync envelope (envelope: ${json['envelope'] ?? 'missing'}).',
      );
    }
    final protocolVersion = json['protocol_version'];
    if (protocolVersion is! int) {
      throw const SyncProtocolException('Missing protocol_version.');
    }
    if (protocolVersion != syncProtocolVersion) {
      throw SyncProtocolVersionException(
        received: protocolVersion,
        supported: syncProtocolVersion,
      );
    }
    final schemaVersion = json['schema_version'];
    if (schemaVersion is! int) {
      throw const SyncProtocolException('Missing schema_version.');
    }
    // Required, not defaulted: a peer that omits it is either pre-10.18 or not
    // a TriTrack peer, and both are cases where guessing a major would let an
    // incompatible payload through. Nothing shipped before this field existed,
    // so there is no build to be lenient toward.
    final schemaMajor = json['schema_major'];
    if (schemaMajor is! int) {
      throw const SyncProtocolException('Missing schema_major.');
    }
    // Task 10.18: same major, any minor. Checked here rather than at each call
    // site for the same reason the protocol check is — this is the one place
    // every request and every response passes through, so a new endpoint cannot
    // forget it. See [SyncSchemaVersionException] for why the minor is allowed
    // to differ and what makes that safe.
    if (schemaMajor != schemaMajorVersion) {
      throw SyncSchemaVersionException(
        received: schemaVersion,
        supported: latestSchemaVersion,
        receivedMajor: schemaMajor,
        supportedMajor: schemaMajorVersion,
      );
    }
    return SyncEnvelope(
      protocolVersion: protocolVersion,
      schemaVersion: schemaVersion,
      schemaMajor: schemaMajor,
    );
  }
}

/// A device's position in the server's delta stream for one project.
///
/// **Keyed on `(userId, deviceId, projectId)` — never on user alone, and this
/// is the single most important detail in the protocol.** One person with a
/// laptop and a phone holds two independent cursors. With a per-user cursor,
/// the laptop's sync advances the shared position past rows the phone never
/// received, and the phone is then never offered them again: it asks for
/// `server_seq > n` forever, and the rows below `n` it never saw simply do not
/// come. Nothing errors. Nothing retries. An observation is just missing on one
/// device, and the only way anyone finds out is by noticing months later.
///
/// Project id is in the key too, because pulls are project-scoped for
/// authorization (task 10.10) and a user can belong to many projects — a single
/// per-device cursor across projects would have the same skipping problem the
/// moment two projects' streams interleave.
class SyncCursorKey {
  const SyncCursorKey({
    required this.userId,
    required this.deviceId,
    required this.projectId,
  });

  final String userId;
  final String deviceId;
  final String projectId;

  @override
  bool operator ==(Object other) =>
      other is SyncCursorKey &&
      other.userId == userId &&
      other.deviceId == deviceId &&
      other.projectId == projectId;

  @override
  int get hashCode => Object.hash(userId, deviceId, projectId);

  @override
  String toString() => 'SyncCursorKey($userId/$deviceId/$projectId)';
}

/// One table's worth of rows in a payload.
typedef SyncRows = Map<String, List<Map<String, Object?>>>;

/// Client → server: rows this device changed locally.
class SyncPushRequest {
  const SyncPushRequest({
    required this.projectId,
    required this.deviceId,
    required this.rows,
    this.envelope = const SyncEnvelope(),
  });

  final String projectId;

  /// Included for the server's device registry and cursor bookkeeping. **Never
  /// used for authorization** — it is a forgeable client-side value; the
  /// session decides who is calling (task 10.6).
  final String deviceId;

  final SyncRows rows;
  final SyncEnvelope envelope;

  int get rowCount => rows.values.fold(0, (sum, list) => sum + list.length);

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'project_id': projectId,
    'device_id': deviceId,
    'rows': rows,
  };

  static SyncPushRequest fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    return SyncPushRequest(
      projectId: requireSyncString(json, 'project_id'),
      deviceId: requireSyncString(json, 'device_id'),
      rows: decodeRows(json['rows']),
      envelope: envelope,
    );
  }
}

/// What the server did with one pushed row.
///
/// `lostToServer` exists because it is the most useful line in the whole
/// system: "my observation disappeared" is the bug that actually gets reported,
/// and a merge that silently discards the loser leaves nothing to answer it
/// with. Task 10.12 turns these into a user-visible record; 10.13 shows them to
/// a developer.
enum SyncRowOutcome {
  inserted('inserted'),
  updated('updated'),

  /// The server's copy won last-write-wins. The client's row was not applied.
  lostToServer('lost_to_server'),

  /// Rejected by `RowValidator`.
  invalid('invalid'),

  /// Rejected by authorization (task 10.10).
  unauthorized('unauthorized');

  const SyncRowOutcome(this.db);
  final String db;

  /// **Finding L-8.** This was a bare `firstWhere` with no `orElse`, which
  /// throws `StateError` — a Dart *`Error`*, meaning "this program has a bug",
  /// not an *`Exception`* meaning "the input was bad". Nothing catches an
  /// `Error`, and this parse runs deep inside `SyncPushResponse.fromJson`,
  /// outside every `SyncTransportException` handler on the client.
  ///
  /// **What that costs, and it is a deployed-fleet problem rather than a
  /// hostile-input one.** The day a server adds a sixth outcome — anything
  /// finer-grained than the five here — every client already in the field
  /// crashes on its next push, mid-response, after the server has already
  /// applied the rows. The user sees the app die on sync, with their data
  /// accepted and their device convinced it was not.
  ///
  /// This is the exact mirror of `decodeRows`, which deliberately *tolerates*
  /// a table it does not know for task 10.18's forward-compatibility
  /// guarantee. An envelope that refuses to parse an unknown outcome broke
  /// that guarantee in the opposite direction, on the one enum with no
  /// `RowValidator.enumField` gate upstream of it — because it is protocol,
  /// not row data.
  ///
  /// Throws [SyncProtocolException], which the transport layer already
  /// handles, so an unknown value now surfaces as a sync that failed rather
  /// than an app that stopped.
  static SyncRowOutcome fromDb(String value) => values.firstWhere(
    (o) => o.db == value,
    orElse: () => throw SyncProtocolException(
      'Unknown row outcome "$value". This server is newer than this '
      'version of the app.',
    ),
  );
}

/// Server → client: what happened to a push.
class SyncPushResponse {
  SyncPushResponse({
    required this.applied,
    required this.outcomes,
    required this.highestServerSeq,
    this.envelope = const SyncEnvelope(),
    this.databaseId,
    Map<String, RowRefusal> refusals = const {},
    Map<String, String> interlockRefusals = const {},
  }) : refusals = _onlyOnInvalid(outcomes, refusals),
       interlockRefusals = _onlyOnInvalidRule(outcomes, interlockRefusals);

  /// Rows that changed stored state (inserted or updated).
  final int applied;

  /// Per-row outcome, keyed `table/primaryKey`. Reported for *every* pushed
  /// row, including the ones that lost — silence about a loss is the failure
  /// mode this whole field exists to prevent.
  final Map<String, SyncRowOutcome> outcomes;

  /// Why a refused row was refused, for the rows the server can say that
  /// about — keyed exactly as [outcomes] is (task 11.124).
  ///
  /// **Sparse on purpose.** Most refusals carry no entry: an unkeyable row, a
  /// write the database itself rejected, a range check with no declared bound
  /// behind it. A missing entry is the ordinary case, and it reaches task
  /// 11.122's honest default rather than any claim about a cause.
  ///
  /// **Only ever on [SyncRowOutcome.invalid].** [_onlyOnInvalid] drops
  /// anything else at construction, so this holds on a response built by this
  /// server *and* on one parsed from a server that got it wrong. `unauthorized`
  /// answers one opaque refusal for every reason (§4.13); a code beside it
  /// would let a push distinguish "not on this project" from "not yours",
  /// which is the existence oracle findings C-2, D-1 and H-3 each closed.
  final Map<String, RowRefusal> refusals;

  /// **Which named rule about the project's other rows refused a row** —
  /// keyed exactly as [outcomes] and [refusals] are, valued with the rule's
  /// own identity (e.g. [DeploymentInterlock.ruleId]), for the refusals a
  /// `RowRefusal` cannot answer (task 11.267).
  ///
  /// **Carries no dates and names no other row.** The device that pushed a
  /// row an interlock refuses already holds every row that rule reads —
  /// that is what makes the rule able to refuse a *push* in the first place
  /// — so it can re-run the same shared rule locally and produce the same
  /// sentence a local link attempt would have. This field only has to say
  /// *which* rule fired, so the device knows to ask itself rather than
  /// falling through to task 11.122's honest default.
  ///
  /// **Only ever on [SyncRowOutcome.invalid]**, for the same reason
  /// [refusals] is: see [_onlyOnInvalidRule].
  final Map<String, String> interlockRefusals;

  /// Keeps only the details that sit on an `invalid` outcome.
  ///
  /// Enforced here rather than at the call sites for the reason task 11.88
  /// gives about hand-maintained lists: there are several places a response is
  /// built and one place it is constructed, and the bound is a security bound
  /// rather than a convention. Filtering is deliberate over throwing — a
  /// misbehaving server must not be able to fail a client's whole push, which
  /// would turn an information-disclosure bug into a denial of one.
  static Map<String, RowRefusal> _onlyOnInvalid(
    Map<String, SyncRowOutcome> outcomes,
    Map<String, RowRefusal> refusals,
  ) => {
    for (final entry in refusals.entries)
      if (outcomes[entry.key] == SyncRowOutcome.invalid) entry.key: entry.value,
  };

  /// [_onlyOnInvalid]'s rule, applied to [interlockRefusals] — a bare string
  /// map rather than one of [RowRefusal], so it is written once more rather
  /// than made generic over a difference of one type parameter.
  static Map<String, String> _onlyOnInvalidRule(
    Map<String, SyncRowOutcome> outcomes,
    Map<String, String> interlockRefusals,
  ) => {
    for (final entry in interlockRefusals.entries)
      if (outcomes[entry.key] == SyncRowOutcome.invalid) entry.key: entry.value,
  };

  /// The highest `server_seq` assigned while applying this push. The client
  /// does **not** treat this as a pull cursor: it has not received the rows
  /// *other* devices wrote below that number.
  final int? highestServerSeq;

  final SyncEnvelope envelope;

  /// Which database answered — see [readSyncDatabaseId] (task 11.58).
  final String? databaseId;

  int countOf(SyncRowOutcome outcome) =>
      outcomes.values.where((o) => o == outcome).length;

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'applied': applied,
    'outcomes': {for (final e in outcomes.entries) e.key: e.value.db},
    // Omitted entirely when empty, which is the steady state, so an older
    // client sees the response it has always seen.
    if (refusals.isNotEmpty)
      'refusals': {for (final e in refusals.entries) e.key: e.value.toJson()},
    // Same "omitted when empty" treatment, for the same reason.
    if (interlockRefusals.isNotEmpty) 'interlock_refusals': interlockRefusals,
    'highest_server_seq': highestServerSeq,
    if (databaseId != null) 'database_id': databaseId,
  };

  static SyncPushResponse fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    final rawOutcomes = json['outcomes'];
    final outcomes = <String, SyncRowOutcome>{};
    if (rawOutcomes is Map) {
      rawOutcomes.forEach((key, value) {
        if (value is String) {
          outcomes[key as String] = SyncRowOutcome.fromDb(value);
        }
      });
    }
    // An unparseable or unrecognised detail is simply absent, never an error
    // and never a guess — see [RowIssueCode.fromWire]. The constructor then
    // drops any that did not land on an `invalid` outcome.
    final rawRefusals = json['refusals'];
    final refusals = <String, RowRefusal>{};
    if (rawRefusals is Map) {
      rawRefusals.forEach((key, value) {
        if (key is! String) return;
        final refusal = RowRefusal.fromJson(value);
        if (refusal != null) refusals[key] = refusal;
      });
    }
    final rawInterlockRefusals = json['interlock_refusals'];
    final interlockRefusals = <String, String>{};
    if (rawInterlockRefusals is Map) {
      rawInterlockRefusals.forEach((key, value) {
        if (key is String && value is String) interlockRefusals[key] = value;
      });
    }
    return SyncPushResponse(
      applied: optionalSyncInt(json, 'applied') ?? 0,
      outcomes: outcomes,
      highestServerSeq: optionalSyncInt(json, 'highest_server_seq'),
      envelope: envelope,
      databaseId: readSyncDatabaseId(json),
      refusals: refusals,
      interlockRefusals: interlockRefusals,
    );
  }
}

/// Client → server: give me everything after my cursor.
class SyncPullRequest {
  const SyncPullRequest({
    required this.projectId,
    required this.deviceId,
    required this.cursor,
    this.batchSize = defaultSyncBatchSize,
    this.envelope = const SyncEnvelope(),
  });

  final String projectId;
  final String deviceId;

  /// **The client's own record of what it has committed**, and this is
  /// deliberately the authoritative input rather than the server's stored copy.
  ///
  /// The server records a cursor too (for diagnostics and task 10.11's
  /// retention check), but it must never be what decides delivery. If it were,
  /// a client that crashed after the server advanced its cursor but before
  /// committing the batch locally would never be offered those rows again —
  /// exactly the silent loss the per-`(user, device)` keying exists to prevent,
  /// reintroduced from the other direction. The client knows what it committed;
  /// the server only knows what it sent.
  final int cursor;

  final int batchSize;
  final SyncEnvelope envelope;

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'project_id': projectId,
    'device_id': deviceId,
    'cursor': cursor,
    'batch_size': batchSize,
  };

  static SyncPullRequest fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    final requested =
        optionalSyncInt(json, 'batch_size') ?? defaultSyncBatchSize;
    return SyncPullRequest(
      projectId: requireSyncString(json, 'project_id'),
      deviceId: requireSyncString(json, 'device_id'),
      cursor: optionalSyncInt(json, 'cursor') ?? 0,
      // A caller may ask for less but never more; the server has to bound its
      // own response regardless of what it is asked for.
      batchSize: requested.clamp(1, maxSyncBatchSize),
      envelope: envelope,
    );
  }
}

/// Server → client: one page of the delta stream.
class SyncPullResponse {
  const SyncPullResponse({
    required this.rows,
    required this.nextCursor,
    required this.remaining,
    this.envelope = const SyncEnvelope(),
    this.databaseId,
  });

  final SyncRows rows;

  /// The cursor to send next. Equal to the request's cursor when nothing came
  /// back, so an idle sync is a no-op rather than a rewind.
  final int nextCursor;

  /// Rows still waiting after this page.
  ///
  /// Exists so task 10.12 can show real progress ("batch 3 of 40") on a first
  /// sync instead of an indeterminate spinner — which is the difference between
  /// a field tech waiting confidently and one force-quitting the app.
  final int remaining;

  final SyncEnvelope envelope;

  /// Which database answered — see [readSyncDatabaseId] (task 11.58).
  final String? databaseId;

  int get rowCount => rows.values.fold(0, (sum, list) => sum + list.length);

  bool get hasMore => remaining > 0;

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'rows': rows,
    'next_cursor': nextCursor,
    'remaining': remaining,
    if (databaseId != null) 'database_id': databaseId,
  };

  static SyncPullResponse fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    return SyncPullResponse(
      rows: decodeRows(json['rows']),
      nextCursor: optionalSyncInt(json, 'next_cursor') ?? 0,
      remaining: optionalSyncInt(json, 'remaining') ?? 0,
      envelope: envelope,
      databaseId: readSyncDatabaseId(json),
    );
  }
}

/// Client → server: I have committed everything up to this cursor.
///
/// **A separate message from the pull, and that separation is the whole
/// resumability story.** The server may not advance its record of a device's
/// position when it *sends* a batch — only when the device says it wrote it.
/// A sync that dies between receiving a page and committing it therefore
/// re-receives that page, which is harmless (the merge is idempotent), whereas
/// the alternative loses it silently.
class SyncAckRequest {
  const SyncAckRequest({
    required this.projectId,
    required this.deviceId,
    required this.cursor,
    this.envelope = const SyncEnvelope(),
  });

  final String projectId;
  final String deviceId;
  final int cursor;
  final SyncEnvelope envelope;

  Map<String, Object?> toJson() => {
    ...envelope.toJson(),
    'project_id': projectId,
    'device_id': deviceId,
    'cursor': cursor,
  };

  static SyncAckRequest fromJson(Map<String, Object?> json) {
    final envelope = SyncEnvelope.fromJson(json);
    return SyncAckRequest(
      projectId: requireSyncString(json, 'project_id'),
      deviceId: requireSyncString(json, 'device_id'),
      cursor: optionalSyncInt(json, 'cursor') ?? 0,
      envelope: envelope,
    );
  }
}

/// Decodes a `rows` payload, keeping only tables this build knows.
///
/// Unknown tables are **ignored rather than rejected**, matching
/// `BackupArchive.decode`'s forward-compatible behaviour: a newer peer that
/// gained a table should not make an older one fail outright, and task 10.11
/// owns the deliberate version-refusal policy. Rejecting here would turn a
/// policy decision into a parse error.
SyncRows decodeRows(Object? raw) {
  final rows = <String, List<Map<String, Object?>>>{};
  if (raw is! Map) return rows;
  raw.forEach((table, value) {
    if (table is! String || !Tables.all.contains(table)) return;
    if (value is! List) return;
    rows[table] = [
      for (final row in value)
        if (row is Map) Map<String, Object?>.from(row),
    ];
  });
  return rows;
}

/// Not private (task 10.67): reused by `project_directory.dart`, a sibling
/// file in this same package, rather than growing a third hand-copied
/// version of the same present-but-wrong-typed-must-throw rule.
String requireSyncString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw SyncProtocolException('Missing "$key".');
  }
  return value;
}

/// `json[key]` when absent (returns `null`, for a caller-supplied default);
/// throws [SyncProtocolException] when present but not an [int].
///
/// **Absent and wrongly-typed are different failures and must draw different
/// responses** (task 10.64, finding J-4: `/sync/pull` with `cursor: "abc"` or
/// `batch_size: {}` drew an uncaught `TypeError` — a bare `500` — from the
/// unchecked `json['cursor'] as int?` this replaces). Absent means "the
/// caller said nothing," which a default answers correctly. Present-but-wrong
/// means "the caller sent something this build cannot use," which is exactly
/// what [SyncProtocolException] exists for — the same distinction
/// `sync_routes.dart`'s `_asString`/`_asInt` draw for the four envelope
/// fields task 10.46 already fixed this way. Task 10.67 found the identical
/// gap on the *response* side of the same two messages (`applied`,
/// `highest_server_seq`, `next_cursor`, `remaining`) and closed it the same
/// way, which is also why this stopped being private.
int? optionalSyncInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int) {
    throw SyncProtocolException('"$key" must be an integer.');
  }
  return value;
}

/// The longest database identifier a response may carry (task 11.58). The
/// server mints a UUID, which is 36 characters; the bound is generous so a
/// later change of minting scheme is not a protocol break, and finite so a
/// server cannot make this device store an arbitrary amount of text.
const int maxSyncDatabaseIdLength = 64;

final RegExp _syncDatabaseIdShape = RegExp(r'^[A-Za-z0-9-]+$');

/// **Which database answered a push or a pull** (task 11.58), or null when
/// the server did not say — a server built before this field existed.
///
/// ## Why the wire needs this at all
///
/// A device's pull bookmark is a position in *one database's* numbering, and
/// its row receipts are statements about what *one database* holds. Neither
/// carried which database that was, so a device pointed at a server that had
/// been restored from a backup or rebuilt kept asking for "everything after
/// 4,812" from a database that had started again at 1 — and was correctly told
/// there was nothing — while its receipts kept rows off the push because a
/// database that no longer exists had once confirmed them. **Both halves
/// reported a clean sync.** `test/data/sync/stale_cursor_new_server_test.dart`
/// in the app is the reproduction.
///
/// The server mints this once per database and **a restore does not carry it
/// across** (see the server's `database_identity.dart`), so a change of value
/// means "the numbering and the contents this device knew are gone", which is
/// exactly the fact the app has to act on.
///
/// ## Compatibility (task 10.18)
///
/// Additive in both directions, and no version moves:
///
/// - an **older app** ignores a field it does not read, and behaves exactly
///   as it always has — including being blind to a rebuilt server;
/// - a **newer app against an older server** reads null here, which means
///   "this server cannot say", and the app neither resets nor forgets what it
///   knew.
///
/// Absent and wrongly shaped are different failures, as [optionalSyncInt]
/// draws them: absent is an older server, while a value that is not a short
/// token is a server this build cannot trust to be the one it thinks, and is
/// refused as a malformed response rather than guessed at. The value is never
/// shown to anybody — it is compared, and stored beside the bookmark.
String? readSyncDatabaseId(Map<String, Object?> json) {
  final value = json['database_id'];
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > maxSyncDatabaseIdLength ||
      !_syncDatabaseIdShape.hasMatch(value)) {
    throw const SyncProtocolException(
      '"database_id" must be a short token of letters, digits and dashes.',
    );
  }
  return value;
}
