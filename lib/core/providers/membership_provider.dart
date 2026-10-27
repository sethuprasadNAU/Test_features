import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/models/project_membership.dart';
import '../../data/models/user.dart';
import '../../data/sync/pending_departure.dart';
import '../../data/sync/project_joiner.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/sync_held_rows.dart';
import '../../data/sync/sync_row_receipts.dart';
import '../../data/sync/sync_transport.dart';
import 'app_context_provider.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'device_id_provider.dart';
import 'join_request_watcher.dart';
import '../../data/repositories/mutation_authorization.dart';
import '../../data/repositories/repository_providers.dart';
import 'project_link_provider.dart';
import 'project_view_refresh.dart';
import 'server_config_provider.dart';
import 'server_transport_provider.dart';
import 'sync_provider.dart';

part 'membership_provider.g.dart';

/// One row of the members screen: the stint, and who it is about.
class ProjectMember {
  const ProjectMember({required this.membership, required this.user});

  final ProjectMembership membership;

  /// Null when this person's profile has not reached this device yet — which
  /// is ordinary for somebody who joined an hour ago and has not synced.
  final User? user;

  /// What to call them.
  ///
  /// Falls back to the address, then to the id, and the fallback is
  /// load-bearing rather than defensive: when the server mints a `Users` row
  /// for a new member it leaves the name **empty on purpose**, because it does
  /// not know their name and must not invent one on the row that attributes
  /// field observations. The address is what it does know, having authenticated
  /// it. See `JoinService._makeIdentityReachable`.
  ///
  /// **Note what is deliberately *not* used here: the name somebody typed on
  /// their join request.** That string exists to help an owner recognise who is
  /// asking, at the moment of approval. Letting it become the app's record of
  /// who took a bearing would turn a claim into an attribution, which is the
  /// harm §4.17 is about.
  String get displayName {
    final name = [
      user?.firstName.trim() ?? '',
      user?.lastName.trim() ?? '',
    ].where((part) => part.isNotEmpty).join(' ');
    if (name.isNotEmpty) return name;
    final email = user?.email.trim() ?? '';
    return email.isNotEmpty ? email : membership.userId;
  }
}

/// Every membership row of a project, ended stints included, for the owner's
/// members screen (task 11.2).
///
/// **Reads local SQLite, so the screen works offline.** Who is on the project
/// is synced data; only the *join code and the pending requests* need the
/// server, which is why they are separate providers that can fail on their own
/// without taking the member list down with them.
@riverpod
Future<List<ProjectMember>> projectMemberships(
  Ref ref,
  String projectId,
) async {
  final repo = await ref.watch(projectMembershipRepositoryProvider.future);
  final users = await ref.watch(userRepositoryProvider.future);
  final memberships = await repo.findByProject(projectId, includeDeleted: true);
  final profiles = <String, User?>{};
  for (final membership in memberships) {
    profiles[membership.userId] ??= await users.findById(
      membership.userId,
      includeDeleted: true,
    );
  }
  return [
    for (final membership in memberships)
      ProjectMember(membership: membership, user: profiles[membership.userId]),
  ];
}

/// **The projects on this device that the signed-in person is no longer on**
/// (task 11.54).
///
/// A closed stint and no open one, and that is the whole definition —
/// `ProjectMembershipRepository.hasDeparted`, the same question
/// `SyncController._weHaveLeft` asks about the active project, asked here for
/// the whole list at once because the projects screen has to render every
/// row's controls in one pass. One derivation since task 11.305, which found
/// the sync round asking a wider version of it and unlinking a project on the
/// answer.
///
/// **Requiring a closed stint, rather than merely the absence of an open one,
/// is what keeps this from meaning "every project you never joined".** A purely
/// local project has no membership rows for anybody, and offering to treat one
/// of those as a project you left would be wrong on the most common kind of
/// project this app holds.
@riverpod
Future<Set<String>> departedProjectIds(Ref ref) async {
  final projects = await ref.watch(allProjectsProvider.future);
  final userId = (await ref.watch(currentUserProvider.future)).userId;
  final repo = await ref.watch(projectMembershipRepositoryProvider.future);
  final departed = <String>{};
  for (final project in projects) {
    if (await repo.hasDeparted(project.projectId, userId)) {
      departed.add(project.projectId);
    }
  }
  return departed;
}

/// **How many of this device's records for [projectId] will never reach the
/// server** (task 11.54).
///
/// Asked before warning somebody that deleting the project loses them, because
/// *"you will lose everything"* and *"you will lose only what never synced"*
/// lead a person to different decisions and only one of them is true on any
/// given day. Warning as though something is stranded when nothing is would
/// train somebody to ignore the warning on the day something is.
///
/// Two numbers, and they are the two ways a record can be on this device and
/// nowhere else:
///
/// - **[waiting]** — never offered to the server yet. Ordinary before this
///   person left; permanent now, because every further attempt is refused.
/// - **[refused]** — offered and refused, already counted against "everything
///   is synced" by the held-row store since task 10.28.
///
/// Both come from the sync engine's own predicates rather than from a second
/// query written to match them, for the reason task 10.33 gave: a count kept in
/// step by hand is a count that eventually disagrees with the thing it counts.
///
/// [everSynced] is the third answer, and it is what stops the warning claiming
/// something about a server for a project that has never been on one. Read from
/// `SyncRowReceiptStore`, which holds one durable receipt per row the server has
/// confirmed and — unlike the cursor and the linked flag — is **deliberately
/// not cleared** when a project unlinks. That is exactly why it can still answer
/// "did this ever reach a server" after leaving, when nothing else can.
///
/// **Every `ref.watch` before the first `await` (task 11.236).** This is one
/// of the four providers named in `TASK_COMMS.md`'s entry for task 11.236,
/// alongside [heldRowRetryProvider] — read bare
/// (`ref.read(strandedRecordCountProvider(...).future)`) by the Projects
/// screen's leave/delete warning, which is exactly the shape
/// [_ensureOwnerMembership] broke on: an auto-disposing provider whose body
/// `ref.watch`ed a second thing after its first `await`. The two watches here
/// have no dependency on one another, so both are issued synchronously before
/// either is awaited.
@riverpod
Future<({int waiting, int refused, bool everSynced})> strandedRecordCount(
  Ref ref,
  String projectId,
) async {
  final dbFuture = ref.watch(appDatabaseProvider.future);
  final userFuture = ref.watch(currentUserProvider.future);
  final db = await dbFuture;
  final userId = (await userFuture).userId;
  await SyncRowReceiptStore.ensureTable(db.raw);
  await SyncHeldRowStore.ensureTable(db.raw);
  return (
    waiting: await SyncEngine.pendingRowCount(db.raw, projectId, userId),
    refused: await SyncEngine.heldRowCount(db.raw, projectId),
    everSynced: await SyncRowReceiptStore(db.raw).count(projectId) > 0,
  );
}

/// What happened when somebody left a project (task 11.28) — enough for the
/// screen to tell them the truth about where their departure has got to.
class LeaveProjectResult {
  const LeaveProjectResult({
    required this.projectId,
    required this.wasLinked,
    required this.serverToldNow,
  });

  final String projectId;

  /// Whether this project was on a server at all. A purely local project has
  /// nobody to tell.
  final bool wasLinked;

  /// Whether the server has confirmed the departure, so this device has
  /// already stopped syncing the project. False means the row is written and
  /// pending — the person has left as far as this device is concerned, and it
  /// binds everyone else at the next successful sync.
  final bool serverToldNow;
}

/// Whether the signed-in user may leave [projectId], and if not, why — the
/// screen-side half of task 11.28, computed from the same membership rows the
/// repository will read at the write.
///
/// Both inputs come from the shared resolution ([resolveProjectOwners] via
/// `ownersOf`, and `findForUser`'s `end_date IS NULL`), so the control cannot
/// render enabled for a write that will then be refused — the failure task
/// 11.12 exists to prevent.
@riverpod
Future<({bool canLeave, String? reason})> leaveProjectVerdictFor(
  Ref ref,
  String projectId,
) async {
  final userId = (await ref.watch(currentUserProvider.future)).userId;
  final repo = await ref.watch(projectMembershipRepositoryProvider.future);
  final mine = await repo.findForUser(projectId, userId);
  if (mine == null) {
    return leaveProjectVerdict(isMember: false, isLastOwner: false);
  }
  final openOwners = await repo.openOwnerships(projectId);
  return leaveProjectVerdict(
    isMember: true,
    // "Last owner" is about the *rows*, not the people: the guard the write
    // applies counts open owner membership rows other than this one, so this
    // has to ask the same question rather than "am I the only owner".
    isLastOwner:
        openOwners.every((m) => m.membershipId == mine.membershipId) &&
        openOwners.isNotEmpty,
  );
}

/// A project's join settings: whether joining is on, the code, the limit, and
/// the two counts. Requires connectivity and ownership.
///
/// **Carries the join code in readable form** — Security Model §4.2.1, the one
/// written exception to §4.2's plaintext rule, so an owner can re-read it after
/// closing the screen instead of rotating and re-broadcasting to a whole crew.
@riverpod
Future<JoinSettings> projectJoinSettings(Ref ref, String projectId) async =>
    (await _transportFor(ref)).joinSettings(projectId);

/// The people waiting for this project's owner to decide. Owner-only, and needs
/// the server — who is *on* the project is synced data and works offline, but a
/// pending request is server-only state by design, so these are separate
/// providers that can fail independently.
@riverpod
Future<List<JoinRequestSummary>> projectJoinRequests(
  Ref ref,
  String projectId,
) async => (await _transportFor(ref)).joinRequests(projectId);

/// The authenticated transport this device can reach a server with, or null
/// when it cannot.
///
/// The membership surface's name for [serverTransportProvider].
///
/// **A one-line delegation since task 11.97, and the name is kept on
/// purpose.** Task 11.83 made this a provider so that the seam every
/// membership call and the join-request watcher reach the server through
/// could be replaced in a test, and `/w-05`'s screenshot harness overrides it
/// by that name. What changed is only where the connection is *built*: there
/// is now one construction of [HttpSyncTransport] in the app rather than
/// three, so a test that substitutes a failing server no longer has to know
/// which surface it is substituting it for.
///
/// **Which override to reach for.** Overriding [serverTransportProvider]
/// replaces the connection everywhere, this provider included, because this
/// one reads it. Overriding *this* one replaces it for the membership surface
/// alone and leaves the sync engine on a real connection — which is exactly
/// what the screenshot harness wants and is not what an app-level test wants.
@Riverpod(keepAlive: true)
Future<SyncTransport?> membershipTransport(Ref ref) =>
    ref.watch(serverTransportProvider.future);

/// The signed-in user id `SyncEngine` has needed since task 11.43, thrown for
/// on the same condition [_transportFor] throws on.
Future<String> _sessionUserIdFor(Ref ref) async {
  final session = await ref.read(currentSessionProvider.future);
  if (session == null) throw const SyncTransportException('not_configured');
  return session.userId;
}

Future<SyncTransport> _transportFor(Ref ref) async {
  // Before `membershipTransportProvider`, for the reason recorded in
  // `SyncController._engine` and `ProjectLinkController._requireTransport`
  // (task 11.104): that provider awaits the http client, and the refusal
  // explaining a rejected address does not survive the trip.
  if (await ref.read(serverUrlRefusalProvider.future) != null) {
    throw const SyncTransportException(
      SyncTransportException.serverAddressRefused,
    );
  }
  final transport = await ref.read(membershipTransportProvider.future);
  if (transport == null) throw const SyncTransportException('not_configured');
  return transport;
}

/// Membership actions: ask to join, approve, reject, rotate the code, re-admit
/// a past member, change a role, end a stint.
///
/// Split from [ProjectLinkController] for the reason that one was split from
/// [SyncController]: these act on a project the *owner* is managing, which is
/// not necessarily the one currently open, and one of them (redeem) acts on a
/// project this device has never seen.
@Riverpod(keepAlive: true)
class MembershipController extends _$MembershipController {
  @override
  void build() {}

  /// Switches joining on or off, or sets the team-size limit.
  Future<JoinSettings> updateJoinSettings({
    required String projectId,
    bool? joiningEnabled,
    int? teamSizeLimit,
  }) async {
    final transport = await _requireTransport();
    final settings = await transport.updateJoinSettings(
      projectId: projectId,
      joiningEnabled: joiningEnabled,
      teamSizeLimit: teamSizeLimit,
    );
    ref.invalidate(projectJoinSettingsProvider(projectId));
    return settings;
  }

  /// Mints a new join code, and optionally clears the pending queue.
  ///
  /// **[clearPending] defaults to false and the screen must default it to
  /// false too.** Rotation is how an owner responds to a code they no longer
  /// trust, and the people already queued are usually the crew they meant to
  /// admit. This is the only bulk operation in the whole design, and it is
  /// reachable only from a rotation the owner went looking for.
  Future<RotateJoinCodeResponse> rotateJoinCode({
    required String projectId,
    bool clearPending = false,
  }) async {
    final transport = await _requireTransport();
    final rotated = await transport.rotateJoinCode(
      projectId: projectId,
      clearPending: clearPending,
    );
    ref.invalidate(projectJoinSettingsProvider(projectId));
    ref.invalidate(projectJoinRequestsProvider(projectId));
    return rotated;
  }

  /// Approves one request and grants the membership.
  ///
  /// **The server writes the membership row, not this device.** Nothing here
  /// shapes it: the project comes from the request, the person comes from the
  /// request, and the role is the one the owner just chose. That is why
  /// approving does not need — and must not get — a permissive branch in the
  /// row authorizer.
  Future<void> approveJoinRequest({
    required String projectId,
    required String requestId,
    required ProjectRole role,
  }) async {
    final transport = await _requireTransport();
    await transport.approveJoinRequest(
      projectId: projectId,
      requestId: requestId,
      role: role,
    );
    ref.invalidate(projectJoinRequestsProvider(projectId));
    ref.invalidate(projectJoinSettingsProvider(projectId));
    _afterMembershipChange(projectId);
  }

  Future<void> rejectJoinRequest({
    required String projectId,
    required String requestId,
  }) async {
    final transport = await _requireTransport();
    await transport.rejectJoinRequest(
      projectId: projectId,
      requestId: requestId,
    );
    ref.invalidate(projectJoinRequestsProvider(projectId));
    ref.invalidate(projectJoinSettingsProvider(projectId));
  }

  /// Puts a past member back on the project directly (task 11.81, design §1.5).
  ///
  /// **This is the one membership grant an owner may make without the other
  /// person acting**, and the bound that makes it safe is the project's own
  /// history: the server refuses anyone who does not already hold a closed
  /// membership row here and no open one. It cannot add a stranger; it can only
  /// reverse a removal the owner themselves made.
  Future<void> readmitMember({
    required String projectId,
    required String userId,
    required ProjectRole role,
  }) async {
    final transport = await _requireTransport();
    await transport.readmitMember(
      projectId: projectId,
      userId: userId,
      role: role,
    );
    ref.invalidate(projectJoinSettingsProvider(projectId));
    _afterMembershipChange(projectId);
  }

  /// Asks to join whichever project [code] names.
  ///
  /// **This grants nothing and joins nothing**, which is the whole difference
  /// from what it replaced. Redeeming an invite code used to make you a member
  /// on the spot, so the app pulled the project immediately. A request only
  /// puts you in the owner's list — so there is nothing to download, and the
  /// screen has to say "waiting for approval" rather than implying otherwise.
  /// **Since task 11.83 the device finishes the job by itself once the owner
  /// approves** — `JoinRequestWatcher` sees the decision, links the project
  /// and syncs it, and the "Your requests" card narrates all of it. Nobody has
  /// to come back to a screen and tap anything.
  ///
  /// [claimedName] is pre-filled from this device's own profile so most people
  /// type nothing. It is still what the requester *says* they are called, and
  /// the owner's screen presents it as such.
  Future<JoinRequestCreatedResponse> requestToJoin(
    String code, {
    String? claimedName,
  }) async {
    final transport = await _requireTransport();
    final JoinRequestCreatedResponse created;
    try {
      created = await transport.requestToJoin(
        code: code,
        claimedName: claimedName,
      );
    } on SyncTransportException catch (e) {
      // **"You have already asked" is a second device catching up, not a
      // failure to record** (task 11.83). One account, two devices: the phone
      // sent the request, and now the laptop types the same code. The server
      // is right to refuse a second row — but this device is every bit as much
      // waiting on that answer as the phone is, so it starts watching for it.
      // Without this the laptop would never learn it had been let in.
      if (e.reason == joinRefusalAlreadyRequested) {
        await _startWatchingForApproval();
      }
      rethrow;
    }
    await _startWatchingForApproval();
    return created;
  }

  /// **Starts the watch** (task 11.83). This is the moment this device
  /// acquires an outstanding request, so it is the moment the 60-second poll
  /// should begin — and until it runs once, nothing on either screen knows
  /// there is a request to narrate.
  ///
  /// The note is written first and awaited: it is what tells the *next* app
  /// launch that there is something to ask about, and losing it would leave
  /// somebody waiting forever on a device that had been closed and reopened.
  Future<void> _startWatchingForApproval() async {
    final watcher = ref.read(joinRequestWatcherProvider.notifier);
    await watcher.noteRequestMade();
    unawaited(watcher.refresh());
  }

  /// Downloads a project the signed-in person is already a member of.
  ///
  /// Kept as a separate step from [requestToJoin] for the reason redemption and
  /// joining were always two steps: the grant happens on the server, and the
  /// join is an ordinary sync from cursor zero (task 10.9) which is fully
  /// resumable. If the download is interrupted the membership still stands and
  /// the next sync continues it — the right failure mode for a device on a
  /// marginal connection at the end of a track.
  Future<void> joinApprovedProject(
    String projectId, {
    void Function(SyncProgress)? onProgress,
  }) async {
    final transport = await _requireTransport();
    final db = await ref.read(appDatabaseProvider.future);
    await ProjectJoiner(
      db: db.raw,
      transport: transport,
      state: ref.read(syncStateStoreProvider),
      deviceId: await ref.read(deviceIdProvider.future),
      userId: await _sessionUserIdFor(ref),
    ).join(projectId, onProgress: onProgress);
    ref.invalidate(allProjectsProvider);
    ref.invalidate(syncControllerProvider);
    ref.invalidate(isProjectLinkedProvider);
  }

  /// Changes [membership]'s role.
  ///
  /// Travels by ordinary sync rather than through an endpoint of its own: this
  /// is an *update* to a row the rule table already governs, checked on this
  /// device by `MutationRule.projectOwner` and again on the server by
  /// `RowAuthorizer`, including task 11.1's last-owner guard on both sides. A
  /// dedicated route would be a third place for the same decision to be made
  /// slightly differently.
  Future<void> changeRole(
    ProjectMembership membership,
    ProjectRole role,
  ) async {
    final repo = await ref.read(projectMembershipRepositoryProvider.future);
    final user = await ref.read(currentUserProvider.future);
    await repo.update(
      membership.copyWith(role: role),
      actor: MutationActor.user(user.userId),
      deviceId: await ref.read(deviceIdProvider.future),
    );
    _afterMembershipChange(membership.projectId);
  }

  /// Ends [membership]'s stint.
  ///
  /// **What this does and does not reach.** It stops future syncs and blocks
  /// server access from the caller's next request onward, because the server
  /// resolves project access from membership on every request and caches
  /// nothing. It does not, and cannot, delete the copy of the project already
  /// on that person's device. See the members screen, where the owner is told
  /// this before they add anybody.
  Future<void> endMembership(ProjectMembership membership) async {
    final repo = await ref.read(projectMembershipRepositoryProvider.future);
    final user = await ref.read(currentUserProvider.future);
    await repo.endMembership(
      membership,
      actor: MutationActor.user(user.userId),
      now: DateTime.now(),
      deviceId: await ref.read(deviceIdProvider.future),
    );
    _afterMembershipChange(membership.projectId);
  }

  /// **The signed-in user leaves [projectId] themselves (task 11.28).**
  ///
  /// Three steps, and the order is the whole design:
  ///
  /// 1. **End the local row.** `ProjectMembershipRepository.leaveProject`
  ///    finds the caller's own open membership and closes it, refusing the
  ///    last owner ([LastOwnerRemoval]) and somebody who is not a member
  ///    ([NotAProjectMember]).
  /// 2. **Try to tell the server now**, rather than waiting for the schedule.
  ///    Leaving is a thing a person does deliberately and then expects to be
  ///    true; a quiet fifteen-minute delay before it binds anybody is the
  ///    wrong shape for it.
  /// 3. **Stop syncing this project — but only once the server has actually
  ///    taken the row.** This is the half task 11.28 calls "the device stays
  ///    in step", and the ordering is what makes it work. Unlinking first
  ///    would strand the departure on this device forever: nothing would push
  ///    it, so the person would still be a member everywhere but here. Waiting
  ///    for the receipt means the local state changes when, and only when, the
  ///    server agrees with it.
  ///
  /// Left linked, the project would go on syncing until the server refused it
  /// with a bare `403` — terminal, unexplained, and indistinguishable from a
  /// broken server. That is what a *removed* member's device does today; a
  /// person who left on purpose should not have to read it as a fault.
  ///
  /// **Nothing is deleted.** The observations, tags and estimates already on
  /// this device stay exactly where they are and the project keeps working
  /// offline — the same truth the members screen tells an owner about removing
  /// somebody, in the other direction. [LeaveProjectResult.serverToldNow] is
  /// what the screen needs to say which of the two things just happened.
  Future<LeaveProjectResult> leaveProject(String projectId) async {
    final state = ref.read(syncStateStoreProvider);
    final wasLinked = await state.isProjectLinked(projectId);
    // **Sync before writing, not only after.** A departure must match the
    // server's copy of the row in every column but `end_date` — that is what
    // stops it also being a promotion or a re-dated stint — so a device
    // holding a *stale* copy would build a row the server correctly refuses,
    // and land back in the held-forever state this task exists to end. The
    // realistic way to be stale is that an owner changed your role while you
    // were offline. Pulling first costs one round trip on an action somebody
    // takes once, and it also means "an owner already removed me" surfaces as
    // [NotAProjectMember] rather than as a refusal after the fact.
    if (wasLinked) {
      try {
        // `syncProjectNow`, not `syncNow`: leaving a project you are not
        // currently working in is the ordinary case — you open Projects,
        // find the one you want off, and leave it — and `syncNow` syncs the
        // *active* project. Pushed through that, a departure from any other
        // project would simply never leave the device.
        await ref
            .read(syncControllerProvider.notifier)
            .syncProjectNow(projectId);
      } catch (_) {
        // Offline is fine: the local copy is then the best available answer,
        // and a mismatch is refused and held rather than lost.
      }
      ref.invalidate(projectMembershipsProvider(projectId));
    }

    final repo = await ref.read(projectMembershipRepositoryProvider.future);
    final user = await ref.read(currentUserProvider.future);
    final departed = await repo.leaveProject(
      projectId: projectId,
      actor: MutationActor.user(user.userId),
      now: DateTime.now(),
      deviceId: await ref.read(deviceIdProvider.future),
    );

    var serverToldNow = false;
    if (wasLinked) {
      // Best effort, and a failure here is not a failure of leaving: the row
      // is written and pending, so the next successful sync carries it. Errors
      // are swallowed for the same reason `CurrentSession.signOut` swallows
      // them — an unreachable server must not trap somebody in a project.
      try {
        await ref
            .read(syncControllerProvider.notifier)
            .syncProjectNow(projectId);
      } catch (_) {
        // Deliberately ignored; `serverToldNow` stays false and the screen
        // says the departure is still on its way.
      }
      serverToldNow = await _serverHasDeparture(projectId, departed);
      if (serverToldNow) {
        // Forget the cursor, the last-success stamp, the linked flag and the
        // remembered failure — `SyncStateStore.clear`, which only ever runs
        // once this device is off the project (sign-out does not call it;
        // task 11.304). Row receipts are deliberately kept — they are
        // statements about what the server holds, which do not stop being true.
        await state.clear(projectId);
        ref.invalidate(isProjectLinkedProvider);
        // **And tell the sync surface, which is the half task 11.54 found
        // missing.** Unlinking is a fact about this project that
        // `SyncController.build` reads once and then holds; nothing here
        // watched it, so the controller went on reporting whatever the last
        // round left behind. On the leave path that last round is the one that
        // pushed the departure and was then refused — so the person read
        // "Sync isn't working" about a project they had just chosen to leave.
        ref.invalidate(syncControllerProvider);
      }
    }

    _afterMembershipChange(projectId);
    ref.invalidate(leaveProjectVerdictForProvider(projectId));
    return LeaveProjectResult(
      projectId: projectId,
      wasLinked: wasLinked,
      serverToldNow: serverToldNow,
    );
  }

  /// Whether the server has confirmed the exact departure row this device just
  /// wrote.
  ///
  /// Asks [departureIsConfirmed], which is the same question the foreground
  /// recovery asks of a departure that never got out at all (task 11.57) — one
  /// spelling, because two would be two answers waiting to disagree.
  ///
  /// The **raw** row is read rather than the model, and the comparison is
  /// against a receipt for the row as it now stands rather than against the
  /// mere existence of one: a receipt from before the departure would otherwise
  /// read as "the server knows", which is the one wrong answer that matters
  /// here.
  Future<bool> _serverHasDeparture(
    String projectId,
    ProjectMembership departed,
  ) async {
    final db = await ref.read(appDatabaseProvider.future);
    final table = syncTablesByName[Tables.projectMemberships]!;
    final rows = await db.raw.query(
      Tables.projectMemberships,
      where: 'membership_id = ? AND project_id = ?',
      whereArgs: [departed.membershipId, projectId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final stored = rows.first;
    if (stored['end_date'] == null) return false;
    return departureIsConfirmed(
      receipts: SyncRowReceiptStore(db.raw),
      table: table,
      projectId: projectId,
      storedRow: stored,
    );
  }

  /// **The list this used to hold inline now lives in
  /// `project_view_refresh.dart`** (task 11.153), because the sync merger has
  /// to invalidate exactly the same set when somebody *else's* membership
  /// change arrives, and two copies of that list are two answers waiting to
  /// disagree. Moving it also found that it was one provider short — see
  /// [refreshProjectViews].
  void _afterMembershipChange(String projectId) {
    refreshProjectViews(ref, projectId: projectId);
    // The change only binds anyone else once it reaches the server, so nudge
    // the schedule rather than waiting for its next interval.
    ref.read(syncControllerProvider.notifier).syncNow();
  }

  Future<SyncTransport> _requireTransport() => _transportFor(ref);
}
