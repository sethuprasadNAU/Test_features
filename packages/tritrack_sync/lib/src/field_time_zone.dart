import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// **A deployment day is the field site's day** (task 11.331, `CLAUDE.md`
/// standing decision 4, design §4).
///
/// Until schema v20 a deployment's attached and removed days were stored as
/// midnight on *the entering phone's* clock, and the zone was not saved. So the
/// same row read as the day before on any phone west of where it was entered,
/// and the server — which runs on UTC — could only guess whether a value was a
/// bare day or a real swap time (`DeploymentInterlock`'s notes, tasks 11.264 and
/// 11.266). Now every project has a time zone (an IANA name such as
/// `America/Phoenix`), and every deployment row records the zone its days were
/// written in. A bare day is midnight **in that zone**, wherever the person
/// reading it is.
///
/// ## The zone rules come from outside, and that is a §3.8 decision
///
/// The IANA time-zone rules (when each zone's clocks change) are the `timezone`
/// package's copy of the tz database, pinned exactly in this package's
/// `pubspec.yaml` and justified in `TriTrack_Security_Model.md` §3.8. It is
/// trusted with one thing: turning an instant into a wall-clock date in a
/// named zone and back. It never sees a row, an id or a name of anything.
///
/// ## A zone this build does not know is read as no zone at all
///
/// A newer build can carry a newer tz database with a zone name this one has
/// never heard of. Refusing the row would strand it; guessing would be worse.
/// So an unknown name reads exactly like a row from before v20: the device's
/// own zone on a phone, and every end an instant on the server (see
/// `DeploymentInterlock.coverageEnd`). [FieldTimeZone.location] returns null
/// for it, and every function below falls back on that null.
abstract final class FieldTimeZone {
  static bool _loaded = false;

  static void _ensureLoaded() {
    if (_loaded) return;
    tzdata.initializeTimeZones();
    _loaded = true;
  }

  /// The zone named [name], or null for null, an empty name, or a name this
  /// build's tz database does not hold.
  static tz.Location? location(String? name) {
    if (name == null || name.isEmpty) return null;
    _ensureLoaded();
    return tz.timeZoneDatabase.locations[name];
  }

  /// Whether [name] is a zone this build can read.
  static bool isKnown(String? name) => location(name) != null;

  /// Every zone name this build's tz database holds, links included.
  static Iterable<String> get allNames {
    _ensureLoaded();
    return tz.timeZoneDatabase.locations.keys;
  }

  /// [zone]'s offset from UTC at [at], or null when [zone] is unknown.
  static Duration? offsetAt(String? zone, DateTime at) =>
      location(zone)?.timeZone(at.millisecondsSinceEpoch).offset;

  /// Whether [zone] is on daylight-saving time at [at]; null when unknown.
  static bool? isDstAt(String? zone, DateTime at) =>
      location(zone)?.timeZone(at.millisecondsSinceEpoch).isDst;
}

/// The first instant of the calendar day [year]-[month]-[day] in [loc].
///
/// Usually midnight. **Not always**: a few zones change their clocks *at*
/// midnight (Havana, Santiago, Beirut), so on that one day midnight does not
/// exist and the day begins at 01:00. The tz package already rolls a missing
/// wall time forward; the loop is the guard that the result really is on the
/// asked-for day, so that [deploymentDateFor] stays idempotent whatever the
/// package does.
DateTime _startOfDay(tz.Location loc, int year, int month, int day) {
  var candidate = tz.TZDateTime(loc, year, month, day);
  final wanted = DateTime.utc(year, month, day);
  for (var i = 0; i < 4; i++) {
    final landed = DateTime.utc(candidate.year, candidate.month, candidate.day);
    if (!landed.isBefore(wanted)) break;
    candidate = tz.TZDateTime.fromMillisecondsSinceEpoch(
      loc,
      candidate.millisecondsSinceEpoch + const Duration(hours: 1).inMilliseconds,
    );
  }
  return DateTime.fromMillisecondsSinceEpoch(candidate.millisecondsSinceEpoch);
}

/// **A collaring date: the calendar day [at] falls in, at that day's first
/// instant** — in [zone] when it is given and known, and in this process's
/// local zone otherwise (a row written before schema v20, or a zone this build
/// does not know). `DateTime.now()` in, the start of today in the field out.
///
/// Returns a local `DateTime` either way, as it always has, so that equality
/// with `DateTime(y, m, d)` in a test on a machine in the same zone still holds.
///
/// Lived in the app's `deployment.dart` from task 11.251 until task 11.263
/// moved it here beside the interlock, which needs it to tell a bare day
/// from a time; the app re-exports it from the same place it always did.
///
/// ## Why a deployment date is a day and not a moment
///
/// Nobody records the hour a collar went on. Storing `DateTime.now()`
/// verbatim would put a ragged time-of-day on every row, so two deployments
/// recorded on the same afternoon would overlap by a few hours nobody meant.
///
/// **The one exception is a same-day swap (design §4a, task 11.251)**, where
/// the time is the only thing that can say which animal a bearing taken that
/// afternoon was about. There the app writes a real instant on purpose, and
/// [deploymentEndHasTime] is how a reader tells the two apart.
///
/// ## The field's midnight, not UTC's and not the reader's (task 11.331)
///
/// The column is a single instant — `Deployments` has no local/UTC/offset
/// triple like `Observations` does, because a date somebody types is not a
/// measurement somebody took. **Local midnight is the one that keeps the
/// first day's bearings:** a collaring at 9am in New Zealand is 20:00 the
/// *previous* day in UTC, so a deployment pinned to UTC midnight would start
/// after that morning's bearings and attribute them to nobody.
///
/// Until task 11.331 "local" meant *the phone that typed it*, which cost two
/// things: the row read as the neighboring day on a phone in another zone, and
/// a reader in another zone (the server, on UTC) took a bare day for a timed
/// end. **Since schema v20 "local" means the row's own zone** — the project's
/// zone at the moment the row was written (`Deployments.time_zone`) — and both
/// costs are gone for every row that carries one.
DateTime deploymentDateFor(DateTime at, [String? zone]) {
  final loc = FieldTimeZone.location(zone);
  if (loc == null) {
    final local = at.toLocal();
    return DateTime(local.year, local.month, local.day);
  }
  final wall = tz.TZDateTime.from(at, loc);
  return _startOfDay(loc, wall.year, wall.month, wall.day);
}

/// **The first instant of the day after the one [at] falls in**, read in
/// [zone] the way [deploymentDateFor] reads it — where a bare day's coverage
/// ends. Not "24 hours later": a day with a clock change is 23 or 25 hours.
DateTime deploymentNextDayFor(DateTime at, [String? zone]) {
  final loc = FieldTimeZone.location(zone);
  if (loc == null) {
    final local = at.toLocal();
    return DateTime(local.year, local.month, local.day + 1);
  }
  final wall = tz.TZDateTime.from(at, loc);
  final next = DateTime.utc(wall.year, wall.month, wall.day + 1);
  return _startOfDay(loc, next.year, next.month, next.day);
}

/// **The calendar date [at] falls on in [zone]**, as a plain local
/// `DateTime(y, m, d)` with no claim about any instant — what a date picker
/// takes as its initial date and what a screen formats as a day.
///
/// Formatting the stored instant directly would print the *reader's* date,
/// which is the bug task 11.331 exists to fix: an Arizona day read in London
/// after 5 p.m. would print as the next day.
DateTime fieldCalendarDate(DateTime at, [String? zone]) {
  final loc = FieldTimeZone.location(zone);
  if (loc == null) {
    final local = at.toLocal();
    return DateTime(local.year, local.month, local.day);
  }
  final wall = tz.TZDateTime.from(at, loc);
  return DateTime(wall.year, wall.month, wall.day);
}

/// **The wall-clock reading of [at] in [zone]**, as a plain local `DateTime`
/// with the field's year, month, day, hour and minute — what a screen formats
/// as "Oct 4, 14:32" for a timed swap, and what a time picker starts from.
DateTime fieldWallClock(DateTime at, [String? zone]) {
  final loc = FieldTimeZone.location(zone);
  if (loc == null) return at.toLocal();
  final wall = tz.TZDateTime.from(at, loc);
  return DateTime(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
  );
}

/// **The start of the calendar date [calendar] names, in [zone]** — the
/// inverse of [fieldCalendarDate]. A date picker hands back a plain local
/// `DateTime(y, m, d)`; only its year, month and day are read here, so a
/// picker on a phone in London choosing *4 October* for an Arizona project
/// stores the start of 4 October in Arizona.
DateTime fieldDayStart(DateTime calendar, [String? zone]) {
  final loc = FieldTimeZone.location(zone);
  if (loc == null) return DateTime(calendar.year, calendar.month, calendar.day);
  return _startOfDay(loc, calendar.year, calendar.month, calendar.day);
}

/// **The instant a field wall-clock reading names** — [wall]'s year, month,
/// day, hour and minute read in [zone]. The inverse of [fieldWallClock]; what
/// a swap time chosen on a time picker becomes.
///
/// A wall time that does not exist (inside a spring-forward gap) is rolled
/// forward by the tz package; one that happens twice (the autumn hour) is the
/// first of the two. Either way the result is one definite instant.
DateTime fieldInstant(DateTime wall, [String? zone]) {
  final loc = FieldTimeZone.location(zone);
  if (loc == null) {
    return DateTime(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
    );
  }
  final at = tz.TZDateTime(
    loc,
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
  );
  return DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch);
}

/// **Whether [end] is a moment or a bare day** — design §4a's distinction,
/// read off the value itself: a date-only end sits at the start of its day
/// **in the row's zone** ([zone]), because [deploymentDateFor] is the only
/// thing that writes one; anything else is a time somebody accepted on a swap.
///
/// With no zone (a row from before schema v20) the question is asked in this
/// process's zone, which is exact on the phone that wrote the row and is not
/// on any other — the cross-zone cost task 11.331 closed for every row that
/// carries a zone. The server never asks a zoneless row this question; see
/// `DeploymentInterlock.coverageEnd`.
///
/// ## Why the columns and not a flag — the wire decision §4a handed task 11.251
///
/// `attached_date` and `removed_date` have been declared as UTC instants
/// (`TextBound.timestamp`) since the table existed; the app merely never
/// wrote anything but midnights into them. Writing a real time on a swap is
/// therefore the app **widening what it writes back to what the column always
/// declared**, not a column given a new meaning — and it was measured before
/// it was decided: every reader in a build without this change gives a
/// correct-by-its-own-rule answer to a timed value. The only place two builds
/// disagree is on a *date-only* removal day — and that disagreement is the
/// bug that task fixed, not something the timed value introduced.
///
/// **The zone column, not a nullable instant column, is what closed the
/// cross-zone trigger** that task 11.251 and 11.263 named here (task 11.331):
/// with the row's zone known, "is this the start of its day" has one answer
/// on every device and on the server.
///
/// A swap recorded at exactly midnight in the field reads as a day. The
/// consequence is the safe one — the day is contested rather than
/// misattributed — and it is now one minute in a day *in the field*, not one
/// hour in 24 wherever the reader happens to be.
bool deploymentEndHasTime(DateTime end, [String? zone]) =>
    !deploymentDateFor(end, zone).isAtSameMomentAs(end);
