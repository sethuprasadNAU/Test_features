import 'dart:convert';

/// **What this device last learned about a project's deletion from the
/// server** (task 11.290).
///
/// ## Why it is stored at all
///
/// The server owns the schedule: an owner asks, the server sets the date, and
/// `GET /projects/mine` tells every member. But the Projects list is read
/// offline far more often than online, and a contributor at a trailhead
/// deciding whether to export needs the date on the screen in front of them,
/// not on a server they cannot reach. So the last answer is written down
/// here, per project, and the list draws from it.
///
/// ## What it is, and is not
///
/// It is a **copy of the server's answer, dated**. [learnedAt] says how old
/// the copy is, and the row says so when the copy is old — the same tense
/// discipline `RememberedSyncFailure` keeps for a failure this device has not
/// re-tested. It is never the schedule itself: nothing on this device decides
/// when the project dies, and a device clock that is wrong changes only which
/// day the countdown *shows*, never which day the server acts on.
///
/// [executed] is set when this device learns the deletion has happened —
/// from the server refusing the project by name (`project_destroyed`), or
/// from an owner's own *delete now* on this device. Until then, a date in the
/// past means only that this device has not been told yet.
class ProjectDeletionNotice {
  const ProjectDeletionNotice({
    required this.destroyAt,
    required this.learnedAt,
    this.executed = false,
  });

  /// When the server said it would destroy the project, UTC.
  final DateTime destroyAt;

  /// When this device last heard that from the server, UTC.
  final DateTime learnedAt;

  /// Whether this device knows the destruction has happened.
  final bool executed;

  /// Whole days from [now] to [destroyAt], rounded up, never below zero — the
  /// number the row shows. A deletion due later today is "1 day" rather than
  /// "0 days", because "0 days left" reads as already gone.
  int daysLeftAt(DateTime now) {
    final remaining = destroyAt.difference(now.toUtc());
    if (remaining <= Duration.zero) return 0;
    return (remaining.inMinutes / Duration.minutesPerDay).ceil();
  }

  /// Whether the server's date has passed by [now], on this device's clock.
  /// A display question only — see the class note.
  bool isPastAt(DateTime now) => !destroyAt.isAfter(now.toUtc());

  ProjectDeletionNotice markExecuted(DateTime at) => ProjectDeletionNotice(
    destroyAt: destroyAt,
    learnedAt: at.toUtc(),
    executed: true,
  );

  Map<String, Object?> toJson() => {
    'destroy_at': destroyAt.toUtc().toIso8601String(),
    'learned_at': learnedAt.toUtc().toIso8601String(),
    'executed': executed,
  };

  /// Null for anything unreadable: a notice this build cannot read is treated
  /// as no notice, and the next `/projects/mine` writes a fresh one — the same
  /// direction `RememberedSyncFailure.decode` chooses, for the same reason.
  static ProjectDeletionNotice? fromJson(Object? json) {
    if (json is! Map) return null;
    // Present-but-wrong-typed is dropped the same as absent: an `as String?`
    // here would throw on a stored `5`, and a notice that cannot be read must
    // read as no notice rather than take the list down with it.
    final rawDestroy = json['destroy_at'];
    final rawLearned = json['learned_at'];
    if (rawDestroy is! String || rawLearned is! String) return null;
    final destroyAt = DateTime.tryParse(rawDestroy);
    final learnedAt = DateTime.tryParse(rawLearned);
    if (destroyAt == null || learnedAt == null) return null;
    return ProjectDeletionNotice(
      destroyAt: destroyAt.toUtc(),
      learnedAt: learnedAt.toUtc(),
      executed: json['executed'] == true,
    );
  }

  /// Encodes a whole map of notices, keyed by project id, as one string.
  static String encodeAll(Map<String, ProjectDeletionNotice> notices) =>
      jsonEncode({
        for (final entry in notices.entries) entry.key: entry.value.toJson(),
      });

  static Map<String, ProjectDeletionNotice> decodeAll(String? raw) {
    if (raw == null) return const {};
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const {};
    }
    if (decoded is! Map) return const {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && fromJson(entry.value) != null)
          entry.key as String: fromJson(entry.value)!,
    };
  }
}
