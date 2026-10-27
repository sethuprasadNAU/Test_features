/// Bounded retention for the server's own long-lived tables (task 10.14,
/// Security Model §4.7; scheduled and measured by task 11.79).
library;

import 'package:postgres/postgres.dart';

/// §4.7's retention windows, one per class, and they are deliberately
/// different.
///
/// **Authentication events: one year.** "Was my account compromised in March?"
/// is a question that gets asked in September.
///
/// **Data access: 180 days.** It must outlive a field season, because the
/// question this log answers — "where did my observation go?" — arrives when
/// someone sits down with the data at the end of the season, not the next day.
///
/// **Decided join requests: 30 days.** A person who asked to join and was
/// turned down has no reason to be a row on this server a year later. The
/// window is not zero because a rejected request is *how* the requester's own
/// phone learns the answer — deleting it the moment the owner decides is what
/// would leave somebody staring at "pending" for ever, the class task 11.60
/// found for removed members. Thirty days is long enough that somebody who
/// asked and then spent three weeks out of signal still gets their answer.
///
/// §4.7's `Violated by:` list names "retention that quietly grows without
/// bound", which is what all three did before task 11.79 scheduled the sweep.
const Duration authAuditRetention = Duration(days: 365);
const Duration dataAccessRetention = Duration(days: 180);
const Duration decidedJoinRequestRetention = Duration(days: 30);

/// One thing this server keeps, for how long, and how a person would name it.
///
/// **Declared once and read by both the sweep and the measurement**, which is
/// the point. Task 11.78's finding was that a control nothing runs is
/// invisible; the shape one level up is a control that runs and a check that
/// measures something *else*, so the check stays green while the sweep does
/// nothing. Here [AuditRetentionService.purge] and
/// [AuditRetentionService.measure] iterate this same list — a fourth class
/// added below is swept and reported on together, or not at all.
class RetentionClass {
  const RetentionClass({
    required this.key,
    required this.table,
    required this.timeColumn,
    required this.window,
    required this.rows,
    this.predicate,
  });

  /// Stable identifier used in output and in tests. Not a display string.
  final String key;

  final String table;

  /// The column that decides a row's age. For a decided join request that is
  /// `decided_at` and not `requested_at`: the window starts when the person
  /// got their answer, not when they asked.
  final String timeColumn;

  final Duration window;

  /// What one row is, in a sentence a person can read: "sign-in events".
  final String rows;

  /// An extra condition, ANDed onto both the delete and the measurement.
  ///
  /// **It must be identical in both or the check is measuring a different
  /// population from the one being deleted** — which is the exact way a green
  /// check can sit on top of a sweep that never touches anything. Both come
  /// from this one field for that reason.
  final String? predicate;

  String get _where => predicate == null ? '' : ' AND ($predicate)';

  /// The DELETE this class applies. `$1` is the cutoff.
  ///
  /// The table name, the column and the predicate are interpolated, and that is
  /// safe **only** because every [RetentionClass] in [retentionClasses] is a
  /// compile-time constant in this file. Nothing here is reachable from request
  /// input; if that ever changes, this becomes an injection point.
  String get deleteSql =>
      'DELETE FROM $table WHERE $timeColumn < \$1$_where RETURNING $timeColumn';

  /// The oldest row that survived, or null when the class holds none.
  String get oldestSql =>
      'SELECT min($timeColumn) FROM $table WHERE $timeColumn IS NOT NULL$_where';
}

/// Every class §4.7 bounds. Adding a table here is the whole change: it is
/// swept, measured and reported on from this one entry.
const List<RetentionClass> retentionClasses = [
  RetentionClass(
    key: 'auth_events',
    table: 'auth_audit_log',
    timeColumn: 'occurred_at',
    window: authAuditRetention,
    rows: 'sign-in events',
  ),
  RetentionClass(
    key: 'data_access',
    table: 'sync_traffic_log',
    timeColumn: 'occurred_at',
    window: dataAccessRetention,
    rows: 'sync-traffic rows',
  ),
  // Task 11.79, widened by task 11.85's finding R-2: six rejections on a fresh
  // project left six rows, and the only bound anywhere was a 200-row cap on
  // what the list routes *return* — which bounds a response and not a table.
  //
  // **Undecided requests are deliberately out of scope.** A pending request is
  // somebody waiting for an answer; deleting it would answer them by silence.
  // Only rows the owner has already decided are eligible, which is what the
  // predicate says.
  RetentionClass(
    key: 'decided_join_requests',
    table: 'project_join_requests',
    timeColumn: 'decided_at',
    window: decidedJoinRequestRetention,
    rows: 'decided join requests',
    predicate: 'decided_at IS NOT NULL',
  ),
];

/// The oldest row that survived one class's sweep.
///
/// [age] is null when the class is empty, which is a perfectly healthy state
/// and **not** the equivalent of task 11.78's "no backup has ever been taken".
/// The asymmetry is worth saying out loud: an empty archive directory means
/// every observation exists only on the phones that recorded it, while an
/// empty audit table means there is nothing here to leak.
class RetentionReading {
  const RetentionReading({required this.retentionClass, required this.oldest});

  final RetentionClass retentionClass;
  final DateTime? oldest;

  Duration? ageAt(DateTime now) =>
      oldest == null ? null : now.toUtc().difference(oldest!.toUtc());
}

/// The result of one sweep: how many rows each class lost.
///
/// Counts, not a boolean, so a caller (or a test) can assert the sweep did
/// something rather than trusting that it ran.
class RetentionSweep {
  const RetentionSweep(this.deleted);

  /// Keyed by [RetentionClass.key].
  final Map<String, int> deleted;

  int operator [](String key) => deleted[key] ?? 0;

  int get authEvents => this['auth_events'];
  int get dataAccess => this['data_access'];
  int get decidedJoinRequests => this['decided_join_requests'];

  int get total => deleted.values.fold(0, (a, b) => a + b);
}

/// Deletes rows past their retention window, and reports what is left.
///
/// **Deleting is the point, not a side effect.** A log that grows forever is
/// not more secure than one that is pruned — it is less, because every extra
/// month is a month of researcher email addresses (asset 4) and device
/// identifiers sitting in a table whose whole justification was answering a
/// question about the recent past. The windows above are the longest span at
/// which each class is still useful; beyond them the rows are pure liability.
class AuditRetentionService {
  AuditRetentionService(this.session, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Session session;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  /// Prunes every class in [retentionClasses].
  Future<RetentionSweep> purge() async {
    final now = _now;
    final deleted = <String, int>{};
    for (final rc in retentionClasses) {
      final result = await session.execute(
        rc.deleteSql,
        parameters: [now.subtract(rc.window)],
      );
      deleted[rc.key] = result.length;
    }
    return RetentionSweep(deleted);
  }

  /// The age of the oldest surviving row in each class.
  ///
  /// **This is the measurement task 11.79 exists to produce.** A scheduler
  /// that exists and does not fire is invisible to "is the scheduler up?" and
  /// obvious to "how old is the oldest row we still hold" — the same
  /// distinction task 11.78 drew between a timer and an archive.
  Future<List<RetentionReading>> measure() async {
    final readings = <RetentionReading>[];
    for (final rc in retentionClasses) {
      final result = await session.execute(rc.oldestSql);
      final value = result.isEmpty ? null : result.first.first;
      readings.add(
        RetentionReading(
          retentionClass: rc,
          oldest: value is DateTime ? value.toUtc() : null,
        ),
      );
    }
    return readings;
  }
}
