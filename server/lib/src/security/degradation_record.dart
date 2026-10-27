/// The record that survives the database (task 11.129).
///
/// ## The defect this exists for
///
/// A sign-in request answers `202 sent` whether or not a link was sent —
/// §4.5's byte-identical response, and it is load-bearing. `auth_routes.dart`
/// says in as many words that the operational visibility comes from the audit
/// log instead. **The audit log is a Postgres table.** So when Postgres is
/// gone: the person is told "sent", no link arrives, the audit write fails
/// too, and the entire surviving record was one line on stdout —
/// `audit log write failed: PgException`.
///
/// Neither half is wrong on its own. **The compensating control is
/// unavailable in exactly the failure it compensates for**, which is the same
/// family as a check that cannot distinguish success from its own failure.
///
/// ## What this is, and — more important — what it is not
///
/// **It is not a fallback audit log.** A second place events are written is a
/// second audit log, and two logs that disagree is a worse problem than one
/// that stops. This holds no events at all. It holds **the shape of the hole
/// in the audit log**: how many writes that log lost, on which days, and when
/// the first and last were. Those are facts *about* the audit log's gaps and
/// are disjoint from anything the audit log itself contains, so the two can
/// never contradict each other — there is no event here for a row over there
/// to disagree with.
///
/// ## What it contains, and this is a decision rather than a default
///
/// **It names nobody.** No email address, no user id, no device id, no source
/// address, no request id. Not because those would be hard to write, but for
/// three reasons in order of weight:
///
/// 1. **§4.7's rules are properties of the table, not of the project.** The
///    retention window, the purge sweep (`audit-retention`), the never-log
///    list enforced by the absence of a token column, and whatever erasure a
///    person is owed — all of that machinery reaches `auth_audit_log` and
///    reaches nothing on a filesystem. An address written here would have no
///    window, nothing sweeping it, and would outlive the account it names.
///    **Writing identifying data to the one place those rules cannot reach is
///    not a smaller version of the audit log; it is an unretained copy of it.**
/// 2. **A file's ownership has bitten this project twice** — task 11.70's
///    backup archive and task 11.125's freshness check, both cases where who
///    could read a path was not who anybody pictured. A file containing no
///    personal data is one where that question cannot cost anybody anything.
/// 3. **The question does not need a name to answer it.** The question is
///    *"was sign-in broken on Tuesday, and how badly?"* A per-day count and a
///    first/last timestamp answer it exactly. Knowing *who* could not sign in
///    would be interesting and is not what an operator does anything with:
///    the remedy for all of them is the same one remedy.
///
/// **There is deliberately no breakdown by event type either**, though it
/// would have been cheap. A gap here means the database was unreachable, which
/// means *every* authenticated route was refused — not some of them. A
/// breakdown would imply the outage was selective when it never is, and it is
/// the first step back toward being a second copy of the audit log.
///
/// The honest reading of the count, stated so nobody over-reads it: **it
/// counts audit writes the log lost, not people.** One person retrying six
/// times is six. It is a size, not a census.
///
/// ## What reads it, plainly
///
/// **Nothing pushes. There is no monitor.** Two things read it, and they are
/// both pull:
///
/// - **`server --degradation-report`**, a second mode of the same binary (the
///   shape `--health-check` and `audit-retention --check` already established,
///   and the reason it is not a script is that the runtime image has no shell
///   tooling and no Dart SDK). **It needs no database**, which is the entire
///   point: it answers during and after the outage.
/// - **`server --health-check`**, which the compose healthcheck already runs
///   every thirty seconds and whose output Docker keeps. It appends one
///   sentence when a loss was recorded in the last [recentWindow], so a
///   `docker compose ps` reading `healthy` still says the audit log lost
///   writes this morning. It does **not** report the container unhealthy for
///   it — a past gap is not a reason to restart anything.
///
/// Beyond that: **an operator who already suspects something.** Saying so is
/// the point; task 11.78's backup healthcheck that nothing consumed and task
/// 11.79's purge that nothing called are what this project gets when a record
/// implies a reader it does not have.
///
/// ## Why the file's existence is proven while things are healthy
///
/// [DegradationRecord.open] **writes the file on a healthy start**, before
/// anything has failed. A fallback whose own writability is first discovered
/// during the outage is the defect this task is about, one layer out; and a
/// reader finding no file would otherwise be unable to tell "nothing has ever
/// failed" from "the record could not be written" — a check that cannot
/// distinguish success from its own failure, again. With this, a missing file
/// means the server could not write one, and the startup log says so.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where the record lives when nothing says otherwise.
///
/// A path inside the container, backed by a **named Docker volume** rather
/// than a bind mount — see `docker-compose.yml`. That is deliberate: a bind
/// mount passes host ownership straight through on Linux, which is precisely
/// what made task 11.70's backup unwritable and task 11.125's two status
/// commands disagree. A named volume is owned by the container that writes it,
/// and there is no host user for it to be a stranger to.
const String defaultDegradationPath = '/var/lib/tritrack/degradation.json';

/// Environment variable naming an alternative path.
///
/// Exists so a bare-metal `dart run bin/server.dart` — and the tests — can put
/// the file somewhere writable. It is not a switch: there is no value that
/// turns the record off, because "the durable record was disabled in this
/// deployment" is the sentence nobody wants to read during an outage.
const String degradationPathVariable = 'TRITRACK_DEGRADATION_PATH';

/// How long after a loss `--health-check` keeps mentioning it.
///
/// **24 hours, chosen rather than inherited.** Long enough that a gap
/// overnight is still being reported when somebody looks in the morning;
/// short enough that the healthcheck does not nag forever about a gap from
/// March, which is how an operator learns to stop reading it. The full history
/// is always in `--degradation-report`, which is where a question about March
/// belongs.
const Duration recentWindow = Duration(hours: 24);

/// How many days of counts are kept.
///
/// The file is fixed-size by construction — this is the only thing in it that
/// grows, and it stops at 31. There is therefore no retention sweep to write
/// and none to forget to run, which given that this project has twice found a
/// sweep nothing called is worth more than a longer history. Days beyond this
/// are folded into [DegradationSnapshot.lostBeforeKeptDays] so the total stays
/// true.
const int keptDays = 31;

/// The current schema of the file. Bumped only if the shape changes; a reader
/// that does not recognise a version says so rather than guessing.
const int degradationSchemaVersion = 1;

/// What the file holds. Immutable; [DegradationRecord] owns the mutation.
class DegradationSnapshot {
  const DegradationSnapshot({
    required this.auditWritesLost,
    required this.firstLossAt,
    required this.lastLossAt,
    required this.lostByDay,
    required this.lostBeforeKeptDays,
    required this.lastStartedAt,
  });

  const DegradationSnapshot.empty()
    : auditWritesLost = 0,
      firstLossAt = null,
      lastLossAt = null,
      lostByDay = const {},
      lostBeforeKeptDays = 0,
      lastStartedAt = null;

  /// Total audit writes lost over the life of this file. **Writes, not
  /// people** — see this library's doc comment.
  final int auditWritesLost;

  final DateTime? firstLossAt;
  final DateTime? lastLossAt;

  /// `yyyy-mm-dd` (UTC) to count, newest [keptDays] days only.
  ///
  /// UTC, and not the host's zone, because the host's zone is a thing that
  /// can be changed by a container image update and would then silently
  /// re-date history.
  final Map<String, int> lostByDay;

  /// Losses whose day has aged out of [lostByDay]. Kept so
  /// [auditWritesLost] and the per-day counts can be reconciled by a reader
  /// rather than appearing to disagree.
  final int lostBeforeKeptDays;

  /// When the server last started successfully enough to write this file.
  /// A reader uses it to tell a live record from an abandoned one.
  final DateTime? lastStartedAt;

  Map<String, Object?> toJson() => {
    'schema': degradationSchemaVersion,
    'audit_writes_lost': auditWritesLost,
    'first_loss_at': firstLossAt?.toUtc().toIso8601String(),
    'last_loss_at': lastLossAt?.toUtc().toIso8601String(),
    'lost_by_day': lostByDay,
    'lost_before_kept_days': lostBeforeKeptDays,
    'last_started_at': lastStartedAt?.toUtc().toIso8601String(),
  };

  /// Reads a snapshot back. Returns null for anything unreadable, unparseable
  /// or of an unrecognised schema — a caller must say "cannot read it" rather
  /// than report zero losses, which would be the reassuring answer and the
  /// wrong one.
  static DegradationSnapshot? fromJson(Object? decoded) {
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['schema'] != degradationSchemaVersion) return null;
    final lost = decoded['audit_writes_lost'];
    if (lost is! int) return null;
    final byDay = <String, int>{};
    final rawDays = decoded['lost_by_day'];
    if (rawDays is Map) {
      for (final entry in rawDays.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is int) byDay[key] = value;
      }
    }
    DateTime? at(String field) {
      final raw = decoded[field];
      return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
    }

    final before = decoded['lost_before_kept_days'];
    return DegradationSnapshot(
      auditWritesLost: lost,
      firstLossAt: at('first_loss_at'),
      lastLossAt: at('last_loss_at'),
      lostByDay: byDay,
      lostBeforeKeptDays: before is int ? before : 0,
      lastStartedAt: at('last_started_at'),
    );
  }
}

/// UTC day key for [when], the key used by [DegradationSnapshot.lostByDay].
String degradationDayKey(DateTime when) {
  final utc = when.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$day';
}

/// Owns the file: accumulates losses in memory and persists them.
///
/// **Writes are coalesced, and the first loss of a burst is never coalesced.**
/// An outage produces one failed audit write per request, and a file write per
/// request during an outage is a second problem layered on the first. So the
/// first loss after a quiet period is flushed immediately — that is the one
/// that must survive if the process dies a moment later — and subsequent
/// losses are batched behind [_coalesce]. [close] flushes whatever is left.
class DegradationRecord {
  DegradationRecord._(this._file, this._state, {required this.onWriteFailure});

  /// Called with the failure's runtime type when the record itself cannot be
  /// written. Required, for the reason `AuthAuditLog.onError` is: a fallback
  /// that fails silently is worse than no fallback, because it is believed.
  final void Function(String) onWriteFailure;

  final File _file;
  DegradationSnapshot _state;
  Timer? _pending;
  bool _closed = false;

  static const Duration _coalesce = Duration(seconds: 5);

  /// The path the record uses, given an environment.
  static String pathFrom(Map<String, String> environment) {
    final configured = environment[degradationPathVariable];
    return configured == null || configured.trim().isEmpty
        ? defaultDegradationPath
        : configured.trim();
  }

  /// Opens (or creates) the record at [path], loading any existing history,
  /// stamping this start, and **writing the file straight away**.
  ///
  /// Returns null if the file cannot be written, having reported the failure
  /// type through [onWriteFailure]. A null return is a real answer the caller
  /// must surface at startup: it means this deployment has no durable record,
  /// and that is a fact worth knowing before the outage rather than during it.
  static Future<DegradationRecord?> open(
    String path, {
    required void Function(String) onWriteFailure,
    DateTime? startedAt,
  }) async {
    final file = File(path);
    var loaded = const DegradationSnapshot.empty();
    try {
      if (file.existsSync()) {
        final parsed = DegradationSnapshot.fromJson(
          jsonDecode(await file.readAsString()),
        );
        // An unreadable existing file is not a reason to refuse to record
        // anything from here on; it is a reason to start a fresh count, and
        // the caller is told through [onWriteFailure] that history was lost.
        if (parsed == null) {
          onWriteFailure('UnreadableExistingRecord');
        } else {
          loaded = parsed;
        }
      }
    } on Object catch (error) {
      onWriteFailure(error.runtimeType.toString());
    }

    final record = DegradationRecord._(
      file,
      DegradationSnapshot(
        auditWritesLost: loaded.auditWritesLost,
        firstLossAt: loaded.firstLossAt,
        lastLossAt: loaded.lastLossAt,
        lostByDay: loaded.lostByDay,
        lostBeforeKeptDays: loaded.lostBeforeKeptDays,
        lastStartedAt: (startedAt ?? DateTime.now()).toUtc(),
      ),
      onWriteFailure: onWriteFailure,
    );
    return record._write() ? record : null;
  }

  /// What the record currently says.
  DegradationSnapshot get snapshot => _state;

  /// One audit write was lost. Cheap and synchronous; never throws.
  void auditWriteLost({DateTime? at}) {
    if (_closed) return;
    final when = (at ?? DateTime.now()).toUtc();
    final key = degradationDayKey(when);
    final byDay = Map<String, int>.from(_state.lostByDay);
    byDay[key] = (byDay[key] ?? 0) + 1;

    // Trim to the newest [keptDays] keys. Lexicographic order is chronological
    // for `yyyy-mm-dd`, which is the reason for that format.
    var dropped = _state.lostBeforeKeptDays;
    if (byDay.length > keptDays) {
      final keys = byDay.keys.toList()..sort();
      for (final old in keys.take(byDay.length - keptDays)) {
        dropped += byDay.remove(old)!;
      }
    }

    final wasQuiet = _pending == null;
    _state = DegradationSnapshot(
      auditWritesLost: _state.auditWritesLost + 1,
      firstLossAt: _state.firstLossAt ?? when,
      lastLossAt: when,
      lostByDay: byDay,
      lostBeforeKeptDays: dropped,
      lastStartedAt: _state.lastStartedAt,
    );

    if (wasQuiet) {
      // The first loss of a burst goes to disk now: if this process dies in
      // the next second, "the audit log started losing writes at T" is the
      // one fact that has to have survived.
      _write();
      _pending = Timer(_coalesce, () {
        _pending = null;
        _write();
      });
    }
  }

  /// Flushes and stops coalescing.
  Future<void> close() async {
    _pending?.cancel();
    _pending = null;
    _write();
    _closed = true;
  }

  /// Atomic replace: write a sibling temp file, then rename over the target.
  /// A reader must never see a half-written record — and this file is read
  /// precisely when something has already gone wrong.
  bool _write() {
    final temp = File('${_file.path}.tmp');
    try {
      _file.parent.createSync(recursive: true);
      temp.writeAsStringSync('${jsonEncode(_state.toJson())}\n', flush: true);
      temp.renameSync(_file.path);
      return true;
    } on Object catch (error) {
      onWriteFailure(error.runtimeType.toString());
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on Object {
        // Nothing useful to do about a temp file we could not remove, and
        // throwing here would replace a logging problem with an outage.
      }
      return false;
    }
  }
}

/// What a reader of the file gets back, distinguishing the three states a
/// reader must not confuse: no file, an unreadable file, and a real record.
sealed class DegradationReading {
  const DegradationReading();
}

/// There is no file at the path.
///
/// **This is not "nothing has failed".** The server writes the file on a
/// healthy start, so an absent file means either the server has never started
/// with this path configured, or it could not write there.
class DegradationRecordMissing extends DegradationReading {
  const DegradationRecordMissing(this.path);
  final String path;
}

/// A file exists and could not be understood.
class DegradationRecordUnreadable extends DegradationReading {
  const DegradationRecordUnreadable(this.path, this.detail);
  final String path;

  /// The failure's runtime type, never the exception — the same rule the audit
  /// log's `onError` follows, and for the same reason.
  final String detail;
}

/// A file was read.
class DegradationRecordRead extends DegradationReading {
  const DegradationRecordRead(this.path, this.snapshot);
  final String path;
  final DegradationSnapshot snapshot;
}

/// Reads the record without needing a database — the property the whole design
/// turns on.
DegradationReading readDegradationRecord(String path) {
  final file = File(path);
  if (!file.existsSync()) return DegradationRecordMissing(path);
  try {
    final parsed = DegradationSnapshot.fromJson(
      jsonDecode(file.readAsStringSync()),
    );
    if (parsed == null) {
      return DegradationRecordUnreadable(path, 'UnrecognisedSchemaOrShape');
    }
    return DegradationRecordRead(path, parsed);
  } on Object catch (error) {
    return DegradationRecordUnreadable(path, error.runtimeType.toString());
  }
}

/// The full report, in the plain English an operator reads at the point they
/// already suspect something.
String describeDegradationRecord(DegradationReading reading) {
  switch (reading) {
    case DegradationRecordMissing(:final path):
      return 'No durable record at $path.\n'
          'This does NOT mean nothing has failed. The server writes this file '
          'on a healthy start, so an absent file means either this server has '
          'never started with that path, or it could not write there — its '
          'startup log says which. Set $degradationPathVariable to a writable '
          'path if this is not a container.';
    case DegradationRecordUnreadable(:final path, :final detail):
      return 'The record at $path could not be read ($detail).\n'
          'Treat the history as lost, not as empty.';
    case DegradationRecordRead(:final path, :final snapshot):
      final buffer = StringBuffer();
      final started = snapshot.lastStartedAt;
      buffer.writeln('Durable degradation record: $path');
      buffer.writeln(
        'Server last started: '
        '${started == null ? "unknown" : started.toIso8601String()}',
      );
      if (snapshot.auditWritesLost == 0) {
        buffer.write(
          'The audit log has lost no writes. Nothing here means sign-in has '
          'always worked — it means every audit write this server attempted '
          'reached the database.',
        );
        return buffer.toString();
      }
      buffer.writeln(
        'The audit log LOST ${snapshot.auditWritesLost} write(s) — '
        'first ${snapshot.firstLossAt?.toIso8601String()}, '
        'last ${snapshot.lastLossAt?.toIso8601String()}.',
      );
      buffer.writeln(
        'While that was happening the database was unreachable, so sign-in '
        'and sync were refused: a person asking for a sign-in link was still '
        'answered "sent" (that response is uniform on purpose) and no link '
        'was sent. This is a count of LOST AUDIT WRITES, not of people — one '
        'person retrying six times is six.',
      );
      buffer.writeln('By day (UTC):');
      final days = snapshot.lostByDay.keys.toList()..sort();
      for (final day in days) {
        buffer.writeln('  $day  ${snapshot.lostByDay[day]}');
      }
      if (snapshot.lostBeforeKeptDays > 0) {
        buffer.writeln(
          '  (a further ${snapshot.lostBeforeKeptDays} on days older than the '
          '$keptDays kept here)',
        );
      }
      buffer.write(
        'What to do: fix the database, then read auth_audit_log for the '
        'periods either side — the rows inside the window above do not exist '
        'and will not appear later.',
      );
      return buffer.toString();
  }
}

/// The one sentence `--health-check` appends, or null when there is nothing
/// recent to say.
///
/// Null for a missing or unreadable file on purpose: the healthcheck's job is
/// liveness, and a probe that started reporting on its own plumbing would
/// crowd out the finding it exists to carry. `--degradation-report` is where
/// those two states are stated.
String? recentDegradationSentence(DegradationReading reading, {DateTime? now}) {
  if (reading is! DegradationRecordRead) return null;
  final last = reading.snapshot.lastLossAt;
  if (last == null || reading.snapshot.auditWritesLost == 0) return null;
  final since = (now ?? DateTime.now()).toUtc().difference(last);
  if (since > recentWindow || since.isNegative) return null;
  return 'NOTE: the audit log lost ${reading.snapshot.auditWritesLost} '
      'write(s), most recently ${last.toIso8601String()} — the database was '
      'unreachable and sign-ins were refused while it lasted. Run '
      '`server --degradation-report` for the history. Not a reason to restart '
      'this container.';
}
