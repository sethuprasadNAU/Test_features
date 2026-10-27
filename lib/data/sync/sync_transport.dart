import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../core/errors/transport_failure.dart';

/// How the sync engine talks to a server.
///
/// An interface, and the acceptance criterion is that **every client sync test
/// runs against a fake implementation with no server** (Phase 10's invariant 5).
/// That is not just testing convenience: it is what keeps the engine's logic
/// independent of HTTP, so the merge and cursor behaviour can be exercised
/// exhaustively without anything to stand up.
abstract interface class SyncTransport {
  Future<SyncPushResponse> push(SyncPushRequest request);
  Future<SyncPullResponse> pull(SyncPullRequest request);
  Future<void> ack(SyncAckRequest request);

  /// Every project the server considers to belong to the signed-in user
  /// (task 10.9) — same-user-only in Phase 10; Phase 11 widens what "belong
  /// to" means server-side without changing this shape.
  Future<List<ProjectSummary>> listMyProjects();

  /// Every project the signed-in user deleted from a device that the server
  /// still holds as a tombstone (task 11.292) — the complement of
  /// [listMyProjects], which leaves a tombstoned project out. Owner only by
  /// construction: the server lists a project here only when it records the
  /// caller as an owner *and* as the sender of the tombstone. See
  /// `DeletedProjectSummary` for what a row carries and why.
  Future<List<DeletedProjectSummary>> listMyDeletedProjects();

  // ---- Joining a project (task 11.81) --------------------------------------
  //
  // **These are the one part of the app that cannot work offline, and that is
  // inherent rather than a gap.** Membership is a grant, and a grant that a
  // disconnected device could mint would not be one. Callers must say so before
  // the user is at a trailhead, not after.
  //
  // They replaced task 11.2's per-address invitations. Holding the code no
  // longer *is* membership — it buys the right to ask, and the owner decides.

  /// [projectId]'s join settings: whether joining is on, the code, the
  /// team-size limit, and the member and pending counts. Owners only; the
  /// server refuses anyone else identically to a project that does not exist.
  Future<JoinSettings> joinSettings(String projectId);

  /// Switches joining on or off and/or sets the team-size limit. Either field
  /// may be omitted, and omitting one leaves it alone.
  Future<JoinSettings> updateJoinSettings({
    required String projectId,
    bool? joiningEnabled,
    int? teamSizeLimit,
  });

  /// Mints a new join code.
  ///
  /// **Unlike an invite code, the result is not the only copy** — the owner can
  /// read it again from [joinSettings] (Security Model §4.2.1). [clearPending]
  /// defaults to false: pending requests survive a rotation unless the owner
  /// asks otherwise, and this is the only place that offer is made.
  Future<RotateJoinCodeResponse> rotateJoinCode({
    required String projectId,
    bool clearPending = false,
  });

  /// The project's join requests, pending first. Owners only.
  Future<List<JoinRequestSummary>> joinRequests(String projectId);

  /// Approves one request in [role] and writes the membership. One at a time —
  /// there is deliberately no bulk approve or bulk reject.
  Future<void> approveJoinRequest({
    required String projectId,
    required String requestId,
    required ProjectRole role,
  });

  Future<void> rejectJoinRequest({
    required String projectId,
    required String requestId,
  });

  /// Puts a **past member** of [projectId] back on it directly, with no code
  /// and no request. Refused unless they already hold a closed membership row
  /// on this project and no open one, which is what stops it adding a stranger.
  Future<void> readmitMember({
    required String projectId,
    required String userId,
    required ProjectRole role,
  });

  /// Asks to join whichever project [code] names.
  ///
  /// **Grants nothing.** It puts the caller in the owner's pending list.
  /// [claimedName] is what the requester says they are called — pre-filled from
  /// their own profile, editable, and bounded by the server exactly as
  /// `Users.first_name` is. The email the owner sees is the one the *server*
  /// authenticated and is never sent from here.
  Future<JoinRequestCreatedResponse> requestToJoin({
    required String code,
    String? claimedName,
  });

  /// The caller's own outstanding and recently-decided requests. This is how a
  /// rejected person finds out, instead of waiting forever.
  Future<List<MyJoinRequest>> myJoinRequests();

  // ---- Destroying a project (task 11.290) ----------------------------------
  //
  // Owner only; the server refuses anyone else identically to a project that
  // does not exist. Both answer with where the deletion stands, so the screen
  // draws what the server holds rather than what it assumed. **The server
  // sets the date** — the body carries an action and nothing else, so no
  // device clock can move anybody's grace period.

  /// Where [projectId]'s deletion stands, and the grace period the server
  /// would apply. Read before the owner is shown the dialog, so the sentence
  /// "in 30 days" is the server's number and not this app's guess.
  Future<ProjectDeletionStanding> projectDeletion(String projectId);

  /// Schedules, carries out, or cancels [projectId]'s destruction.
  Future<ProjectDeletionStanding> setProjectDeletion(
    String projectId,
    ProjectDeletionAction action,
  );
}

/// Refusal codes this client recognises, and will act on (task 10.11).
///
/// **A fixed vocabulary, deliberately.** The server's `error` string is only
/// honoured when it appears here; anything else collapses to
/// [SyncTransportException.serverRejected]. That keeps §4.13's posture intact —
/// no server-supplied text ever reaches the UI. What reaches the user is
/// client-authored copy selected by a known code, with integers (version
/// numbers, cursor positions) as the only values that cross.
const Set<String> knownSyncRefusals = {
  syncRefusalSchemaVersion,
  syncRefusalProtocolVersion,
  syncRefusalCursorTooOld,
  // Tasks 11.2 and 11.81. Same mechanism, same reason: the code is a fixed
  // vocabulary the client switches on, and the sentence the user reads is
  // written below rather than by the server.
  //
  // **Every code here has copy in [SyncTransportException.userMessage], and
  // that is not optional** — a refusal the server took care to make actionable
  // arrives as a generic "something went wrong" if nobody writes the sentence.
  // `sync_transport_refusal_test.dart` fails if one of these has none.
  joinRefusalCodeNotValid,
  joinRefusalAlreadyMember,
  joinRefusalAlreadyRequested,
  joinRefusalTeamFull,
  joinRefusalInvalidName,
  joinRefusalRequestNotOpen,
  joinRefusalNotAPastMember,
  syncRefusalRateLimited,
  // Task 11.290: the project named was destroyed on the server. The one
  // refusal that says why, so a device offline across the deletion is told
  // the cause rather than reading a bare 403 as "an owner may have removed
  // you".
  syncRefusalProjectDestroyed,
};

const String syncRefusalSchemaVersion = 'schema_version_mismatch';
const String syncRefusalProtocolVersion = 'protocol_version_mismatch';
const String syncRefusalCursorTooOld = 'cursor_too_old';
const String syncRefusalRateLimited = 'rate_limited';

/// Raised when a server answers something the engine cannot act on.
///
/// Carries no server-supplied *text*. [detail] holds integers only, and
/// [userMessage] is written here rather than by the server, so a refusal can be
/// actionable (task 10.11 requires it) without piping protocol noise — or an
/// untrusted server's prose — into the UI.
class SyncTransportException implements Exception {
  const SyncTransportException(
    this.reason, {
    this.statusCode,
    this.detail = const {},
    this.transportFailure,
  });

  static const String serverRejected = 'server_rejected';

  /// The reason a socket-level failure carries — no route, no DNS, connection
  /// refused. A named constant because [classifySyncFailure] keys "no network"
  /// off it, and a string literal matched in two files is the kind of pair that
  /// drifts.
  ///
  /// **No longer "timed out" as well** (task 11.61). It said so when nothing
  /// this app sent could give up and the only timeout available was a
  /// platform's; a request that reaches this app's own deadline is
  /// [requestTimedOut].
  static const String unreachable = 'unreachable';

  /// **This device will not use the server address it has saved** — task
  /// 11.104. Not a statement about the network, the server, or the wire: no
  /// request was made, because `describeServerUrlProblem` disqualified the
  /// address before one could be. A named constant for the same reason
  /// [unreachable] is one: [classifySyncFailure] keys off it, and the two
  /// files must not drift.
  ///
  /// **It has to be checked ahead of [unreachable] everywhere**, because the
  /// symptom is identical from the outside — nothing gets through — and the
  /// remedy is not remotely the same.
  static const String serverAddressRefused = 'server_address_refused';

  /// **This device reached the server and refused its security certificate**
  /// (task 11.113). The request went out; TLS is what stopped it.
  ///
  /// Named for exactly the reason [serverAddressRefused] is: from the outside
  /// this is indistinguishable from having no signal, and it is not remotely
  /// the same problem. Nobody fixes a self-signed certificate by walking
  /// uphill, and Michael's phone reported *"Offline"* against a server whose
  /// certificate Safari, on that same phone, was refusing by name.
  ///
  /// **Deliberately not terminal.** A certificate is fixed on the server, with
  /// nothing changing on this device, so the schedule must keep backing off
  /// and retrying rather than stopping — otherwise the app would never notice
  /// the day it was replaced.
  static const String certificateRejected = 'certificate_rejected';

  /// **This device set a deadline on the request and reached it** (task
  /// 11.61). Named for the same reason the two above are: [classifySyncFailure]
  /// keys off it, and a string literal matched in two files is the kind of pair
  /// that drifts.
  ///
  /// **Carries no [userMessage], deliberately.** A request that timed out and a
  /// request that found nothing there send a person to check the same three
  /// things, so this renders exactly as [unreachable] does — the whole point of
  /// task 11.61 being that the app's *existing* honest states finally become
  /// reachable, not that it gains new ones. What is kept apart is the *cause*:
  /// the durable failure record, the retry policy and `RequestGaveUp`'s own
  /// text, which names the request and which half of the exchange had stopped.
  ///
  /// **Not terminal.** A server that was too slow once may not be next time.
  static const String requestTimedOut = 'request_timed_out';

  /// **The server was reached and answered `404` for a route this app knows**
  /// (task 11.307). Assigned by [HttpSyncTransport] when a non-200 carries no
  /// recognized refusal code and its status is 404 — which is what
  /// shelf_router answers for a path it has no handler for, and also what a
  /// proxy in front of the server answers when it takes the path itself.
  ///
  /// **The app cannot tell those two apart, and this reason does not try.**
  /// The one version fact a server sends is the sync envelope's schema pair,
  /// and neither half moves when a route is added: tasks 11.290 and 11.292
  /// added three routes between them and changed neither, so a server built
  /// on 2026-09-15 and one built on 2026-09-21 both say `5.18` and only one
  /// of them has `/projects/deleted/mine`. `/health` and `/ready` carry no
  /// build identity, and the diagnostics route that does is loopback-only.
  /// So the sentence for this reason names both causes and says which one it
  /// is cannot be told from here — the honest default (defect vocabulary
  /// entry 9), and the one that stays true if a third cause turns up.
  ///
  /// Its own reason rather than [serverRejected] plus a status, so the
  /// durable failure record (`lastError`) says what happened, and so the
  /// sentence lives in [userMessage] where every screen already reads it —
  /// task 11.290 had written its own 404 sentence at one call site, and it
  /// asserted the first cause as fact.
  ///
  /// **Not terminal**, for the reason [certificateRejected] is not: the fix
  /// is on the server, and the schedule has to keep trying to notice it.
  static const String routeNotOffered = 'route_not_offered';

  /// **The server's database changed identity twice inside one sync round**
  /// (task 11.58). Raised by `SyncEngine.run`, never by a server — no
  /// response carries it.
  ///
  /// Once is not a failure: a server restored from a backup or rebuilt names a
  /// new database, the engine starts this project's sync over, and the round
  /// completes, with a sentence on the status screen saying so. **Twice, in a
  /// round that had just started over, is not a restore** — a restore needs
  /// the server stopped, and a stopped server answers nothing — it is two
  /// databases answering at one address, which retrying cannot fix. Its own
  /// reason so [classifySyncFailure] can name it, which is the member task
  /// 11.54 deliberately left out of `SyncFailureCause` while nothing could
  /// produce it.
  ///
  /// **Not terminal**, like [certificateRejected]: the fix is on the server,
  /// and the schedule has to keep trying so it notices when it lands.
  static const String serverDatabaseChanged = 'server_database_changed';

  final String reason;
  final int? statusCode;

  /// Numeric context for [reason] — version numbers, cursor positions. Never
  /// strings, so nothing a server sends can become user-facing text.
  final Map<String, int> detail;

  /// The classified transport failure this refusal came from, when it came
  /// from one (task 11.113). Null for everything a server answered.
  ///
  /// **Carrying the whole classification rather than re-deriving a cause from
  /// [reason] is the point of the task.** The sync surface and the server
  /// screen show the same sentence about the same certificate because there is
  /// only one place that sentence is written, and it travels rather than being
  /// looked up twice. It holds no server-supplied text — every word in it is
  /// authored in `transport_failure.dart` — so §4.13 is intact.
  final TransportFailure? transportFailure;

  /// True when retrying is pointless until something changes — a version
  /// mismatch, an authorization failure, or a device that has fallen behind a
  /// tombstone purge. The scheduler stops attempting rather than backing off,
  /// because backoff implies "try later" and later will not help.
  bool get isTerminal =>
      statusCode == 401 || statusCode == 403 || statusCode == 409;

  /// True when the server says this device holds no valid session — the client
  /// half of §4.3's revocation guarantee (task 10.14).
  ///
  /// **A 401 is not the same failure as a 403, and conflating them made
  /// revocation illegible.** Both are terminal, so before this the schedule
  /// stopped and the status surface reported a generic "sync isn't working" with
  /// no actionable text — which is exactly what task 10.12 warned trains people
  /// to ignore the indicator. When Phase 11's member removal revokes someone,
  /// their app should say their access ended, not that something broke.
  ///
  /// Distinguished by status rather than by an error code because the server
  /// deliberately keeps this response uninformative (§4.13): the code is a bare
  /// `unauthorized`, and expired, revoked, and never-valid are indistinguishable
  /// from outside, on purpose.
  bool get isSessionEnded => statusCode == 401;

  /// True when the two sides disagree about the schema and this build is the
  /// older one — the case where updating the *app* is the fix.
  ///
  /// Null when the direction cannot be determined (a refusal that carried no
  /// version detail), so a caller can tell "app is behind" from "cannot say"
  /// rather than defaulting to blaming the app, which is the wrong instruction
  /// half the time and sends a field tech chasing an update that does not
  /// exist.
  /// The schema *major* is consulted first because it is what compatibility is
  /// actually decided on (task 10.18); the minor and the protocol version are
  /// fallbacks for refusals that carried one but not the other.
  bool? get appIsBehindServer {
    final mine =
        detail['client_schema_major'] ??
        detail['client_schema_version'] ??
        detail['client_protocol_version'];
    final theirs =
        detail['server_schema_major'] ??
        detail['server_schema_version'] ??
        detail['server_protocol_version'];
    if (mine == null || theirs == null) return null;
    return mine < theirs;
  }

  /// Client-authored, actionable text for the refusals that have a clear
  /// remedy. Null when there is nothing specific to say and the caller should
  /// fall back to its generic "sync failed" presentation (task 10.12 owns how
  /// any of this is actually rendered).
  String? get userMessage {
    // Checked before the code switch: a 401's code is a bare `unauthorized`,
    // which is not in `knownSyncRefusals` and would otherwise fall through to
    // null and be rendered as a generic breakage.
    if (isSessionEnded) {
      // Says nothing about *why* — expired, revoked, and server-reinstalled are
      // indistinguishable from here by design (§4.13), and guessing would
      // sometimes tell a removed member they had been removed, which is the
      // project owner's message to deliver, not the app's.
      return 'This device is signed out. Sign in again to resume syncing. '
          'Nothing on this device has been changed or lost.';
    }
    final remedy = _remedy;
    if (remedy != null) return remedy.message;
    switch (reason) {
      case serverDatabaseChanged:
        // Says what this device saw and what it did, names the one likely
        // cause as a likelihood rather than a verdict, and sends it to the
        // only person who can look. "Nothing lost" and not "nothing changed":
        // a page that arrived before the second change was merged, which is
        // an ordinary sync write and not a loss.
        return "The server's records changed twice during one sync, as if "
            'two different servers were answering at the same address. This '
            'device will keep trying; tell TriTrack support (More → App '
            'Info), so they can check that only one copy is running. Nothing '
            'on this device has been lost.';
      case certificateRejected:
        // The cause-naming half is [TransportFailure.explanation], written
        // once and shared with the server screen; only the reassurance clause
        // differs, and it differs because the surfaces do — see
        // `transport_failure.dart`'s library comment. The fallback is the
        // honest one rather than a guess, for a refusal that somehow arrived
        // without its classification.
        return '${transportFailure?.explanation ?? certificateLead} '
            'Nothing on this device has been changed or lost.';
      case serverAddressRefused:
        // Deliberately *not* the full explanation. The full one — which fault,
        // and the two ways to get an https:// address — belongs on the screen
        // that owns the address and can show it beside the field, and lives in
        // `ServerUrlProblem.message`. What this has to do is refuse to be read
        // as a network problem and point at the one screen that can say more.
        return 'This device refuses the server address it has saved, so '
            'nothing has synced. It is not your network or the server: open '
            'More → Server Connection to see what to change. Nothing on this '
            'device has been changed or lost.';
      case joinRefusalCodeNotValid:
        // **Says nothing about which reason it was**, because the server does
        // not distinguish them and must not: telling somebody their code named
        // a real project whose owner has joining switched off would confirm
        // that the project exists. What the person needs is the same either
        // way — check it, then ask the owner.
        //
        // **The old sentence here said codes "expire, can only be used once,
        // and only work for the email address they were sent to." All three
        // clauses became false with task 11.81** and were not softened but
        // deleted: a join code does not expire, is used by the whole crew, and
        // is not bound to an address. Copy describing a mechanism the code does
        // not have is the defect task 11.54 exists to have fixed.
        return "That code didn't work. Check it against what the owner gave "
            'you (8 characters, like ABCD-EFGH). If it still fails, ask them '
            'whether joining is switched on.';
      case joinRefusalAlreadyRequested:
        return "You've already asked to join that project. It appears in the "
            'list below once the owner approves it.';
      case joinRefusalTeamFull:
        // **Says that pending requests count, because otherwise this sentence
        // is unreadable.** An owner looking at 40 members against a limit of
        // 50 has no way to understand a "full" refusal unless they are told
        // that the people waiting in the queue occupy places too.
        return 'That project is full. People waiting for approval count '
            'toward its limit too, so ask the owner to clear some requests or '
            'raise the limit.';
      case joinRefusalInvalidName:
        // The app bounds the field itself, so a person should never see this.
        // It is here because a bound enforced only by a text field is not a
        // bound, and a refusal nobody wrote copy for is a blank screen.
        return 'That name cannot be used. Use the name your colleagues would '
            'recognize, in ordinary letters.';
      case joinRefusalRequestNotOpen:
        return 'That request is no longer waiting — it was approved, rejected, '
            'or cleared when the code changed. Refresh the list.';
      case joinRefusalNotAPastMember:
        return 'Only someone who was removed can be put back. Give this person '
            'the join code instead, and approve their request.';
      case joinRefusalAlreadyMember:
        // **The remedy this names has to be one the app can actually
        // deliver** (task 11.57, and task 11.54's own subject one layer up).
        // The previous wording sent the person to "Join a project" — which is
        // the screen they are already on when they read this, and which until
        // task 11.57 **excluded the very project** they were looking for,
        // because a deleted or unlinked local copy counted as "already have
        // it". Message and listing were one defect and are one fix:
        // `ProjectDirectoryClient.listAvailableToJoin` now offers any project
        // the server says you are on and this device is not syncing, so the
        // list below this card holds it whenever this sentence is shown.
        return "You're already on that project. If it is not on this device, "
            'join it from the list below.';
      default:
        return null;
    }
  }

  /// **Headline for a refusal reaching [SyncFailureCause.refusedWithRemedy]**
  /// (task 11.303). Null for every other code — the Sync Status screen only
  /// consults this for [SyncHealth.versionRefused], the one state that
  /// bundles several causes under one name.
  ///
  /// Declared beside [message] in [_remedy] rather than as a parallel switch,
  /// on purpose: `sync_transport_refusal_test.dart` enumerates every code
  /// [classifySyncFailure] can route to `refusedWithRemedy` and fails if
  /// either half is missing, so a code cannot pick up a sentence without a
  /// headline of its own — the trap this task exists to close, one enum
  /// member further along than tasks 11.104 and 11.113 closed it.
  String? get userHeadline => _remedy?.headline;

  /// The headline and sentence for a code that lands in
  /// [SyncFailureCause.refusedWithRemedy], as one declaration. Null for
  /// [certificateRejected], [serverAddressRefused] and the `join…` codes,
  /// which either never reach that cause or already carry their own headline
  /// elsewhere ([SyncHealth.certificateRejected],
  /// [SyncHealth.serverAddressRefused]) — see [userMessage]'s switch for
  /// those.
  ({String headline, String message})? get _remedy {
    switch (reason) {
      case syncRefusalSchemaVersion:
      case syncRefusalProtocolVersion:
        return _versionRemedy();
      case syncRefusalCursorTooOld:
        // Deliberately does not promise an automatic fix, because there is
        // not one — see the retention policy in
        // `TriTrack_Technical_Context.md`.
        //
        // **And names no manual one either** (task 11.299). This used to end
        // "its records need to be reconciled before it can sync again", and
        // there is no reconcile step: a person reading that goes looking for
        // a button. What exists is export, from the More tab. What does not
        // exist is any way back onto the project from this device — joining
        // it again relinks the copy that is already here rather than
        // fetching the server's (`ProjectDirectoryClient`), and the round
        // that follows pushes first, which is the request being refused. So
        // the sentence names the one act the app offers, says plainly that
        // there is no second one, and sends the news to the one person whose
        // status output counts refused devices. The tile it names is
        // coupled to the More screen's source in
        // `sync_transport_refusal_test.dart`.
        return (
          headline: 'Offline too long to sync',
          message:
              'This device has been offline too long to sync this project '
              'safely: syncing now could bring back records deleted while it '
              'was away. Nothing on this device has been changed or lost, and '
              'More → Data Export / Backup saves a copy. There is no step in '
              'this app that fixes this — tell TriTrack support (More → App '
              'Info).',
        );
      case syncRefusalRateLimited:
        // **Not "Update needed"** (task 11.303) — the app is current and the
        // fix is to wait, not to install anything. This is the one cause in
        // the family somebody meets on an ordinary day: a device that just
        // synced retrying too soon.
        return (
          headline: 'Too many attempts',
          message: 'Too many attempts. Wait a few minutes and try again.',
        );
      case syncRefusalProjectDestroyed:
        // **Not "Update needed"** either (task 11.303) — nothing about this
        // app or its version is at issue. Says what happened and what is
        // still true, in that order. The records on this device are not
        // lost and not about to be — the server no longer holds this
        // project, and nothing from here will reach it again. What the
        // person can still do is export, which the Projects list offers
        // from the project's own row.
        return (
          headline: 'Project deleted',
          message:
              'This project was deleted from the server by a project owner, '
              'so nothing from this device will reach it again. The records '
              'on this device are kept — open Projects to export them.',
        );
      case routeNotOffered:
        // Task 11.307. **Names both causes and asserts neither**, because
        // this device cannot tell them apart — see [routeNotOffered] for
        // why not. The sign-in screen's own 404 sentence leads with the
        // address because at sign-in the address is the usual fault; by the
        // time this is read the address has already answered other routes,
        // so the address is not offered as a cause here. The remedy is the
        // operator's, and it is given as two things to check rather than as
        // a verdict. **Not "Update needed"** — that headline is for the one
        // case where this app is known to be the older side.
        return (
          headline: "Server doesn't offer this",
          message:
              'The server was reached, but it does not offer what this app '
              'asked for. Either it is older than this app, or something '
              'between this device and the server, such as a proxy, is '
              'answering in its place — this app cannot tell which. Tell '
              'TriTrack support (More → App Info). Nothing on this device has '
              'been changed or lost.',
        );
      default:
        return null;
    }
  }

  ({String headline, String message}) _versionRemedy() {
    const reassurance = 'Nothing on this device has been changed or lost.';
    return switch (appIsBehindServer) {
      true => (
        headline: 'Update needed',
        message:
            'This version of TriTrack is too old to sync with the server. '
            'Update the app to continue syncing. $reassurance',
      ),
      false => (
        headline: 'Server needs an update',
        message:
            'The server is older than this app and cannot sync with it. '
            'Tell TriTrack support (More → App Info) so it can be updated. '
            '$reassurance',
      ),
      // Neither version number crossed, so the direction cannot honestly be
      // named — see [appIsBehindServer]. "Update needed" would guess wrong
      // half the time, which is exactly what this task exists to stop.
      null => (
        headline: 'Version mismatch',
        message:
            'This app and the server are running incompatible versions and '
            'cannot sync. $reassurance',
      ),
    };
  }

  @override
  String toString() => 'SyncTransportException($reason)';
}

/// [SyncTransportException.userHeadline] for a bare refusal code, when only
/// the code survived — [RememberedSyncFailure] persists
/// [RememberedSyncFailure.stoppedReason] across a restart, but not the
/// version numbers [SyncTransportException.detail] would have carried, so a
/// restored version-skew headline cannot say which side is behind (task
/// 11.303). Reuses [SyncTransportException.userHeadline] rather than a
/// second mapping, so the two can never disagree about a code that has one.
///
/// `null` — nothing survived — and any code this build does not recognise
/// both fall back to the same honest, generic headline.
String syncRefusalHeadline(String? code) {
  if (code == null) return 'Sync refused';
  return SyncTransportException(code).userHeadline ?? 'Sync refused';
}

/// The real transport.
///
/// Takes an `http.Client` rather than making one, so it can only be constructed
/// where `serverHttpClientProvider` produced one — which is only when a server
/// is configured (task 10.2's invariant).
class HttpSyncTransport implements SyncTransport {
  const HttpSyncTransport({
    required this.httpClient,
    required this.baseUrl,
    required this.sessionToken,
  });

  final http.Client httpClient;
  final String baseUrl;
  final String sessionToken;

  Map<String, String> get _headers => {
    'content-type': 'application/json',
    'authorization': 'Bearer $sessionToken',
  };

  Map<String, Object?> _decode(http.Response response) {
    if (response.statusCode != 200) {
      throw _refusal(response);
    }
    try {
      return jsonDecode(response.body) as Map<String, Object?>;
    } catch (_) {
      throw const SyncTransportException('malformed_response');
    }
  }

  /// Turns a non-200 into the most specific exception the body supports.
  ///
  /// **This is the fix for the half of task 10.11 that was already built and
  /// then discarded.** The server has been returning `{"error": ...}` since
  /// 10.7, and this method previously threw it away, collapsing every refusal
  /// to `server_rejected` plus a status code — so a refusal the server took
  /// care to make actionable arrived as "something went wrong". A parse failure
  /// or an unrecognised code still collapses, so a malformed or hostile body
  /// degrades to the old behaviour rather than propagating.
  SyncTransportException _refusal(http.Response response) {
    String? code;
    final detail = <String, int>{};
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, Object?>) {
        final raw = body['error'];
        if (raw is String && knownSyncRefusals.contains(raw)) {
          code = raw;
          for (final entry in body.entries) {
            final value = entry.value;
            if (value is int) detail[entry.key] = value;
          }
        }
      }
    } catch (_) {
      // Fall through to the generic refusal below.
    }
    // A 404 with no recognized code is a route this server does not offer
    // (task 11.307). A recognized code wins: the code is the more specific
    // fact, whatever status it rode in on.
    return SyncTransportException(
      code ??
          (response.statusCode == 404
              ? SyncTransportException.routeNotOffered
              : SyncTransportException.serverRejected),
      statusCode: response.statusCode,
      detail: detail,
    );
  }

  /// Runs [parse] on a decoded body, converting the shared package's version
  /// exceptions into transport refusals.
  ///
  /// The *response* envelope is version-checked too (`SyncEnvelope.fromJson`),
  /// so a newer server answering 200 still trips the guard — on the client
  /// side, where the exception would otherwise escape as a bare
  /// `SyncSchemaVersionException` past every `SyncTransportException` handler
  /// and surface as an opaque "unexpected". Mapped here so both directions of
  /// skew produce the same terminal, actionable refusal regardless of which
  /// side noticed it.
  ///
  /// A 409 status is synthesised because no HTTP error occurred — the server
  /// answered normally, and it is this build that is refusing. `isTerminal`
  /// keys off the status, and retrying is exactly as pointless here.
  T _parse<T>(
    Map<String, Object?> body,
    T Function(Map<String, Object?>) parse,
  ) {
    try {
      return parse(body);
    } on SyncSchemaVersionException catch (error) {
      throw SyncTransportException(
        syncRefusalSchemaVersion,
        statusCode: 409,
        detail: {
          'client_schema_version': error.supported,
          'server_schema_version': error.received,
          'client_schema_major': error.supportedMajor,
          'server_schema_major': error.receivedMajor,
        },
      );
    } on SyncProtocolVersionException catch (error) {
      throw SyncTransportException(
        syncRefusalProtocolVersion,
        statusCode: 409,
        detail: {
          'client_protocol_version': error.supported,
          'server_protocol_version': error.received,
        },
      );
    }
  }

  /// Turns a request that never produced a response into a refusal.
  ///
  /// **This is where task 11.113's defect lived.** Both `catch` blocks below
  /// used to throw a bare `unreachable`, so every transport failure the sync
  /// engine ever saw was flattened into "no network" before
  /// `classifySyncFailure` got a look at it — which is why teaching that
  /// function about certificates would have changed nothing, and why the
  /// screen that *had* been taught could disagree with the sync bar about the
  /// same rejected certificate on the same device.
  ///
  /// Deliberately does not include the exception's own text: it can contain
  /// the URL, and what this carries travels toward the UI. What it does carry
  /// is the classification, whose every word is authored in
  /// `transport_failure.dart`.
  ///
  /// Falls back to [SyncTransportException.unreachable] when
  /// [classifyTransportFailure] does not recognise the error — the exact
  /// behaviour this had before — because something that is not a transport
  /// failure at all reaching here is a bug in this file, not a fact about the
  /// network worth asserting to a person.
  SyncTransportException _transportRefusal(Object error) {
    final failure = classifyTransportFailure(error);
    if (failure == null) {
      return const SyncTransportException(SyncTransportException.unreachable);
    }
    // **A switch over the classifier's answer rather than a test of one of its
    // booleans** (task 11.61). `!failure.isCertificate` used to stand in for
    // "everything else", so the first cause added that was neither a
    // certificate nor an unreachable socket would have been flattened into
    // "no network" — which is the exact defect task 11.113 wrote this method
    // to fix, one cause later.
    return switch (failure.cause) {
      TransportFaultCause.timedOut => SyncTransportException(
        SyncTransportException.requestTimedOut,
        transportFailure: failure,
      ),
      TransportFaultCause.certificateExpired ||
      TransportFaultCause.certificateUntrusted ||
      TransportFaultCause.certificateHostnameMismatch ||
      TransportFaultCause.certificateCauseUnknown => SyncTransportException(
        SyncTransportException.certificateRejected,
        transportFailure: failure,
      ),
      TransportFaultCause.unreachable => const SyncTransportException(
        SyncTransportException.unreachable,
      ),
    };
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final http.Response response;
    try {
      response = await httpClient.post(
        Uri.parse('$baseUrl$path'),
        headers: _headers,
        body: jsonEncode(body),
      );
    } catch (error) {
      throw _transportRefusal(error);
    }
    return _decode(response);
  }

  Future<Map<String, Object?>> _get(String path) async {
    final http.Response response;
    try {
      response = await httpClient.get(
        Uri.parse('$baseUrl$path'),
        headers: _headers,
      );
    } catch (error) {
      throw _transportRefusal(error);
    }
    return _decode(response);
  }

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async => _parse(
    await _post('/sync/push', request.toJson()),
    SyncPushResponse.fromJson,
  );

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async => _parse(
    await _post('/sync/pull', request.toJson()),
    SyncPullResponse.fromJson,
  );

  @override
  Future<void> ack(SyncAckRequest request) async {
    _parse(await _post('/sync/ack', request.toJson()), SyncEnvelope.fromJson);
  }

  @override
  Future<List<ProjectSummary>> listMyProjects() async => _parse(
    await _get('/projects/mine'),
    ProjectDirectoryResponse.fromJson,
  ).projects;

  @override
  Future<List<DeletedProjectSummary>> listMyDeletedProjects() async => _parse(
    await _get('/projects/deleted/mine'),
    DeletedProjectDirectoryResponse.fromJson,
  ).projects;

  /// Path-segment encoded, always. `project_id`, `request_id` and `user_id`
  /// are opaque ids that reach this from the database and from a server
  /// response rather than from a text field, but a value spliced raw into a URL
  /// is the shape of bug that survives right up until the first id containing a
  /// slash.
  String _segment(String value) => Uri.encodeComponent(value);

  @override
  Future<JoinSettings> joinSettings(String projectId) async =>
      JoinSettings.fromJson(
        await _get('/projects/${_segment(projectId)}/join-settings'),
      );

  @override
  Future<JoinSettings> updateJoinSettings({
    required String projectId,
    bool? joiningEnabled,
    int? teamSizeLimit,
  }) async => JoinSettings.fromJson(
    await _post('/projects/${_segment(projectId)}/join-settings', {
      // Omitted rather than sent as null, so "leave this alone" and "set this
      // to nothing" cannot be confused by the route.
      'joining_enabled': ?joiningEnabled,
      'team_size_limit': ?teamSizeLimit,
    }),
  );

  @override
  Future<RotateJoinCodeResponse> rotateJoinCode({
    required String projectId,
    bool clearPending = false,
  }) async => RotateJoinCodeResponse.fromJson(
    await _post('/projects/${_segment(projectId)}/join-code/rotate', {
      'clear_pending': clearPending,
    }),
  );

  @override
  Future<List<JoinRequestSummary>> joinRequests(String projectId) async =>
      JoinRequestListResponse.fromJson(
        await _get('/projects/${_segment(projectId)}/join-requests'),
      ).requests;

  @override
  Future<void> approveJoinRequest({
    required String projectId,
    required String requestId,
    required ProjectRole role,
  }) async {
    await _post(
      '/projects/${_segment(projectId)}/join-requests/'
      '${_segment(requestId)}/approve',
      {'role': role.db},
    );
  }

  @override
  Future<void> rejectJoinRequest({
    required String projectId,
    required String requestId,
  }) async {
    await _post(
      '/projects/${_segment(projectId)}/join-requests/'
      '${_segment(requestId)}/reject',
      const {},
    );
  }

  @override
  Future<void> readmitMember({
    required String projectId,
    required String userId,
    required ProjectRole role,
  }) async {
    await _post('/projects/${_segment(projectId)}/members/readmit', {
      'user_id': userId,
      'role': role.db,
    });
  }

  @override
  Future<JoinRequestCreatedResponse> requestToJoin({
    required String code,
    String? claimedName,
  }) async => JoinRequestCreatedResponse.fromJson(
    // **No project id anywhere in this request**, deliberately — see the route.
    // The only two things on the wire are the code and the claimed name; the
    // email the owner will see comes from the session, server-side.
    await _post('/projects/join-requests', {
      'code': code,
      if (claimedName != null && claimedName.isNotEmpty)
        'claimed_name': claimedName,
    }),
  );

  @override
  Future<ProjectDeletionStanding> projectDeletion(String projectId) async =>
      ProjectDeletionStanding.fromJson(
        await _get('/projects/${_segment(projectId)}/deletion'),
      );

  @override
  Future<ProjectDeletionStanding> setProjectDeletion(
    String projectId,
    ProjectDeletionAction action,
  ) async => ProjectDeletionStanding.fromJson(
    await _post('/projects/${_segment(projectId)}/deletion', {
      'action': action.wire,
    }),
  );

  @override
  Future<List<MyJoinRequest>> myJoinRequests() async =>
      MyJoinRequestsResponse.fromJson(
        await _get('/projects/join-requests/mine'),
      ).requests;
}
