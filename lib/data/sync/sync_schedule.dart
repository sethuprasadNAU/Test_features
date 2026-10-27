/// When automatic sync is allowed to attempt (task 10.8).
///
/// ## The decisions, and the field conditions that drove them
///
/// The design target is not a phone on office Wi-Fi. It is a device that spends
/// days without connectivity, whose battery has to last a full day away from
/// power, and which sometimes has metered or satellite data that costs real
/// money per megabyte.
///
/// **1. Automatic sync runs only while the app is foregrounded. There is no
/// background sync.** Background execution on iOS is opportunistic and
/// unreliable — the OS decides, and it will not decide often on a device that
/// spends the day in a pack. Registering for it costs battery on every wake
/// whether or not there is signal, needs background-mode entitlements, and buys
/// very little for a workflow whose natural rhythm is "open the app when back
/// in range". The manual trigger covers the case background sync would have
/// served, and covers it *predictably*, which matters more than covering it
/// automatically.
///
/// **2. A manual "sync now" is always available and ignores every restriction
/// below.** This is required regardless of the automatic policy. The moment a
/// field tech reaches signal at a trailhead and wants their data off the device
/// before a four-hour drive is precisely the moment a scheduler must not be the
/// only way to sync — and it is also the moment they will happily spend cellular
/// data. Manual means manual.
///
/// **3. Automatic sync is rate-limited by [minimumInterval], not by
/// connectivity type.** No connectivity plugin is used, and that is deliberate
/// rather than an omission: connectivity APIs report the *interface*, not
/// whether it works, so they say "connected" on a captive portal at a
/// campground and "cellular" on a hotspot that is really Wi-Fi backhaul. The
/// engine treats an unreachable server as an ordinary failure and backs off,
/// which handles the dead-zone case correctly without a dependency that lies.
///
/// **The cost of that choice, stated plainly: automatic sync is not currently
/// Wi-Fi-only, so it can spend cellular data.** It is bounded — one attempt per
/// [minimumInterval] at most, and a steady-state round is a handful of rows —
/// but on a genuinely metered or satellite link a user who cares must turn
/// automatic sync off and use the manual button. A real "unmetered only"
/// setting needs interface detection and is filed as follow-up scope. The plan
/// asked for this to be decided and documented rather than defaulted; this is
/// the decision, and this is what it costs.
///
/// **4. The user picks the cadence, from a named list, and the list only
/// contains promises this code keeps (task 11.59).** [SyncFrequency] is that
/// list. Because of decision 1, "frequency" here means *how long after the
/// last attempt a foreground counts as due* — not how often the app syncs.
/// **With the app closed, nothing syncs at any setting**, and every surface
/// that offers this choice has to say so in those words rather than implying
/// a timer that does not exist.
///
/// **5. Failure backs off exponentially and caps.** A device in a dead zone
/// must not spend its battery rediscovering that every few seconds. A terminal
/// failure (revoked session, version mismatch) stops attempts entirely rather
/// than backing off, because "try later" is the wrong model for something later
/// will not fix.
library;

/// Smallest gap between automatic attempts when the last one succeeded.
///
/// Fifteen minutes. Long enough that foregrounding the app repeatedly — which
/// field use does constantly, between the map and the record screen — does not
/// mean a round trip each time; short enough that a device sitting in signal
/// keeps reasonably current without anyone thinking about it.
///
/// The interval behind [SyncFrequency.everyFifteenMinutes], which is the
/// default and the recommended choice. **[SyncFrequency.everyForeground]
/// deliberately removes this floor** — see its own note for what that costs.
const Duration minimumInterval = Duration(minutes: 15);

/// First backoff after a failure, doubling to [maximumBackoff].
const Duration initialBackoff = Duration(minutes: 1);

/// Ceiling on backoff.
///
/// Two hours, not "forever". A device that has been out of range all day should
/// still make an occasional cheap attempt when foregrounded rather than needing
/// the user to remember the manual button — but an attempt every two hours is
/// invisible on a battery budget.
const Duration maximumBackoff = Duration(hours: 2);

/// How long after the last attempt a foreground counts as due (task 11.59).
///
/// **A named list rather than a free minutes field**, because a free number
/// invites "1" — battery and cellular data spent for nothing — and "1440",
/// which is indistinguishable from off and does not say so.
///
/// **[label] is written here, once, and both the sync bar and the sync screen
/// render this same string.** The bar has to name the setting in the user's
/// own words when it is [onlyWhenIAsk] ("3 records waiting" while nothing is
/// going to happen is the silence task 11.59 exists to remove), and a second
/// copy of these words somewhere in the widget layer is a second copy that can
/// drift out of step with the first.
///
/// **None of these is a background timer.** Automatic sync only ever attempts
/// while the app is foregrounded (see decision 1 above), so every one of these
/// means "when you next open the app, and at least this long since the last
/// attempt". With the app closed nothing syncs at any of them.
enum SyncFrequency {
  /// No floor at all: every foreground is due.
  ///
  /// **This gives up what [minimumInterval] was for.** Field use foregrounds
  /// the app constantly, between the map and the record screen, and this
  /// setting makes each of those a round trip. Offered anyway, because
  /// somebody working beside a colleague on Wi-Fi wants their bearings visible
  /// to the other device now rather than within a quarter of an hour — but
  /// offered knowing the cost, and never as the default.
  everyForeground('every_foreground', 'Every time I open it', Duration.zero),

  /// The default and the recommendation. See [minimumInterval].
  everyFifteenMinutes('every_15_minutes', 'Every 15 minutes', minimumInterval),

  /// For a metered or satellite link somebody does not want to stop using
  /// automatically altogether.
  hourly('hourly', 'Hourly', Duration(hours: 1)),

  /// Automatic sync off: nothing syncs until the person taps "Sync now".
  ///
  /// **Legitimate, and it is why [interval] is nullable rather than "a very
  /// large number".** There is no next automatic attempt to time, and a
  /// sentinel interval would leave every reader of this enum deciding for
  /// itself how large counts as never. The surfaces ask [isAutomatic].
  onlyWhenIAsk('only_when_i_ask', 'Only when I ask', null);

  const SyncFrequency(this.id, this.label, this.interval);

  /// Stable key for `SharedPreferences`. Never the enum's `name`: renaming a
  /// value in Dart would then silently reset everybody's setting.
  final String id;

  /// The words the user chose, reused verbatim by every surface. See the
  /// class note.
  final String label;

  /// Minimum gap between automatic attempts, or null when automatic sync is
  /// off.
  final Duration? interval;

  /// Whether the app may sync without being asked.
  bool get isAutomatic => interval != null;

  /// Reads a stored [id].
  ///
  /// **An unreadable value falls back to [defaultSyncFrequency] rather than to
  /// "off".** Both directions of that choice are wrong in some way: this one
  /// can start syncing for somebody who had turned it off on a newer build,
  /// and the other would silently stop syncing for everybody else — which is
  /// exactly the beta-blocking silence this task removed. What makes the
  /// chosen direction survivable is that the sync screen always renders the
  /// frequency actually in effect, so the fallback is visible rather than
  /// silent.
  static SyncFrequency fromId(String? id) =>
      values.firstWhere((f) => f.id == id, orElse: () => defaultSyncFrequency);
}

/// What a device syncs at until somebody says otherwise.
const SyncFrequency defaultSyncFrequency = SyncFrequency.everyFifteenMinutes;

/// Decides whether automatic sync may attempt now.
///
/// Pure, and takes the clock as an argument, so the policy is testable without
/// waiting on real time — which is the only way a backoff curve gets verified
/// rather than assumed.
class SyncSchedule {
  const SyncSchedule({
    this.frequency = defaultSyncFrequency,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.consecutiveFailures = 0,
    this.stoppedReason,
  });

  /// The user's setting. Defaults to [defaultSyncFrequency] — on: the app is
  /// more useful synced, and the field tech who needs it off (satellite
  /// billing) is the one who will go looking.
  ///
  /// **This replaced a separate `automaticEnabled` flag** (task 11.59). Off is
  /// [SyncFrequency.onlyWhenIAsk], one of the four choices, rather than a
  /// second setting that could disagree with the frequency beside it.
  final SyncFrequency frequency;

  /// Whether the app may sync without being asked. Derived from [frequency],
  /// deliberately: one setting, one answer.
  bool get automaticEnabled => frequency.isAutomatic;

  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final int consecutiveFailures;

  /// Set when a terminal failure means attempts should stop until something
  /// changes — a revoked session, or a protocol version the server refuses.
  final String? stoppedReason;

  /// How long to wait after [consecutiveFailures] failures, or null when
  /// automatic sync is off and there is therefore no next attempt to time.
  ///
  /// **Never shorter than the interval the user chose** (task 11.59). The
  /// backoff curve starts at [initialBackoff] — one minute — which was written
  /// when fifteen minutes was the only cadence and a quick retry after a blip
  /// was free. It is not free under "Hourly": somebody who picked that to hold
  /// down cellular use on a satellite plan would have got an attempt every
  /// minute for as long as the server stayed unreachable, which is the setting
  /// promising less than the code does. So the wait is the longer of the
  /// backoff and the chosen interval, and the doubling still applies above it.
  Duration? get currentBackoff {
    final interval = frequency.interval;
    if (interval == null) return null;
    if (consecutiveFailures == 0) return interval;
    var backoff = initialBackoff;
    for (var i = 1; i < consecutiveFailures; i++) {
      backoff *= 2;
      if (backoff >= maximumBackoff) {
        backoff = maximumBackoff;
        break;
      }
    }
    return backoff < interval ? interval : backoff;
  }

  /// Whether an automatic attempt is due at [now].
  bool shouldAttemptAt(DateTime now) {
    if (stoppedReason != null) return false;
    final wait = currentBackoff;
    if (wait == null) return false;
    final last = lastAttemptAt;
    if (last == null) return true;
    return !now.isBefore(last.add(wait));
  }

  /// A sentinel distinguishing "not passed" from "explicitly set to null" in
  /// [copyWith]'s nullable parameters — `??` alone cannot tell the two apart,
  /// and both are real here: `recordSuccess` means *clear the terminal stop*,
  /// while `recordAttempt` means *leave it alone*.
  static const _unset = Object();

  /// A copy of this schedule with the named fields replaced and every other
  /// field — including one added after this method was written — carried over
  /// unchanged.
  ///
  /// **This is the same fix task 11.96/11.117 made to `SyncStatus`, applied to
  /// the third instance of the pattern in this subsystem** (task 11.124). The
  /// five methods below used to rebuild the whole object by hand, naming every
  /// field at every site. Nothing failed when one was left out: the dropped
  /// field silently became its constructor default, and for a schedule the
  /// calm defaults are *no failures* and *not stopped* — the two states hardest
  /// to notice being wrong. A caller of this method cannot drop a field by
  /// omission; the only way to change one is to name it.
  SyncSchedule copyWith({
    SyncFrequency? frequency,
    Object? lastAttemptAt = _unset,
    Object? lastSuccessAt = _unset,
    int? consecutiveFailures,
    Object? stoppedReason = _unset,
  }) => SyncSchedule(
    frequency: frequency ?? this.frequency,
    lastAttemptAt: identical(lastAttemptAt, _unset)
        ? this.lastAttemptAt
        : lastAttemptAt as DateTime?,
    lastSuccessAt: identical(lastSuccessAt, _unset)
        ? this.lastSuccessAt
        : lastSuccessAt as DateTime?,
    consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
    stoppedReason: identical(stoppedReason, _unset)
        ? this.stoppedReason
        : stoppedReason as String?,
  );

  SyncSchedule recordAttempt(DateTime at) => copyWith(lastAttemptAt: at);

  SyncSchedule recordSuccess(DateTime at) => copyWith(
    lastAttemptAt: at,
    lastSuccessAt: at,
    // Reset, so one good round clears an accumulated backoff.
    consecutiveFailures: 0,
    stoppedReason: null,
  );

  /// [terminalReason] is passed through as given: null means *not terminal*,
  /// which for an ordinary failure is the correct value to write rather than
  /// one to leave alone. A previous stop is therefore cleared by an ordinary
  /// failure, exactly as the hand-written rebuild did.
  SyncSchedule recordFailure(DateTime at, {String? terminalReason}) => copyWith(
    lastAttemptAt: at,
    consecutiveFailures: consecutiveFailures + 1,
    stoppedReason: terminalReason,
  );

  SyncSchedule withFrequency(SyncFrequency frequency) =>
      copyWith(frequency: frequency);
}
