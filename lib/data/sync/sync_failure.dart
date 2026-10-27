import 'sync_transport.dart';

/// **Why sync is not working, as one closed set** (task 11.54).
///
/// ## The defect this exists to close
///
/// Until this, a failed sync was described by three parallel channels — a
/// `reason` string, a nullable `userMessage`, and a `sessionEnded` flag — and
/// the state the screens rendered was *reconstructed* from them by ordering.
/// Reconstruction can only ever recover the causes somebody thought of while
/// writing it, so a cause with no channel to travel in became whatever the
/// reconstruction fell through to. **That is why somebody who had just left a
/// project read "Sync has failed repeatedly. If this continues, contact
/// whoever manages your project server"** — pointing them at the one person
/// who could not help, for a state that was not a failure at all.
///
/// It is the third time this shape has been fixed on this project: task 11.37
/// separated "could not reach the server" from "the server answered with an
/// error", and task 11.42's stale bar was a relative. So this is written as a
/// **classification, not a third special case**: every cause a sync round can
/// end in is a member of this enum, produced in exactly one place
/// ([classifySyncFailure]), and every surface switches over the health state
/// it maps to exhaustively. A cause added later cannot silently render as a
/// generic failure — it is a compile error until every surface says what it
/// means.
///
/// ## What was deliberately left out, and is now here
///
/// A cause for "this device's sync bookmark was minted against a different
/// server's database" (task 11.51) was left out by task 11.54, because nothing
/// in the protocol could tell one server's database from another's and **an
/// unreachable state in a classification is worse than an absent one**: it
/// reads as covered. Task 11.58 put an identifier on the wire, and the answer
/// turned out to be mostly *not a failure*: a replaced database is detected
/// and the project's sync started over inside the same round, which then
/// succeeds. What remains a failure — and is [serverDatabaseChanged] — is the
/// database changing again inside the round that had just started over.
///
/// ## What is deliberately *not* here
///
/// A split of [unreachable] into "this phone has no network" and "this
/// phone has a network but the server did not answer" (task 11.115).
/// **Investigated and closed as not reliably possible**, rather than left
/// unconsidered: this project already ruled out a device connectivity check
/// once, for exactly this reason — `sync_schedule.dart`'s scheduling policy
/// (task 10.8) runs no connectivity plugin because those APIs report the
/// *interface*, not whether it works, and say "connected" behind a captive
/// portal. The
/// platform APIs behind such a plugin are not even consistent with each
/// other: Android's `NetworkCapabilities.NET_CAPABILITY_VALIDATED` actually
/// probes for a working route, while iOS's and macOS's `NWPathMonitor`
/// reports "satisfied" once an interface is up, with no such probe — so the
/// same captive-portal Wi-Fi would read differently depending on which
/// phone is holding it, which is worse than [unreachable] naming neither: a
/// classification is supposed to make two surfaces incapable of disagreeing
/// about the same failure (task 11.113), not add a third disagreement
/// between platforms. **A check that answers confidently and wrongly is
/// worse than the single word it replaces** — task 11.115's own acceptance
/// criterion — so the honest answer stands: "no signal" and "the server is
/// off" both report [unreachable], on every platform this app ships to.
enum SyncFailureCause {
  /// **The server could not be reached at all** — no signal, the laptop is
  /// off, the address is wrong. The normal field condition, and the one case
  /// worth a silent retry rather than somebody's attention.
  unreachable('unreachable'),

  /// **This device refuses the server address it has saved**, so no request
  /// was made (task 11.104). Distinct from [unreachable] on exactly the
  /// grounds task 11.66 measured being missed: both look like "nothing is
  /// getting through", and one of them is fixed by moving somewhere with
  /// signal while the other never resolves on its own, no matter where the
  /// person stands. Reported as "Offline — last synced 5 min ago" on a real
  /// Android build, which sent somebody to check a network that was working.
  serverAddressRefused('server_address_refused'),

  /// **This device reached the server and refused its security certificate**
  /// (task 11.113). The request went out; TLS is what stopped it.
  ///
  /// Ranked with [serverAddressRefused] and a long way from [unreachable], on
  /// the precedent [serverAddressRefused] set: *a configuration fault is not a
  /// transient one.* Being offline is fixed by walking uphill; a self-signed
  /// certificate is not, on any hill, and reporting one as the other
  /// guarantees the person looks in the wrong place. **Michael's iPhone
  /// reported "Offline" against a server whose certificate Safari, on that
  /// same phone, was refusing by name** — while this app's own server screen,
  /// two taps away, named it correctly.
  ///
  /// The whole cause, including which of expired / untrusted / wrong-hostname
  /// it was, is classified once in `core/errors/transport_failure.dart` and
  /// travels on [SyncTransportException.transportFailure].
  certificateRejected('certificate_rejected'),

  /// **The signed-in person is no longer a member of this project**, and this
  /// device's own records say so: the server refused access, and this device
  /// holds a **closed** membership row for them on it and no open one.
  ///
  /// Not a failure. It is the expected consequence of leaving a project, or of
  /// an owner removing somebody, and the app's job is to say so rather than to
  /// report breakage.
  ///
  /// **The closed row is the whole of it** (task 11.305). "No open row" is
  /// also true of somebody this device has never recorded on the project at
  /// all — a second account signing in on a device still holding the first
  /// account's linked project — and reading that as a departure unlinked the
  /// first person's project and told the second one they had left something
  /// they were never on. That case is [accessRefused].
  membershipEnded('membership_ended'),

  /// **The server refused access to this project, and this device's own
  /// records do not say the person left it** — either it still holds an open
  /// membership for them, or it holds no record of them on it at all.
  ///
  /// Distinct from [membershipEnded] on purpose: the usual cause is an owner
  /// removing somebody whose device has not yet pulled the news — the pull
  /// that would carry it is the very request being refused — so this device
  /// genuinely cannot tell whether that happened or something is wrong with
  /// the server. Saying which of the two it is would be a guess; saying that
  /// the server refused, and naming both possibilities, is not.
  ///
  /// The no-record case (task 11.305) lands here for the same reason: this
  /// device knows nothing that would let it say *why* the server refused, so
  /// "the server refused" is the only sentence it can stand behind.
  accessRefused('access_refused'),

  /// **The server holds no valid session for this device** — expired, or
  /// revoked. Signing in again is the fix.
  sessionEnded('session_ended'),

  /// **The server refused with a code this app has actionable words for** — a
  /// schema or protocol version skew, a device past the tombstone retention
  /// window, a rate limit, a route the server does not offer (task 11.307).
  /// The sentence comes from
  /// [SyncTransportException.userMessage], which is client-authored and merely
  /// *selected* by the code, never supplied by the server (§4.13).
  refusedWithRemedy('refused_with_remedy'),

  /// **The server answered, and with something this app cannot act on** — an
  /// unrecognised refusal, a malformed body, a 500. Nothing more specific can
  /// honestly be said, and this is the one cause for which "contact whoever
  /// manages your project server" is the right advice.
  serverRejected('server_rejected'),

  /// **This device set a deadline on the request and reached it** (task
  /// 11.61) — either nothing came back at all, or the answer stopped part way
  /// through.
  ///
  /// **Its own member rather than folded into [unreachable]**, because until
  /// task 11.61 this event could not happen at all: no request this app made
  /// was bounded, so a server that accepted a connection and then went quiet
  /// held the app until the platform gave up — sixty seconds on an iPhone, and
  /// never on Android, Windows or Linux. Keeping it separate is what lets the
  /// durable failure record say *this device gave up* rather than *nothing was
  /// there*, which are different facts about the server and lead somebody
  /// looking at two devices' records to different conclusions.
  ///
  /// **It renders exactly as [unreachable] does, and that is deliberate.** The
  /// remedy is the same three things — the address, the network, the server —
  /// and task 11.61's whole argument was that the app's *existing* honest
  /// states become reachable once a request can fail, not that it needs new
  /// ones. See `core/errors/transport_failure.dart`'s `_timedOut`.
  timedOut('timed_out'),

  /// **The server named a different database twice inside one round** (task
  /// 11.58) — see [SyncTransportException.serverDatabaseChanged].
  ///
  /// **Not the ordinary restore.** A server restored from a backup or rebuilt
  /// names a new database once; the engine starts the project over and the
  /// round succeeds, so that case never reaches this enum — it is reported on
  /// the status screen as something that happened, not as a failure. This is
  /// the round that had just started over meeting yet another database: two
  /// copies of the server answering at one address. Nothing on this device
  /// can fix that, and it will not fix itself.
  serverDatabaseChanged('server_database_changed'),

  /// **Something went wrong on this device** rather than on the wire. A bug,
  /// and it is named as one rather than blamed on the server.
  deviceFault('device_fault');

  const SyncFailureCause(this.id);

  /// Stable key for the durable failure record (task 11.116). **Never the
  /// enum's `name`**: renaming a value in Dart would then silently turn every
  /// device's remembered failure into an unreadable one — which resets the bar
  /// to calm, the exact defect that task exists to close. Same rule, and the
  /// same reason, as `SyncFrequency.id`.
  final String id;

  /// Reads a stored [id], or null if it is absent or from a build that knew a
  /// cause this one does not.
  ///
  /// **Null rather than a fallback cause.** [SyncFrequency.fromId] falls back
  /// to a default because a frequency must have *some* value; a failure must
  /// not, because inventing one would make this device report a failure it was
  /// never told about. An unreadable record is treated as no memory — the app
  /// then re-tests on the very next foreground and writes a fresh one.
  static SyncFailureCause? fromId(String? id) {
    for (final cause in values) {
      if (cause.id == id) return cause;
    }
    return null;
  }
}

/// Classifies a refused sync round. **The only place a cause is decided.**
///
/// [departed] is this device's own answer to "have I left this project" —
/// `ProjectMembershipRepository.hasDeparted`: a closed membership row for the
/// signed-in person and no open one — and it is what separates
/// [SyncFailureCause.membershipEnded] from [SyncFailureCause.accessRefused].
/// It is passed in rather than read here so that this function stays pure and
/// the read happens once, in the controller, alongside the unlink that depends
/// on the same answer.
///
/// **It is "have I left", not "am I still a member"** (task 11.305). Until
/// then this took `holdsOpenMembership`, and `!holdsOpenMembership` is true of
/// two different states: a closed row, which is a departure, and **no row at
/// all**, which is not. `SyncController.build` was already asking the narrower
/// question; this function, fed the wider one, was the path that acted — it
/// unlinked another account's project on a second person's first sign-in and
/// told them they had left it. Only the closed row may say *membershipEnded*.
///
/// The order of the checks is the design:
///
/// 1. An address this device refuses first of all, because no request was made
///    and every other member of this enum describes something that came back
///    from a server.
/// 2. A rejected certificate next, for the mirror-image reason: the request
///    went out and **nothing came back from a server**, so none of the checks
///    below can be true of it (task 11.113).
/// 3. A `401` next, because a revoked session is refused everywhere and would
///    otherwise be read as a project-level refusal.
/// 3a. A database that changed twice in one round (task 11.58), before the
///    remedy check, because it carries a sentence and is not a refusal.
/// 4. A refusal carrying a remedy next, because those already have the right
///    words and are more specific than the status code they arrived with (a
///    version skew is synthesised as a `409`).
/// 5. Only then the `403` split, which is the whole of task 11.54's item 2.
SyncFailureCause classifySyncFailure(
  SyncTransportException error, {
  required bool departed,
}) {
  // **First, ahead of the remedy check below** (task 11.104). This refusal
  // carries a `userMessage`, so a later position here would classify it as
  // `refusedWithRemedy` and the screens would head it "Update needed" — the
  // wrong cause again, one enum member further along.
  if (error.reason == SyncTransportException.serverAddressRefused) {
    return SyncFailureCause.serverAddressRefused;
  }
  // **Ahead of the remedy check below, for the same reason** (task 11.113).
  // This refusal carries a `userMessage` — the certificate sentence — so a
  // later position here would classify it as `refusedWithRemedy` and every
  // surface would head it "Update needed", which is the wrong cause one enum
  // member further along. That is not hypothetical: it is exactly the trap
  // task 11.104 documented one line above, and the second cause to fall into
  // it would have been the first sign nobody had fixed the class.
  if (error.reason == SyncTransportException.certificateRejected) {
    return SyncFailureCause.certificateRejected;
  }
  if (error.isSessionEnded) return SyncFailureCause.sessionEnded;
  // **Ahead of the remedy check, for the reason the two above are** (task
  // 11.58): this reason carries a `userMessage`, and a later position would
  // file it as `refusedWithRemedy` — a refusal, which it is not; the server
  // refused nothing.
  if (error.reason == SyncTransportException.serverDatabaseChanged) {
    return SyncFailureCause.serverDatabaseChanged;
  }
  if (error.userMessage != null) return SyncFailureCause.refusedWithRemedy;
  if (error.statusCode == 403) {
    return departed
        ? SyncFailureCause.membershipEnded
        : SyncFailureCause.accessRefused;
  }
  // A named constant rather than a null status code: `malformed_response` and
  // `not_configured` also carry no status, and neither of them means "no
  // network". Only the transport's own catch-all for a socket-level failure
  // does.
  if (error.reason == SyncTransportException.unreachable) {
    return SyncFailureCause.unreachable;
  }
  // Beside [SyncFailureCause.unreachable] and for the same reason it is a named
  // constant rather than a null status: this device gave up on the request, and
  // that is not the same fact as nothing having been there (task 11.61).
  if (error.reason == SyncTransportException.requestTimedOut) {
    return SyncFailureCause.timedOut;
  }
  return SyncFailureCause.serverRejected;
}
