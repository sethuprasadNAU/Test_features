import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// A scriptable [SyncTransport] with an in-memory server behind it.
///
/// Every client sync test runs against this — the acceptance criterion, and
/// Phase 10's invariant 5 ("a test suite that needs a server" is forbidden).
/// It follows the same protocol rules the real server does, and critically
/// merges with the **shared** `MergeResolver` rather than reimplementing it, so
/// a genuine disagreement about who wins cannot hide in the fake.
class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport();

  final Map<String, Map<String, Map<String, Object?>>> _tables = {};
  final Map<String, Map<String, int>> _seq = {};
  int _nextSeq = 0;

  /// Set to make the next N calls throw, modelling a dead zone.
  int failNextCalls = 0;

  /// Set to make every call throw until cleared — "sync permanently failing".
  SyncTransportException? permanentFailure;

  /// Set to fail only after this many pull pages, modelling a drop mid-stream.
  int? failPullAfterPages;

  int pushCalls = 0;
  int pullCalls = 0;

  /// **Which database this fake server says it is** (task 11.58), returned on
  /// every push and pull the way the real server's `server_database_identity`
  /// row is.
  ///
  /// Non-null by default, because the honest default for a fake is what the
  /// real server does. Set it to null to model a server built before the
  /// field existed; change it — or call [replaceDatabase] — to model a restore
  /// or a rebuild.
  String? databaseId = 'fake-database-1';

  /// When set, called before every push and pull response to choose the
  /// identifier that response carries — for modelling two databases answering
  /// at one address, which no single value of [databaseId] can.
  String? Function()? databaseIdPerResponse;

  String? get _answeringDatabase =>
      databaseIdPerResponse != null ? databaseIdPerResponse!() : databaseId;

  /// **This fake server's database is replaced by a new, empty one** (task
  /// 11.58) — a rebuild, or a restore of a backup taken before any of this
  /// fake's rows existed. Every row goes, the numbering starts again, and the
  /// database names itself [newDatabaseId].
  void replaceDatabase(String newDatabaseId) {
    _tables.clear();
    _seq.clear();
    _nextSeq = 0;
    databaseId = newDatabaseId;
  }

  /// How many times this device has asked "have I been approved yet".
  ///
  /// Counted because task 11.83's foreground check is only defensible if it
  /// stays off devices with no join business, and a test that cannot see the
  /// request cannot tell silence from a check that happened to find nothing.
  int myJoinRequestsCalls = 0;
  final List<int> ackedCursors = [];
  final List<SyncPushRequest> pushes = [];

  /// Rows this server will refuse, keyed `table/pk` → the outcome to answer
  /// with. Models the real server's row-level refusals: task 10.20's
  /// row-naming invariant answering `unauthorized`, or `RowValidator`
  /// answering `invalid` — a `200` response whose per-row outcome says the row
  /// was not stored (§8.4's `200 unauthorized` transcript).
  ///
  /// Before task 10.28 nothing in this fake could deny a row, which is why a
  /// suite of 700+ tests never saw finding D-3.
  final Map<String, SyncRowOutcome> refuseRows = {};

  /// Rows this server will refuse as `invalid` **and name a shared rule
  /// for**, keyed `table/pk` → the rule id (task 11.267). Models
  /// `SyncService`'s deployment-interlock refusal: `outcomes[key]` is set to
  /// `invalid` and `interlockRefusals[key]` names the rule, exactly as the
  /// real server does — a second channel beside [refuseRows], not a variant
  /// of it, because a `RowRefusal` never carries an interlock's identity.
  final Map<String, String> interlockRefuseRows = {};

  /// Whether pushed rows are put through the shared [RowValidator], the way
  /// `SyncService` does before writing one.
  ///
  /// **On by default**, because the honest default for a fake server is the
  /// rule the real one enforces. Tests whose fixtures predate a validation rule
  /// and are not about validation may turn it off, and doing so is a visible
  /// line in the test rather than a silent gap in the fake.
  bool validateRows = true;

  /// Rows this server will answer about **not at all** — the version-skew case
  /// where the server does not know a table the client pushed, so the outcome
  /// map simply has no entry for the row. Silence must not read as success.
  final Set<String> ignoreRows = {};

  /// **Projects this fake has ended the caller's stint on** (task 11.60).
  ///
  /// Models the server's project-level refusal for somebody who is no longer a
  /// member, *including* §4.27's closed-membership disclosure — because the
  /// two are one behaviour and a fake that had only the refusal would let a
  /// client test pass against a build that could never learn it had been
  /// removed.
  ///
  /// While a project is in here:
  ///
  /// - **push and ack are refused** with the same `403 forbidden` the real
  ///   server sends. Ack included, and that is the half worth stating: it is a
  ///   write, and it is what makes acknowledging the disclosure page a
  ///   mistake.
  /// - **pull answers `200` with exactly [sessionUserId]'s closed
  ///   `Project_Memberships` rows on that project**, and hands the cursor
  ///   straight back with nothing remaining — a page that is terminal and
  ///   asks for no acknowledgement.
  ///
  /// Seed the closed row with [seedServerRow] as an owner's removal would have
  /// written it; this set only decides how the routes answer.
  final Set<String> closedMembershipProjects = {};

  static const SyncTransportException _projectForbidden =
      SyncTransportException('forbidden', statusCode: 403);

  void _maybeFail() {
    final permanent = permanentFailure;
    if (permanent != null) throw permanent;
    if (failNextCalls > 0) {
      failNextCalls--;
      throw const SyncTransportException('unreachable');
    }
  }

  /// Seeds a row as though another device had pushed it.
  void seedServerRow(String table, Map<String, Object?> row) {
    final spec = syncTablesByName[table]!;
    final key = spec.primaryKey.map((c) => row[c]).join('/');
    _tables.putIfAbsent(table, () => {})[key] = Map<String, Object?>.of(row);
    _seq.putIfAbsent(table, () => {})[key] = ++_nextSeq;
  }

  Map<String, Object?>? serverRow(String table, String key) =>
      _tables[table]?[key];

  int get serverRowCount =>
      _tables.values.fold(0, (sum, rows) => sum + rows.length);

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async {
    _maybeFail();
    _refuseIfDestroyed(request.projectId);
    pushCalls++;
    pushes.add(request);
    // Recorded before the refusal, not after: the request reached the server
    // and was turned away, and a test asking "what did this device try to
    // send" needs the refused attempt most of all.
    if (closedMembershipProjects.contains(request.projectId)) {
      throw _projectForbidden;
    }

    final outcomes = <String, SyncRowOutcome>{};
    final refusals = <String, RowRefusal>{};
    final interlockRefusals = <String, String>{};
    var applied = 0;
    int? highest;

    for (final table in syncTables) {
      for (final row in request.rows[table.name] ?? const []) {
        final spec = syncTablesByName[table.name]!;
        final key = spec.primaryKey.map((c) => row[c]).join('/');
        final reference = '${table.name}/$key';
        final store = _tables.putIfAbsent(table.name, () => {});
        final existing = store[key];

        if (ignoreRows.contains(reference)) continue;

        // **The real validator, not a scripted refusal** (task 11.84 item 3).
        // The same argument as `MergeResolver` above: a fake that reimplements
        // — or simply omits — a rule the server enforces cannot be used to
        // measure what a device does when that rule fires. Task 11.81 made
        // `Users.first_name`/`last_name` refusable on the sync path, and until
        // this line nothing in the suite could push a row and have the real
        // rule turn it away.
        if (validateRows) {
          final issues = RowValidator.validate(table.name, row);
          if (issues.isNotEmpty) {
            outcomes[reference] = SyncRowOutcome.invalid;
            // Task 11.124. Through `RowRefusal.fromIssues`, which is the same
            // function the real server calls — a fake that derived the detail
            // its own way would let a client test pass against behaviour the
            // real server does not have.
            final refusal = RowRefusal.fromIssues(issues);
            if (refusal != null) refusals[reference] = refusal;
            continue;
          }
        }

        final refusal = refuseRows[reference];
        if (refusal != null) {
          // Refused rows are *not* stored, exactly as the real server does not
          // store them — the whole point is that this row is on the client only.
          outcomes[reference] = refusal;
          continue;
        }

        final interlockRule = interlockRefuseRows[reference];
        if (interlockRule != null) {
          outcomes[reference] = SyncRowOutcome.invalid;
          interlockRefusals[reference] = interlockRule;
          continue;
        }

        if (existing != null && !MergeResolver.incomingWins(row, existing)) {
          outcomes[reference] = SyncRowOutcome.lostToServer;
          continue;
        }
        store[key] = Map<String, Object?>.of(row);
        highest = ++_nextSeq;
        _seq.putIfAbsent(table.name, () => {})[key] = highest;
        outcomes[reference] = existing == null
            ? SyncRowOutcome.inserted
            : SyncRowOutcome.updated;
        applied++;
      }
    }

    return SyncPushResponse(
      applied: applied,
      outcomes: outcomes,
      refusals: refusals,
      interlockRefusals: interlockRefusals,
      highestServerSeq: highest,
      databaseId: _answeringDatabase,
    );
  }

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    _maybeFail();
    _refuseIfDestroyed(request.projectId);
    if (closedMembershipProjects.contains(request.projectId)) {
      pullCalls++;
      final memberships = _tables[Tables.projectMemberships] ?? const {};
      return SyncPullResponse(
        rows: {
          Tables.projectMemberships: [
            for (final row in memberships.values)
              if (row['project_id'] == request.projectId &&
                  row['user_id'] == sessionUserId &&
                  (row['end_date'] != null || row['deleted_at'] != null))
                Map<String, Object?>.of(row),
          ],
        },
        nextCursor: request.cursor,
        remaining: 0,
        databaseId: _answeringDatabase,
      );
    }
    final limit = failPullAfterPages;
    if (limit != null && pullCalls >= limit) {
      throw const SyncTransportException('unreachable');
    }
    pullCalls++;

    final candidates = <({String table, String key, int seq})>[];
    for (final table in syncTables) {
      final rows = _tables[table.name] ?? const {};
      final seqs = _seq[table.name] ?? const {};
      for (final entry in rows.entries) {
        final seq = seqs[entry.key];
        if (seq == null || seq <= request.cursor) continue;
        final scope = table.projectScopeColumn;
        if (scope != null && entry.value[scope] != request.projectId) continue;
        candidates.add((table: table.name, key: entry.key, seq: seq));
      }
    }
    candidates.sort((a, b) => a.seq.compareTo(b.seq));
    final page = candidates.take(request.batchSize).toList();

    final rows = <String, List<Map<String, Object?>>>{};
    for (final item in page) {
      rows
          .putIfAbsent(item.table, () => [])
          .add(Map<String, Object?>.of(_tables[item.table]![item.key]!));
    }

    return SyncPullResponse(
      rows: rows,
      nextCursor: page.isEmpty ? request.cursor : page.last.seq,
      remaining: candidates.length - page.length,
      databaseId: _answeringDatabase,
    );
  }

  @override
  Future<void> ack(SyncAckRequest request) async {
    _maybeFail();
    _refuseIfDestroyed(request.projectId);
    if (closedMembershipProjects.contains(request.projectId)) {
      throw _projectForbidden;
    }
    ackedCursors.add(request.cursor);
  }

  /// Seeded directly by tests — the fake has no real notion of "which user
  /// owns which project," so tests set up exactly the list they want to
  /// assert against.
  final List<ProjectSummary> serverProjects = [];

  /// How many times the device asked `GET /projects/mine` — counted because
  /// task 11.302's foreground check is only defensible if a device with
  /// nothing to bring back never asks.
  int listMyProjectsCalls = 0;

  @override
  Future<List<ProjectSummary>> listMyProjects() async {
    _maybeFail();
    listMyProjectsCalls++;
    // Task 11.290: a scheduled deletion rides on the directory row, exactly
    // as the real `/projects/mine` LEFT JOINs it.
    return [
      for (final project in serverProjects)
        ProjectSummary(
          projectId: project.projectId,
          projectName: project.projectName,
          ownerUserId: project.ownerUserId,
          role: project.role,
          destroyAt: scheduledDeletions[project.projectId]?.destroyAt,
        ),
    ];
  }

  /// Projects the caller deleted from a device that this fake server still
  /// holds as tombstones (task 11.292) — seeded directly, like
  /// [serverProjects]. The real route lists only tombstones the caller sent
  /// on projects it records them as owner of, so everything a test seeds
  /// here is, by construction, the caller's own to destroy: [_callerOwns]
  /// counts them.
  final List<DeletedProjectSummary> serverDeletedProjects = [];

  /// When set, [listMyDeletedProjects] throws this instead of answering — a
  /// server older than the route (a 404), or one that cannot be reached.
  SyncTransportException? deletedListingFailure;

  @override
  Future<List<DeletedProjectSummary>> listMyDeletedProjects() async {
    _maybeFail();
    final failure = deletedListingFailure;
    if (failure != null) throw failure;
    return [
      for (final project in serverDeletedProjects)
        DeletedProjectSummary(
          projectId: project.projectId,
          projectName: project.projectName,
          deletedAt: project.deletedAt,
          destroyAt: scheduledDeletions[project.projectId]?.destroyAt,
        ),
    ];
  }

  // ---- Destroying a project (task 11.290) ----------------------------------

  /// Deletions this fake server holds, keyed by project id. A scheduled one
  /// has `destroyAt` and no `executedAt`; a destroyed one has both, and its
  /// project is gone from [serverProjects] and refused on every sync route
  /// with [syncRefusalProjectDestroyed].
  final Map<String, ProjectDeletionStanding> scheduledDeletions = {};

  /// The grace period this fake applies, so a test can say "in 30 days" and
  /// mean the number the dialog will show.
  int deletionGraceDays = 30;

  /// How many archives the fake's backups keep — the number "delete now"
  /// has to name. Separate from the grace on purpose (see the real policy).
  int deletionBackupRetentionDays = 30;

  /// The fake's clock for deletion dates — settable so a test can put a
  /// scheduled date in the past without waiting for it.
  DateTime Function() deletionClock = () => DateTime.now().toUtc();

  /// Project ids that draw [syncRefusalProjectDestroyed] on push, pull and
  /// ack — set by [setProjectDeletion]'s immediate action, or by a test
  /// modelling a sweep that ran while the device was away.
  final Set<String> destroyedProjects = {};

  /// What the owner asked, in order — so a test can assert the dialog sent
  /// `immediate` rather than `schedule`, which is the whole difference the
  /// second confirmation exists for.
  final List<(String projectId, ProjectDeletionAction action)>
  deletionRequests = [];

  /// When set, every `POST /projects/<id>/deletion` is recorded in
  /// [deletionRequests] and then refused with this — a server older than
  /// the action (a 400), or one that no longer records the caller as the
  /// owner who deleted the project (a 403).
  SyncTransportException? deletionActionFailure;

  bool _callerOwns(String projectId) =>
      serverProjects.any(
        (p) => p.projectId == projectId && p.role == ownerMembershipRole,
      ) ||
      serverDeletedProjects.any((p) => p.projectId == projectId);

  @override
  Future<ProjectDeletionStanding> projectDeletion(String projectId) async {
    _maybeFail();
    if (!_callerOwns(projectId)) {
      throw const SyncTransportException('forbidden', statusCode: 403);
    }
    return scheduledDeletions[projectId] ??
        ProjectDeletionStanding(
          graceDays: deletionGraceDays,
          backupRetentionDays: deletionBackupRetentionDays,
        );
  }

  @override
  Future<ProjectDeletionStanding> setProjectDeletion(
    String projectId,
    ProjectDeletionAction action,
  ) async {
    _maybeFail();
    deletionRequests.add((projectId, action));
    final failure = deletionActionFailure;
    if (failure != null) throw failure;
    if (!_callerOwns(projectId)) {
      throw const SyncTransportException('forbidden', statusCode: 403);
    }
    final now = deletionClock();
    switch (action) {
      case ProjectDeletionAction.schedule:
        scheduledDeletions.putIfAbsent(
          projectId,
          () => ProjectDeletionStanding(
            graceDays: deletionGraceDays,
            backupRetentionDays: deletionBackupRetentionDays,
            scheduledAt: now,
            destroyAt: now.add(Duration(days: deletionGraceDays)),
          ),
        );
      case ProjectDeletionAction.cancel:
        scheduledDeletions.remove(projectId);
      case ProjectDeletionAction.immediate:
        destroyProject(projectId, at: now);
      case ProjectDeletionAction.restore:
        // Task 11.302. The real route admits exactly the listing's
        // population; here that is "seeded as deleted". A live project the
        // caller owns is a no-op, as on the real server.
        if (serverDeletedProjects.any((p) => p.projectId == projectId)) {
          restoreServerProject(projectId, restoredBy: sessionUserId, at: now);
        }
    }
    return scheduledDeletions[projectId] ??
        ProjectDeletionStanding(
          graceDays: deletionGraceDays,
          backupRetentionDays: deletionBackupRetentionDays,
        );
  }

  /// Models an owner's *restore* (task 11.302): the project leaves
  /// [serverDeletedProjects] for [serverProjects], any scheduled destruction
  /// is withdrawn, and the server's own `Projects` row — when one is seeded —
  /// is un-tombstoned exactly as the real server does it: revision up, the
  /// restorer's name, and a fresh sequence number so every device's next
  /// pull carries it.
  void restoreServerProject(
    String projectId, {
    required String restoredBy,
    DateTime? at,
  }) {
    final when = (at ?? deletionClock()).toUtc();
    final deleted = serverDeletedProjects
        .where((p) => p.projectId == projectId)
        .toList();
    serverDeletedProjects.removeWhere((p) => p.projectId == projectId);
    if (!destroyedProjects.contains(projectId)) {
      scheduledDeletions.remove(projectId);
    }
    final row = _tables[Tables.projects]?[projectId];
    if (row != null) {
      row
        ..['deleted_at'] = null
        ..['revision'] = ((row['revision'] as int?) ?? 0) + 1
        ..['updated_at'] = when.toIso8601String()
        ..['last_modified_by'] = restoredBy
        ..['origin_device_id'] = 'server-restore';
      _seq[Tables.projects]![projectId] = ++_nextSeq;
    }
    if (!serverProjects.any((p) => p.projectId == projectId)) {
      serverProjects.add(
        ProjectSummary(
          projectId: projectId,
          projectName: deleted.isNotEmpty
              ? deleted.first.projectName
              : (row?['project_name'] as String? ?? projectId),
          ownerUserId: row?['owner_user_id'] as String? ?? restoredBy,
          role: ownerMembershipRole,
        ),
      );
    }
  }

  /// Models the sweep (or an immediate request) destroying [projectId]: the
  /// directory stops listing it, and every sync route refuses it by name.
  void destroyProject(String projectId, {DateTime? at}) {
    final when = at ?? deletionClock();
    scheduledDeletions[projectId] = ProjectDeletionStanding(
      graceDays: deletionGraceDays,
      backupRetentionDays: deletionBackupRetentionDays,
      scheduledAt: when,
      destroyAt: when,
      executedAt: when,
    );
    serverProjects.removeWhere((p) => p.projectId == projectId);
    serverDeletedProjects.removeWhere((p) => p.projectId == projectId);
    destroyedProjects.add(projectId);
  }

  void _refuseIfDestroyed(String projectId) {
    if (destroyedProjects.contains(projectId)) {
      throw const SyncTransportException(
        syncRefusalProjectDestroyed,
        statusCode: 403,
      );
    }
  }

  // ---- Joining a project (task 11.81) --------------------------------------
  //
  // **What this half models, and what changed.** It used to model per-address
  // invitations, where the whole security property was that a code redeemed
  // only for the address the server had authenticated. Under the join code
  // there is no address binding — so the property this fake now has to model
  // faithfully is the one that replaced it: **a code produces a request, and
  // only an owner's approval produces a membership.**
  //
  // A fake that granted membership on a code would let a client test pass
  // against a build that had dropped the approval step entirely, which is
  // exactly the kind of false green this fake exists to prevent.

  /// The `user_id` the session belongs to, used for the granted membership row.
  String sessionUserId = 'user-requester';

  /// The address this fake considers the caller authenticated as.
  ///
  /// **No longer the security property it was**, but still modelled, because
  /// the server copies it onto the request from `auth_accounts` and the owner's
  /// screen renders it as the one thing the server can vouch for. A fake that
  /// let it come from the request body would let a test pass against a build
  /// where a requester could name any address they liked.
  String sessionEmail = 'requester@example.org';

  /// Project id → its join settings.
  final Map<String, JoinSettings> joinSettingsByProject = {};

  /// Canonical code → project id.
  ///
  /// **Fail-closed like the server: a project with no entry here has joining
  /// off**, whatever else is true of it. The absent-settings case is the most
  /// dangerous line in the real design, so the fake must not be more permissive
  /// than the thing it stands in for.
  final Map<String, String> joinCodes = {};

  /// Every request made, decided or not.
  final List<JoinRequestSummary> serverJoinRequests = [];

  /// Request id → the `user_id` that made it.
  ///
  /// Kept beside the summary rather than on it, because the **wire contract
  /// deliberately does not carry a `user_id`** — the owner's screen shows the
  /// server-authenticated email and nothing else identifying. The fake needs
  /// the id to model "one pending request per person per project", so it keeps
  /// its own note rather than widening what goes over the wire.
  final Map<String, String> joinRequestUserIds = {};

  /// The rows this fake's server holds for [table], for a test that needs to
  /// find one it did not choose the key for.
  List<Map<String, Object?>> serverRows(String table) => [
    for (final row in (_tables[table] ?? const {}).values) Map.of(row),
  ];

  int _joinCounter = 0;
  int _membershipCounter = 0;

  /// Switches joining on for [projectId] and returns the code, as an owner
  /// would see it after enabling joining.
  String enableJoining(
    String projectId, {
    int teamSizeLimit = 50,
    String? code,
  }) {
    // Deterministic and legal in the real alphabet, so a test exercises the
    // same canonicalization path a typed code does.
    final issued = code ?? 'ABCD${(++_joinCounter).toString().padLeft(4, '0')}';
    joinCodes[issued] = projectId;
    joinSettingsByProject[projectId] = JoinSettings(
      projectId: projectId,
      joiningEnabled: true,
      teamSizeLimit: teamSizeLimit,
      memberCount: _openMemberCount(projectId),
      pendingCount: _pendingCount(projectId),
      code: issued,
    );
    return issued;
  }

  int _openMemberCount(String projectId) =>
      (_tables[Tables.projectMemberships] ?? const {}).values
          .where(
            (row) =>
                row['project_id'] == projectId &&
                row['end_date'] == null &&
                row['deleted_at'] == null,
          )
          .length;

  int _pendingCount(String projectId) => serverJoinRequests
      .where((r) => r.projectId == projectId && r.isPending)
      .length;

  JoinSettings _settingsFor(String projectId) {
    final stored = joinSettingsByProject[projectId];
    return JoinSettings(
      projectId: projectId,
      // **Absent means off.** Not "absent means on with a default code".
      joiningEnabled: stored?.joiningEnabled ?? false,
      teamSizeLimit: stored?.teamSizeLimit ?? 50,
      memberCount: _openMemberCount(projectId),
      pendingCount: _pendingCount(projectId),
      code: stored?.code,
      rotatedAt: stored?.rotatedAt,
    );
  }

  @override
  Future<JoinSettings> joinSettings(String projectId) async {
    _maybeFail();
    return _settingsFor(projectId);
  }

  @override
  Future<JoinSettings> updateJoinSettings({
    required String projectId,
    bool? joiningEnabled,
    int? teamSizeLimit,
  }) async {
    _maybeFail();
    final current = _settingsFor(projectId);
    var code = current.code;
    if (joiningEnabled == true && code == null) {
      code = 'ABCD${(++_joinCounter).toString().padLeft(4, '0')}';
      joinCodes[code] = projectId;
    }
    joinSettingsByProject[projectId] = JoinSettings(
      projectId: projectId,
      joiningEnabled: joiningEnabled ?? current.joiningEnabled,
      teamSizeLimit: teamSizeLimit ?? current.teamSizeLimit,
      memberCount: current.memberCount,
      pendingCount: current.pendingCount,
      code: code,
      rotatedAt: current.rotatedAt,
    );
    return _settingsFor(projectId);
  }

  @override
  Future<RotateJoinCodeResponse> rotateJoinCode({
    required String projectId,
    bool clearPending = false,
  }) async {
    _maybeFail();
    final current = _settingsFor(projectId);
    joinCodes.removeWhere((_, value) => value == projectId);
    final code = 'ABCD${(++_joinCounter).toString().padLeft(4, '0')}';
    joinCodes[code] = projectId;
    var cleared = 0;
    if (clearPending) {
      for (var i = 0; i < serverJoinRequests.length; i++) {
        final r = serverJoinRequests[i];
        if (r.projectId != projectId || !r.isPending) continue;
        serverJoinRequests[i] = _decided(r, 'cleared');
        cleared++;
      }
    }
    joinSettingsByProject[projectId] = JoinSettings(
      projectId: projectId,
      joiningEnabled: current.joiningEnabled,
      teamSizeLimit: current.teamSizeLimit,
      memberCount: current.memberCount,
      pendingCount: _pendingCount(projectId),
      code: code,
      rotatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    return RotateJoinCodeResponse(code: code, clearedPending: cleared);
  }

  @override
  Future<List<JoinRequestSummary>> joinRequests(String projectId) async {
    _maybeFail();
    return [
      for (final r in serverJoinRequests)
        if (r.projectId == projectId) r,
    ];
  }

  @override
  Future<void> approveJoinRequest({
    required String projectId,
    required String requestId,
    required ProjectRole role,
  }) async {
    _maybeFail();
    final index = serverJoinRequests.indexWhere(
      (r) =>
          r.requestId == requestId && r.projectId == projectId && r.isPending,
    );
    if (index < 0) {
      throw const SyncTransportException(
        joinRefusalRequestNotOpen,
        statusCode: 409,
      );
    }
    final request = serverJoinRequests[index];
    serverJoinRequests[index] = _decided(request, 'approved');
    // **The server writes the membership row, not the joining device.** The
    // fake does the same, so a client test that expected to push one would fail
    // here rather than quietly passing against a design the real server does
    // not implement.
    //
    // And it grants to **the person who made the request**, taken from the
    // request itself — never to whoever the current session happens to be.
    // That is the property that makes nothing in a request body able to shape
    // the membership row.
    _grant(
      projectId: projectId,
      userId: joinRequestUserIds[requestId] ?? sessionUserId,
      role: role.db,
    );
  }

  @override
  Future<void> rejectJoinRequest({
    required String projectId,
    required String requestId,
  }) async {
    _maybeFail();
    final index = serverJoinRequests.indexWhere(
      (r) =>
          r.requestId == requestId && r.projectId == projectId && r.isPending,
    );
    if (index < 0) {
      throw const SyncTransportException(
        joinRefusalRequestNotOpen,
        statusCode: 409,
      );
    }
    serverJoinRequests[index] = _decided(serverJoinRequests[index], 'rejected');
  }

  @override
  Future<void> readmitMember({
    required String projectId,
    required String userId,
    required ProjectRole role,
  }) async {
    _maybeFail();
    final memberships = (_tables[Tables.projectMemberships] ?? const {}).values;
    final hasOpen = memberships.any(
      (row) =>
          row['project_id'] == projectId &&
          row['user_id'] == userId &&
          row['end_date'] == null &&
          row['deleted_at'] == null,
    );
    final hasClosed = memberships.any(
      (row) =>
          row['project_id'] == projectId &&
          row['user_id'] == userId &&
          (row['end_date'] != null || row['deleted_at'] != null),
    );
    // The condition that makes re-admission safe, modelled rather than assumed:
    // it can only reverse a removal, never add a stranger.
    if (hasOpen || !hasClosed) {
      throw const SyncTransportException(
        joinRefusalNotAPastMember,
        statusCode: 409,
      );
    }
    _grant(projectId: projectId, userId: userId, role: role.db);
  }

  @override
  Future<JoinRequestCreatedResponse> requestToJoin({
    required String code,
    String? claimedName,
  }) async {
    _maybeFail();
    // Same order of checks the server makes, and the same single refusal for
    // every reason the code itself did not work.
    final canonical = canonicalizeJoinCode(code);
    final projectId = canonical == null ? null : joinCodes[canonical];
    if (projectId == null) throw _codeNotValid;
    final settings = _settingsFor(projectId);
    // **Joining switched off answers exactly like a wrong code.** Anything else
    // would tell a code-sweeper that their guess named a real project.
    if (!settings.joiningEnabled) throw _codeNotValid;
    final project = serverRow(Tables.projects, projectId);
    if (project == null) throw _codeNotValid;

    final alreadyOpen = (_tables[Tables.projectMemberships] ?? const {}).values
        .any(
          (row) =>
              row['project_id'] == projectId &&
              row['user_id'] == sessionUserId &&
              row['end_date'] == null &&
              row['deleted_at'] == null,
        );
    if (alreadyOpen) {
      throw const SyncTransportException(
        joinRefusalAlreadyMember,
        statusCode: 409,
      );
    }
    if (serverJoinRequests.any(
      (r) =>
          r.projectId == projectId &&
          r.isPending &&
          joinRequestUserIds[r.requestId] == sessionUserId,
    )) {
      throw const SyncTransportException(
        joinRefusalAlreadyRequested,
        statusCode: 409,
      );
    }
    // Pending requests count toward the limit, exactly as on the server.
    if (settings.memberCount + settings.pendingCount >=
        settings.teamSizeLimit) {
      throw const SyncTransportException(joinRefusalTeamFull, statusCode: 409);
    }

    final requestId = 'request-${++_joinCounter}';
    joinRequestUserIds[requestId] = sessionUserId;
    serverJoinRequests.add(
      JoinRequestSummary(
        requestId: requestId,
        projectId: projectId,
        // From the session, never from the request — the fake models that
        // asymmetry because the owner's screen depends on it.
        email: normalizeEmail(sessionEmail),
        claimedName: (claimedName ?? '').trim().isEmpty
            ? null
            : claimedName!.trim(),
        requestedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    // **No membership row is written here.** That is the whole point of the
    // change, and the assertion most worth being able to make against a fake.
    return JoinRequestCreatedResponse(
      requestId: requestId,
      projectName: project['project_name']! as String,
    );
  }

  @override
  Future<List<MyJoinRequest>> myJoinRequests() async {
    myJoinRequestsCalls++;
    _maybeFail();
    return [
      for (final r in serverJoinRequests)
        // Keyed on the session and nothing else — there is no field on this
        // route by which a caller could name somebody else.
        if (joinRequestUserIds[r.requestId] == sessionUserId)
          if (serverRow(Tables.projects, r.projectId) case final project?)
            MyJoinRequest(
              requestId: r.requestId,
              projectName: project['project_name']! as String,
              requestedAt: r.requestedAt,
              decision: r.decision,
              decidedAt: r.decidedAt,
              // **Approved only, exactly as the real route does** (task 11.83).
              // A fake that handed the id out for a pending request would let a
              // test pass on behaviour the server does not have.
              projectId: r.decision == joinDecisionApproved
                  ? r.projectId
                  : null,
            ),
    ];
  }

  void _grant({
    required String projectId,
    required String userId,
    required String role,
  }) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    seedServerRow(Tables.projectMemberships, {
      'membership_id': 'membership-${++_membershipCounter}',
      'project_id': projectId,
      'user_id': userId,
      'join_date': stamp,
      'end_date': null,
      'role': role,
      'created_at': stamp,
      'updated_at': stamp,
      'deleted_at': null,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': null,
    });
  }

  JoinRequestSummary _decided(JoinRequestSummary request, String decision) =>
      JoinRequestSummary(
        requestId: request.requestId,
        projectId: request.projectId,
        email: request.email,
        claimedName: request.claimedName,
        requestedAt: request.requestedAt,
        decision: decision,
        decidedAt: DateTime.now().toUtc().toIso8601String(),
      );

  static const SyncTransportException _codeNotValid = SyncTransportException(
    joinRefusalCodeNotValid,
    statusCode: 403,
  );
}
