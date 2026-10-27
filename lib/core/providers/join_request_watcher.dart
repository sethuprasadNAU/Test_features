import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/db/data_arrival.dart';
import '../../data/sync/sync_transport.dart';
import 'app_context_provider.dart';
import 'database_provider.dart';
import 'membership_provider.dart';
import 'sync_provider.dart';

part 'join_request_watcher.g.dart';

/// How often this device asks whether its outstanding join request has been
/// decided (task 11.83).
///
/// **Sixty seconds, and the number is chosen against a published limit rather
/// than picked.** `RateLimits.joinRequestListPerUser` allows 60 reads per 15
/// minutes — one every 15 seconds — and that bucket was written for exactly
/// this poll, in its author's words: *"a device polling for 'has the owner
/// approved me yet' must not be able to deny itself the answer."* One a minute
/// is a quarter of what is allowed, which leaves room for a pull-to-refresh
/// and an app resume in the same minute without the device locking itself out
/// of the answer it is waiting for.
const Duration joinRequestPollInterval = Duration(seconds: 60);

// **The two-minute queue timeout that used to live here is gone** (task
// 11.61), and its own note is why: it existed *because* "nothing in this app's
// http client sets a response timeout yet", so that one socket hanging rather
// than failing could not wedge the poll for the rest of the session. Every
// request this watcher makes is now bounded at the seam that makes it — 30
// seconds for the poll, and each page of a project download separately — so
// the condition it guarded against cannot arise.
//
// **Deleting it is the point rather than a tidy-up.** It bounded how long a
// check could *hold the queue*, not how long a request could run, so it could
// only ever abandon a check while leaving the socket behind it alive; and it
// would have cut short a download that was working perfectly well and merely
// taking longer than two minutes, which is an ordinary first pull of a season
// of data on a field link.

/// What this device has managed to do about an approval it has seen.
///
/// **There is no `approved` state without one of these.** The point of task
/// 11.83 is that "the owner said yes" is not news a person can use; "the
/// project is on this device" is. So the card reports where the download got
/// to, and every one of these values is a different sentence.
enum JoinArrival {
  /// Linked, and the first pull is running now.
  arriving,

  /// The project is on this device and syncing.
  arrived,

  /// **Linked, and the pull did not finish.** The membership stands, the
  /// cursor is wherever it stopped, and the next check continues it — the
  /// resumable-download property `SyncEngine` has had since task 10.8. What
  /// the person sees depends on whether any page landed before the connection
  /// went: with one, the project is on the projects screen and behind; with
  /// none, it is not there yet. The card says which, from [projectPresent].
  incomplete,

  /// **The server said approved and did not say which project** — a server
  /// older than task 11.83. Nothing here can complete the join, so the card
  /// says so and points at the one screen that can.
  cannotAct,
}

/// One approval, and how far this device has got with it.
class JoinArrivalState {
  const JoinArrivalState({required this.arrival, required this.projectPresent});

  final JoinArrival arrival;

  /// Whether a live local `Projects` row for it exists — i.e. whether the
  /// project is visible on the projects screen at all. Only interesting when
  /// [arrival] is [JoinArrival.incomplete], where "present and behind" and
  /// "not here yet" are two different things to be told.
  final bool projectPresent;
}

/// The requester's side of joining: the requests, and what became of them.
class JoinWatch {
  const JoinWatch({this.requests = const [], this.arrivals = const {}});

  /// This person's own requests, newest first, exactly as the server ordered
  /// them.
  final List<MyJoinRequest> requests;

  /// Request id → what this device did about it. **In memory only**, and that
  /// is deliberate: "you're in, it's downloading" is news, and news is worth
  /// telling once. The durable half — *has this approval already been acted
  /// on* — lives in `SyncStateStore.autoJoinedRequestIds`, because that is the
  /// half that must survive a restart.
  final Map<String, JoinArrivalState> arrivals;

  bool get hasOutstandingRequest => requests.any((r) => r.isPending);

  JoinWatch copyWith({
    List<MyJoinRequest>? requests,
    Map<String, JoinArrivalState>? arrivals,
  }) => JoinWatch(
    requests: requests ?? this.requests,
    arrivals: arrivals ?? this.arrivals,
  );
}

/// **Turns "the owner approved you" into "the project is on your phone"**
/// (task 11.83).
///
/// ## The defect this exists to close
///
/// Task 11.81 shipped the flow the design specified, and §2.3 of
/// `JOIN_CODE_AND_APPROVAL_DESIGN.md` said of the requester's side *"nothing
/// new is needed"* — because after approval the project does appear in
/// `GET /projects/mine`, and the "Join a project" screen does render it with a
/// Join button. Michael ran it on two real devices on 2026-08-31: the Mac
/// approved, and the project never appeared on the iPhone. Nothing errored.
/// **The person had no reason to go back to that screen and nothing told them
/// to**, and the one element that had been tracking the request — the "Your
/// requests" card — filtered approvals out of its own list, so at the exact
/// moment the news arrived it went blank.
///
/// So this does two things, and they are one mechanism rather than two:
///
/// 1. **It completes the join without being asked.** A device that knows it
///    has been let in and waits to be told again is the same silence in a new
///    place.
/// 2. **It carries the state the card narrates**, so approval and rejection
///    are told through the same element in the same place.
///
/// ## When it asks
///
/// - **Every [joinRequestPollInterval] while a request is outstanding**, and
///   only then. A device with nothing pending polls nothing, and the poll
///   stops the moment the last outstanding request is decided — see
///   [_reschedule]. That is what keeps this from being a battery cost with no
///   purpose.
/// - **Once whenever the app comes to the foreground.** The approval usually
///   lands while the phone is in a pocket, so this is the common real case.
/// - **On pull-to-refresh** on the projects screen, which is the manual
///   override and the thing a person actually reaches for.
///
/// **Foreground only. If the app is closed, nothing arrives until it is
/// opened**, and there is no mechanism here or anywhere else in this app that
/// changes that: delivering to a closed app means push notifications, which
/// need an Apple developer account this project does not have.
///
/// **It is not the sync tick, and that was measured rather than assumed.**
/// Automatic sync (task 11.59) runs against the *active, linked* project and
/// asks neither `/projects/join-requests/mine` nor `/projects/mine` —
/// so for somebody joining their **first** project, which is the case that
/// matters most, there is no loop to piggyback on at all.
@Riverpod(keepAlive: true)
class JoinRequestWatcher extends _$JoinRequestWatcher {
  Timer? _timer;

  /// The tail of the queue of checks. **Serialised rather than dropped**: a
  /// pull-to-refresh arriving while the poll's own read is in flight is a
  /// person asking a question, and answering it with the result of a request
  /// that was already on its way — one made *before* the owner decided — is
  /// how "I pulled and nothing happened" gets built.
  Future<void> _queue = Future<void>.value();

  /// Projects whose download is running right now.
  ///
  /// The one thing two overlapping checks must not do is start the same
  /// project's first pull twice against the same database.
  final Set<String> _joiningProjects = {};

  /// Approvals whose download failed since the last foreground.
  ///
  /// Cleared by [check] when it is called for a resume or a manual refresh, so
  /// a device that has just been picked up tries again — but *not* by the
  /// periodic tick, so a project the server will not hand over cannot turn the
  /// 60-second poll into a 60-second retry of a failing sync round.
  final Set<String> _failedSinceForeground = {};

  @override
  JoinWatch build() {
    ref.onDispose(suspend);
    // Task 11.302: "it's on this device" is re-checked whenever synced data
    // arrives, because an owner's deletion (or restore) arrives that way.
    void onArrival() => unawaited(_recheckArrivedProjects());
    DataArrival.addListener(onArrival);
    ref.onDispose(() => DataArrival.removeListener(onArrival));
    return const JoinWatch();
  }

  /// Re-reads, for every approval this session has reported as arrived,
  /// whether its project is still live on this device — and moves
  /// [JoinArrivalState.projectPresent] if it is not (or is again).
  ///
  /// Found on Michael's device look for task 11.302 (2026-09-24): the card
  /// said *"It's on this device and syncing — open it from your projects
  /// list"* after the owner had deleted the project and it had left that
  /// list. The arrival was right when it was recorded and nothing re-asked.
  /// Costs nothing on a device with no arrival to report — the common case —
  /// and one indexed read per arrival otherwise.
  Future<void> _recheckArrivedProjects() async {
    final arrived = [
      for (final request in state.requests)
        if (request.projectId != null &&
            state.arrivals[request.requestId]?.arrival == JoinArrival.arrived)
          request,
    ];
    for (final request in arrived) {
      if (!ref.mounted) return;
      final row = await _localProjectRow(request.projectId!);
      if (!ref.mounted) return;
      final live = row != null && row['deleted_at'] == null;
      final current = state.arrivals[request.requestId];
      if (current == null ||
          current.arrival != JoinArrival.arrived ||
          current.projectPresent == live) {
        continue;
      }
      _setArrival(request.requestId, JoinArrival.arrived, live);
    }
  }

  /// Whether the 60-second poll is currently running.
  ///
  /// Exposed because the report on this task claims the poll stops when the
  /// last request is decided, and a claim about a timer that nothing can see
  /// is not a claim anything can check.
  bool get isPolling => _timer != null;

  /// Stops the poll. Called when the app leaves the foreground.
  void suspend() {
    _timer?.cancel();
    _timer = null;
  }

  /// **A person asked** — pull-to-refresh, or opening the "Join a project"
  /// screen. Always reaches the server, and always retries a download that
  /// failed earlier.
  Future<void> refresh() =>
      _enqueue(clearFailures: true, onlyIfWorkPending: false);

  /// **The app came to the foreground.** Reaches the server only if this
  /// device has join business outstanding — an undecided request, or an
  /// approval whose download stopped partway.
  ///
  /// That gate is what keeps this off the great majority of devices, which
  /// have never asked to join anything: they make no request at all, and cost
  /// one `SharedPreferences` read. It is the same shape as the automatic-sync
  /// foreground hook, which costs one local query on a device with nothing
  /// stuck.
  Future<void> checkOnForeground() =>
      _enqueue(clearFailures: true, onlyIfWorkPending: true);

  /// The 60-second tick. Same gate, and it does **not** retry a download that
  /// already failed this foreground — a project the server will not hand over
  /// must not turn a one-minute poll into a one-minute retry of a failing
  /// sync round.
  Future<void> check() =>
      _enqueue(clearFailures: false, onlyIfWorkPending: true);

  /// **Never throws.** Every caller is either the app lifecycle or a refresh
  /// gesture, and neither has anywhere to put an exception; an unreachable
  /// server is the ordinary field condition rather than an error, and the
  /// state below records what could not be done.
  Future<void> _enqueue({
    required bool clearFailures,
    required bool onlyIfWorkPending,
  }) {
    final mine = _queue.then(
      (_) => _check(
        clearFailures: clearFailures,
        onlyIfWorkPending: onlyIfWorkPending,
      ),
    );
    // Failures are already swallowed inside `_check`; this keeps one that
    // escaped anyway from poisoning every later check in the queue.
    _queue = mine.catchError((Object _) {});
    return _queue;
  }

  Future<void> _check({
    required bool clearFailures,
    required bool onlyIfWorkPending,
  }) async {
    if (!ref.mounted) return;
    if (clearFailures) _failedSinceForeground.clear();
    final store = ref.read(syncStateStoreProvider);
    if (onlyIfWorkPending && !await store.joinWorkPending()) {
      // Nothing outstanding and nothing half-downloaded: this device has no
      // question to ask, so it asks nothing.
      suspend();
      return;
    }
    if (!ref.mounted) return;
    try {
      final transport = await ref.read(membershipTransportProvider.future);
      if (transport == null) {
        // No server, or signed out. Nothing to poll and nothing to say.
        suspend();
        _publish(const JoinWatch());
        return;
      }
      if (!ref.mounted) return;
      final requests = await transport.myJoinRequests();
      _publish(state.copyWith(requests: requests));
      await _completeApprovals(requests);
      // **Recorded after the work, from what the work found.** Outstanding
      // means a request nobody has decided, or an approval whose download did
      // not finish — the two states a later foreground still has something to
      // do about. Anything else and this device stops asking.
      await store.setJoinWorkPending(
        state.hasOutstandingRequest ||
            state.arrivals.values.any(
              (a) => a.arrival == JoinArrival.incomplete,
            ),
      );
      _reschedule();
    } on SyncTransportException {
      // Offline, rate-limited, or a session that has ended. The card keeps
      // whatever it last knew rather than replacing it with an error; the sync
      // surface is where a broken server is reported.
    } catch (_) {
      // Same reasoning. A check that cannot run must not take the app with it.
    }
  }

  /// Writes state only while this notifier is still alive.
  ///
  /// Every write here follows a network round trip, and a container disposed
  /// mid-flight — an app shutting down, a test finishing — would otherwise
  /// turn an ordinary in-flight check into a thrown "used after disposed".
  void _publish(JoinWatch next) {
    if (ref.mounted) state = next;
  }

  /// Links and pulls every approved project this device has not got.
  ///
  /// **One at a time, deliberately.** Each of these is a full sync round from
  /// cursor zero; running several at once would put several rounds through the
  /// same database and the same connection for no gain.
  Future<void> _completeApprovals(List<MyJoinRequest> requests) async {
    final store = ref.read(syncStateStoreProvider);
    final handled = await store.autoJoinedRequestIds();
    for (final request in requests) {
      if (!ref.mounted) return;
      if (request.decision != joinDecisionApproved) continue;
      if (_failedSinceForeground.contains(request.requestId)) continue;
      final projectId = request.projectId;
      if (projectId == null) {
        // An approval from a server older than task 11.83. It can still be
        // told; it cannot be acted on.
        _setArrival(request.requestId, JoinArrival.cannotAct, false);
        continue;
      }
      if (_joiningProjects.contains(projectId)) continue;
      final present = await _localProjectRow(projectId);
      if (!_shouldJoin(
        alreadyHandled: handled.contains(request.requestId),
        localRow: present,
        pullUnfinished:
            state.arrivals[request.requestId]?.arrival ==
            JoinArrival.incomplete,
      )) {
        continue;
      }
      _joiningProjects.add(projectId);
      try {
        await _join(request, projectId);
      } finally {
        _joiningProjects.remove(projectId);
      }
    }
  }

  /// **Whether an approval is this device's to act on.** Three rules, and
  /// between them they answer both of the questions task 11.83 raised.
  ///
  /// 1. **No local `Projects` row at all → join.** There is nothing here to
  ///    resurrect, so this is always safe, and it is also how a first pull
  ///    that never delivered a page resumes: the membership stands, the cursor
  ///    is wherever it stopped, and the next check continues it rather than
  ///    starting again.
  /// 2. **This device started this download and did not finish it → carry on**,
  ///    even though a row is now here. A pull commits each page before
  ///    advancing, so an interruption partway leaves the project on the
  ///    projects screen holding part of its history — and without this clause
  ///    the rule below would read that row as "already dealt with" and leave
  ///    it half-downloaded. [pullUnfinished] is this session's own record of
  ///    having tried; across a restart it is gone, and the ordinary sync of a
  ///    linked project is what finishes the job.
  /// 3. **Otherwise a local row means don't.** This is the guard on
  ///    `ProjectJoiner._withdrawLocalTombstone`, which exists because a local
  ///    visibility choice once outranked the server. A project somebody
  ///    deleted leaves a tombstoned row behind, so an approval this device has
  ///    already completed will not bring it back. A *fresh* request — a new
  ///    id, which means the person went and asked again — will, and that is
  ///    right: asking again is the deliberate act that outranks the earlier
  ///    deletion.
  ///
  /// **What is deliberately not compared is the two clocks.** The server
  /// stamps the decision and the device stamps the deletion, and "is the
  /// approval newer than the deletion" across two machines is a guess. Asking
  /// "has this device already acted on this exact request" is a fact it holds
  /// itself, and it answers the same question without one.
  bool _shouldJoin({
    required bool alreadyHandled,
    required Map<String, Object?>? localRow,
    required bool pullUnfinished,
  }) => localRow == null || pullUnfinished || !alreadyHandled;

  Future<void> _join(MyJoinRequest request, String projectId) async {
    // **Recorded before the download, not after** — see
    // `SyncStateStore.markRequestAutoJoined`. If the app dies mid-pull, this
    // approval is still marked acted-on, and rule 1 above is what resumes it.
    await ref
        .read(syncStateStoreProvider)
        .markRequestAutoJoined(request.requestId);
    _setArrival(request.requestId, JoinArrival.arriving, false);
    try {
      await ref
          .read(membershipControllerProvider.notifier)
          .joinApprovedProject(projectId);
      _setArrival(request.requestId, JoinArrival.arrived, true);
    } catch (_) {
      _failedSinceForeground.add(request.requestId);
      // **Present and behind, or not here yet** — the pull commits each page
      // before advancing its cursor, so an interruption after the first page
      // leaves the project on the projects screen with part of its history.
      // The card has to say which of the two happened, because "your project
      // is there but incomplete" and "your project has not arrived" lead a
      // person to different actions.
      final present = await _localProjectRow(projectId) != null;
      _setArrival(request.requestId, JoinArrival.incomplete, present);
    } finally {
      ref.invalidate(allProjectsProvider);
    }
  }

  void _setArrival(String requestId, JoinArrival arrival, bool projectPresent) {
    _publish(
      state.copyWith(
        arrivals: {
          ...state.arrivals,
          requestId: JoinArrivalState(
            arrival: arrival,
            projectPresent: projectPresent,
          ),
        },
      ),
    );
  }

  /// A live (non-tombstoned) local row for [projectId], or null.
  ///
  /// A tombstoned row counts as **present** here, and that is the point: it is
  /// the record of somebody having deleted this project, which is exactly what
  /// rule 2 of [_shouldJoin] must not walk over. The `deleted_at` column is
  /// read so the caller can tell the two apart when it needs to.
  Future<Map<String, Object?>?> _localProjectRow(String projectId) async {
    final db = await ref.read(appDatabaseProvider.future);
    final rows = await db.raw.query(
      Tables.projects,
      columns: ['project_id', 'deleted_at'],
      where: 'project_id = ?',
      whereArgs: [projectId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Starts the poll while something is outstanding, and stops it otherwise.
  ///
  /// **This is how the poll ends.** The moment the last pending request is
  /// decided — approved, rejected or cleared by a rotation — there is nothing
  /// left to wait for, the timer is cancelled, and this device makes no
  /// further requests of `/projects/join-requests/mine` until somebody asks to
  /// join something or the app is foregrounded again.
  void _reschedule() {
    if (!ref.mounted || !state.hasOutstandingRequest) {
      suspend();
      return;
    }
    _timer ??= Timer.periodic(joinRequestPollInterval, (_) => check());
  }

  /// Called when this device has just made a request, so the next foreground
  /// and the poll both know there is something to ask about (task 11.83).
  Future<void> noteRequestMade() =>
      ref.read(syncStateStoreProvider).setJoinWorkPending(true);
}
