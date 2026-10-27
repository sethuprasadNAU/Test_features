import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/repositories/repository_providers.dart';
import '../../data/sync/pending_departure.dart';
import '../../data/sync/pending_project_change.dart';
import '../../data/sync/remembered_sync_failure.dart';
import '../../data/sync/restored_project_arrival.dart';
import '../../data/sync/sync_engine.dart';
import '../../data/sync/sync_failure.dart';
import '../../data/sync/sync_row_receipts.dart';
import '../../data/sync/sync_schedule.dart';
import '../../data/sync/sync_state_store.dart';
import '../../data/sync/sync_transport.dart';
import 'active_selection_provider.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'device_id_provider.dart';
import 'project_deletion_provider.dart';
import 'project_link_provider.dart';
import 'server_config_provider.dart';
import 'server_transport_provider.dart';
import 'sync_conflicts_provider.dart';
import 'sync_dropped_rows_provider.dart';
import 'sync_held_rows_provider.dart';

part 'sync_provider.g.dart';

@Riverpod(keepAlive: true)
SyncStateStore syncStateStore(Ref ref) => SyncStateStore();

/// Why sync is not currently possible, when it isn't.
enum SyncUnavailable {
  /// No server URL configured — the default, and a fully supported mode.
  notConfigured,

  /// **A server URL is configured and this build will not use it** (task
  /// 11.104). The address is refused before any request is made — plain
  /// `http://` in a release or profile build being the case a beta tester
  /// actually hits, because `README.md` §4's LAN procedure ends in one.
  ///
  /// A [SyncUnavailable] rather than a failure cause, because nothing was
  /// attempted: there is no round to have failed. Like
  /// [SyncUnavailable.leftProject] it is **rendered rather than silent** — it
  /// is the answer to "why has nothing synced", and the state it replaced
  /// answered that question with "Offline", which is a different problem and
  /// sent somebody to check a working network.
  serverAddressRefused,

  /// Configured but not signed in.
  signedOut,

  /// No project selected, so there is nothing to sync.
  noProject,

  /// The active project exists locally but has never been published or
  /// joined (task 10.9). Sync must not silently publish it — that is a
  /// deliberate, explicit action, not something tapping "sync now" should do
  /// on a project the user never asked to put on a server.
  notLinked,

  /// **The signed-in person is no longer a member of this project**, so this
  /// device has stopped syncing it (task 11.54).
  ///
  /// A separate value from [notLinked], and derived rather than remembered:
  /// unlinking clears the linked flag, so after it the two states are
  /// indistinguishable from `SyncStateStore` alone — but this device still
  /// holds the *closed* membership row that says why, and that is what
  /// `SyncController._weHaveLeft` reads.
  ///
  /// **The one [SyncUnavailable] the status surface still renders.** The
  /// others are silence because there is genuinely nothing to say; this one
  /// is the answer to a question somebody has just asked by leaving, and no
  /// status icon at all is exactly the "a control that works and says
  /// nothing" half-control this task exists to close.
  leftProject,
}

/// The three states task 10.12 requires be visually distinguishable — all of
/// which look identical from `lastError` alone otherwise.
enum SyncHealth {
  /// Synced recently, or has never had a reason not to be. The default.
  healthy,

  /// No connectivity, or a single transient failure. **The normal field
  /// state** — a dead zone, not a problem — and the one case worth a silent
  /// retry rather than a user's attention.
  offline,

  /// The connection works and the server has **refused** at least one record,
  /// which is therefore on this device only (task 10.28 / finding D-3).
  ///
  /// The third of task 10.12's three states, and the one that was missing:
  /// offline is "not yet", broken is "nothing is getting through", and this is
  /// "everything is getting through except this, and it never will until
  /// somebody does something." Retrying does not help; it is not an error; and
  /// it is the only state here that means a primary record exists in exactly
  /// one place.
  rowsRefused,

  /// The server sent this device records it **refused to store** — so they
  /// exist on the server, and on whoever's device wrote them, and not here
  /// (found 2026-08-27, task 11.41's second round).
  ///
  /// The mirror image of [rowsRefused], and it had no state at all: the pull
  /// discarded the merge report, counted a dropped row as pulled, and reported
  /// "Synced." A teammate's bearing could go missing between the wire and the
  /// database with nothing said anywhere.
  ///
  /// **Nothing is lost** — the record is unharmed wherever it was written, and
  /// this is the one state here where that is true of a record this device
  /// cannot see. The usual cause is two devices on different builds, so the
  /// instruction is "update the app", not "something is wrong."
  recordsMissing,

  /// **This device will not use the server address it has saved** (task
  /// 11.104), so nothing has been attempted and nothing will be.
  ///
  /// Ranked with [membershipEnded] above every other state, and kept a long
  /// way from [offline] on purpose. Task 11.66 measured a release build
  /// refusing a plain-`http://` LAN address and reporting *"Offline — last
  /// synced 5 min ago"*: not a vaguer description of the same thing, but a
  /// different problem, with a remedy — go somewhere with signal — that can
  /// never work here. The network was fine throughout, and the app said it was
  /// the network.
  serverAddressRefused,

  /// **This device reached the server and refused its security certificate**
  /// (task 11.113) — self-signed, expired, or issued for a different address.
  ///
  /// Ranked beside [serverAddressRefused] and kept the same long way from
  /// [offline], for the reason that state was created: *a configuration fault
  /// is not a transient one.* Michael pointed an iPhone at a server with a
  /// self-signed certificate — Safari, on the same phone, said "this
  /// connection is not private" — and the sync bar said **"Offline"**, which
  /// sends a field tech to check a network that is working perfectly.
  ///
  /// **Unlike [broken], one occurrence is enough.** A rejected certificate is
  /// deterministic: the second attempt fails identically, so waiting for three
  /// would only mean saying something false twice first.
  certificateRejected,

  /// A version mismatch this device or the server needs updating to fix.
  /// Retrying will not help until that happens. **Also every other refusal
  /// that carries its own sentence** (task 11.303's finding): a rate limit,
  /// a destroyed project, a route the server does not offer (task 11.307).
  /// Each has its own headline; the name here is the original member's.
  versionRefused,

  /// The server holds no valid session for this device — expired, or revoked
  /// (task 10.14 / §4.3). Signing in again is the fix, and it is a different
  /// instruction from every other state here.
  sessionEnded,

  /// **The signed-in person is no longer a member of this project**
  /// (task 11.54). Not a fault, and nothing here needs fixing: they left, or
  /// an owner removed them, and this device has stopped syncing the project
  /// as a result.
  ///
  /// Ranked above every other state below, including [broken]: a departed
  /// member's device will keep producing refusals for as long as it keeps
  /// asking, and every one of them has this same, complete explanation. This
  /// is the state whose absence made the app tell somebody to contact their
  /// server administrator about a project they had chosen to leave.
  membershipEnded,

  /// **The server refused this project, and this device's own records do not
  /// say the person left it** (task 11.54) — it still holds an open
  /// membership for them, or (task 11.305) no record of them on it at all.
  ///
  /// Kept apart from [broken] because the likeliest cause is specific and
  /// worth naming — an owner removed this person and the news has not arrived,
  /// because the pull that would carry it is the request being refused. The
  /// copy names both that and "something is wrong with the server", because
  /// this device genuinely cannot tell which, and picking one would be a
  /// guess presented as an answer.
  accessRefused,

  /// Repeated failures, or a terminal refusal with no actionable message —
  /// the one state actually worth alarming someone over.
  broken,

  /// **Nothing has failed — this project simply has not synced successfully
  /// in over 24 hours, and records exist on this device only** (task 11.114).
  ///
  /// Reachable only from [healthy] or [offline]: every other state already
  /// has something more specific and more urgent to say, and letting
  /// staleness override one of those would be the same silence this state
  /// exists to remove, pointed the other way. **This is the one half of the
  /// dismissable pair** — see [SyncStatus.health] for the rule that a
  /// dismissal can only ever produce [staleRecordsPending] or
  /// [staleNothingPending] reverting to [healthy]/[offline], never any other
  /// value in this enum.
  staleRecordsPending,

  /// The mirror of [staleRecordsPending] for a device with nothing of its own
  /// waiting — the sync that stopped is only keeping this device from
  /// hearing about *other* people's records, not from delivering its own
  /// (task 11.114).
  staleNothingPending,
}

/// Glanceable sync state.
///
/// **"Never synced" and "sync is broken" are deliberately different states.**
/// No connectivity is the *normal* field condition, not an error, and a UI that
/// reports it as a failure trains people to ignore the indicator. Task 10.12
/// owns the presentation; this is the state it renders.
class SyncStatus {
  const SyncStatus({
    required this.schedule,
    this.unavailable,
    this.running = false,
    this.progress,
    this.lastReport,
    this.lastError,
    this.lastErrorMessage,
    this.lastErrorHeadline,
    this.lastSuccessAt,
    this.pendingCount = 0,
    this.heldCount = 0,
    this.droppedOnArrivalCount = 0,
    this.hasUnrecognizedFields = false,
    this.lastFailure,
    this.remembered,
    this.staleDismissedAt,
    this.serverDatabaseChangedAt,
  });

  final SyncSchedule schedule;
  final SyncUnavailable? unavailable;
  final bool running;
  final SyncProgress? progress;
  final SyncRunReport? lastReport;

  /// A short, non-technical reason. Never carries server-supplied text.
  final String? lastError;

  /// Client-authored, actionable sentence for the refusals that have a
  /// remedy — a version skew or a device past the tombstone retention window
  /// (task 10.11). Null for ordinary failures, where [lastError] plus the
  /// schedule is all there is to say and inventing prose would overstate it.
  ///
  /// Still never server-supplied text: this is written client-side and merely
  /// *selected* by a refusal code from a fixed vocabulary.
  final String? lastErrorMessage;

  /// **The headline for [lastErrorMessage], declared alongside it** (task
  /// 11.303) — `SyncTransportException.userHeadline`, written by the same
  /// code that chose the sentence, so the two can never name different
  /// causes. Null for every failure that has no remedy sentence, and for a
  /// remembered failure this session has not retried — [health] falls back to
  /// [syncRefusalHeadline] with [RememberedSyncFailure.stoppedReason] there.
  final String? lastErrorHeadline;

  final DateTime? lastSuccessAt;

  /// Local rows not yet offered to the server — task 10.12's "count of
  /// records pending upload." Refreshed on build and after every attempt;
  /// see `SyncController._refreshCounts`. Excludes [heldCount].
  final int pendingCount;

  /// Records the server has **refused**, which therefore exist on this device
  /// only (task 10.28 / finding D-3).
  ///
  /// Read from `SyncHeldRowStore`, not from [lastReport], so it survives a
  /// restart and a later round that refused nothing new. **This is the number
  /// that forbids reporting a clean sync** — before it existed, a refused row
  /// was discarded, the watermark advanced past it, and the app said "Synced."
  final int heldCount;

  /// How many records this device is missing *in total* because it refused
  /// to store them when the server sent them.
  ///
  /// Read from `SyncDroppedRowStore`, not from [lastReport], so it survives a
  /// restart and a later round that dropped nothing new — task 11.44's
  /// answer to the gap task 10.28 left on this side: until then, a dropped
  /// row left nothing behind, so this field reset the moment the app was
  /// reopened or the next attempt failed for an unrelated reason, and the
  /// only record of "did I get everything?" was whatever was still on
  /// screen. See [SyncRunReport.droppedOnArrival] for this round's tally, and
  /// `SyncEngine.droppedRowCount` for where this number comes from.
  final int droppedOnArrivalCount;

  /// Whether this device is holding column values from a newer schema minor
  /// it cannot display (task 10.18's compatibility floor doing its job). Not
  /// a refusal or an error — sync is working — but a materially different
  /// message from either: some fields other devices filled in are being kept
  /// safe, not shown, on this build.
  final bool hasUnrecognizedFields;

  /// **Why the last attempt failed, as one classified answer** (task 11.54).
  ///
  /// This replaced a `bool sessionEnded` flag, and the replacement is the
  /// point rather than a tidy-up. That flag was the third parallel channel
  /// describing one failure — alongside [lastError] and [lastErrorMessage] —
  /// and [health] had to *reconstruct* a cause by asking each in turn. A cause
  /// nobody had given a channel to could not be reconstructed, so it fell
  /// through to [SyncHealth.broken]: which is precisely how somebody who had
  /// just left a project was told to contact their server administrator.
  ///
  /// Null when the last attempt succeeded, or when none has been made.
  final SyncFailureCause? lastFailure;

  /// **The failure written down on this device, which survives a restart and
  /// a rebuild of this provider** (task 11.116).
  ///
  /// [lastFailure] is what *this session* was told when it tried; this is what
  /// the device knows regardless of whether it has tried since. The pair is
  /// the whole of the tense this task added:
  ///
  /// - both null — nothing has failed;
  /// - both set — a round ran and failed, and this is current;
  /// - **this one set and [lastFailure] null — the app came back holding a
  ///   failure it has not re-tested**, which is [failureIsRemembered].
  ///
  /// Kept written down after every live failure too, so the two can never come
  /// to disagree about the count behind [looksBroken].
  final RememberedSyncFailure? remembered;

  /// Whether the failure being reported is one this app has **not tried since
  /// being told about** (task 11.116).
  ///
  /// True after a restart or a provider rebuild that restored a failure, and
  /// false again the moment a round runs, in either direction. The surfaces
  /// render the same state, colour and icon either way and change only the
  /// words — see `RememberedSyncFailure` for why the severity is not softened.
  bool get failureIsRemembered => lastFailure == null && remembered != null;

  /// **When this device last dismissed the stale-sync warning** (task
  /// 11.114), device-wide rather than per project — see
  /// `SyncStateStore.staleDismissedAt`.
  ///
  /// Null means never dismissed. A non-null value does not necessarily mean
  /// the dismissal is still in effect — [health] checks it against the next
  /// 04:00 local time after it, and treats an expired one exactly like null.
  final DateTime? staleDismissedAt;

  /// **When this device last found the server's database had been replaced
  /// under this project** — restored from a backup, or rebuilt — and started
  /// the project's sync over (task 11.58). Null if it never has.
  ///
  /// Not a failure and not a [health] input: the round that found it went on
  /// to succeed. It is a fact the status screen states, because a person
  /// whose "waiting to sync" count has just jumped, or whose phone has just
  /// fetched the whole project again, deserves to be told why. See
  /// `SyncStateStore.databaseChangedAt`.
  final DateTime? serverDatabaseChangedAt;

  /// A sentinel distinguishing "not passed" from "explicitly set to null" in
  /// [copyWith]'s nullable parameters — `??` alone cannot tell the two apart,
  /// and both are real: most callers mean "leave this alone," but a round
  /// that succeeds means "clear the remembered failure," which is not the
  /// same thing.
  static const _unset = Object();

  /// A copy of this status with the named fields replaced and every other
  /// field — including one added after this method was written — carried
  /// over unchanged.
  ///
  /// **This is task 11.96/11.117's fix.** Before it, every place that rebuilt
  /// a [SyncStatus] from an existing one did so by listing all fifteen fields
  /// by hand, and nothing failed if one was left out: a dropped field
  /// silently became its constructor default, which for the failure fields
  /// means *healthy* — the hardest signal in the app to notice being wrong.
  /// It bit twice (task 11.116): once on every restart, once on tapping the
  /// frequency control. A caller of this method cannot drop a field by
  /// omission; the only way to change one is to name it.
  SyncStatus copyWith({
    SyncSchedule? schedule,
    Object? unavailable = _unset,
    bool? running,
    Object? progress = _unset,
    Object? lastReport = _unset,
    Object? lastError = _unset,
    Object? lastErrorMessage = _unset,
    Object? lastErrorHeadline = _unset,
    Object? lastSuccessAt = _unset,
    int? pendingCount,
    int? heldCount,
    int? droppedOnArrivalCount,
    bool? hasUnrecognizedFields,
    Object? lastFailure = _unset,
    Object? remembered = _unset,
    Object? staleDismissedAt = _unset,
    Object? serverDatabaseChangedAt = _unset,
  }) => SyncStatus(
    schedule: schedule ?? this.schedule,
    unavailable: identical(unavailable, _unset)
        ? this.unavailable
        : unavailable as SyncUnavailable?,
    running: running ?? this.running,
    progress: identical(progress, _unset)
        ? this.progress
        : progress as SyncProgress?,
    lastReport: identical(lastReport, _unset)
        ? this.lastReport
        : lastReport as SyncRunReport?,
    lastError: identical(lastError, _unset)
        ? this.lastError
        : lastError as String?,
    lastErrorMessage: identical(lastErrorMessage, _unset)
        ? this.lastErrorMessage
        : lastErrorMessage as String?,
    lastErrorHeadline: identical(lastErrorHeadline, _unset)
        ? this.lastErrorHeadline
        : lastErrorHeadline as String?,
    lastSuccessAt: identical(lastSuccessAt, _unset)
        ? this.lastSuccessAt
        : lastSuccessAt as DateTime?,
    pendingCount: pendingCount ?? this.pendingCount,
    heldCount: heldCount ?? this.heldCount,
    droppedOnArrivalCount: droppedOnArrivalCount ?? this.droppedOnArrivalCount,
    hasUnrecognizedFields: hasUnrecognizedFields ?? this.hasUnrecognizedFields,
    lastFailure: identical(lastFailure, _unset)
        ? this.lastFailure
        : lastFailure as SyncFailureCause?,
    remembered: identical(remembered, _unset)
        ? this.remembered
        : remembered as RememberedSyncFailure?,
    staleDismissedAt: identical(staleDismissedAt, _unset)
        ? this.staleDismissedAt
        : staleDismissedAt as DateTime?,
    serverDatabaseChangedAt: identical(serverDatabaseChangedAt, _unset)
        ? this.serverDatabaseChangedAt
        : serverDatabaseChangedAt as DateTime?,
  );

  bool get isAvailable => unavailable == null;

  /// Whether the sync surface should render at all.
  ///
  /// **Not the same question as [isAvailable].** Every other reason sync is
  /// unavailable is a reason there is nothing to say — no server, no project,
  /// a project never published. [SyncUnavailable.leftProject] is the one that
  /// is itself the answer to a question the person has just asked, so the
  /// status icon and the status card render it rather than vanishing. A
  /// control that works and says nothing is half a control (2026-08-27).
  ///
  /// **This is also task 10.2's invariant, and it is the whole of it.** A
  /// person who never configured a server sees no sync surface at all — not a
  /// green tick, which would be claiming a sync succeeded when nothing ever
  /// tried. `SyncStatusIcon`, `SyncStatusBadge` and `SyncStatusDot` all gate
  /// on this, and
  /// `sync_status_icon_test.dart` watches the case.
  bool get isWorthShowing =>
      isAvailable ||
      unavailable == SyncUnavailable.leftProject ||
      // Same reason, one task later: a refused address is the answer to the
      // question, and vanishing would leave the person with a silent bar and a
      // server screen still reading "Server configured" (task 11.104).
      unavailable == SyncUnavailable.serverAddressRefused;

  /// True when something is genuinely wrong, as opposed to merely offline.
  ///
  /// One failed attempt is not "broken" — that is a dead zone, which is
  /// expected. Repeated failures, or a terminal one, are.
  /// **Counted from [remembered] when there is one**, because that is the
  /// count that survives a restart (task 11.116). Before this record existed
  /// the threshold below could only ever be reached inside one uninterrupted
  /// session, so a device that had been refused every hour for a week reported
  /// "Offline" — a single transient blip — for as long as it kept being
  /// relaunched.
  /// **The refusal is the server saying the project was deleted** (task
  /// 11.319), one of the five that share [SyncHealth.versionRefused].
  ///
  /// Read from the same place [health] reads its cause: this session's own
  /// [lastError] when it has attempted something, otherwise the code the
  /// durable record kept across a restart. The code is a fixed-vocabulary
  /// string, never server text, so comparing it is safe.
  ///
  /// It exists because the other four codes in that state are faults and
  /// this one is not: the sentence written for it says nothing on this
  /// device is wrong, and it is drawn quiet, like [SyncHealth.membershipEnded].
  bool get refusedBecauseProjectDestroyed =>
      (lastFailure != null ? lastError : remembered?.stoppedReason) ==
      syncRefusalProjectDestroyed;

  bool get looksBroken {
    final durable = remembered;
    if (durable != null) return durable.looksBroken;
    return schedule.stoppedReason != null ||
        schedule.consecutiveFailures >= brokenAfterFailures;
  }

  /// Which of [SyncHealth]'s states best describes right now.
  ///
  /// A version refusal is checked ahead of "broken" deliberately: three
  /// consecutive attempts against an incompatible server *are* three
  /// consecutive failures, but the fix is "update the app," not "something
  /// is generically wrong" — conflating the two sends a field tech chasing a
  /// problem that already has a known, specific answer.
  /// A session end is checked first for the same reason: repeated attempts
  /// against a revoked session are repeated failures, but "sign in again" is
  /// the answer, and reporting generic breakage would leave a removed member
  /// filing a bug report instead.
  ///
  /// A refused row outranks [SyncHealth.offline] and cannot be reached from
  /// [SyncHealth.healthy] at all: being offline is transient and expected,
  /// while a held record is a permanent condition that needs a human decision,
  /// and "Synced" while holding one is the lie this state exists to prevent.
  /// It ranks *below* broken because a device getting nothing through has a
  /// more urgent message, and the held record is still safely on the device
  /// and still reported on the status screen either way.
  SyncHealth get health {
    // Ranked above everything, including a held record: once somebody is off a
    // project, every other thing this screen could say about it is a
    // consequence of that one fact, and none of them has a remedy.
    if (unavailable == SyncUnavailable.leftProject) {
      return SyncHealth.membershipEnded;
    }
    // Ranked alongside it, and for the mirror-image reason: nothing here has
    // been attempted, so every other state below describes a round that never
    // happened (task 11.104).
    if (unavailable == SyncUnavailable.serverAddressRefused) {
      return SyncHealth.serverAddressRefused;
    }
    // **The remembered cause stands in when this session has not tried** (task
    // 11.116). The state, and therefore the colour and the icon, are the same
    // either way; only the words the surfaces choose differ, keyed on
    // [failureIsRemembered].
    final failure = lastFailure ?? remembered?.cause;
    if (failure != null) {
      // **An exhaustive switch, and that is the guard.** A cause added to
      // [SyncFailureCause] without a decision here does not quietly become
      // "broken" — it fails to compile, and so does every surface that
      // switches on the [SyncHealth] value it maps to. That is what makes this
      // a classification rather than the hand-kept ordering it replaced.
      final fromFailure = switch (failure) {
        SyncFailureCause.serverAddressRefused =>
          SyncHealth.serverAddressRefused,
        // **Not gated on `looksBroken`**, unlike the three below. Those are
        // gated because one of them can be a dead zone; a certificate this
        // device will not trust is the same on every attempt, and the only
        // thing three tries buys is two rounds of telling somebody they are
        // offline first (task 11.113).
        SyncFailureCause.certificateRejected => SyncHealth.certificateRejected,
        SyncFailureCause.membershipEnded => SyncHealth.membershipEnded,
        SyncFailureCause.sessionEnded => SyncHealth.sessionEnded,
        SyncFailureCause.refusedWithRemedy => SyncHealth.versionRefused,
        SyncFailureCause.accessRefused => SyncHealth.accessRefused,
        // **Not gated on `looksBroken`** (task 11.58), for the certificate's
        // reason: a single restore never reaches this cause — the engine
        // starts over and the round succeeds — so the first time it is seen,
        // two databases are already answering at one address, and that is
        // the same on every attempt. The sentence is
        // `SyncTransportException.userMessage`, which the status screen
        // prefers over the generic broken advice.
        SyncFailureCause.serverDatabaseChanged => SyncHealth.broken,
        // The three that are only worth alarming somebody over once they have
        // *repeated*. One failed attempt is a dead zone, which is the normal
        // field condition and not a fault — the distinction task 10.12 made,
        // and which a classification has to preserve rather than flatten.
        // **A reached deadline sits with them, not on its own** (task 11.61).
        // One timed-out attempt is a loaded server or a link that stalled,
        // which is the same "not yet worth anybody's attention" as a dead zone;
        // and it deliberately gains no state of its own, because the argument
        // for bounding requests was that the honest states already written
        // become reachable, not that new ones are needed.
        SyncFailureCause.timedOut ||
        SyncFailureCause.unreachable ||
        SyncFailureCause.serverRejected ||
        SyncFailureCause.deviceFault => looksBroken ? SyncHealth.broken : null,
      };
      if (fromFailure != null) return fromFailure;
    }
    if (heldCount > 0) return SyncHealth.rowsRefused;
    // Ranked below a refused row and above offline, for the reason each of
    // those is where it is: a record only this device holds is more urgent
    // than one this device is merely missing (the missing one is safe on the
    // server), and both outrank "no signal", which is expected.
    if (droppedOnArrivalCount > 0) return SyncHealth.recordsMissing;
    final base = failure != null ? SyncHealth.offline : SyncHealth.healthy;
    // **Staleness only ever replaces one of these two "calm" answers** (task
    // 11.114). Every other branch above has already returned by this point,
    // so a held record, a rejected certificate, a refused address, an ended
    // membership and the rest can never reach here — which is the whole of
    // the acceptance criterion that the dismiss below must not be able to
    // silence any of them: it can only ever turn *this* return value into
    // [SyncHealth.healthy] or [SyncHealth.offline], never into one of theirs.
    final success = lastSuccessAt;
    if (success == null) return base;
    final now = DateTime.now().toUtc();
    if (now.difference(success) < staleThreshold) return base;
    if (_staleDismissalActive(now)) return base;
    return pendingCount > 0
        ? SyncHealth.staleRecordsPending
        : SyncHealth.staleNothingPending;
  }

  /// **24 hours, flat, regardless of the frequency setting** (Michael's
  /// decision, 2026-09-01) — the warning is about *where the data is*, not
  /// about whether the schedule is behaving, so it must not bend to a setting
  /// that could be argued into silence.
  static const staleThreshold = Duration(hours: 24);

  /// Whether a past dismissal of the stale warning is still in effect at
  /// [now].
  ///
  /// **Re-arms at the next 04:00 local time after the dismissal** (Michael's
  /// decision, 2026-09-01, over the 08:00 he first proposed): "likely before
  /// fieldwork begins in most situations," ahead of the workday rather than
  /// into the middle of it. **No minimum-interval floor**, deliberately — the
  /// only way to get a same-day reappearance is dismissing between midnight
  /// and 04:00, which costs one extra tap, once, rather than a warning
  /// returning mid-transect the way an 08:00 re-arm would.
  bool _staleDismissalActive(DateTime now) {
    final dismissedAt = staleDismissedAt;
    if (dismissedAt == null) return false;
    final local = dismissedAt.toLocal();
    var rearm = DateTime(local.year, local.month, local.day, 4);
    if (!rearm.isAfter(local)) rearm = rearm.add(const Duration(days: 1));
    return now.isBefore(rearm);
  }
}

/// Runs sync and holds its status.
///
/// **Nothing that reads local data waits on this.** Every screen reads SQLite
/// through the existing repositories; this provider is watched only by the
/// status UI and the manual button. A sync in flight, failing, or permanently
/// impossible changes nothing about whether the app works.
@Riverpod(keepAlive: true)
class SyncController extends _$SyncController {
  @override
  Future<SyncStatus> build() async {
    // **Read before anything can return.** The frequency is the user's
    // setting and the last attempt is what the interval is measured from;
    // both are device-wide, both are durable, and a rebuild that quietly
    // restored the defaults would be a setting that does not stick (task
    // 11.59). Every branch below carries this same schedule.
    final schedule = await _persistedSchedule();
    final config = await ref.watch(serverConfigProvider.future);
    if (!config.isConfigured) {
      return SyncStatus(
        schedule: schedule,
        unavailable: SyncUnavailable.notConfigured,
      );
    }
    // **Before the session check, and before anything is attempted** (task
    // 11.104). An address this build refuses is a fact about this device that
    // is settled without a network, so it is answered here rather than waiting
    // for a round to fail and be classified — which is what produced "Offline"
    // on a working network. It is also checked ahead of `signedOut`, because
    // signing in is the very thing a refused address prevents: reporting
    // "signed out" would name a symptom and hide its cause.
    //
    // Read as a value. `serverUrlRefusalProvider` never throws, which is the
    // whole reason it exists — see `InvalidServerUrl`'s doc for what happens
    // to an exception raised inside a provider on this project.
    final refusal = await ref.watch(serverUrlRefusalProvider.future);
    if (refusal != null) {
      return SyncStatus(
        schedule: schedule,
        unavailable: SyncUnavailable.serverAddressRefused,
        // Client-authored and selected by a fault this device decided, never
        // server-supplied text (§4.13) — the same rule every other value that
        // lands in this field obeys.
        lastErrorMessage: refusal.message,
      );
    }
    final session = await ref.watch(currentSessionProvider.future);
    if (session == null) {
      return SyncStatus(
        schedule: schedule,
        unavailable: SyncUnavailable.signedOut,
      );
    }
    final projectId = await ref.watch(activeProjectIdProvider.future);
    if (projectId == null) {
      return SyncStatus(
        schedule: schedule,
        unavailable: SyncUnavailable.noProject,
      );
    }
    final store = ref.read(syncStateStoreProvider);
    if (!await store.isProjectLinked(projectId)) {
      // **Two different silences, and one of them is not silence.** A project
      // that was never published has nothing to report. A project this device
      // stopped syncing *because the person left it* has exactly one thing to
      // report, and reporting nothing is how a departed member was left with a
      // red "sync isn't working" bar and no way to find out why (task 11.54).
      // Derived from the membership rows rather than remembered in a flag,
      // because unlinking erases the flags and the closed stint is the durable
      // record of what happened.
      return SyncStatus(
        schedule: schedule,
        unavailable: await _weHaveLeft(projectId, session.userId)
            ? SyncUnavailable.leftProject
            : SyncUnavailable.notLinked,
      );
    }
    final counts = await _refreshCounts(projectId);
    return SyncStatus(
      schedule: schedule,
      lastSuccessAt: await store.lastSuccessAt(projectId),
      pendingCount: counts.pending,
      heldCount: counts.held,
      droppedOnArrivalCount: counts.dropped,
      hasUnrecognizedFields: counts.hasUnrecognizedFields,
      // **The whole of task 11.116 on this line.** Every other field here was
      // already read back from somewhere durable; the failure was not, so a
      // rebuild of this provider — which does not even need the app to close —
      // reported a week-old refusal as a calm "Synced" bar. Read as a fact
      // this device wrote down, and rendered with its tense: see
      // [SyncStatus.failureIsRemembered].
      remembered: await store.rememberedFailure(projectId),
      staleDismissedAt: await store.staleDismissedAt(),
      serverDatabaseChangedAt: await store.databaseChangedAt(projectId),
    );
  }

  /// The schedule as this device last left it (task 11.59).
  ///
  /// Two reads of `SharedPreferences`, on a path that already does several.
  /// **Failing here must not fail the whole status**, so an unreadable store
  /// yields the shipped default — which the sync screen then displays, so the
  /// fallback is something the user can see rather than something that happens
  /// to them.
  Future<SyncSchedule> _persistedSchedule() async {
    try {
      final store = ref.read(syncStateStoreProvider);
      return SyncSchedule(
        frequency: await store.frequency(),
        lastAttemptAt: await store.lastAttemptAt(),
      );
    } catch (_) {
      return const SyncSchedule();
    }
  }

  /// Recomputes [SyncStatus.pendingCount], [SyncStatus.heldCount],
  /// [SyncStatus.droppedOnArrivalCount] and [SyncStatus.hasUnrecognizedFields]
  /// — cheap local queries, but real ones, run on build and after every
  /// attempt rather than maintained incrementally.
  ///
  /// [SyncStatus.pendingCount] is the exact set of rows the next push will
  /// offer, because it is computed by the same predicate the push selects with
  /// (task 10.33's `_pendingClause`) rather than by a second query that has to
  /// be kept in step by hand.
  ///
  /// [SyncStatus.heldCount] and [SyncStatus.droppedOnArrivalCount] are read
  /// here rather than taken from the run report on purpose: a refusal — in
  /// either direction — from a previous session, or from a `publish` this
  /// controller never saw, must still be counted the moment the app opens
  /// (task 10.28 for the outbound count, task 11.44 for the inbound one).
  /// [SyncStatus.pendingCount] needs the signed-in user, because since task
  /// 11.43 the push's own predicate does: a record the server keeps for itself
  /// about somebody else is not this device's to offer, so it is not pending.
  /// Every call site reaches here past a session check, so a missing session is
  /// a programming error rather than a state to render — and reporting a count
  /// computed for nobody would restate exactly the phantom "records waiting"
  /// this task removed.
  Future<({int pending, int held, int dropped, bool hasUnrecognizedFields})>
  _refreshCounts(String projectId) async {
    final db = await ref.read(appDatabaseProvider.future);
    final session = await ref.read(currentSessionProvider.future);
    if (session == null) {
      throw StateError(
        '_refreshCounts needs a signed-in session to count pending rows; '
        'every caller is meant to have checked for one already.',
      );
    }
    final pending = await SyncEngine.pendingRowCount(
      db.raw,
      projectId,
      session.userId,
    );
    final held = await SyncEngine.heldRowCount(db.raw, projectId);
    final dropped = await SyncEngine.droppedRowCount(db.raw, projectId);
    final hasUnrecognizedFields = await SyncEngine.hasHeldUnknownColumns(
      db.raw,
      projectId,
    );
    return (
      pending: pending,
      held: held,
      dropped: dropped,
      hasUnrecognizedFields: hasUnrecognizedFields,
    );
  }

  /// The manual "sync now" trigger.
  ///
  /// **Ignores the schedule entirely — no interval, no backoff, no automatic
  /// setting.** This is the trailhead case: someone with signal who wants their
  /// data off the device before a long drive. Making them wait out a backoff, or
  /// discovering that automatic sync is switched off, would be exactly the
  /// wrong answer at the only moment it really matters.
  Future<void> syncNow() async {
    // **The stranded project rows first, then the open project** (task
    // 11.289). Michael's measurement was exactly this button: delete a
    // published project, pick another, tap "Sync now", and the deletion never
    // left the phone because `_run` is scoped to the open project. The
    // person tapping this wants everything delivered, so the one table that
    // has no other route out goes here too. Skipped while a round is already
    // in flight — two engine rounds at once is what `app.dart` sequences its
    // hooks to avoid — and never a reason for the open project's round not to
    // run: the foreground hook is the durable path for these rows, this is
    // the courtesy.
    if (!(state.value?.running ?? false)) {
      try {
        await deliverPendingProjectChanges();
      } catch (_) {
        // The open project's round below still runs and still reports.
      }
      // Task 11.302: and anything the server restored that this device
      // still holds as deleted. Never throws.
      await bringBackRestoredProjects();
    }
    await _run(manual: true);
  }

  /// An opportunistic attempt, e.g. on foreground. Respects the schedule.
  Future<void> syncIfDue() => _run(manual: false);

  Future<void> _run({required bool manual}) async {
    // **Wait for the first build rather than doing nothing.** Both triggers
    // that matter arrive before this provider has ever produced a value — the
    // foreground hook on cold launch, and pull-to-refresh on a screen that has
    // only just been opened — and reading `state.value` while it is still
    // loading returned null, which this method silently treated as "nothing to
    // do". A sync that no-ops because it was asked early is indistinguishable
    // from one that never had a caller, which is the defect task 11.59 exists
    // to fix.
    if (!state.hasValue) {
      try {
        await future;
      } catch (_) {
        // A status that cannot even be built has nothing to sync, and the
        // screen already reports the error. Never throw out of a trigger the
        // app lifecycle fires.
        return;
      }
    }
    final current = state.value;
    if (current == null || !current.isAvailable || current.running) return;

    final now = DateTime.now().toUtc();
    if (!manual && !current.schedule.shouldAttemptAt(now)) return;

    final projectId = await ref.read(activeProjectIdProvider.future);
    if (projectId == null) return;

    // **Durable, and written for a manual round too** — the interval is "how
    // long since this app last talked to the server", so a "Sync now" a minute
    // ago is a reason for the next foreground to leave it alone. Recorded
    // before the attempt rather than after, so a round that hangs or is killed
    // mid-flight still counts as having been tried; the alternative is a
    // device that retries on every foreground for as long as the server keeps
    // it waiting.
    try {
      await ref.read(syncStateStoreProvider).setLastAttemptAt(now);
    } catch (_) {
      // Bookkeeping. Losing it costs one extra attempt, which is not a reason
      // to skip the sync the user is waiting for.
    }

    // `remembered` (and every other field not named below) is carried
    // through by `copyWith`, not dropped: a round that hangs, or a rebuild
    // while one is in flight, must not land back on a calm bar (task 11.116).
    // The session-level failure fields are cleared explicitly — a fresh
    // attempt reports nothing about itself yet, even though the durable
    // `remembered` record survives it — and are replaced below by whatever
    // this round decides.
    state = AsyncData(
      current.copyWith(
        schedule: current.schedule.recordAttempt(now),
        running: true,
        progress: null,
        lastError: null,
        lastErrorMessage: null,
        lastErrorHeadline: null,
        lastFailure: null,
      ),
    );

    try {
      final engine = await _engine();
      final report = await engine.run(
        projectId,
        onProgress: (progress) {
          final running = state.value;
          if (running == null) return;
          state = AsyncData(running.copyWith(progress: progress));
        },
      );
      // **A round can succeed and still be the round that ended the stint**
      // (task 11.60).
      //
      // Since the server tells a removed member so (§4.27), the news arrives
      // *in a `200`*: a device with nothing pending never makes a push to be
      // refused, so the pull carries the closed membership row and the round
      // completes normally. Reporting "Synced" there would be the same defect
      // task 11.54 fixed from the other direction — a truthful-looking status
      // for a project this person is no longer on.
      //
      // Asked from the database, which the round has just written, and using
      // the same question the failure path and [build] both ask, so all three
      // cannot come to disagree about what "off the project" means.
      if (await _signedInPersonHasLeft(projectId)) {
        await _unlinkIfWeAlreadyLeft(projectId);
        state = AsyncData(_leftProjectStatus(current.schedule));
        return;
      }
      final counts = await _refreshCounts(projectId);
      // A push can lose last-write-wins even on a round that otherwise
      // succeeds — the conflict list task 10.12 builds must reflect it right
      // away, not on the next unrelated rebuild.
      if (report.lostToServer.isNotEmpty) {
        ref.invalidate(syncConflictsProvider(projectId));
      }
      // Same immediacy for the held list: a row the server just refused, or
      // one it has just accepted after being held, changes what the status
      // screen must show about *this* round (task 10.28).
      if (report.refused.isNotEmpty || counts.held != current.heldCount) {
        ref.invalidate(syncHeldRowsProvider(projectId));
      }
      // The inbound counterpart, and it needs the same immediacy for the same
      // reason: a row this device just refused, or one that finally arrived
      // and resolved an earlier drop, must not wait for an unrelated rebuild
      // (task 11.44).
      if (report.droppedOnArrival.isNotEmpty ||
          counts.dropped != current.droppedOnArrivalCount) {
        ref.invalidate(syncDroppedRowsProvider(projectId));
      }
      // **And the screens that show the data itself** — but not from here.
      //
      // Found on real hardware on 2026-08-27, immediately after task 11.41's
      // fix: a Mac synced, reported success, and the teammate's bearings were
      // not on the map. They were in SQLite. Nothing told the map. The first
      // fix was a `recordingsRevisionProvider` bump on this line; task 11.45
      // moved it into `ProjectMerger`, which every pulled page goes through,
      // so that a *new* caller of the merger cannot repeat the omission. See
      // `DataArrival`.
      // Read back rather than taken from [report] (task 11.58), so a change
      // found by a round that then failed — which writes the date and throws
      // — is not lost to the next round that succeeds.
      final databaseChangedAt = await _databaseChangedAt(projectId);
      state = AsyncData(
        current.copyWith(
          schedule: current.schedule.recordSuccess(now),
          lastReport: report,
          serverDatabaseChangedAt: databaseChangedAt,
          // **Forgotten, on disk and here.** A round that got through is the
          // one piece of evidence that outranks the written-down failure, and
          // leaving the record behind would be the mirror defect: a bar
          // reporting a refusal the server has stopped making (task 11.116).
          remembered: null,
          lastSuccessAt: now,
          pendingCount: counts.pending,
          heldCount: counts.held,
          droppedOnArrivalCount: counts.dropped,
          hasUnrecognizedFields: counts.hasUnrecognizedFields,
          // The session-level failure fields, cleared: a status carrying a
          // stale refusal alongside a report that just succeeded is the same
          // defect as forgetting a failure that is still current, in the
          // opposite direction.
          lastError: null,
          lastErrorMessage: null,
          lastErrorHeadline: null,
          lastFailure: null,
        ),
      );
    } on SyncTransportException catch (error) {
      // Non-destructive: a status, never a modal wall. Nothing local changed —
      // the engine's failure path leaves the database exactly as it was.
      final counts = await _refreshCounts(projectId);
      // **Classify first, then act on the classification.** Until task 11.54
      // the unlink below happened and the status was written from the raw
      // exception, so a device that had correctly noticed the person had left
      // still reported generic breakage: the control fired and nothing told
      // the user. One read, one answer, and both the unlink and the message
      // come out of it.
      //
      // **The same question [build] and the success path ask** — a closed
      // stint and no open one, `ProjectMembershipRepository.hasDeparted` —
      // and not, as until task 11.305, merely "no open row". That wider
      // reading was true of somebody with no row at all, so a second account
      // signing in on a device still holding the first account's linked
      // project had its first refused round read as *"you left"*: the
      // project was unlinked, the cursor erased, and the newcomer told they
      // were no longer on a project they were never on. **A `403` on a
      // project this device has no record of the person on is access
      // refused**, and the unlink below cannot fire for it.
      var cause = SyncFailureCause.serverRejected;
      try {
        cause = classifySyncFailure(
          error,
          departed: await _signedInPersonHasLeft(projectId),
        );
        if (cause == SyncFailureCause.membershipEnded) {
          await _unlinkIfWeAlreadyLeft(projectId);
        }
        // **Task 11.290.** The server said the project was destroyed. Write
        // it down so the Projects list stops counting down and says the
        // project is gone from the server, and unlink it so nothing keeps
        // offering rows to a refusal. Records untouched — see
        // `ProjectDeletionNotices.markDestroyed`.
        if (error.reason == syncRefusalProjectDestroyed) {
          await ref
              .read(projectDeletionNoticesProvider.notifier)
              .markDestroyed(projectId);
        }
      } catch (_) {
        // Tidying, not reporting. If the membership or identity read fails
        // here, the refusal still has to reach the status surface below —
        // swallowing the error is what keeps this from turning a legible
        // "access refused" into an "unexpected" one. The fallback is
        // deliberately the *least* specific cause rather than the most: an
        // unanswerable question must not be answered confidently.
        cause = classifySyncFailure(error, departed: false);
      }
      if (cause == SyncFailureCause.membershipEnded) {
        // Nor written down as one (task 11.116) — see [_forgetFailure].
        await _forgetFailure(projectId);
        // **Not a failure, so not recorded as one.** The person left this
        // project (or an owner removed them and this device already knows);
        // the refusal that told us is the expected consequence, and there is
        // nothing here to retry, back off from, or alarm anybody about. This
        // is the whole of item 1: leaving used to raise a red bar reporting
        // the very thing the person had just chosen.
        state = AsyncData(_leftProjectStatus(current.schedule));
        return;
      }
      if (error.isSessionEnded) {
        // **Drop the dead credential** (task 10.14 / §4.3). A 401 from this
        // server means specifically "no valid session for this token", so the
        // stored one is worthless — keeping it left the app holding a revoked
        // bearer token indefinitely and showing generic breakage instead of
        // "sign in again". Discarding it is also the fail-closed reading: the
        // cost is one sign-in, and signing in is how you recover either way.
        //
        // Only local state is cleared. Project data is untouched, which
        // task 10.19's no-failure-path-deletes-data invariant requires and
        // `durability_test.dart` asserts.
        await ref.read(currentSessionProvider.notifier).signOut();
      }
      final remembered = await _rememberFailure(
        projectId,
        current.remembered,
        cause,
        now,
        stoppedReason: error.isTerminal ? error.reason : null,
      );
      state = AsyncData(
        current.copyWith(
          schedule: current.schedule.recordFailure(
            now,
            terminalReason: error.isTerminal ? error.reason : null,
          ),
          lastError: error.reason,
          lastErrorMessage: error.userMessage,
          lastErrorHeadline: error.userHeadline,
          lastFailure: cause,
          remembered: remembered,
          // A round that failed may still have found a replaced database and
          // started the project over before failing (task 11.58).
          serverDatabaseChangedAt: await _databaseChangedAt(projectId),
          pendingCount: counts.pending,
          heldCount: counts.held,
          droppedOnArrivalCount: counts.dropped,
          hasUnrecognizedFields: counts.hasUnrecognizedFields,
        ),
      );
    } catch (_) {
      final remembered = await _rememberFailure(
        projectId,
        current.remembered,
        SyncFailureCause.deviceFault,
        now,
      );
      state = AsyncData(
        current.copyWith(
          schedule: current.schedule.recordFailure(now),
          lastError: 'unexpected',
          // No `error.userMessage` to carry on this path (an unclassified
          // exception, not a `SyncTransportException`) — cleared rather than
          // left holding whatever the previous attempt said.
          lastErrorMessage: null,
          lastErrorHeadline: null,
          lastFailure: SyncFailureCause.deviceFault,
          remembered: remembered,
        ),
      );
    }
  }

  /// Changes how often the app may sync on its own, durably (task 11.59).
  ///
  /// **Persisted first, then reflected in the state.** The in-memory-only
  /// version of this — the on/off switch it replaced — reverted on every
  /// restart and on every rebuild of this provider, so a person who turned
  /// automatic sync off before a metered trip was syncing again by the time
  /// they next opened the app, with the switch showing "off".
  ///
  /// It does not start a sync. Changing a setting is not asking for a round,
  /// "Sync now" sits next to the control for anybody who wants one, and a
  /// setting that quietly spends cellular data the moment it is touched is the
  /// shape of thing this task exists to remove.
  Future<void> setFrequency(SyncFrequency frequency) async {
    final current = state.value;
    if (current == null) return;
    await ref.read(syncStateStoreProvider).setFrequency(frequency);
    // **Carried, every channel, by construction** (task 11.116, and — since
    // `copyWith` — task 11.117). Changing a setting is not evidence about the
    // server, and dropping the failure here was a third route to the calm
    // bar task 11.116 exists to remove — one that needed no restart at all,
    // only a tap on the frequency control. Before `copyWith` this rebuild
    // also silently reset `running`/`progress` to false/null on every call,
    // which [dismissStaleness] below never did; `copyWith` makes the two
    // consistent by construction rather than by remembering to list the same
    // fields twice.
    state = AsyncData(
      current.copyWith(schedule: current.schedule.withFrequency(frequency)),
    );
  }

  /// Dismisses the stale-sync warning (task 11.114).
  ///
  /// **Falls back to the ordinary grey "Synced 3 days ago" line, not to
  /// silence** — [SyncStatus.health] can only ever turn back into
  /// [SyncHealth.healthy] or [SyncHealth.offline] from here, the two states
  /// staleness is reachable from in the first place, so a dismissed device
  /// looks exactly like it did before its last successful sync went stale,
  /// never like a healthy one with nothing to say. Re-arms automatically at
  /// the next 04:00 local time — see [SyncStatus.health] for that
  /// arithmetic.
  Future<void> dismissStaleness() async {
    final current = state.value;
    if (current == null) return;
    final now = DateTime.now().toUtc();
    await ref.read(syncStateStoreProvider).setStaleDismissedAt(now);
    state = AsyncData(current.copyWith(staleDismissedAt: now));
  }

  /// **The other end of leaving a project (task 11.28).**
  ///
  /// Stops syncing [projectId] when the server has refused access to it *and*
  /// this device's own records say the signed-in person left it.
  ///
  /// `MembershipController.leaveProject` unlinks the project as soon as the
  /// server confirms the departure. That covers leaving while online. **A
  /// field device is usually not online** — somebody leaves a project at the
  /// end of a track, the departure goes out on the next sync days later, and
  /// from the sync *after that* the server refuses the project. Without this,
  /// the app would keep attempting a project the person deliberately left and
  /// report a bare `403`: terminal, unexplained, and indistinguishable from a
  /// broken server.
  ///
  /// **The condition is narrow, and the second half is what keeps it narrow.**
  /// A `403` alone is not enough: it is also what a member *removed by an
  /// owner* sees, and that device's membership row still reads open because
  /// the pull that would have updated it is the very thing being refused.
  /// Unlinking on the refusal alone would make the app quietly stop syncing a
  /// project somebody may be about to be re-added to. Requiring that this
  /// device already holds a **closed** membership row for the person, and no
  /// open one, means this fires only where the device itself is the source of
  /// the news.
  ///
  /// **Since task 11.54 that condition lives in [classifySyncFailure]** rather
  /// than here: it is the same question the status surface has to answer to
  /// say *why* sync stopped, and asking it twice in two places is how the
  /// unlink and the message came to disagree. This method is now only the
  /// tidying half, and it runs exactly when the cause is
  /// [SyncFailureCause.membershipEnded].
  ///
  /// **And since task 11.305 the answer fed to the classifier is
  /// [_weHaveLeft]'s** — the same one [build] reads. Until then the failure
  /// path asked a wider question ("no open row?"), which is also true of
  /// somebody with no row at all, so this unlink ran on a project belonging
  /// to a different account the moment a second person signed in on the
  /// device. That is not the device being the source of any news; it is the
  /// device holding no news, and it now reads as access refused.
  ///
  /// Only sync bookkeeping is cleared — cursor, last-success, linked flag,
  /// remembered failure — the same `SyncStateStore.clear` the leave path makes
  /// once the server has confirmed a departure. (Sign-out makes no such call
  /// for any project; task 11.304.) **No project data is touched**, which
  /// task 10.19's "no failure path deletes data" invariant requires.
  Future<void> _unlinkIfWeAlreadyLeft(String projectId) async {
    final store = ref.read(syncStateStoreProvider);
    if (!await store.isProjectLinked(projectId)) return;
    await store.clear(projectId);
    ref.invalidate(isProjectLinkedProvider);
  }

  /// [_weHaveLeft] for the *signed-in* person, for the two paths in [_run]
  /// that have no session in hand: a round that succeeded (the departure
  /// arrived in a `200`, task 11.60) and a round the server refused (the
  /// `403` split, task 11.54).
  ///
  /// Reads the session rather than the local profile, and reads it the same
  /// way [build] does, because all three are answering the same question
  /// about the same project — and the session's user id is the identity the
  /// server actually refused. A status that disagreed with the next rebuild
  /// would flicker between "you're not on this project" and "Synced"; until
  /// task 11.305 the refused path *did* disagree with [build], by asking a
  /// different question, and its answer was the one that unlinked.
  ///
  /// A session that cannot be read answers **no**: this decides whether to
  /// replace a round's status with a departure, and an unanswerable question
  /// must not be answered confidently — the same rule [_weHaveLeft]'s own
  /// catch states. On the refused path "no" reads as access refused, which is
  /// the least specific true thing.
  Future<bool> _signedInPersonHasLeft(String projectId) async {
    try {
      final session = await ref.read(currentSessionProvider.future);
      if (session == null) return false;
      // `await`ed so a failure lands in this `catch` — returned bare, the Future
      // escapes the `try` and the "an unanswerable question answers no" promise
      // above is not kept (task 11.335).
      return await _weHaveLeft(projectId, session.userId);
    } catch (_) {
      return false;
    }
  }

  /// Whether this device's own records say [userId] is off [projectId] — a
  /// closed stint and no open one. `ProjectMembershipRepository.hasDeparted`
  /// is the derivation; this is the controller's read of it, with the one
  /// thing a controller adds — a read that fails answers "no".
  ///
  /// **Derived, not remembered.** Unlinking clears every flag in
  /// `SyncStateStore`, so after it "never published" and "you left" look
  /// identical from there. The closed membership row is the durable record of
  /// which it was, and it is the same row the members screen renders as a past
  /// member — so the two surfaces cannot disagree.
  ///
  /// Requires a closed row rather than merely the absence of an open one: a
  /// project somebody has genuinely never joined has neither, and reporting
  /// "you left this project" about one of those would be a confident wrong
  /// answer. **That sentence was true of [build] from task 11.54 and not of
  /// [_run] until task 11.305**, which is how a second account's first sync
  /// came to unlink the first account's project — see `hasDeparted`'s doc.
  Future<bool> _weHaveLeft(String projectId, String userId) async {
    try {
      final memberships = await ref.read(
        projectMembershipRepositoryProvider.future,
      );
      return await memberships.hasDeparted(projectId, userId);
    } catch (_) {
      // A read that cannot answer must not answer. Falling back to "no" means
      // the surface says nothing rather than saying something wrong.
      return false;
    }
  }

  /// The status a project the signed-in person is no longer a member of.
  ///
  /// Built in one place because two paths reach it — [build], on the next app
  /// start or provider rebuild, and [_run], the moment a refusal establishes
  /// it — and two constructions of the same state are two states that drift.
  SyncStatus _leftProjectStatus(SyncSchedule schedule) =>
      SyncStatus(schedule: schedule, unavailable: SyncUnavailable.leftProject);

  /// Forgets the written-down failure for [projectId] (task 11.116).
  ///
  /// **Called where a refusal is not a failure** — the person is no longer a
  /// member — because that state is derived from the membership rows on every
  /// build and has its own words, and a leftover record saying "access
  /// refused" would be a second, contradictory account of the same fact.
  ///
  /// Swallows its own errors. This is bookkeeping; failing to clear it must
  /// not fail the status the person is waiting for.
  Future<void> _forgetFailure(String projectId) async {
    try {
      await ref.read(syncStateStoreProvider).clearRememberedFailure(projectId);
    } catch (_) {
      // Bookkeeping only — see the note above.
    }
  }

  /// Writes down a failed round, continuing the count across restarts (task
  /// 11.116).
  ///
  /// Returns the record to put on the status, so the in-memory state and the
  /// stored one are the same value rather than two computations of it. **If
  /// the write fails the record is still returned**: the bar for this session
  /// stays correct, and the only thing lost is the memory of it after a
  /// restart — which is the old behaviour, not a worse one.
  Future<RememberedSyncFailure> _rememberFailure(
    String projectId,
    RememberedSyncFailure? previous,
    SyncFailureCause cause,
    DateTime at, {
    String? stoppedReason,
  }) async {
    final next =
        previous?.next(cause: cause, at: at, stoppedReason: stoppedReason) ??
        RememberedSyncFailure(
          cause: cause,
          consecutiveFailures: 1,
          stoppedReason: stoppedReason,
          recordedAt: at.toUtc(),
        );
    try {
      await ref
          .read(syncStateStoreProvider)
          .setRememberedFailure(projectId, next);
    } catch (_) {
      // See the note above: the session's own bar is already correct.
    }
    return next;
  }

  /// One sync round for [projectId] specifically, rather than for whichever
  /// project happens to be open (task 11.28).
  ///
  /// [syncNow] and [syncIfDue] both operate on the **active** project, because
  /// that is what ongoing background sync means and what this controller's
  /// status — pending counts, held rows, last success — is about. Leaving a
  /// project is the first action that needs a round for a *named* project that
  /// may not be the open one, and it genuinely needs it: a departure that is
  /// never pushed leaves the person still a member everywhere but here, which
  /// is the divergence task 11.28 exists to end.
  ///
  /// When [projectId] *is* the active project this defers to [syncNow], so the
  /// status surface updates exactly as it would have. Otherwise it runs the
  /// engine directly and leaves the status alone — reporting another project's
  /// round as this one's counts would be a lie on the sync screen.
  ///
  /// Throws whatever the engine throws, including [SyncTransportException]
  /// when there is no server, no session, or no connection. Callers decide
  /// what an unreachable server means for them; for leaving, it means the
  /// departure is written and pending rather than refused.
  Future<void> syncProjectNow(String projectId) async {
    final active = await ref.read(activeProjectIdProvider.future);
    if (active == projectId) {
      await syncNow();
      return;
    }
    await (await _engine()).run(projectId);
  }

  /// **Delivers every departure this device wrote that the server never took**
  /// (task 11.57, item 4), and unlinks each project it succeeds for.
  ///
  /// Returns how many were delivered, so a caller can refresh what it needs to.
  ///
  /// ## Why this is not just another sync
  ///
  /// [syncNow] and [syncIfDue] act on the **active** project, and the project a
  /// stuck departure belongs to is by definition not the active one: the person
  /// has left it, and in the case that produced this fix they have deleted their
  /// copy as well, which takes it off every screen. So the row sat pending with
  /// nothing that could ever offer it, the person stayed a member on the server,
  /// and no invitation could be issued to them because the server was right to
  /// say they were already on it. `findUndeliveredDepartures` states the trap in
  /// full; this is the way out of it.
  ///
  /// **Called on cold launch and on every foreground** (`app.dart`), which is
  /// the moment a device that left a project out of signal gets its signal
  /// back, and cheap when there is nothing stuck — one small local query.
  ///
  /// ## The exception that is expected rather than tolerated
  ///
  /// A round that delivers a departure **fails on its own second half**, every
  /// time and by design: the engine pushes, the server takes the departure, and
  /// the pull that follows is refused because the person is — correctly, and as
  /// of that instant — no longer a member. Measured against the real server on
  /// 2026-08-29. So the outcome is never read from whether the round threw; it
  /// is read from the receipt afterwards, which is the same question
  /// `MembershipController.leaveProject` asks for the same reason.
  Future<int> deliverPendingDepartures() async {
    final session = await ref.read(currentSessionProvider.future);
    if (session == null) return 0;
    final config = await ref.read(serverConfigProvider.future);
    if (!config.isConfigured) return 0;

    final db = await ref.read(appDatabaseProvider.future);
    final store = ref.read(syncStateStoreProvider);
    final pending = await findUndeliveredDepartures(
      db: db.raw,
      state: store,
      userId: session.userId,
    );
    if (pending.isEmpty) return 0;

    final SyncEngine engine;
    try {
      engine = await _engine();
    } on SyncTransportException {
      // No transport to try with. Nothing is lost: the rows stay pending and
      // the next foreground asks again.
      return 0;
    }

    final receipts = SyncRowReceiptStore(db.raw);
    final table = syncTablesByName[Tables.projectMemberships]!;
    var delivered = 0;
    for (final departure in pending) {
      var settledByRefusal = false;
      try {
        await engine.run(departure.projectId);
      } on SyncTransportException catch (error) {
        // Task 11.301: a self-departure's own push refused with a
        // whole-request `403` has already achieved what it asked for — see
        // `departureSettledByRefusal`. Narrow to this call on purpose:
        // `deliverPendingProjectChanges`'s own refusal handling, one method
        // away, is the opposite rule for a *deletion*.
        if (departureSettledByRefusal(error)) settledByRefusal = true;
      } catch (_) {
        // See the doc above: the pull half of this round is *expected* to be
        // refused. Whether the departure landed is settled by the receipt.
      }
      final confirmed =
          settledByRefusal ||
          await departureIsConfirmed(
            receipts: receipts,
            table: table,
            projectId: departure.projectId,
            storedRow: {
              'membership_id': departure.membershipId,
              'project_id': departure.projectId,
              'updated_at': departure.updatedAt,
            },
          );
      if (!confirmed) continue;
      // The same call the leave path makes once the server agrees: forget the
      // cursor, the last-success stamp and the linked flag. Row receipts are
      // deliberately kept (`SyncStateStore.clear`).
      await store.clear(departure.projectId);
      delivered++;
    }
    if (delivered > 0) {
      ref.invalidate(isProjectLinkedProvider);
      ref.invalidateSelf();
    }
    return delivered;
  }

  /// **Delivers every change to a project's own row that no ordinary round
  /// can carry** (task 11.289) — above all a deleted project's tombstone.
  ///
  /// Returns how many it delivered.
  ///
  /// ## Why this is not just another sync
  ///
  /// The same reason [deliverPendingDepartures] is not: [syncNow] and
  /// [syncIfDue] act on the **active** project, and the project whose row is
  /// stranded here is by definition not the active one. Deleting the open
  /// project sets the active project to null (`ProjectsScreen._deleteProject`);
  /// a deleted project is hidden from the list and can never be selected; and
  /// selecting a different project runs *that* project's round. **So the
  /// project row is the only row in this app whose deletion destroys the scope
  /// that would have pushed it.** Michael measured the result on 2026-09-20:
  /// a project deleted on the phone, still live on the server, and nine such
  /// projects after a month. `findUndeliveredProjectChanges` states the trap
  /// in full and derives the stranded set from the push's own predicate.
  ///
  /// **Called on cold launch and on every foreground** (`app.dart`), which is
  /// when a device that deleted a project out of signal gets it back; from
  /// [syncNow], so a person who taps "Sync now" gets everything delivered and
  /// not only the open project; and right after a delete or an undo on the
  /// Projects list, as an immediate attempt that costs nothing when it fails.
  /// The lifecycle hook is the durable path; the other two are courtesies.
  ///
  /// ## What it deliberately does not do
  ///
  /// - **It does not unlink the project afterwards.** A departure unlinks
  ///   because the person is off the project. A deletion leaves the person
  ///   the owner of a project they may undo; unlinking would strand the undo
  ///   the same way the delete was stranded. The receipt the round writes is
  ///   what takes the row out of the pending set, and the next launch's query
  ///   finds nothing to do.
  /// - **It does not touch the status surface.** The counts, last-success and
  ///   remembered-failure fields describe the open project, and reporting a
  ///   hidden project's round there would be a lie on the sync screen.
  /// - **It does not run for the active project**, whose own round owns its
  ///   row; two engine rounds on one project at once is the thing `app.dart`
  ///   sequences these hooks to avoid.
  ///
  /// ## The round's second half
  ///
  /// A round for a deleted project pulls as well as pushes, and the pull is
  /// ordinary: the person is still a member, so the server answers with
  /// whatever it has, including the tombstone's own echo. Whether a change
  /// landed is read from the pending set afterwards — the same question that
  /// selected it — not from whether the round threw.
  Future<int> deliverPendingProjectChanges() async {
    final session = await ref.read(currentSessionProvider.future);
    if (session == null) return 0;
    final config = await ref.read(serverConfigProvider.future);
    if (!config.isConfigured) return 0;

    final db = await ref.read(appDatabaseProvider.future);
    final store = ref.read(syncStateStoreProvider);
    final active = await ref.read(activeProjectIdProvider.future);
    final pending = await findUndeliveredProjectChanges(
      db: db.raw,
      state: store,
      userId: session.userId,
      excludingProjectId: active,
    );
    if (pending.isEmpty) return 0;

    final SyncEngine engine;
    try {
      engine = await _engine();
    } on SyncTransportException {
      // No transport to try with. Nothing is lost: the rows stay pending and
      // the next foreground asks again.
      return 0;
    }

    var delivered = 0;
    for (final change in pending) {
      try {
        await engine.run(change.projectId);
      } on SyncTransportException catch (error) {
        // Task 11.290: the one refusal worth acting on here. A project the
        // server has destroyed will refuse this row on every foreground for
        // ever; recording the fact unlinks it, so the next derivation stops
        // offering it, and the Projects list says why.
        if (error.reason == syncRefusalProjectDestroyed) {
          try {
            await ref
                .read(projectDeletionNoticesProvider.notifier)
                .markDestroyed(change.projectId);
          } catch (_) {
            // Bookkeeping; the next foreground asks again.
          }
        }
        _rememberProjectChangeRefusal(change.projectId, error);
      } catch (_) {
        // Offline, refused, or a fault: the row is still pending and is asked
        // about again below and on the next foreground. Deciding "delivered"
        // from anything other than the pending set would be the mistake.
      }
      final stillPending = await findUndeliveredProjectChanges(
        db: db.raw,
        state: store,
        userId: session.userId,
        excludingProjectId: active,
      );
      if (stillPending.any((c) => c.projectId == change.projectId)) continue;
      delivered++;
      ref.read(projectChangeRefusalsProvider.notifier).forget(change.projectId);
    }
    if (delivered > 0) ref.invalidate(undeliveredProjectDeletionsProvider);
    return delivered;
  }

  /// **Brings back every project this device holds as deleted that the
  /// server has restored** (task 11.302) — and says which ones arrived.
  ///
  /// The inbound mirror of [deliverPendingProjectChanges]. An owner's restore
  /// clears the tombstone on the server; every device that already holds the
  /// tombstone has the project hidden, and a hidden project is never the
  /// active one, so no ordinary round would ever fetch it back.
  /// `restored_project_arrival.dart` states which tombstones are this
  /// device's to bring back and why each of the others is not.
  ///
  /// **The order of questions is the cost.** Local data first — a device
  /// holding no settled tombstone returns here without touching the network.
  /// Then one `GET /projects/mine`, which is what says a project is live
  /// again. Then one round per project that is, which pulls the restored row
  /// and pushes anything this device recorded there and never sent.
  ///
  /// **Arrival is read from the data afterwards**: a project is reported only
  /// if its row on this device is no longer tombstoned once the round is
  /// done. A round that failed part-way leaves the tombstone, reports
  /// nothing, and the next foreground asks again.
  ///
  /// [onlyProjectId] narrows it to one project — the owner's own restore on
  /// this device, which wants that one back now and nothing else.
  ///
  /// **Called on cold launch and on every foreground** (`app.dart`), from
  /// [syncNow], and right after an owner restores a project on this device.
  /// It runs the engine directly, like the two deliveries, so `app.dart`
  /// sequences it with them rather than beside them. Never throws.
  Future<List<RestoredProjectArrival>> bringBackRestoredProjects({
    String? onlyProjectId,
  }) async {
    try {
      final session = await ref.read(currentSessionProvider.future);
      if (session == null) return const [];
      final config = await ref.read(serverConfigProvider.future);
      if (!config.isConfigured) return const [];

      final db = await ref.read(appDatabaseProvider.future);
      final store = ref.read(syncStateStoreProvider);
      final settled = [
        for (final projectId in await findSettledProjectTombstones(
          db: db.raw,
          state: store,
          userId: session.userId,
        ))
          if (onlyProjectId == null || projectId == onlyProjectId) projectId,
      ];
      if (settled.isEmpty) return const [];

      final transport = await requireServerTransport(ref);
      final live = {
        for (final project in await transport.listMyProjects())
          project.projectId,
      };
      final restored = settled.where(live.contains).toList();
      if (restored.isEmpty) return const [];

      final engine = await _engine();
      final arrivals = <RestoredProjectArrival>[];
      for (final projectId in restored) {
        try {
          await engine.run(projectId);
        } catch (_) {
          // Offline mid-way, or refused: the tombstone is still here, which
          // is what the next foreground asks about. Decided below from the
          // row, not from this.
        }
        final rows = await db.raw.query(
          Tables.projects,
          columns: ['project_name', 'deleted_at', 'last_modified_by'],
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        if (rows.isEmpty || rows.single['deleted_at'] != null) continue;
        // Reported to the caller only. What a person is *told* is announced
        // by the merge that took the row from deleted to live
        // (`ProjectRestoration`), because this is one of three routes a
        // restore can arrive by — see that class.
        arrivals.add(
          RestoredProjectArrival(
            projectId: projectId,
            projectName: rows.single['project_name'] as String? ?? '',
            restoredBy: rows.single['last_modified_by'] as String?,
          ),
        );
      }
      if (arrivals.isNotEmpty) {
        ref.invalidate(undeliveredProjectDeletionsProvider);
        // The open project may be the one that came back; its status is
        // about it. The project lists themselves are refreshed by the pull's
        // own arrival announcement (`ArrivalRefresh`).
        ref.invalidateSelf();
      }
      return arrivals;
    } catch (_) {
      // No server, no signal, a refused listing: nothing to bring back this
      // time, and nothing lost by it.
      return const [];
    }
  }

  /// Writes down why a stranded project row's round was refused, for the
  /// Projects list's *"the server has not accepted this deletion"* row (task
  /// 11.290, task 11.289's fold-in). Classified through the same function
  /// every other refusal goes through, and with `departed: false`: this
  /// device offered the row as an owner, so a refusal here is an access
  /// refusal until a pull says otherwise.
  void _rememberProjectChangeRefusal(
    String projectId,
    SyncTransportException error,
  ) {
    try {
      final cause = classifySyncFailure(error, departed: false);
      ref.read(projectChangeRefusalsProvider.notifier).record(projectId, cause);
      ref.invalidate(undeliveredProjectDeletionsProvider);
    } catch (_) {
      // Bookkeeping for a row on a list; never worth failing the flush over.
    }
  }

  /// [SyncStatus.serverDatabaseChangedAt], read back from where the engine
  /// writes it. **Failing here must not fail the round's report** — it is one
  /// informational sentence — so an unreadable store reads as "never".
  Future<DateTime?> _databaseChangedAt(String projectId) async {
    try {
      return await ref.read(syncStateStoreProvider).databaseChangedAt(projectId);
    } catch (_) {
      return null;
    }
  }

  Future<SyncEngine> _engine() async {
    // **The connection comes from the app's one seam** (task 11.97). This
    // method used to build its own `HttpSyncTransport`, which is why nothing
    // could put a failing server in front of a sync round: *offline*,
    // *records refused*, *records missing* and *you are no longer on this
    // project* were four states this bar draws and no test could reach.
    // `requireServerTransport` keeps the order task 11.104 established — the
    // refused address is asked for as a value first, because the exception
    // explaining it does not survive a provider load.
    //
    // `_run` normally never reaches a refusal here, because `build` has
    // already made the status unavailable — this covers the publish, join and
    // pending-departure paths, and the window where the address changes
    // between a build and a round.
    final transport = await requireServerTransport(ref);
    final session = await ref.read(currentSessionProvider.future);
    if (session == null) {
      throw const SyncTransportException('not_configured');
    }
    final db = await ref.read(appDatabaseProvider.future);
    return SyncEngine(
      db: db.raw,
      transport: transport,
      state: ref.read(syncStateStoreProvider),
      deviceId: await ref.read(deviceIdProvider.future),
      userId: session.userId,
    );
  }
}
