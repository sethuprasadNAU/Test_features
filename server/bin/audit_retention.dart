/// Applies §4.7's retention windows, and says how old the oldest surviving row
/// is (tasks 10.14 and 11.79).
///
/// ## Why this is a compiled entrypoint and not a README line
///
/// It used to be neither. `AuditRetentionService.purge()` worked and **nothing
/// called it**, so the windows in `server/README.md` described an intention
/// rather than what was on disk. That is task 11.78's finding one table over: a
/// control nothing runs is invisible, and the belief that it runs is the
/// damage.
///
/// The documented remedy was worse than absent — it was *wrong*.
/// `dart run bin/purge_audit_logs.dart`, offered as "e.g. a daily cron inside
/// the container", **cannot run in the shipped image at all**: `server/
/// Dockerfile` AOT-compiles `bin/server.dart` into a bare `debian-slim` with no
/// Dart SDK and no source. It worked on a developer's laptop and nowhere the
/// operator would ever be. So this file is compiled into the image beside the
/// server (task 11.70's class: a fix that travels with the repository beats a
/// step a human performs and nothing checks).
///
/// ## Three modes, and the third one is the point
///
///     tritrack-audit-retention              purge once, print what went
///     tritrack-audit-retention --schedule   the loop docker compose runs
///     tritrack-audit-retention --check      the measurement; exit 1 if over
///
/// `--check` reads **the age of the oldest surviving row**, and knows nothing
/// about whether the loop is running. That asymmetry is the whole design, and
/// it is task 11.78's, unchanged: a wedged scheduler, a container somebody
/// stopped, a database the purge cannot write to and a `.env` edited last month
/// all produce the same red, because to a person they are the same fact —
/// **we are still holding rows we said we would have deleted.** A check that
/// asked "is the scheduler up?" would have been green through every one of them.
///
/// ## Its last line is its finding (CLAUDE.md, established by task 11.69)
///
/// Docker keeps only the tail of a healthcheck's output. So the last thing
/// every mode prints is what it found — an age, or a count — never its own
/// name.
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:tritrack_server/tritrack_server.dart';

/// How long past its window a row may survive before that is a fault.
///
/// **Not zero, and the reason is the same one that put 48h between task 11.78's
/// 24h backup interval and its 48h staleness limit.** The sweep runs on an
/// interval, so between runs a row legitimately sits a few hours past its
/// window; a check with no grace would be red for part of every day and would
/// therefore be ignored, which is the only failure mode that puts us back where
/// this started. Two days of grace on a 30-day window is a schedule that has
/// stopped, not a schedule that is late.
Duration get _grace => Duration(
  hours:
      int.tryParse(
        Platform.environment['TRITRACK_AUDIT_RETENTION_GRACE_HOURS'] ?? '',
      ) ??
      48,
);

/// How often the loop wakes. Hourly by default: the answer changes on the day
/// scale, and a tighter loop would spend a database connection for nothing.
Duration get _checkInterval => Duration(
  seconds:
      int.tryParse(
        Platform.environment['TRITRACK_AUDIT_RETENTION_CHECK_SECONDS'] ?? '',
      ) ??
      3600,
);

Future<void> main(List<String> args) async {
  final mode = switch (args) {
    [] || ['--once'] => _Mode.once,
    ['--schedule'] => _Mode.schedule,
    ['--check'] => _Mode.check,
    _ => null,
  };
  if (mode == null) {
    stderr.writeln(
      'usage: tritrack-audit-retention [--once | --schedule | --check]',
    );
    exitCode = 64;
    return;
  }

  if (mode == _Mode.schedule) {
    await _scheduleForever();
    return;
  }

  final connection = await _connect();
  if (connection == null) {
    exitCode = 1;
    return;
  }
  try {
    if (mode == _Mode.once) {
      await _purgeOnce(connection);
    } else {
      exitCode = await _report(connection) ? 0 : 1;
    }
  } finally {
    await connection.close();
  }
}

enum _Mode { once, schedule, check }

/// Opens a connection and drops to the app role.
///
/// Returns null having already explained itself. **"I cannot reach the
/// database" is its own outcome**, never reported as "nothing is over its
/// window" — a check that cannot measure must not answer green, which is the
/// difference between a check and a decoration.
Future<Connection?> _connect() async {
  try {
    final config = DatabaseConfig.fromEnvironment();
    final connection = await Connection.open(
      config.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    // Task 10.63: this does not stay the admin `config.username` (a superuser)
    // any further than opening the connection.
    //
    // **But not `tritrack_app`, and that correction is task 11.79's third
    // finding.** The entrypoint this replaces demoted itself to the app role
    // with a comment saying the DML it holds already covered the deletes — true
    // when written, false from the moment task 10.83 revoked `DELETE` on both
    // audit tables from the role every network-facing connection runs as.
    // **Nothing noticed, because nothing ran it.** Watched on a real stack:
    // `permission denied for table auth_audit_log`.
    //
    // `tritrack_retention` is the narrower credential `ensureServerAppRole`'s
    // own comment said this would need — read and delete on three tables and
    // nothing else — so 10.83's property survives: the server's own connection
    // still cannot erase the record of itself.
    //
    // Ensured here, not only from [PostgresMigrations.run], because this is a
    // standalone entrypoint that may run before the server process ever has
    // against this database.
    await ensureAuditRetentionRole(connection);
    await assumeAuditRetentionRole(connection);
    return connection;
  } on Object catch (error) {
    // The type only — never the error, which can carry the connection string
    // (§4.7 rule 5).
    stderr.writeln(
      'AUDIT RETENTION UNKNOWN — no database available (${error.runtimeType}), '
      'so the age of the oldest surviving row cannot be measured. This does '
      'NOT say the windows are being applied, and it does not say they are '
      'not.',
    );
    return null;
  }
}

Future<void> _purgeOnce(Connection connection) async {
  try {
    final sweep = await AuditRetentionService(connection).purge();
    for (final rc in retentionClasses) {
      final n = sweep[rc.key];
      stdout.writeln(
        'Deleted $n ${n == 1 ? 'row' : 'rows'} from ${rc.table} — '
        '${rc.rows} older than ${rc.window.inDays} days.',
      );
    }
    stdout.writeln(
      'Purged ${sweep.total} ${sweep.total == 1 ? 'row' : 'rows'} past their '
      'retention window.',
    );
  } on Object catch (error) {
    stderr.writeln(
      'PURGE FAILED (${error.runtimeType}) — nothing was deleted.',
    );
    exitCode = 1;
  }
}

/// Prints the age of the oldest surviving row in every class.
///
/// Returns whether everything is inside its window plus the grace.
Future<bool> _report(Connection connection) async {
  final List<RetentionReading> readings;
  try {
    readings = await AuditRetentionService(connection).measure();
  } on Object catch (error) {
    stderr.writeln(
      'AUDIT RETENTION UNKNOWN — the oldest-row query failed '
      '(${error.runtimeType}). Nothing here says whether the windows are '
      'being applied.',
    );
    return false;
  }

  final now = DateTime.now().toUtc();
  final grace = _grace;
  final over = <String>[];
  for (final reading in readings) {
    final rc = reading.retentionClass;
    final age = reading.ageAt(now);
    if (age == null) {
      // **Empty is healthy here, and that is the one place this differs from
      // task 11.78's freshness check.** An empty backup directory means every
      // observation exists only on the phones that recorded it; an empty audit
      // table means there is nothing here to leak.
      stdout.writeln(
        '${rc.table}: no ${rc.rows} held at all — nothing to prune.',
      );
      continue;
    }
    final limit = rc.window + grace;
    final verdict = age > limit ? 'PAST ITS' : 'within the';
    stdout.writeln(
      '${rc.table}: oldest of ${rc.rows} is ${age.inDays}d '
      '(${age.inHours}h) old — $verdict ${rc.window.inDays}-day window '
      '(+${grace.inHours}h grace).',
    );
    if (age > limit) {
      over.add(
        '${age.inDays}-day-old ${rc.rows} in ${rc.table} '
        '(window ${rc.window.inDays} days)',
      );
    }
  }

  if (over.isEmpty) {
    stdout.writeln(
      'RETENTION IS BEING APPLIED — nothing on this server is past its '
      'window.',
    );
    return true;
  }
  stdout.writeln(
    'RETENTION HAS STOPPED BEING APPLIED — this server is still holding '
    '${over.join('; ')}. Those rows carry researcher email addresses and '
    'device identifiers past the window that justified keeping them, and the '
    'sweep that should have deleted them has not run.',
  );
  return false;
}

/// The loop `docker compose up` starts.
///
/// ## It decides by the rows, not by its own clock
///
/// The loop does not remember when it last ran. Every wake-up it measures, and
/// purges when something is past its window. Three things follow, and they are
/// the reason for the design rather than side effects:
///
///   - a container restarted five times an hour does not sweep five times;
///   - a machine switched off for a month sweeps immediately on return, rather
///     than waiting for the next tick;
///   - somebody who runs `--once` by hand has genuinely satisfied the schedule,
///     because the schedule is a statement about rows and not about this
///     process.
///
/// ## It stays running when it is failing
///
/// A failed sweep logs loudly and the loop continues. It must NOT exit: a
/// stopped container has no healthcheck, so exiting on failure would replace a
/// red signal with no signal — the exact shape of the defect this file exists
/// to end.
/// How long to wait after a cycle that could not sweep.
///
/// Sooner than a successful cycle, and **the first boot of a new deployment is
/// why** — observed on a real stack, not theorised. `docker compose up` starts
/// this container and the server at the same time, so the very first sweep can
/// land before the server has created a single table, and the loop's answer is
/// correctly "I could not measure". Waiting a full hour to find out that fixed
/// itself in seconds would leave a fresh deployment red over nothing. Task
/// 11.78's scheduler caps its retry the same way, for the same reason.
Duration _retryAfter(Duration interval) =>
    interval > const Duration(seconds: 300)
    ? const Duration(seconds: 300)
    : interval;

Future<void> _scheduleForever() async {
  final interval = _checkInterval;
  stdout.writeln(
    'tritrack-audit-retention: sweeping whenever a row passes its window; '
    'checked every ${interval.inSeconds}s. Windows: '
    '${retentionClasses.map((c) => '${c.table} ${c.window.inDays}d').join(', ')}. '
    'Staleness is reported separately at +${_grace.inHours}h grace — that is '
    'the number the healthcheck uses.',
  );

  while (true) {
    final stamp = DateTime.now().toUtc().toIso8601String();
    var failed = false;
    final connection = await _connect();
    if (connection != null) {
      try {
        final sweep = await AuditRetentionService(connection).purge();
        stdout.writeln(
          '--- $stamp swept ${sweep.total} '
          '${sweep.total == 1 ? 'row' : 'rows'} past their window.',
        );
        // The last thing each cycle prints is the finding, not the schedule's
        // name — `docker compose logs` is one of the two places a person ever
        // sees this, and a tail ending in "swept 0 rows" says less than one
        // ending in the age of what is still held.
        await _report(connection);
      } on Object catch (error) {
        failed = true;
        stderr.writeln(
          'SWEEP FAILED (${error.runtimeType}) — nothing was deleted this '
          'cycle. This container stays up so the healthcheck keeps reporting '
          'the age of the oldest surviving row; it will try again in '
          '${_retryAfter(interval).inSeconds}s.',
        );
      } finally {
        await connection.close();
      }
    } else {
      failed = true;
    }
    await Future<void>.delayed(failed ? _retryAfter(interval) : interval);
  }
}
