/// Clock-skew detection for incoming rows (task 10.5).
///
/// **The server never rewrites a client's `updated_at`.** That timestamp is
/// part of the field record — it says when a biologist actually edited an
/// observation — and it is also a last-write-wins tie-break input that peers
/// which never saw the server will compare against. Silently "correcting" it
/// would destroy the record's own history *and* make two devices converge
/// differently depending on whether their data passed through the server.
/// So this classifies and records; it does not fix. Correcting a skewed
/// timestamp is a deliberate, visible decision for a human, not a side effect
/// of syncing.
library;

/// What the server concluded about a row's `updated_at` when it received it.
enum ClockSkewFlag {
  /// `updated_at` is meaningfully in the server's future. No legitimate cause
  /// — a device cannot have edited a row later than the moment the server
  /// received it (modulo [ClockSkew.tolerance] for ordinary drift and
  /// in-flight latency).
  future('future'),

  /// `updated_at` predates [ClockSkew.plausibleFloor] — the classic
  /// dead-battery symptom, where a phone comes back believing it is 1970.
  /// Distinguished from ordinary backlog by an *absolute* floor rather than a
  /// relative one; see [ClockSkew.classify].
  implausiblePast('implausible_past'),

  /// `updated_at` is earlier than the same row's `created_at`. Internally
  /// impossible for a well-behaved client, and a signal the row was
  /// hand-crafted or the device's clock moved backwards mid-session.
  updatedBeforeCreated('updated_before_created');

  const ClockSkewFlag(this.db);

  /// Stored value for the `clock_skew_flag` column.
  final String db;

  static ClockSkewFlag? fromDb(String? value) =>
      value == null ? null : values.firstWhere((f) => f.db == value);
}

/// Classifies the trustworthiness of an incoming row's timestamps.
abstract final class ClockSkew {
  /// How far into the future an `updated_at` may sit before it is flagged.
  ///
  /// Five minutes, chosen against the two things it has to separate. An
  /// NTP-synced phone is within seconds of correct, and request latency is
  /// sub-second, so a row claiming to be five minutes ahead of the server is
  /// genuinely anomalous. A much tighter window (say 30 seconds) would flag
  /// every mildly-drifted device and make the flag noise that gets ignored —
  /// worse than not having it, because a real problem would hide in the
  /// backlog of false ones.
  static const Duration tolerance = Duration(minutes: 5);

  /// Timestamps before this are treated as a broken clock rather than old
  /// data. TriTrack did not exist before 2026, so anything from 2020 or
  /// earlier cannot be a real field record; the value is deliberately well
  /// below the app's own history so a legitimately old import is never
  /// mistaken for a fault.
  static final DateTime plausibleFloor = DateTime.utc(2020);

  /// Classifies [updatedAt] against the server's [receivedAt] clock reading.
  /// Returns `null` when nothing is wrong.
  ///
  /// **"Old" is deliberately not a fault.** The task's framing — flag a row
  /// "far older than the sync that carried it" — cannot be implemented as a
  /// relative-age check, because that is exactly what a legitimate offline
  /// backlog looks like: a device off-network for a full field season pushes
  /// rows genuinely weeks old, and flagging those would mean flagging normal
  /// field use. The real "far older" fault is a device whose clock reset, and
  /// that is caught by an *absolute* floor ([plausibleFloor]) plus the
  /// internal-consistency check below. Both distinguish a broken clock from a
  /// long trip.
  static ClockSkewFlag? classify({
    required DateTime updatedAt,
    required DateTime receivedAt,
    DateTime? createdAt,
  }) {
    if (updatedAt.isAfter(receivedAt.add(tolerance))) {
      return ClockSkewFlag.future;
    }
    if (updatedAt.isBefore(plausibleFloor)) {
      return ClockSkewFlag.implausiblePast;
    }
    if (createdAt != null && updatedAt.isBefore(createdAt)) {
      return ClockSkewFlag.updatedBeforeCreated;
    }
    return null;
  }

  /// [classify] over a raw column-map, tolerating unparseable input.
  ///
  /// A row whose `updated_at` cannot be parsed is *not* flagged as skewed —
  /// that is a validation problem (`RowValidator`, and the merge path's own
  /// handling), and conflating "malformed" with "clock is wrong" would send a
  /// misleading signal to whoever reads the diagnostics console.
  static ClockSkewFlag? classifyRow(
    Map<String, Object?> row, {
    required DateTime receivedAt,
  }) {
    final updatedAt = _parseUtc(row['updated_at']);
    if (updatedAt == null) return null;
    return classify(
      updatedAt: updatedAt,
      receivedAt: receivedAt,
      createdAt: _parseUtc(row['created_at']),
    );
  }

  static DateTime? _parseUtc(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}
