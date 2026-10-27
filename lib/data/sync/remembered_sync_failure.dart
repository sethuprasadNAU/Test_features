import 'dart:convert';

import 'sync_failure.dart';

/// **The failure this device was last told about, written down** (task
/// 11.116).
///
/// ## The defect this exists to close
///
/// Until this, `SyncFailureCause` and `SyncSchedule`'s `consecutiveFailures`
/// and `stoppedReason` lived only in `SyncController`'s in-memory state. Only
/// the frequency setting and the last-attempt stamp were persisted — so a
/// week-old, ongoing refusal became a calm "Synced" bar on **every app restart
/// and every rebuild of the provider**. A phone reclaiming a backgrounded app
/// is a restart, so a device whose sync had been refused for a week could show
/// a calm bar several times a day.
///
/// ## The decision: a remembered failure is shown, and shown *as* remembered
///
/// When the app comes back holding one of these, the honest question is
/// whether the failure is still true, and there are three possible answers.
///
/// 1. **Show it as current.** That is a claim the app has not re-tested — the
///    server may have come back an hour ago.
/// 2. **Discard it and show healthy.** That is the defect above.
/// 3. **Show it, and say it has not been re-tested since.** Chosen.
///
/// Option 3 is chosen because the difference is a real one to the person
/// making the decision this bar exists for: *"the server is refusing us"* and
/// *"the server was refusing us on Monday and we have not been in signal
/// since"* lead to different choices about whether to walk half a mile to a
/// ridge. Neither of the other two can express that difference at all.
///
/// **The severity is not softened.** A remembered failure keeps the same
/// [SyncHealth] state, the same colour and the same icon as a live one, and
/// only the words change. Downgrading it would be discarding it slowly, and
/// this record is the best evidence the app has about where the data is.
///
/// **This state is short-lived by construction.** [stoppedReason] is
/// deliberately *not* restored into `SyncSchedule`, so a restart still grants
/// one cheap attempt: within seconds of the app opening in signal, the
/// remembered failure is replaced by a live result in one direction or the
/// other. It lasts only while the device genuinely has not tried — which is
/// exactly when the person needs to be told so. The one case where it lasts is
/// `SyncFrequency.onlyWhenIAsk`, where nothing will attempt until somebody
/// taps the button, and there the tense clause is the whole message.
///
/// ## Why the backoff curve still starts fresh
///
/// `SyncStateStore.lastAttemptAt`'s own note records the earlier decision that
/// the failure count behind the backoff is *not* persisted, so a device that
/// has been failing all day makes one cheap attempt when the app is opened
/// afresh rather than sitting in a two-hour backoff it can no longer see the
/// reason for. **That decision is untouched, and this record does not
/// contradict it**, because the two numbers answer different questions:
/// `SyncSchedule.consecutiveFailures` is *how long to wait before trying
/// again*, and [consecutiveFailures] here is *how much evidence there is that
/// something is wrong*. Only the second needs to survive a restart, and
/// restoring it into the first would have re-introduced the backoff this
/// project already decided against.
class RememberedSyncFailure {
  const RememberedSyncFailure({
    required this.cause,
    required this.consecutiveFailures,
    required this.recordedAt,
    this.stoppedReason,
  });

  /// Why the last attempt failed. Never null: a record with no cause is not a
  /// record, and is discarded on read.
  final SyncFailureCause cause;

  /// How many attempts in a row have failed, **counted across restarts**.
  ///
  /// This is the number `SyncStatus.looksBroken` reads. Before this record it
  /// reset to zero on every rebuild, so the three-failure threshold that
  /// separates "a dead zone" from "something is wrong" could only ever be
  /// reached inside a single uninterrupted session.
  final int consecutiveFailures;

  /// A terminal refusal's reason, when there was one — a revoked session, or a
  /// protocol version the server refuses.
  ///
  /// Kept for reporting only. It is **not** restored into `SyncSchedule`,
  /// where it would stop the next attempt: see the class note on why a restart
  /// still gets to re-test.
  final String? stoppedReason;

  /// When the failure this record describes happened, in UTC. The whole point
  /// of the tense the surfaces render — "last tried on Monday" is the fact,
  /// and it is only available because it is written down here.
  final DateTime recordedAt;

  /// Whether this is enough evidence to alarm somebody over.
  ///
  /// The same rule `SyncStatus.looksBroken` applied to the in-memory schedule,
  /// moved here so the durable record and the live one cannot come to disagree
  /// about what "repeatedly" means.
  bool get looksBroken =>
      stoppedReason != null || consecutiveFailures >= brokenAfterFailures;

  /// The next record after one more failed attempt, continuing this one's
  /// count.
  RememberedSyncFailure next({
    required SyncFailureCause cause,
    required DateTime at,
    String? stoppedReason,
  }) => RememberedSyncFailure(
    cause: cause,
    consecutiveFailures: consecutiveFailures + 1,
    stoppedReason: stoppedReason,
    recordedAt: at.toUtc(),
  );

  String encode() => jsonEncode({
    'cause': cause.id,
    'consecutive_failures': consecutiveFailures,
    if (stoppedReason != null) 'stopped_reason': stoppedReason,
    'recorded_at': recordedAt.toUtc().toIso8601String(),
  });

  /// Reads a stored record, or null if there is nothing readable there.
  ///
  /// **Every unreadable shape yields null rather than a partial record**, and
  /// null is the safe direction here for one specific reason: it makes the
  /// device re-test on its very next foreground and write a fresh record, so
  /// an unreadable memory costs one round trip rather than a wrong bar in
  /// either direction. A malformed record that was *partly* honoured could
  /// report a cause with no count behind it, which is a calm bar wearing a
  /// failure's clothes.
  static RememberedSyncFailure? decode(String? raw) {
    if (raw == null) return null;
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (parsed is! Map<String, dynamic>) return null;
    final rawCause = parsed['cause'];
    final cause = SyncFailureCause.fromId(
      rawCause is String ? rawCause : null,
    );
    if (cause == null) return null;
    final at = DateTime.tryParse(
      parsed['recorded_at'] is String ? parsed['recorded_at'] as String : '',
    );
    if (at == null) return null;
    final count = parsed['consecutive_failures'];
    if (count is! int || count < 1) return null;
    final stopped = parsed['stopped_reason'];
    return RememberedSyncFailure(
      cause: cause,
      consecutiveFailures: count,
      stoppedReason: stopped is String ? stopped : null,
      recordedAt: at.toUtc(),
    );
  }
}

/// How many failures in a row before sync is described as broken rather than
/// as a dead zone.
///
/// Three, unchanged from where it was written inline in `SyncStatus`. It lives
/// here so the live schedule and the durable record read the same constant —
/// two copies of a threshold is how the bar and the screen come to disagree.
const int brokenAfterFailures = 3;
